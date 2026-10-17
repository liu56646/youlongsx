/*
 * 引擎侧最小 QMP 客户端。
 *
 * 协议极简：unix socket 上跑「一行一条 JSON」。
 *   S→C  {"QMP": {...}}                     问候语
 *   C→S  {"execute":"qmp_capabilities"}     进入命令模式
 *   C→S  {"execute":"input-send-event",...}
 *   S→C  {"return":{}} / {"error":{...}}
 *   S→C  {"event":"...","data":{...}}       异步事件（随时可能插进来）
 *
 * 两个必须注意的点：
 *   1) 读的方向不能假设"下一条就是回复"，要跳过 event 行；
 *   2) 本模块跑在 NativeActivity 的输入线程上，**绝不能长时间阻塞**。
 *      QEMU 主循环在 TCG 高负载下可能几百毫秒才回一条，所以给 socket 设
 *      读超时：超时只表示"回复还没来"，不算连接坏，留到下次再收即可。
 */

#include "vm_qmp.h"

#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define TAG "VmQmp"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

/* virtio-input 的绝对坐标域：QEMU 的 input-send-event 把 abs 值规范到 0..0x7FFF */
#define QMP_ABS_MAX 0x7FFF

/* 握手读超时（连接刚建好，QEMU 应立即回） */
#define HANDSHAKE_TIMEOUT_MS 3000
/* 常规命令读超时：给输入线程的阻塞上限 */
#define REPLY_TIMEOUT_MS 200
/* 连不上时的重试间隔：触摸是高频事件，不能每个 MOVE 都去 socket()/connect() */
#define RECONNECT_INTERVAL_MS 1000

static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static int       s_fd = -1;
static bool      s_btn_down;
static long long s_last_fail_ms = -1;
static const char *s_touch_button = "touch";

/* 读缓冲：QMP 是行协议，粘包/半包都要处理，所以留一份跨调用的残留缓冲 */
static char   s_rbuf[4096];
static size_t s_rlen;

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long) ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void set_rcv_timeout_locked(int ms)
{
    struct timeval tv;
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
    setsockopt(s_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
}

/**
 * 读出一整行（不含换行）。
 * @return 1=读到一行；0=超时（连接还活着，只是没数据）；-1=连接已断
 */
static int read_line_locked(char *out, size_t cap)
{
    for (;;) {
        char *nl = memchr(s_rbuf, '\n', s_rlen);
        if (nl != NULL) {
            size_t len = (size_t) (nl - s_rbuf);
            size_t copy = (len < cap - 1) ? len : cap - 1;
            memcpy(out, s_rbuf, copy);
            out[copy] = '\0';
            if (copy > 0 && out[copy - 1] == '\r') {
                out[copy - 1] = '\0';       /* 去掉可能的 \r */
            }
            const size_t consumed = len + 1;
            memmove(s_rbuf, s_rbuf + consumed, s_rlen - consumed);
            s_rlen -= consumed;
            return 1;
        }

        if (s_rlen >= sizeof(s_rbuf) - 1) {
            s_rlen = 0;                     /* 单行超长，丢弃（正常 QMP 不会） */
            return -1;
        }

        const ssize_t n = read(s_fd, s_rbuf + s_rlen, sizeof(s_rbuf) - 1 - s_rlen);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                return 0;                   /* 超时 */
            }
            return -1;
        }
        if (n == 0) {
            return -1;                      /* 对端关闭 */
        }
        s_rlen += (size_t) n;
    }
}

/** 把一整行写进 socket（自动补 \n）。 */
static bool write_line_locked(const char *line)
{
    char buf[1024];
    const int n = snprintf(buf, sizeof(buf), "%s\n", line);
    if (n <= 0 || n >= (int) sizeof(buf)) {
        return false;
    }

    size_t off = 0;
    const size_t total = (size_t) n;
    while (off < total) {
        const ssize_t w = write(s_fd, buf + off, total - off);
        if (w < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        off += (size_t) w;
    }
    return true;
}

/*
 * 发一条命令 —— fire-and-forget。
 *
 * input-send-event 不需要应答。旧实现发出后会**阻塞读回复**，最坏等
 * REPLY_TIMEOUT_MS(200ms)（TCG 高负载下 QEMU 常几百毫秒才回一行）；而输入回调
 * 就跑在**跑渲染的那条 looper 线程**上，于是每个触摸 MOVE 都可能把渲染一起卡住
 * —— 这是"跟手"变差的主因之一。
 *
 * 现在只做“写 + 非阻塞把已到达的数据读掉”（防止回复堆积把 socket 缓冲撑满），
 * 绝不等待。连接是否还活着，靠 write 是否失败 / 读到 EOF 判断。
 * @return false 表示连接已坏，需要重连
 */
static bool command_locked(const char *json)
{
    if (!write_line_locked(json)) {
        return false;
    }

    const int flags = fcntl(s_fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(s_fd, F_SETFL, flags | O_NONBLOCK);
    }
    char line[2048];
    bool alive = true;
    for (int i = 0; i < 64; i++) {
        const int r = read_line_locked(line, sizeof(line));
        if (r == 0) {
            break;                          /* 无更多数据（EAGAIN） */
        }
        if (r < 0) {
            alive = false;                  /* 对端关闭 */
            break;
        }
        /* return / event / error 一律丢弃即可 */
    }
    if (flags >= 0) {
        fcntl(s_fd, F_SETFL, flags);
    }
    return alive;
}

/**
 * 读一条**命令应答**（跳过异步 event），带总时限。
 *
 * 与 command_locked 的"非阻塞排空"不同，这里是真的等：调用方（快照保存、
 * stop/cont）必须确认 QEMU 的结果。等待切成 500ms 一段，以便到点就返回。
 *
 * @return 1=拿到应答行；0=超时；-1=连接已断
 */
static int read_reply_locked(char *out, size_t cap, int timeout_ms)
{
    const long long deadline = now_ms() + timeout_ms;
    for (;;) {
        const long long remain = deadline - now_ms();
        if (remain <= 0) {
            return 0;
        }
        set_rcv_timeout_locked((int) (remain > 500 ? 500 : remain));

        char line[4096];
        const int r = read_line_locked(line, sizeof(line));
        if (r < 0) {
            return -1;
        }
        if (r == 0) {
            continue;                       /* 这一段没数据，回去看总时限 */
        }
        if (strstr(line, "\"event\"") != NULL) {
            continue;                       /* 异步事件不是应答 */
        }
        if (out != NULL && cap > 0) {
            snprintf(out, cap, "%s", line);
        }
        return 1;
    }
}

static void close_locked(void)
{
    if (s_fd >= 0) {
        close(s_fd);
        s_fd = -1;
    }
    s_rlen = 0;
    s_btn_down = false;
}

bool vm_qmp_connect(const char *sock_path)
{
    if (sock_path == NULL || sock_path[0] == '\0') {
        return false;
    }

    pthread_mutex_lock(&s_lock);

    if (s_fd >= 0) {
        pthread_mutex_unlock(&s_lock);
        return true;
    }

    const long long now = now_ms();
    if (s_last_fail_ms >= 0 && now - s_last_fail_ms < RECONNECT_INTERVAL_MS) {
        pthread_mutex_unlock(&s_lock);
        return false;                        /* 失败节流 */
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(sock_path) >= sizeof(addr.sun_path)) {
        LOGW("QMP 路径过长：%s", sock_path);
        s_last_fail_ms = now;
        pthread_mutex_unlock(&s_lock);
        return false;
    }
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", sock_path);

    const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        LOGW("创建 unix socket 失败：%s", strerror(errno));
        s_last_fail_ms = now;
        pthread_mutex_unlock(&s_lock);
        return false;
    }
    if (connect(fd, (struct sockaddr *) &addr, sizeof(addr)) != 0) {
        LOGW("连接 QMP 失败（%s）：%s", sock_path, strerror(errno));
        close(fd);
        s_last_fail_ms = now;
        pthread_mutex_unlock(&s_lock);
        return false;
    }

    s_fd = fd;
    s_rlen = 0;
    set_rcv_timeout_locked(HANDSHAKE_TIMEOUT_MS);

    char line[2048];
    if (read_line_locked(line, sizeof(line)) != 1 || strstr(line, "QMP") == NULL) {
        LOGW("QMP 问候语异常：%s", line);
        close_locked();
        s_last_fail_ms = now;
        pthread_mutex_unlock(&s_lock);
        return false;
    }
    if (!write_line_locked("{\"execute\":\"qmp_capabilities\"}") ||
        read_line_locked(line, sizeof(line)) != 1 ||
        strstr(line, "\"return\"") == NULL) {
        LOGW("QMP qmp_capabilities 握手失败");
        close_locked();
        s_last_fail_ms = now;
        pthread_mutex_unlock(&s_lock);
        return false;
    }

    set_rcv_timeout_locked(REPLY_TIMEOUT_MS);
    s_last_fail_ms = -1;
    LOGI("QMP 已连接：%s（输入注入可用）", sock_path);
    pthread_mutex_unlock(&s_lock);
    return true;
}

void vm_qmp_disconnect(void)
{
    pthread_mutex_lock(&s_lock);
    close_locked();
    pthread_mutex_unlock(&s_lock);
}

bool vm_qmp_is_connected(void)
{
    pthread_mutex_lock(&s_lock);
    const bool ok = (s_fd >= 0);
    pthread_mutex_unlock(&s_lock);
    return ok;
}

void vm_qmp_set_legacy_touch(bool legacy)
{
    pthread_mutex_lock(&s_lock);
    s_touch_button = legacy ? "left" : "touch";
    s_btn_down = false;
    pthread_mutex_unlock(&s_lock);
}

/*
 * 注入一次触摸。
 *
 * 【关键，实测得出，不要把 "touch" 改回 "left"】
 * QEMU 的 virtio-tablet 只暴露 ABS_X / ABS_Y 两个绝对轴，没有多点触控。
 *   - 若按鼠标左键发（button:"left"），Android 的 InputReader 会把这个设备
 *     判定成**鼠标**：绝对坐标要先经 CursorInputMapper 的 viewport 映射落到
 *     "光标"上才起作用。实测结果是**位置完全不生效** —— 不管 abs 发到哪个
 *     坐标，Android 看到的都是"在当前光标处按下/抬起"。表现出来就是：
 *     长按能弹出桌面长按菜单（弹出说明按下了），但点图标、上下滑动全都毫无
 *     反应，且 console.log 里没有任何 START u0 记录。
 *   - 改用 BTN_TOUCH（button:"touch"）后，Android 按**触摸屏**处理，
 *     ABS_X/ABS_Y 直接作为触摸坐标生效。实测仅仅把 button 名字从 left 换成
 *     touch，同一个坐标立刻就能点开图标、触发 GLOBAL_SEARCH。
 *
 * 拖动分支（按住后只补发 abs）同样依赖这一点：位置更新只有在触摸屏语义下
 * 才会被采纳。
 *
 * p9/p71 没有 virtio-tablet，QMP 事件落到 goldfish-events 的 legacy absolute
 * mouse handler；该 handler 只看 buttons_state 的 bit0，所以
 * vm_qmp_set_legacy_touch(true) 会把按钮名切回 "left"。这两条路径互斥，
 * p11/p13 仍然必须用 "touch"。
 */
void vm_qmp_touch(int x, int y, int max_x, int max_y, bool down)
{
    if (max_x <= 0 || max_y <= 0) {
        return;
    }

    if (x < 0) {
        x = 0;
    }
    if (y < 0) {
        y = 0;
    }
    if (x >= max_x) {
        x = max_x - 1;
    }
    if (y >= max_y) {
        y = max_y - 1;
    }

    const int ax = (int) ((long) x * QMP_ABS_MAX / max_x);
    const int ay = (int) ((long) y * QMP_ABS_MAX / max_y);

    /* 触摸 slop + 节流。
     *
     * guest 侧是单指绝对坐标设备（virtio-tablet），每一帧手指抖动都会被当作
     * MOVE 发给它。TCG 下 guest 本来就慢，一个"轻点"很容易因为几像素的抖动
     * 被判成拖动（列表跟着滑、图标被拖走）。这里做两件事：
     *   1) 从按下点算起，位移小于 12 个 guest 像素时不发 MOVE —— 轻点就是轻点；
     *   2) 两次 MOVE 之间至少隔 8ms，避免把 QEMU 的输入队列灌爆。
     * 12px 在 320dpi 下约 6dp，比 Android 默认 touch slop（8dp≈16px）略小，
     * 不会吃掉正常的拖动起手。 */
    static int s_down_x, s_down_y;
    static int s_last_sent_x, s_last_sent_y;
    static uint64_t s_last_move_ms;
    const int kTouchSlopGuestPx = 12;
    const uint64_t kMoveIntervalMs = 8;

    pthread_mutex_lock(&s_lock);
    if (s_fd < 0) {
        pthread_mutex_unlock(&s_lock);
        return;
    }

    char cmd[768];
    bool ok;

    if (!down) {
        if (!s_btn_down) {
            pthread_mutex_unlock(&s_lock);
            return;                    /* 没按下过，孤立的抬起忽略 */
        }
        snprintf(cmd, sizeof(cmd),
                 "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":["
                 "{\"type\":\"btn\",\"data\":{\"button\":\"%s\",\"down\":false}}]}}",
                 s_touch_button);
        ok = command_locked(cmd);
        s_btn_down = false;
    } else if (!s_btn_down) {
        /* 新接触：先定位再按下。
           开头那条 touch-up 是"状态复位"：QMP 断线重连后 guest 仍可能以为自己
           还按着（上一次的 up 丢在坏掉的连接里），于是之后每次触摸都变成拖动。
           多发一次 up 在正常路径上无害，但能保证 guest 从干净状态开始。 */
        s_down_x = x;
        s_down_y = y;
        s_last_sent_x = x;
        s_last_sent_y = y;
        s_last_move_ms = now_ms();
        snprintf(cmd, sizeof(cmd),
                 "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":["
                 "{\"type\":\"btn\",\"data\":{\"button\":\"%s\",\"down\":false}},"
                 "{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":%d}},"
                 "{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":%d}},"
                 "{\"type\":\"btn\",\"data\":{\"button\":\"%s\",\"down\":true}}]}}",
                 s_touch_button, ax, ay, s_touch_button);
        ok = command_locked(cmd);
        if (ok) {
            s_btn_down = true;
        }
    } else {
        /* 拖动：只更新位置 */
        const int dx = x - s_down_x;
        const int dy = y - s_down_y;
        const int adx = dx < 0 ? -dx : dx;
        const int ady = dy < 0 ? -dy : dy;
        if (adx < kTouchSlopGuestPx && ady < kTouchSlopGuestPx) {
            pthread_mutex_unlock(&s_lock);
            return;                    /* 还在 slop 内：保持轻点语义 */
        }
        if (x == s_last_sent_x && y == s_last_sent_y) {
            pthread_mutex_unlock(&s_lock);
            return;
        }
        const uint64_t now = now_ms();
        if (now - s_last_move_ms < kMoveIntervalMs) {
            pthread_mutex_unlock(&s_lock);
            return;
        }
        s_last_move_ms = now;
        s_last_sent_x = x;
        s_last_sent_y = y;
        snprintf(cmd, sizeof(cmd),
                 "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":["
                 "{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":%d}},"
                 "{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":%d}}]}}",
                 ax, ay);
        ok = command_locked(cmd);
    }

    if (!ok) {
        LOGW("input-send-event 发送失败，断开重连");
        close_locked();
        s_last_fail_ms = now_ms();
    }
    pthread_mutex_unlock(&s_lock);
}

/* 注入一次按键（Linux keycode，例如 KEY_VOLUMEUP=115）。
 *
 * 子进程模式下 vmhost_input_key() 只在 QEMU 进程里有意义（父进程的 s_con
 * 恒为 NULL），所以按键和触摸一样走 QMP。QEMU 的 input-send-event 用
 * "type":"key" + Linux keycode，和 evdev 一致。 */
void vm_qmp_key(int linux_keycode, bool down)
{
    if (linux_keycode <= 0) {
        return;
    }
    pthread_mutex_lock(&s_lock);
    if (s_fd < 0) {
        pthread_mutex_unlock(&s_lock);
        return;
    }
    char cmd[384];
    snprintf(cmd, sizeof(cmd),
             "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":["
             "{\"type\":\"key\",\"data\":{\"down\":%s,"
             "\"key\":{\"type\":\"number\",\"data\":%d}}}]}}",
             down ? "true" : "false", linux_keycode);
    if (!command_locked(cmd)) {
        LOGW("按键 input-send-event 发送失败，断开重连");
        close_locked();
        s_last_fail_ms = now_ms();
    }
    pthread_mutex_unlock(&s_lock);
}

int vm_qmp_request(const char *command, const char *arguments_json,
                   char *reply_out, size_t reply_cap, int timeout_ms)
{
    if (command == NULL || command[0] == '\0') {
        return -1;
    }
    if (reply_out != NULL && reply_cap > 0) {
        reply_out[0] = '\0';
    }

    pthread_mutex_lock(&s_lock);
    if (s_fd < 0) {
        pthread_mutex_unlock(&s_lock);
        return -1;
    }

    char json[1024];
    if (arguments_json != NULL && arguments_json[0] != '\0') {
        snprintf(json, sizeof(json),
                 "{\"execute\":\"%s\",\"arguments\":%s}", command, arguments_json);
    } else {
        snprintf(json, sizeof(json), "{\"execute\":\"%s\"}", command);
    }

    int rc = -1;
    if (!write_line_locked(json)) {
        LOGW("QMP 请求 %s 写失败，断开重连", command);
        close_locked();
    } else {
        char line[4096];
        const int r = read_reply_locked(line, sizeof(line), timeout_ms);
        if (r == 1) {
            if (reply_out != NULL && reply_cap > 0) {
                snprintf(reply_out, reply_cap, "%s", line);
            }
            /* QEMU 回 error 也算"拿到了应答"，但要与成功区分开：
               命令不存在（老引擎）走的就是这条路。 */
            rc = (strstr(line, "\"error\"") != NULL) ? 1 : 0;
        } else if (r < 0) {
            LOGW("QMP 请求 %s 时连接断开", command);
            close_locked();
        } else {
            LOGW("QMP 请求 %s 超时（%d ms）", command, timeout_ms);
        }
    }
    pthread_mutex_unlock(&s_lock);
    return rc;
}
