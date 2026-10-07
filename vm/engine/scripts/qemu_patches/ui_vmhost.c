/*
 * vmhost 显示后端（QEMU 侧实现）
 * ==============================
 *
 * 这是本项目的自定义 QEMU 显示后端：把访客帧缓冲直接留在同进程内存里，
 * 交给引擎用 EGL/OpenGL ES 上屏。参考架构（光速虚拟机那类）走的也是这条路，
 * 而不是子进程 + VNC/共享内存。
 *
 * 接入方式（由 engine/scripts/build_qemu.sh 幂等施加）：
 *   1. 本文件被拷到 <qemu>/ui/vmhost.c，并加进 ui/meson.build 的 system_ss
 *   2. ui/console.c 的 graphic_console_init() 末尾插入一行 vmhost_display_attach(s)
 *
 * 为什么挂在 graphic_console_init()：
 *   console.c 里所有 dpy_* 通知都会先做 `if (con != dcl->con) continue`，
 *   所以 DCL 必须绑定到具体 QemuConsole；graphic_console_init() 正是
 *   控制台创建完成的时机，也是能拿到 QemuConsole* 的地方。
 */

#include "qemu/osdep.h"
#include "sysemu/runstate.h"
#include "ui/console.h"
#include "ui/surface.h"
#include "ui/input.h"
#include "ui/vmhost_display.h"
#include "ui/vmhost_input.h"
#include "ui/vmhost_control.h"

#include <pthread.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* 帧缓冲                                                              */
/* ------------------------------------------------------------------ */

static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;

static uint8_t  *s_pixels;      /* RGBA8888，stride == width * 4 */
static int       s_width;
static int       s_height;
static uint64_t  s_seq;

static bool ensure_buffer(int width, int height)
{
    if (width <= 0 || height <= 0) {
        return false;
    }

    pthread_mutex_lock(&s_lock);
    if (s_pixels != NULL && s_width == width && s_height == height) {
        pthread_mutex_unlock(&s_lock);
        return true;
    }

    uint8_t *fresh = g_try_malloc0((size_t) width * (size_t) height * 4u);
    if (fresh == NULL) {
        pthread_mutex_unlock(&s_lock);
        return false;
    }

    g_free(s_pixels);
    s_pixels = fresh;
    s_width = width;
    s_height = height;
    s_seq = 0;
    pthread_mutex_unlock(&s_lock);
    return true;
}

/*
 * 把源像素转成 RGBA8888。
 *
 * QEMU 的控制台表面在 32bpp 下基本是 x8r8g8b8 / a8r8g8b8：
 * 小端内存里是 B,G,R,X。目标布局是 R,G,B,A，所以需要交换 R/B 并补 alpha。
 * 16bpp 的 r5g6b5 也一并支持；其它格式记录一次警告后按 32bpp 处理。
 */
static inline uint32_t to_rgba8888(uint32_t px, pixman_format_code_t fmt)
{
    const int bpp = PIXMAN_FORMAT_BPP(fmt);

    if (bpp == 32) {
        return 0xFF000000u
             | ((px & 0x000000FFu) << 16)   /* B -> R 位 */
             | (px & 0x0000FF00u)           /* G 不动 */
             | ((px & 0x00FF0000u) >> 16);  /* R -> B 位 */
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

static void copy_rect(const uint8_t *src, int src_stride, pixman_format_code_t fmt,
                      uint8_t *dst, int dst_stride, int w, int h)
{
    const int src_bytes = PIXMAN_FORMAT_BPP(fmt) / 8;

    for (int row = 0; row < h; row++) {
        const uint8_t *s = src + (size_t) row * src_stride;
        uint32_t *d = (uint32_t *) (void *) (dst + (size_t) row * dst_stride);

        for (int col = 0; col < w; col++) {
            uint32_t px = 0;
            switch (src_bytes) {
            case 4:
                memcpy(&px, s + (size_t) col * 4, 4);
                break;
            case 2: {
                uint16_t p16 = 0;
                memcpy(&p16, s + (size_t) col * 2, 2);
                px = p16;
                break;
            }
            default:
                px = 0;
                break;
            }
            d[col] = to_rgba8888(px, fmt);
        }
    }
}

/* ------------------------------------------------------------------ */
/* DisplayChangeListener                                              */
/* ------------------------------------------------------------------ */

static void vmhost_gfx_switch(DisplayChangeListener *dcl,
                              struct DisplaySurface *new_surface)
{
    if (new_surface == NULL) {
        return;
    }
    ensure_buffer(surface_width(new_surface), surface_height(new_surface));
}

static void vmhost_gfx_update(DisplayChangeListener *dcl,
                              int x, int y, int w, int h)
{
    DisplaySurface *surface = qemu_console_surface(dcl->con);
    if (surface == NULL) {
        return;
    }

    const int sw = surface_width(surface);
    const int sh = surface_height(surface);
    if (!ensure_buffer(sw, sh)) {
        return;
    }

    /* 裁剪到画面范围内 */
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > sw) { w = sw - x; }
    if (y + h > sh) { h = sh - y; }
    if (w <= 0 || h <= 0) {
        return;
    }

    const uint8_t *src = (const uint8_t *) pixman_image_get_data(surface->image);
    const int src_stride = surface_stride(surface);
    const pixman_format_code_t fmt = surface_format(surface);

    pthread_mutex_lock(&s_lock);
    if (s_pixels != NULL && s_width == sw && s_height == sh) {
        copy_rect(src + (size_t) y * src_stride + (size_t) x * (PIXMAN_FORMAT_BPP(fmt) / 8),
                  src_stride, fmt,
                  s_pixels + (size_t) y * s_width * 4u + (size_t) x * 4u, s_width * 4,
                  w, h);
        s_seq++;
    }
    pthread_mutex_unlock(&s_lock);
}

static const DisplayChangeListenerOps vmhost_dcl_ops = {
    .dpy_name        = "vmhost",
    .dpy_gfx_update  = vmhost_gfx_update,
    .dpy_gfx_switch  = vmhost_gfx_switch,
};

static DisplayChangeListener vmhost_dcl = {
    .update_interval = 16,   /* ms */
    .ops             = &vmhost_dcl_ops,
};

static QemuConsole *s_con;
static bool s_attached;

/* ui/console.c 的 graphic_console_init() 会调用本函数；
   先给出前置声明，既满足 -Wmissing-prototypes，也便于阅读依赖方向。 */
void vmhost_display_attach(QemuConsole *con);

/** 由 ui/console.c 的 graphic_console_init() 调用。 */
void vmhost_display_attach(QemuConsole *con)
{
    if (s_attached || con == NULL) {
        return;
    }
    s_attached = true;
    s_con = con;
    vmhost_dcl.con = con;
    register_displaychangelistener(&vmhost_dcl);
}

/* ------------------------------------------------------------------ */
/* 对引擎暴露的接口（见 include/ui/vmhost_display.h）                   */
/* ------------------------------------------------------------------ */

bool vmhost_display_copy_frame(uint8_t *dst, size_t cap,
                               int *width, int *height, uint64_t *seq)
{
    bool ok = false;

    if (dst == NULL) {
        return false;
    }

    pthread_mutex_lock(&s_lock);
    if (s_pixels != NULL && s_seq > 0) {
        const size_t need = (size_t) s_width * (size_t) s_height * 4u;
        if (cap >= need) {
            memcpy(dst, s_pixels, need);
            if (width)  { *width  = s_width; }
            if (height) { *height = s_height; }
            if (seq)    { *seq    = s_seq; }
            ok = true;
        }
    }
    pthread_mutex_unlock(&s_lock);

    return ok;
}

bool vmhost_display_get_size(int *width, int *height)
{
    bool ok;

    pthread_mutex_lock(&s_lock);
    ok = (s_pixels != NULL && s_seq > 0);
    if (ok) {
        if (width)  { *width  = s_width; }
        if (height) { *height = s_height; }
    }
    pthread_mutex_unlock(&s_lock);

    return ok;
}

/* ------------------------------------------------------------------ */
/* 输入注入（见 include/ui/vmhost_input.h）                            */
/* ------------------------------------------------------------------ */

/*
 * Android AKEYCODE_* → Linux 键码。
 *
 * QEMU 自带 linux_to_qcode 映射表，所以这里只需要做 Android→Linux 这一层。
 * 只覆盖虚拟机常用的按键；未列出的按键会被忽略（便于排查时看日志）。
 */
static int android_keycode_to_linux(int keycode)
{
    switch (keycode) {
    case 3:   return 172;  /* HOME        -> KEY_HOMEPAGE   */
    case 4:   return 158;  /* BACK        -> KEY_BACK       */
    case 19:  return 103;  /* DPAD_UP     -> KEY_UP         */
    case 20:  return 108;  /* DPAD_DOWN   -> KEY_DOWN       */
    case 21:  return 105;  /* DPAD_LEFT   -> KEY_LEFT       */
    case 22:  return 106;  /* DPAD_RIGHT  -> KEY_RIGHT      */
    case 23:  return 28;   /* DPAD_CENTER -> KEY_ENTER      */
    case 24:  return 115;  /* VOLUME_UP   -> KEY_VOLUMEUP   */
    case 25:  return 114;  /* VOLUME_DOWN -> KEY_VOLUMEDOWN */
    case 26:  return 116;  /* POWER       -> KEY_POWER      */
    case 61:  return 15;   /* TAB         -> KEY_TAB        */
    case 62:  return 57;   /* SPACE       -> KEY_SPACE      */
    case 66:  return 28;   /* ENTER       -> KEY_ENTER      */
    case 67:  return 111;  /* DEL         -> KEY_DELETE     */
    case 82:  return 139;  /* MENU        -> KEY_MENU       */
    case 84:  return 217;  /* SEARCH      -> KEY_SEARCH     */
    case 111: return 1;    /* ESCAPE      -> KEY_ESC        */
    case 187: return 580;  /* APP_SWITCH  -> KEY_APPSELECT  */
    default:  return -1;
    }
}

/* 每个 slot 一个 tracking_id：QEMU 靠它把同一次接触的 begin/data/end 串起来 */
static int s_tracking_id[VMHOST_TOUCH_SLOTS];
static int s_next_tracking_id = 1;

static int alloc_tracking_id(void)
{
    if (s_next_tracking_id <= 0 || s_next_tracking_id > 0x7FFF) {
        s_next_tracking_id = 1;
    }
    return s_next_tracking_id++;
}

void vmhost_input_touch(int slot, int x, int y, int max_x, int max_y, bool down)
{
    if (s_con == NULL || slot < 0 || slot >= VMHOST_TOUCH_SLOTS) {
        return;
    }
    if (max_x <= 0 || max_y <= 0) {
        return;
    }

    int tid = s_tracking_id[slot];

    if (tid <= 0) {
        if (!down) {
            return;             /* 没有按下过，忽略孤立的抬起 */
        }
        tid = alloc_tracking_id();
        s_tracking_id[slot] = tid;
        /* 新接触：MT-B 语义下的 begin + tracking_id */
        qemu_input_queue_mtt(s_con, INPUT_MULTI_TOUCH_TYPE_BEGIN, slot, tid);
    }

    /* 位置数据：按下与移动都发 data */
    qemu_input_queue_mtt_abs(s_con, INPUT_AXIS_X, x, 0, max_x, slot, tid);
    qemu_input_queue_mtt_abs(s_con, INPUT_AXIS_Y, y, 0, max_y, slot, tid);

    if (!down) {
        qemu_input_queue_mtt(s_con, INPUT_MULTI_TOUCH_TYPE_END, slot, tid);
        s_tracking_id[slot] = 0;
    }

    qemu_input_event_sync();
}

void vmhost_input_key(int android_keycode, bool down)
{
    if (s_con == NULL) {
        return;
    }

    const int linux_key = android_keycode_to_linux(android_keycode);
    if (linux_key < 0) {
        return;   /* 未映射的按键 */
    }

    const int qcode = qemu_input_linux_to_qcode((unsigned int) linux_key);
    if (qcode <= 0) {   /* Q_KEY_CODE_UNMAPPED == 0 */
        return;
    }

    qemu_input_event_send_key_qcode(s_con, (QKeyCode) qcode, down);
    qemu_input_event_sync();
}

/* ------------------------------------------------------------------ */
/* 生命周期控制（见 include/ui/vmhost_control.h）                       */
/* ------------------------------------------------------------------ */

void vmhost_control_request_shutdown(void)
{
    /*
     * 与收到 SIGTERM 走同一条路：runstate.c 里 main_loop_should_exit() 会
     * 看到 shutdown_requested 并返回 true，主循环随即退出。
     * 用的是 SHUTDOWN_CAUSE_HOST_SIGNAL，不会去等访客响应 ACPI 关机。
     */
    qemu_system_shutdown_request(SHUTDOWN_CAUSE_HOST_SIGNAL);
}
