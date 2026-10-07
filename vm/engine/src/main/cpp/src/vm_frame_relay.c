/*
 * 帧回传客户端（B1 子进程模式）—— 实现。
 *
 * 协议见 vm_frame_relay.h。这里只做三件事：
 *   1. 读 <dir>/frame.seq，与上次比较，判断 QEMU 是否回传了新帧；
 *   2. 有新帧就读 <dir>/frame.ppm（P6）并转成 RGBA8888；
 *   3. 没有新帧时按节流补写 <dir>/frame.request。
 *
 * 线程模型：只在渲染线程调用（vm_guest_display_poll），因此不需要加锁。
 */

#include "vm_frame_relay.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <android/log.h>

#define TAG "VmFrameRelay"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

/*
 * QEMU 侧截图线程是 200ms 一轮（vmhost_gfx_screen_thread）。
 * 请求间隔比它略大，既不会堆积请求，也不会白白空转。
 */
#define REQUEST_INTERVAL_MS 250

/*
 * 同一个 frame.seq 连续解码失败多少次后就放弃这一帧。
 *
 * 为什么需要：QEMU 侧的 seq 只在**成功截图并写盘**后自增。如果 frame.ppm
 * 真的坏了（截断 / 内容不是 P6），seq 就再也不会变，而「解码失败就重试」
 * 会一直重试同一个坏文件，既不产出画面，也永远不会再发 frame.request ——
 * 整个回传通道就此永久卡死。连续失败几次后直接跳过该 seq、重新要一帧。
 */
#define DECODE_RETRY_MAX 3

#define DIR_CAP 512

static char     s_dir[DIR_CAP];
static uint64_t s_last_seq;
static bool     s_request_pending;
static uint64_t s_next_request_ms;
static bool     s_warned_short_ppm;

/* 解码失败重试用（见 DECODE_RETRY_MAX 的说明） */
static uint64_t s_failed_seq;
static unsigned s_failed_count;

/* 最近一帧的输出缓冲（RGBA8888） */
static uint8_t *s_pixels;
static size_t   s_cap;
static int      s_width;
static int      s_height;

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
/* PPM (P6) 解码                                                       */
/* ------------------------------------------------------------------ */

/** 跳过空白与 '#' 注释，读一个十进制整数。 */
static bool ppm_next_int(const char **pp, const char *end, long *out)
{
    const char *p = *pp;

    for (;;) {
        while (p < end && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) {
            p++;
        }
        if (p < end && *p == '#') {
            while (p < end && *p != '\n') {
                p++;
            }
            continue;
        }
        break;
    }
    if (p >= end) {
        return false;
    }

    long v = 0;
    bool any = false;
    while (p < end && *p >= '0' && *p <= '9') {
        v = v * 10 + (*p - '0');
        p++;
        any = true;
    }
    if (!any) {
        return false;
    }

    *pp = p;
    *out = v;
    return true;
}

/**
 * 把 P6 PPM 解成 RGBA8888 存进 s_pixels，并更新 s_width/s_height。
 * 成功返回 true。
 */
static bool ppm_decode_to_rgba(const uint8_t *data, size_t len)
{
    const char *p = (const char *) data;
    const char *end = p + len;

    if (len < 8 || p[0] != 'P' || p[1] != '6') {
        return false;
    }
    p += 2;

    long w = 0;
    long h = 0;
    long maxval = 0;
    if (!ppm_next_int(&p, end, &w) || !ppm_next_int(&p, end, &h) ||
        !ppm_next_int(&p, end, &maxval)) {
        return false;
    }
    if (w <= 0 || h <= 0 || maxval != 255) {
        return false;
    }
    /* 头之后恰好一个空白分隔符，随后就是像素数据 */
    if (p >= end) {
        return false;
    }
    p++;

    const size_t need = (size_t) w * (size_t) h * 3u;
    if ((size_t) (end - p) < need) {
        if (!s_warned_short_ppm) {
            s_warned_short_ppm = true;
            LOGW("frame.ppm 数据不足（需要 %zu 字节，只有 %zu）",
                 need, (size_t) (end - p));
        }
        return false;
    }

    const size_t px = (size_t) w * (size_t) h;
    const size_t out_bytes = px * 4u;
    if (s_cap < out_bytes) {
        uint8_t *fresh = (uint8_t *) realloc(s_pixels, out_bytes);
        if (fresh == NULL) {
            LOGW("回传缓冲分配失败（需要 %zu 字节）", out_bytes);
            return false;
        }
        s_pixels = fresh;
        s_cap = out_bytes;
    }

    const uint8_t *s = (const uint8_t *) p;
    uint8_t *d = s_pixels;
    for (size_t i = 0; i < px; i++) {
        d[0] = s[0];
        d[1] = s[1];
        d[2] = s[2];
        d[3] = 0xFF;
        d += 4;
        s += 3;
    }

    s_width = (int) w;
    s_height = (int) h;
    return true;
}

/** 读 <dir>/frame.ppm 并解码。成功返回 true。 */
static bool load_ppm(void)
{
    char path[DIR_CAP + 32];

    if (!build_path(path, sizeof(path), "frame.ppm")) {
        return false;
    }

    FILE *fp = fopen(path, "rb");
    if (fp == NULL) {
        return false;
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return false;
    }
    const long size = ftell(fp);
    if (size <= 0) {
        fclose(fp);
        return false;
    }
    rewind(fp);

    uint8_t *buf = (uint8_t *) malloc((size_t) size);
    if (buf == NULL) {
        fclose(fp);
        return false;
    }
    const size_t got = fread(buf, 1, (size_t) size, fp);
    fclose(fp);

    const bool ok = (got == (size_t) size) && ppm_decode_to_rgba(buf, got);
    free(buf);
    return ok;
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

    /* 上一次的请求还在（QEMU 侧没删）就继续等，别堆文件 */
    if (s_request_pending) {
        if (access(req, F_OK) == 0) {
            return;
        }
        s_request_pending = false;
    }

    const uint64_t now = now_ms();
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
}

/* ------------------------------------------------------------------ */
/* 对外接口                                                            */
/* ------------------------------------------------------------------ */

void vm_frame_relay_set_dir(const char *dir)
{
    if (dir == NULL || dir[0] == '\0') {
        s_dir[0] = '\0';
        return;
    }

    snprintf(s_dir, sizeof(s_dir), "%s", dir);

    /* 目录由 vm_engine.c 的 ensure_log_dir 负责创建；这里兜一手，
       免得因为没有目录而永远写不出 frame.request。 */
    if (mkdir(s_dir, 0755) != 0 && errno != EEXIST) {
        LOGW("创建回传目录 %s 失败：%s", s_dir, strerror(errno));
    }

    s_last_seq = 0;
    s_request_pending = false;
    s_next_request_ms = 0;
    s_width = 0;
    s_height = 0;
    s_warned_short_ppm = false;
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

    /* 1. 先看有没有新帧 */
    uint64_t seq_now = 0;
    if (read_seq(&seq_now) && seq_now != s_last_seq) {
        if (load_ppm()) {
            s_failed_seq = 0;
            s_failed_count = 0;
            s_last_seq = seq_now;
            s_request_pending = false;
            if (rgba) { *rgba = s_pixels; }
            if (w)    { *w = s_width; }
            if (h)    { *h = s_height; }
            if (seq)  { *seq = seq_now; }
            return true;
        }

        /*
         * 解码失败。两种情况：
         *   a) 恰好撞上 QEMU 侧 rename 的瞬间（理论上原子替换不会出现，
         *      但非原子写入的旧版 glue 会）—— 下一轮就好；
         *   b) frame.ppm 真的坏了 —— seq 不会再变，一直重试就会永久卡死。
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

        LOGW("frame.ppm 连续 %u 次解码失败（seq=%llu），跳过该帧并重新请求",
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
