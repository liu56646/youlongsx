/*
 * Goldfish framebuffer -> frame.shm bridge.
 *
 * p9/p71 use the ranchu goldfish_fb device instead of virtio-gpu. gfxstream's
 * post callback is therefore never called, so the frame relay would stay at
 * seq=0 forever. This small DisplayChangeListener converts the goldfish_fb
 * surface to RGBA8888 and publishes it through the same shared memory protocol
 * used by vmhost_gfx_glue.cpp.
 *
 * It is only active when VMHOST_GOLDFISH_FB=1 is present in QEMU's
 * environment; p11/p13 continue to use the virtio-gpu/gfxstream path.
 */

#include "qemu/osdep.h"
#include "ui/console.h"
#include "vm_frame_shm.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static int s_shm_fd = -1;
static VmFrameShmHeader *s_shm;
static size_t s_shm_len;
static uint8_t *s_frame;
static int s_width;
static int s_height;
static bool s_attached;

static void shm_close_locked(void)
{
    if (s_shm != NULL) {
        munmap(s_shm, s_shm_len);
        s_shm = NULL;
    }
    if (s_shm_fd >= 0) {
        close(s_shm_fd);
        s_shm_fd = -1;
    }
    s_shm_len = 0;
}

static bool shm_open_locked(int width, int height)
{
    const char *dir = getenv("VMHOST_FRAME_DIR");
    char path[1024];
    size_t stride;
    size_t total;
    size_t map_len;
    struct stat st;
    void *map;
    VmFrameShmHeader *header;

    if (dir == NULL || dir[0] == '\0' ||
        width <= 0 || height <= 0 ||
        width > 8192 || height > 8192) {
        return false;
    }
    if (snprintf(path, sizeof(path), "%s/frame.shm", dir) >= (int) sizeof(path)) {
        return false;
    }

    stride = (size_t) width * (size_t) height * 4u;
    stride = (stride + 4095u) & ~(size_t) 4095u;
    if (stride < 4096u) {
        stride = 4096u;
    }
    total = vm_frame_shm_total((uint32_t) stride);

    const int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) {
        fprintf(stderr, "VMHOSTGFB: open %s failed: %s\n", path, strerror(errno));
        return false;
    }
    if (fstat(fd, &st) != 0) {
        fprintf(stderr, "VMHOSTGFB: size %s failed: %s\n", path, strerror(errno));
        close(fd);
        return false;
    }
    if ((size_t) st.st_size < total) {
        if (ftruncate(fd, (off_t) total) != 0) {
            fprintf(stderr, "VMHOSTGFB: size %s failed: %s\n", path, strerror(errno));
            close(fd);
            return false;
        }
        st.st_size = (off_t) total;
    }

    /* 关键：文件可能由上一个分辨率更大的 VM 留下（例如 720x1280 的
       frame.shm 被 800x600 的 p71 复用）。header 里的 stride_cap 仍是
       较大值，写入端按它算 slot 偏移；因此 mmap 必须覆盖整个文件，
       不能只映射本次计算出的 total，否则第 2/3 个缓冲会越界。 */
    map_len = (size_t) st.st_size;
    map = mmap(NULL, map_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        fprintf(stderr, "VMHOSTGFB: mmap %s failed: %s\n", path, strerror(errno));
        close(fd);
        return false;
    }

    header = (VmFrameShmHeader *) map;
    const bool layout_ok =
        header->magic == VM_FRAME_SHM_MAGIC &&
        header->version == VM_FRAME_SHM_VERSION &&
        header->nbufs == VM_FRAME_SHM_NBUFS &&
        header->stride_cap >= stride;

    if (layout_ok) {
        const size_t header_total =
            vm_frame_shm_total(header->stride_cap);
        if (map_len < header_total) {
            munmap(map, map_len);
            if (ftruncate(fd, (off_t) header_total) != 0) {
                fprintf(stderr, "VMHOSTGFB: grow %s failed: %s\n",
                        path, strerror(errno));
                close(fd);
                return false;
            }
            map_len = header_total;
            map = mmap(NULL, map_len, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, 0);
            if (map == MAP_FAILED) {
                fprintf(stderr, "VMHOSTGFB: mmap %s failed: %s\n",
                        path, strerror(errno));
                close(fd);
                return false;
            }
            header = (VmFrameShmHeader *) map;
        }
        /* A new VM process starts a new frame sequence. */
        header->disp_w = (uint32_t) width;
        header->disp_h = (uint32_t) height;
        header->seq = 0;
        header->slot = 0;
        header->width = 0;
        header->height = 0;
    } else {
        memset(header, 0, sizeof(*header));
        header->version = VM_FRAME_SHM_VERSION;
        header->nbufs = VM_FRAME_SHM_NBUFS;
        header->stride_cap = (uint32_t) stride;
        header->disp_w = (uint32_t) width;
        header->disp_h = (uint32_t) height;
        header->seq = 0;
        header->slot = 0;
        __atomic_thread_fence(__ATOMIC_RELEASE);
        header->magic = VM_FRAME_SHM_MAGIC;
    }

    s_shm_fd = fd;
    s_shm = header;
    s_shm_len = map_len;
    fprintf(stderr, "VMHOSTGFB: frame.shm ready %dx%d stride=%u map=%zu\n",
            width, height, header->stride_cap, map_len);
    return true;
}

static inline uint32_t to_rgba8888(uint32_t px, pixman_format_code_t format)
{
    const int bpp = PIXMAN_FORMAT_BPP(format);

    if (bpp == 32) {
        return 0xFF000000u
             | ((px & 0x000000FFu) << 16)
             | (px & 0x0000FF00u)
             | ((px & 0x00FF0000u) >> 16);
    }
    if (bpp == 16) {
        const uint32_t r5 = (px >> 11) & 0x1Fu;
        const uint32_t g6 = (px >> 5) & 0x3Fu;
        const uint32_t b5 = px & 0x1Fu;
        return 0xFF000000u
             | ((r5 << 3 | r5 >> 2) << 16)
             | ((g6 << 2 | g6 >> 4) << 8)
             | (b5 << 3 | b5 >> 2);
    }
    return 0xFF000000u | (px & 0x00FFFFFFu);
}

static void copy_rect(DisplaySurface *surface, int x, int y, int w, int h)
{
    const int sw = surface_width(surface);
    const int src_stride = surface_stride(surface);
    const pixman_format_code_t format = surface_format(surface);
    const int bytes = PIXMAN_FORMAT_BPP(format) / 8;
    const uint8_t *src;
    uint8_t *dst;

    if ((bytes != 2 && bytes != 4) ||
        x < 0 || y < 0 || x + w > sw || y + h > s_height) {
        return;
    }

    src = (const uint8_t *) pixman_image_get_data(surface->image);
    dst = s_frame;
    for (int row = 0; row < h; row++) {
        const uint8_t *s = src + (size_t) (y + row) * src_stride +
                           (size_t) x * bytes;
        uint32_t *d = (uint32_t *) (void *) (
            dst + (size_t) (y + row) * (size_t) s_width * 4u +
            (size_t) x * 4u);

        for (int col = 0; col < w; col++) {
            uint32_t px = 0;
            memcpy(&px, s + (size_t) col * bytes, bytes);
            d[col] = to_rgba8888(px, format);
        }
    }
}

static void publish_frame_locked(void)
{
    const size_t need = (size_t) s_width * (size_t) s_height * 4u;
    uint32_t next;
    uint32_t slot;
    uint8_t *dst;

    if (s_shm == NULL || need > s_shm->stride_cap) {
        return;
    }
    next = s_shm->seq + 1u;
    slot = next % VM_FRAME_SHM_NBUFS;
    dst = vm_frame_shm_buf(s_shm, slot);
    memcpy(dst, s_frame, need);
    s_shm->slot = slot;
    s_shm->width = (uint32_t) s_width;
    s_shm->height = (uint32_t) s_height;
    s_shm->format = 0;
    __atomic_thread_fence(__ATOMIC_RELEASE);
    __atomic_store_n(&s_shm->seq, next, __ATOMIC_RELEASE);
}

static void goldfish_fb_update(DisplayChangeListener *dcl,
                               int x, int y, int w, int h)
{
    DisplaySurface *surface = qemu_console_surface(dcl->con);
    const int sw = surface ? surface_width(surface) : 0;
    const int sh = surface ? surface_height(surface) : 0;

    if (surface == NULL || surface->image == NULL ||
        pixman_image_get_data(surface->image) == NULL ||
        sw <= 0 || sh <= 0) {
        return;
    }

    pthread_mutex_lock(&s_lock);
    if (s_frame == NULL || s_width != sw || s_height != sh) {
        g_free(s_frame);
        s_frame = g_malloc0((size_t) sw * (size_t) sh * 4u);
        s_width = sw;
        s_height = sh;
        shm_close_locked();
    }
    if (s_shm == NULL && !shm_open_locked(sw, sh)) {
        pthread_mutex_unlock(&s_lock);
        return;
    }

    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > sw) { w = sw - x; }
    if (y + h > sh) { h = sh - y; }
    if (w > 0 && h > 0) {
        copy_rect(surface, x, y, w, h);
        publish_frame_locked();
    }
    pthread_mutex_unlock(&s_lock);
}

static void goldfish_fb_switch(DisplayChangeListener *dcl,
                               DisplaySurface *surface)
{
    const int sw = surface ? surface_width(surface) : 0;
    const int sh = surface ? surface_height(surface) : 0;

    /* 分辨率切换后先整帧重画，避免旧尺寸残留或首帧丢失。 */
    if (sw > 0 && sh > 0) {
        goldfish_fb_update(dcl, 0, 0, sw, sh);
    }
}

static const DisplayChangeListenerOps goldfish_fb_ops = {
    .dpy_name = "vmhost-goldfish-fb",
    .dpy_gfx_update = goldfish_fb_update,
    .dpy_gfx_switch = goldfish_fb_switch,
};

static DisplayChangeListener goldfish_fb_dcl = {
    .update_interval = 16,
    .ops = &goldfish_fb_ops,
};

void vmhost_goldfish_fb_attach(QemuConsole *con);

void vmhost_goldfish_fb_attach(QemuConsole *con)
{
    const char *enabled = getenv("VMHOST_GOLDFISH_FB");

    if (enabled == NULL || strcmp(enabled, "1") != 0 ||
        s_attached || con == NULL) {
        return;
    }
    s_attached = true;
    goldfish_fb_dcl.con = con;
    register_displaychangelistener(&goldfish_fb_dcl);
    fprintf(stderr, "VMHOSTGFB: attached to graphic console %p\n", (void *) con);

    /* 首帧可能在 relay 进程第一次 mmap 之前就已经画好；注册完成后主动
       整帧发布一次，静态开机画面才不会一直黑着。 */
    {
        DisplaySurface *surface = qemu_console_surface(con);
        if (surface != NULL) {
            goldfish_fb_update(&goldfish_fb_dcl, 0, 0,
                               surface_width(surface), surface_height(surface));
        }
    }
}
