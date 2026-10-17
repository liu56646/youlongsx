/*
 * 帧回传客户端（B1 子进程模式）—— 实现。
 *
 * 协议见 vm_frame_relay.h。这里只做三件事：
 *   1. 读 <dir>/frame.seq，与上次比较，判断 QEMU 是否回传了新帧；
 *   2. 有新帧就读 <dir>/frame.rgba —— 内容已是原生 RGBA8888，读进来直接交给 GL；
 *   3. 没有新帧时按节流补写 <dir>/frame.request。
 *
 * 线程模型：只在渲染线程调用（vm_guest_display_poll），因此不需要加锁。
 */

#include "vm_frame_relay.h"
#include "vm_frame_shm.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <android/log.h>

#define TAG "VmFrameRelay"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

/*
 * 请求节流间隔 —— 也就是显示回传的目标帧率上限（16ms ≈ 60Hz）。
 *
 * 以前是 250ms（≈4 FPS），这是"卡"最主要的来源之一：触摸和滚动的跟手感
 * 几乎全被它吃掉，跟 TCG 快慢无关。
 * 现在 QEMU 侧回传线程是 8ms 一轮，且**只有访客真的 post 了新帧**才写盘 + 推进
 * frame.seq，所以高频请求不会产生额外 IO —— 只是让新画面尽快被取走。
 */
#define REQUEST_INTERVAL_MS 16

/*
 * 同一个 frame.seq 连续解码失败多少次后就放弃这一帧。
 *
 * 为什么需要：QEMU 侧的 seq 只在**成功截图并写盘**后自增。如果 frame.ppm
 * 真的坏了（截断 / 内容不是 P6），seq 就再也不会变，而「解码失败就重试」
 * 会一直重试同一个坏文件，既不产出画面，也永远不会再发 frame.request ——
 * 整个回传通道就此永久卡死。连续失败几次后直接跳过该 seq、重新要一帧。
 */
#define DECODE_RETRY_MAX 3

/*
 * 一个已发出但没被 QEMU 侧删掉的 frame.request 最多算"在途"多久。
 *
 * 为什么需要：QEMU 侧只在截图线程跑完一轮后才 unlink 请求文件。子进程若在
 * 那之前就崩了，这个文件会永远躺在磁盘上，s_request_pending 不复位 ——
 * 之后即使实例仍在跑（或子进程被重新拉起），也**再也不会发出新请求**，
 * 回传通道静默卡死。超时后当成陈旧请求丢弃，重新发一次；QEMU 侧对重复
 * 请求是幂等的（读到就截图、写完就删）。
 */
#define REQUEST_PENDING_TIMEOUT_MS 2000

#define DIR_CAP 512

static char     s_dir[DIR_CAP];
static uint64_t s_last_seq;
static bool     s_request_pending;
static uint64_t s_request_sent_ms;   /* 在途请求的发出时刻（判超时用） */
static uint64_t s_next_request_ms;

/* 解码（读文件）失败重试用（见 DECODE_RETRY_MAX 的说明） */
static uint64_t s_failed_seq;
static unsigned s_failed_count;

/*
 * 帧文件读入缓冲（复用，避免每帧 malloc/free 几 MB）。
 * v2 起文件内容就是原生 RGBA8888，所以这块缓冲**直接**交给 GL 上传：
 * 不再需要单独的输出缓冲，也不再有任何逐像素色彩转换。
 */
static uint8_t *s_buf;
static size_t   s_buf_cap;

/* 当前帧在 s_buf 里的像素起点与尺寸（load_raw 填，poll 返回给调用方） */
static const uint8_t *s_frame_pixels;
static int s_frame_w;
static int s_frame_h;

/* ------------------------------------------------------------------ */
/* 小工具                                                              */
/* ------------------------------------------------------------------ */

static uint64_t now_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return (uint64_t) ts.tv_sec * 1000u + (uint64_t) (ts.tv_nsec / 1000000L);
}

/** 把 <dir>/<name> 拼进 out；放不下返回 false。 */
static bool build_path(char *out, size_t out_len, const char *name)
{
    const int n = snprintf(out, out_len, "%s/%s", s_dir, name);
    return n > 0 && (size_t) n < out_len;
}

/** 读一个小文本文件到 buf（补 '\0'）。成功返回读到的字节数，失败返回 -1。 */
static long read_small_file(const char *path, char *buf, size_t buf_len)
{
    FILE *fp = fopen(path, "rb");
    if (fp == NULL) {
        return -1;
    }
    const size_t n = fread(buf, 1, buf_len - 1, fp);
    fclose(fp);
    buf[n] = '\0';
    return (long) n;
}

/** 读 <dir>/frame.seq。成功返回 true。 */
static bool read_seq(uint64_t *out)
{
    char path[DIR_CAP + 32];
    char buf[64];

    if (!build_path(path, sizeof(path), "frame.seq")) {
        return false;
    }
    if (read_small_file(path, buf, sizeof(buf)) < 0) {
        return false;
    }

    errno = 0;
    char *end = NULL;
    const unsigned long long v = strtoull(buf, &end, 10);
    if (end == buf || errno != 0) {
        return false;
    }
    *out = (uint64_t) v;
    return true;
}

/* ------------------------------------------------------------------ */
/* v2 帧文件读取（原生 RGBA8888，无色彩转换）                          */
/* ------------------------------------------------------------------ */

/*
 * 文件格式（与 QEMU 侧 vmhost_gfx_glue.cpp 的 vmhost_gfx_write_raw_file 一致）：
 *   [0..3] u32 width（小端）  [4..7] u32 height（小端）  [8..] RGBA8888
 *
 * "解码"因此退化成一次读文件：读进来的缓冲里，头部之后就是可以**直接**
 * 交给 glTexSubImage2D 的像素 —— 不再有 P6 解析，也不再有逐像素 RGB->RGBA，
 * 更没有为输出另拷的一份全帧缓冲。
 */
#define RAW_HDR 8u
/* 尺寸护栏：真机在 1080p 上下，防坏文件把内存吃爆。 */
#define RAW_MAX_DIM 8192

/** 读 <dir>/frame.rgba 并定位像素。成功返回 true。 */
static bool load_raw(void)
{
    char path[DIR_CAP + 32];

    if (!build_path(path, sizeof(path), "frame.rgba")) {
        return false;
    }

    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return false;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= (off_t) RAW_HDR) {
        close(fd);
        return false;
    }

    const size_t need = (size_t) st.st_size;
    if (s_buf_cap < need) {
        uint8_t *fresh = (uint8_t *) realloc(s_buf, need);
        if (fresh == NULL) {
            LOGW("回传缓冲分配失败（需要 %zu 字节）", need);
            close(fd);
            return false;
        }
        s_buf = fresh;
        s_buf_cap = need;
    }

    size_t got = 0;
    while (got < need) {
        const ssize_t n = read(fd, s_buf + got, need - got);
        if (n <= 0) {
            break;
        }
        got += (size_t) n;
    }
    close(fd);
    if (got != need) {
        return false;
    }

    uint32_t w = 0;
    uint32_t h = 0;
    memcpy(&w, s_buf + 0, 4);
    memcpy(&h, s_buf + 4, 4);
    if (w == 0 || h == 0 || w > RAW_MAX_DIM || h > RAW_MAX_DIM) {
        return false;
    }
    if (need - RAW_HDR < (size_t) w * (size_t) h * 4u) {
        return false;
    }

    s_frame_pixels = s_buf + RAW_HDR;
    s_frame_w = (int) w;
    s_frame_h = (int) h;
    return true;
}

/* ------------------------------------------------------------------ */
/* 请求发送                                                            */
/* ------------------------------------------------------------------ */

/** 没有新帧时按节流补一个 frame.request（原子写：先 tmp 再 rename）。 */
static void maybe_request(int req_w, int req_h)
{
    char req[DIR_CAP + 32];
    char tmp[DIR_CAP + 40];

    if (!build_path(req, sizeof(req), "frame.request")) {
        return;
    }

    const uint64_t now = now_ms();

    /* 上一次的请求还在（QEMU 侧还没删）就继续等，别堆文件；
       但超过 REQUEST_PENDING_TIMEOUT_MS 就当它陈旧，重新发（见宏注释）。 */
    if (s_request_pending) {
        if (access(req, F_OK) == 0 &&
            (now - s_request_sent_ms) < REQUEST_PENDING_TIMEOUT_MS) {
            return;
        }
        s_request_pending = false;
    }

    if (now < s_next_request_ms) {
        return;
    }
    s_next_request_ms = now + REQUEST_INTERVAL_MS;

    if (!build_path(tmp, sizeof(tmp), "frame.request.tmp")) {
        return;
    }

    FILE *fp = fopen(tmp, "wb");
    if (fp == NULL) {
        return;
    }
    /* 内容 "宽 高"；任一方 <=0 时 QEMU 侧按原生分辨率截图 */
    fprintf(fp, "%d %d\n", req_w > 0 ? req_w : 0, req_h > 0 ? req_h : 0);
    fclose(fp);

    if (rename(tmp, req) != 0) {
        unlink(tmp);
        return;
    }
    s_request_pending = true;
    s_request_sent_ms = now;
}

/* ------------------------------------------------------------------ */
/* v3 共享内存帧回传（首选路径，替代 frame.rgba 文件握手）              */
/* ------------------------------------------------------------------ */
/*
 * 写端（QEMU 子进程的 vmhost_gfx_glue.cpp）把最新帧写进 <dir>/frame.shm 的
 * 轮转缓冲并 release 递增头里的 seq；这里 mmap 同一文件，按 seq 变化取帧。
 * 相比读文件：省掉每帧的 open/read 两条系统调用与文件页缓存开销。
 *
 * 拿不到 frame.shm（旧版写端 / 还没建好）时自动回退原来的 file 协议。
 */

static int                s_shm_fd = -1;
static VmFrameShmHeader*  s_shm = NULL;
static size_t             s_shm_len = 0;
static uint64_t           s_shm_last_seq = 0;
static uint64_t           s_shm_last_try_ms = 0;

static void shm_close(void)
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
    s_shm_last_seq = 0;
}

/** 尽力打开并映射 <dir>/frame.shm；成功返回 true（之后缓存）。 */
static bool shm_try_open(void)
{
    if (s_shm != NULL) {
        return true;
    }
    if (s_dir[0] == '\0') {
        return false;
    }

    char path[DIR_CAP + 32];
    if (!build_path(path, sizeof(path), "frame.shm")) {
        return false;
    }
    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return false;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)VM_FRAME_SHM_HDR_SIZE) {
        close(fd);
        return false;
    }
    void* m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) {
        close(fd);
        return false;
    }
    VmFrameShmHeader* h = (VmFrameShmHeader*)m;
    /* magic 由写端最后写入：不匹配说明还没初始化好，下次再试。 */
    if (h->magic != VM_FRAME_SHM_MAGIC ||
        h->version != VM_FRAME_SHM_VERSION ||
        h->nbufs == 0 || h->stride_cap == 0 ||
        (size_t)st.st_size <
            (size_t)VM_FRAME_SHM_HDR_SIZE + (size_t)h->nbufs * (size_t)h->stride_cap) {
        munmap(m, (size_t)st.st_size);
        close(fd);
        return false;
    }

    s_shm_fd = fd;
    s_shm = h;
    s_shm_len = (size_t)st.st_size;
    s_shm_last_seq = h->seq;
    LOGI("共享内存帧回传就绪：%s（disp %ux%u stride=%u n=%u）",
         path, h->disp_w, h->disp_h, h->stride_cap, h->nbufs);
    return true;
}

/** 从共享内存取一帧；有新帧返回 true。 */
static bool shm_poll(int req_w, int req_h,
                     const uint8_t **rgba, int *w, int *h, uint64_t *seq)
{
    const uint32_t s = __atomic_load_n(&s_shm->seq, __ATOMIC_ACQUIRE);
    if (s == 0 || (uint64_t)s == s_shm_last_seq) {
        /* 共享内存路径不需要请求文件：写端只要访客出新帧就会发布。
           这里直接返回"还没有新帧"即可（省掉每 16ms 一次的文件写入）。 */
        return false;
    }

    const uint32_t slot = s_shm->slot;
    const uint32_t fw = s_shm->width;
    const uint32_t fh = s_shm->height;
    if (slot >= s_shm->nbufs || fw == 0 || fh == 0 ||
        fw > RAW_MAX_DIM || fh > RAW_MAX_DIM) {
        return false;
    }
    const size_t need = (size_t)fw * (size_t)fh * 4u;
    if (need > s_shm->stride_cap) {
        return false;
    }

    /*
     * 零拷贝：直接把共享内存里这一槽的指针交出去，不再 memcpy 进 s_buf。
     *
     * 安全性：写端写的是 (seq+1)%NBUFS 槽，读端读的是 seq%NBUFS 槽；3 缓冲轮转下
     * 写端要再过 NBUFS-1 帧才会复用读端这一槽，而调用方（vm_guest_display_poll）
     * 在本次调用内就把它交给 glTexSubImage2D 上传，窗口远小于 1 帧，因此安全。
     * 返回值在下一次 seq 前进 NBUFS 次之前保持有效。
     */
    const uint8_t* px = (const uint8_t*)s_shm + VM_FRAME_SHM_HDR_SIZE +
                        (size_t)slot * (size_t)s_shm->stride_cap;

    s_shm_last_seq = s;
    s_frame_pixels = px;
    s_frame_w = (int)fw;
    s_frame_h = (int)fh;
    s_request_pending = false;
    if (rgba) { *rgba = s_frame_pixels; }
    if (w)    { *w = s_frame_w; }
    if (h)    { *h = s_frame_h; }
    if (seq)  { *seq = s; }
    return true;
}

/* ------------------------------------------------------------------ */
/* 对外接口                                                            */
/* ------------------------------------------------------------------ */

void vm_frame_relay_set_dir(const char *dir)
{
    if (dir == NULL || dir[0] == '\0') {
        s_dir[0] = '\0';
        shm_close();
        return;
    }

    snprintf(s_dir, sizeof(s_dir), "%s", dir);

    /* 目录由 vm_engine.c 的 ensure_log_dir 负责创建；这里兜一手，
       免得因为没有目录而永远写不出 frame.request。 */
    if (mkdir(s_dir, 0755) != 0 && errno != EEXIST) {
        LOGW("创建回传目录 %s 失败：%s", s_dir, strerror(errno));
    }

    shm_close();              /* 换目录：旧的映射作废 */
    s_shm_last_try_ms = 0;
    s_last_seq = 0;
    s_request_pending = false;
    s_next_request_ms = 0;
    s_frame_pixels = NULL;
    s_frame_w = 0;
    s_frame_h = 0;
    s_failed_seq = 0;
    s_failed_count = 0;

    LOGI("帧回传目录已设置：%s", s_dir);
}

bool vm_frame_relay_enabled(void)
{
    return s_dir[0] != '\0';
}

const char *vm_frame_relay_dir(void)
{
    return s_dir;
}

bool vm_frame_relay_poll(int req_w, int req_h,
                         const uint8_t **rgba, int *w, int *h, uint64_t *seq)
{
    if (s_dir[0] == '\0') {
        return false;
    }

    /* 首选：共享内存回传（v3）。若 frame.shm 尚未建好，按 500ms 节流重试，
       期间回退下面的文件协议，保证旧写端/启动竞态下仍能出画面。 */
    if (s_shm != NULL) {
        return shm_poll(req_w, req_h, rgba, w, h, seq);
    }
    {
        const uint64_t now = now_ms();
        if (now - s_shm_last_try_ms >= 500) {
            s_shm_last_try_ms = now;
            if (shm_try_open()) {
                return shm_poll(req_w, req_h, rgba, w, h, seq);
            }
        }
    }

    /* 1. 先看有没有新帧 */
    uint64_t seq_now = 0;
    if (read_seq(&seq_now) && seq_now != s_last_seq) {
        if (load_raw()) {
            s_failed_seq = 0;
            s_failed_count = 0;
            s_last_seq = seq_now;
            s_request_pending = false;
            if (rgba) { *rgba = s_frame_pixels; }
            if (w)    { *w = s_frame_w; }
            if (h)    { *h = s_frame_h; }
            if (seq)  { *seq = seq_now; }
            return true;
        }

        /*
         * 读取失败。两种情况：
         *   a) 恰好撞上 QEMU 侧 rename 的瞬间（理论上原子替换不会出现，
         *      但非原子写入的旧版 glue 会）—— 下一轮就好；
         *   b) frame.rgba 真的坏了 —— seq 不会再变，一直重试就会永久卡死。
         * 所以同一个 seq 连续失败 DECODE_RETRY_MAX 次后跳过它，
         * 继续往下走重新要一帧（此时**不要**更新 s_last_seq 太早，
         * 否则会白白丢掉一个只是暂时读不到的帧）。
         */
        if (seq_now == s_failed_seq) {
            s_failed_count++;
        } else {
            s_failed_seq = seq_now;
            s_failed_count = 1;
        }
        if (s_failed_count < DECODE_RETRY_MAX) {
            return false;
        }

        LOGW("frame.rgba 连续 %u 次读取失败（seq=%llu），跳过该帧并重新请求",
             s_failed_count, (unsigned long long) seq_now);
        s_last_seq = seq_now;
        s_failed_seq = 0;
        s_failed_count = 0;
        /* 落到下面补一个新请求 */
    }

    /* 2. 还没有新帧：补请求，并让调用方继续显示上一帧 */
    maybe_request(req_w, req_h);
    return false;
}
