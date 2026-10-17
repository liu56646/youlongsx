/*
 * QEMU 嵌入层：把 QEMU 当作「库」在自己的进程里跑起来。
 *
 * 为什么能这么做：QEMU 的 system/main.c 只有三行——
 *
 *     int main(int argc, char **argv)
 *     {
 *         qemu_init(argc, argv);
 *         return qemu_main();
 *     }
 *
 * 其中 qemu_init / qemu_main_loop / qemu_cleanup 都在静态库里，
 * main() 本身在可执行体里。我们只要自己调用这三个函数，
 * 就能把 QEMU 当成进程内的一个组件来驱动。
 *
 * 注意：QEMU 出错时大量使用 exit()，会直接结束本进程。
 * 因此在真正调用前先做参数校验，把可预期的错误挡在外面。
 */

#include "vm_qemu.h"
#include "vm_qmp.h"
#include "vm_frame_relay.h"
#include "vmhost_control.h"

#include <pthread.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/system_properties.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <android/log.h>

#define TAG "VmQemu"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/* ---- QEMU 嵌入入口（见 qemu/include/sysemu/sysemu.h） ---- */
extern void qemu_init(int argc, char **argv);
extern int  qemu_main_loop(void);
extern void qemu_cleanup(int status);

#define MAX_ARGS    80
#define ARG_CAP     768

static pthread_t s_thread;
static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static bool s_started = false;
static bool s_running = false;
static bool s_finished = false;   /* QEMU 主循环已返回、线程即将结束 */
static bool s_joined = false;     /* 线程已 join，避免重复 join */
static bool s_child_mode = false; /* 本次是 fork/exec 子进程模式（B1），不是进程内嵌 */
static int  s_argc = 0;
static char s_args[MAX_ARGS][ARG_CAP];
static char *s_argv[MAX_ARGS + 1];
static char s_serial_log[ARG_CAP];

static void add_arg(const char *fmt, ...)
{
    if (s_argc >= MAX_ARGS) {
        LOGW("参数数量超上限，丢弃：%s", fmt);
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(s_args[s_argc], ARG_CAP, fmt, ap);
    va_end(ap);
    s_argv[s_argc] = s_args[s_argc];
    s_argc++;
}

static bool file_ok(const char *path)
{
    return path != NULL && access(path, R_OK) == 0;
}

/** 取镜像目录里与 [base_path] 同级的文件；成功返回 true。 */
static bool image_sibling(const char *base_path, const char *name,
                          char *out, size_t out_len)
{
    if (base_path == NULL || name == NULL || out == NULL || out_len == 0) {
        return false;
    }
    snprintf(out, out_len, "%s", base_path);
    char *slash = strrchr(out, '/');
    if (slash == NULL) {
        return false;
    }
    snprintf(slash + 1, out_len - (size_t) (slash + 1 - out), "%s", name);
    return file_ok(out);
}

/**
 * Detect the standalone-ext4 layout used by p11/p13 (and p71's whole-disk
 * system image).
 *
 * p9 is the exception: its system.img is a GPT disk (partition 1 is vda1).
 * p11/p13 package every logical partition as a standalone ext4 file and carry
 * a complete first-stage fstab in the ramdisk, so the legacy DT fstab must not
 * be added there. p71 also ships a whole ext4 system image and uses the fstab
 * repacked into its ramdisk.
 */
static bool image_is_plain_ext4(const char *path)
{
    if (!file_ok(path)) {
        return false;
    }

    unsigned char magic[2];
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return false;
    }

    ssize_t n = pread(fd, magic, sizeof(magic), 0x438);
    close(fd);
    return n == (ssize_t) sizeof(magic) && magic[0] == 0x53 && magic[1] == 0xEF;
}

/** 把参数列表打到日志，便于现场排查。 */
static void dump_args(void)
{
    LOGI("QEMU 参数（%d 个）：", s_argc);
    for (int i = 0; i < s_argc; i++) {
        LOGI("  [%02d] %s", i, s_args[i]);
    }
}

/**
 * 把 stdout/stderr 重定向到 <日志目录>/qemu-stderr.log。
 *
 * QEMU 的报错（error_report、glib 的 g_error/g_assert）全部走 stderr，
 * 而 Android 上原生进程的 stderr 默认被丢弃 —— 真机崩了会一点线索都没有，
 * 只能靠 tombstone 里的寄存器瞎猜。
 *
 * 输出目录直接沿用串口日志所在目录，省得多传一个参数。
 */
static void redirect_std_streams(const char *serial_log_path)
{
    if (serial_log_path == NULL) {
        return;
    }

    char path[ARG_CAP];
    snprintf(path, sizeof(path), "%s", serial_log_path);

    char *slash = strrchr(path, '/');
    if (slash == NULL) {
        return;
    }
    snprintf(slash + 1, sizeof(path) - (size_t) (slash + 1 - path), "qemu-stderr.log");

    int fd = open(path, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd < 0) {
        LOGW("打开 %s 失败，QEMU 的 stderr 将无据可查", path);
        return;
    }
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    if (fd > STDERR_FILENO) {
        close(fd);
    }
    /* stderr 本来就无缓冲；stdout 重定向到文件后会变成全缓冲，改成行缓冲免得丢日志 */
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    LOGI("QEMU 的 stdout/stderr 已重定向到 %s", path);
}

static void *qemu_thread_main(void *arg)
{
    (void) arg;

    redirect_std_streams(s_serial_log);

    LOGI("调用 qemu_init()");
    qemu_init(s_argc, s_argv);

    LOGI("进入 QEMU 主循环");
    int status = qemu_main_loop();
    LOGI("QEMU 主循环退出，status=%d", status);

    qemu_cleanup(status);

    pthread_mutex_lock(&s_lock);
    s_running = false;
    s_finished = true;
    pthread_mutex_unlock(&s_lock);
    return NULL;
}

/* ------------------------------------------------------------------ *
 * B1 模式：以子进程方式运行「已验证能把这套访客跑起来」的 AOSP QEMU(ranchu)。
 *
 * 为什么不能用进程内的上游 QEMU：访客是按 ranchu/goldfish 配的，它的
 * vendor.hwcomposer-2-3 依赖 goldfish 的 pipe/gfxstream；换到上游 QEMU 的
 * `-M virt` 上，HWC 会致命 abort，其 onrestart 去重启 surfaceflinger，
 * 而 surfaceflinger 的 onrestart 又会重启 zygote —— 系统永远到不了 boot_completed。
 *
 * 子进程的二进制作成 jniLib 随包分发，落在本 .so 同目录（nativeLibraryDir），
 * 那是 Android 上唯一允许 app 执行的位置；找不到它时退回进程内嵌的方式。
 * ------------------------------------------------------------------ */
/*
 * 子进程可执行体的候选文件名，都在 nativeLibraryDir 里查找。
 *
 * Android 10+ 只允许执行 nativeLibraryDir 下的文件，而该目录由 APK 的
 * jniLibs 解压而来，所以 QEMU 必须打包成 lib*.so：
 *   - libqemu_exec.so            ：build_qemu_aosp.sh 的正式产物名
 *                                  （见 engine/.gitignore 里那条忽略规则）
 *   - libqemu-system-aarch64.so  ：build_qemu.sh（上游 QEMU）的产物名
 * 这里挨个试，避免构建脚本一改名引擎就静默退回进程内嵌模式。
 */
static const char *const kQemuChildNames[] = {
    "libqemu_exec.so",
    "libqemu-system-aarch64.so",
};

static pid_t s_child_pid = -1;
extern char **environ;

/** 取本 .so 所在目录（= nativeLibraryDir）。 */
static bool self_lib_dir(char *out, size_t out_len)
{
    Dl_info info;
    if (dladdr((void *) &vm_qemu_start, &info) == 0 || info.dli_fname == NULL) {
        return false;
    }
    snprintf(out, out_len, "%s", info.dli_fname);
    char *slash = strrchr(out, '/');
    if (slash == NULL) {
        return false;
    }
    *slash = '\0';
    return true;
}

/** 追加一块 virtio-blk。磁盘的先后顺序决定访客里的 vda/vdb/...
 *
 * 默认走 MMIO（virtio-blk-device），可用环境变量 VMHOST_BLK_PCI=1 切到 PCI
 * （virtio-blk-pci）。真机实测结论：
 *   - p11 能用，是因为它的 ramdisk 里带了 `/lib/modules/virtio_blk.ko`
 *     （console.log 可见 "Loaded kernel module .../virtio_blk.ko"），内核才有
 *     virtio-blk 能力；此时 MMIO 就能认盘，且盘符是**反序**（先加的 data 落到
 *     vdf），p11 的 fstab 就是按反序写的。
 *   - p9 的 4.4 SDK kernel 里 VIRTIO_BLK / VIRTIO_MMIO 都是内建的，
 *     不需要 ramdisk 模块；它的问题在 GPT uevent/by-name 与 SAR 根挂载。
 *   - p13 的 ramdisk/内核组合不同，走单独的 physical-ext4 路径。
 *   - 切到 PCI 时盘符变**正序**（vda=data、vdf=system），fstab 要跟着反过来写。 */
static bool blk_use_pci(void)
{
    /* p9 SAR 启动依赖 virtio-mmio 的盘符顺序（system 最后添加 -> vda）。
       PCI 会改变枚举顺序，而且调试开关不应该破坏已适配的启动路径。 */
    const char *sar = getenv("VMHOST_SAR");
    if (sar != NULL && sar[0] == '1') {
        return false;
    }
    const char *v = getenv("VMHOST_BLK_PCI");
    return v != NULL && v[0] == '1';
}

static void add_blk_dev(const char *id, const char *path, bool readonly)
{
    add_arg("%s", "-drive");
    add_arg("if=none,id=%s,file=%s,format=raw%s,cache=unsafe",
            id, path, readonly ? ",readonly=on" : "");
    add_arg("%s", "-device");
    add_arg(blk_use_pci() ? "virtio-blk-pci,drive=%s" : "virtio-blk-device,drive=%s", id);
}

/**
 * p71（Android 7.1 / API 25）的内核是 Linux 3.18，早于 virtio 1.0。
 * 当前 ranchu 的 virtio-mmio 传输默认是 modern，必须对它切回 legacy，
 * 否则 virtio-blk 根本不会 probe，init 会报 partition(s) not found。
 *
 * 镜像目录固定是 .../images/p71_arm64，用 ramdisk 路径识别比按内核版本
 * 解析二进制更稳，也不会影响 p11 的 modern virtio-input。
 */
static bool guest_is_p71_api25(const VmQemuParams *p)
{
    if (p == NULL) {
        return false;
    }

    const char *paths[] = {
        p->initrd_path,
        p->kernel_path,
        p->system_img_path,
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (paths[i] != NULL && strstr(paths[i], "p71_arm64") != NULL) {
            return true;
        }
    }

    /* The image tag may be renamed when imported. make_guest_image.sh puts
       this marker next to ramdisk.img, so layout detection stays reliable. */
    char marker[ARG_CAP];
    return image_sibling(p->initrd_path, "vmhost_guest_p71",
                         marker, sizeof(marker));
}

/**
 * p9（Android 9 / API 28）的 system.img 是 system-as-root（SAR）：
 * 内核必须直接 root=/dev/vda1，init 不能再把 system 挂到 /。
 * 镜像目录固定是 .../images/p9_arm64；打包脚本还会在 kernel 旁放
 * vmhost_guest_p9，镜像改名后也能识别。
 */
static bool guest_is_p9_api28(const VmQemuParams *p)
{
    if (p == NULL) {
        return false;
    }

    const char *paths[] = {
        p->system_img_path,
        p->kernel_path,
        p->initrd_path,
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (paths[i] != NULL && strstr(paths[i], "p9_arm64") != NULL) {
            return true;
        }
    }

    char marker[ARG_CAP];
    return image_sibling(p->kernel_path, "vmhost_guest_p9",
                         marker, sizeof(marker));
}

/** 子进程 QEMU 是否还活着（顺带回收，并记录退出原因）。 */
static bool child_alive(void)
{
    if (s_child_pid <= 0) {
        return false;
    }
    int status = 0;
    const pid_t r = waitpid(s_child_pid, &status, WNOHANG);
    if (r == s_child_pid) {
        /* 不记录原因的话，事后只看得到一个僵尸进程和"日志突然停了" */
        if (WIFSIGNALED(status)) {
            const int sig = WTERMSIG(status);
            LOGE("子进程 QEMU 被信号 %d（%s）终止", sig, strsignal(sig));
        } else if (WIFEXITED(status)) {
            LOGE("子进程 QEMU 正常退出，code=%d", WEXITSTATUS(status));
        } else {
            LOGE("子进程 QEMU 结束，status=0x%x", status);
        }
        s_child_pid = -1;
        return false;
    }
    if (r < 0 && errno != EINTR) {
        LOGW("waitpid(%d) 失败：%s（按已退出处理）", (int) s_child_pid, strerror(errno));
        s_child_pid = -1;
        return false;
    }
    return true;
}

/** 拼参数并 fork/exec 出子进程 QEMU。返回 0 成功。 */
/* ------------------------------------------------------------------ */
/* 快照恢复的 unix socket 中转                                          */
/* ------------------------------------------------------------------ */
/*
 * QEMU 2.12 的迁移通道实测结论：
 *   - `file:` 直接被拒（"expects a valid migration protocol"）
 *   - `exec:dd if=` / `exec:cat` / `exec:sh + 双向吞咽` 全部以
 *     "load of migration failed: I/O error" 结束（exec 通道只有单向语义）
 *   - 只有 unix:/tcp: 是**原生双向**通道
 *
 * 关键（源码佐证 migration/socket.c 的 socket_start_incoming_migration）：
 *   `-incoming unix:<path>` 里 **QEMU 自己是 server** —— 它调
 *   qio_net_listener_open_sync() 去 bind+listen 该路径。
 *   所以 App 必须反过来做 **client**：先删掉残留的 socket 文件，
 *   等 QEMU 把监听建起来，再 connect 上去把快照喂进去。
 *   （最早按"App 当 server"写，等于和 QEMU 抢同一个路径，QEMU 监听失败，
 *    表现就是 App 永远 accept 不到、QEMU 报 load failed。）
 */
static char s_snap_sock[ARG_CAP];
static char s_snap_file[ARG_CAP];
/* 本次启动是否走「快照恢复」，以及恢复是否已判定失败。
   恢复失败 = 子进程早早退出（迁移流没被接受），上层据此删档回退冷启动。 */
static bool s_restoring = false;

static void snap_prepare(const char *sock_path)
{
    /* 清掉上次残留的 socket 文件，否则 QEMU bind 会 Address already in use */
    unlink(sock_path);
}

static void *snap_feed_thread(void *arg)
{
    (void) arg;

    /* 等 QEMU 把监听建起来，再连上去（最多重试 ~20 秒） */
    int cfd = -1;
    for (int i = 0; i < 200 && cfd < 0; i++) {
        const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            LOGE("快照中转：socket 失败 %s", strerror(errno));
            return NULL;
        }
        struct sockaddr_un sa;
        memset(&sa, 0, sizeof(sa));
        sa.sun_family = AF_UNIX;
        snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", s_snap_sock);
        if (connect(fd, (const struct sockaddr *) &sa, sizeof(sa)) == 0) {
            cfd = fd;
            break;
        }
        close(fd);
        usleep(100 * 1000);
    }
    if (cfd < 0) {
        LOGE("快照中转：连不上 QEMU 的迁移 socket %s", s_snap_sock);
        return NULL;
    }
    LOGI("快照中转：已连上 QEMU，开始喂 %s", s_snap_file);

    FILE *fp = fopen(s_snap_file, "rb");
    if (fp == NULL) {
        LOGE("快照中转：打不开快照 %s", s_snap_file);
        close(cfd);
        return NULL;
    }
    char buf[64 * 1024];
    unsigned long long total = 0;
    for (;;) {
        const size_t n = fread(buf, 1, sizeof(buf), fp);
        if (n == 0) {
            break;
        }
        size_t off = 0;
        while (off < n) {
            const ssize_t w = write(cfd, buf + off, n - off);
            if (w <= 0) {
                LOGE("快照中转：写 socket 失败（已喂 %llu 字节）", total);
                goto done;
            }
            off += (size_t) w;
        }
        total += n;
    }
    LOGI("快照中转：喂完 %llu 字节", total);
done:
    fclose(fp);
    close(cfd);
    return NULL;
}

/* ------------------------------------------------------------------ */
/* 模拟器快照（aemu Snapshotter）：通过 QMP 触发                          */
/* ------------------------------------------------------------------ */
/*
 * 与上面那条「snapshot.bin + -incoming」不同，这是模拟器自己的 quickboot 路径：
 * QEMU 侧由 `vmhostsnapshot`（build_qemu_aosp.sh 里补丁注册的 HMP 命令）调 aemu
 * 的 Snapshotter，把 guest RAM + 设备状态 + 宿主渲染器状态一起存/取。
 *
 * 引擎这边只做三件事：
 *   1) 启动后若存在 <dataDir>/snapshot.state（= 上次保存成功）就发 load；
 *      失败就删标记、本次按冷启动继续 —— 不给用户留黑屏。
 *   2) 停机前先把 guest 冻住（QMP stop），再 save；成功才写标记。
 *      **必须落在静止点**：否则磁盘已经往前走、而快照 RAM 还停在过去，ext4 会坏。
 *   3) 命令不存在（现役引擎都还没有）时只记一次日志，绝不影响正常启动/停机。
 *
 * A/B 开关：`setprop debug.vmhost.snapshot 0` 可整体关掉。
 */

#define VMHOST_SNAP_NAME     "default_boot"
#define SNAP_SAVE_TIMEOUT_MS 180000
#define SNAP_LOAD_TIMEOUT_MS 180000
#define SNAP_STATE_MAGIC     "vmhost-snapshot-v1\n"

static char s_snap_state_file[ARG_CAP];   /* <dataDir>/snapshot.state */
static bool s_snap_cmd_missing = false;   /* 本版 QEMU 没有 vmhostsnapshot 命令 */

/** 由 userdata 路径推出 <dataDir>/snapshot.state。 */
static void snap_state_path_from(const char *userdata_path, char *out, size_t cap)
{
    out[0] = '\0';
    if (userdata_path == NULL) {
        return;
    }
    snprintf(out, cap, "%s", userdata_path);
    char *slash = strrchr(out, '/');
    if (slash == NULL) {
        out[0] = '\0';
        return;
    }
    snprintf(slash + 1, cap - (size_t) (slash + 1 - out), "snapshot.state");
}

/** 快照总开关（默认开，`debug.vmhost.snapshot=0` 关）。 */
static bool snap_enabled(void)
{
    char v[PROP_VALUE_MAX] = {0};
    if (__system_property_get("debug.vmhost.snapshot", v) > 0 &&
        v[0] == '0' && v[1] == '\0') {
        return false;
    }
    return true;
}

/**
 * 发一条 HMP 命令（经 QMP human-monitor-command）。
 * @return 0=成功；1=HMP 报错；2=没有这条命令；-1=连接/超时
 */
static int hmp_run(const char *cmdline, char *out, size_t out_cap, int timeout_ms)
{
    char args[512];
    char reply[4096];
    reply[0] = '\0';
    snprintf(args, sizeof(args), "{\"command-line\":\"%s\"}", cmdline);
    const int rc = vm_qmp_request("human-monitor-command", args,
                                  reply, sizeof(reply), timeout_ms);
    if (out != NULL && out_cap > 0) {
        snprintf(out, out_cap, "%s", reply);
    }
    /* 老引擎里没有这条 HMP 命令：QEMU 会回 CommandNotFound / "... not been found" */
    if (strstr(reply, "CommandNotFound") != NULL ||
        strstr(reply, "not been found") != NULL) {
        return 2;
    }
    return rc;
}

static int snap_hmp(const char *op, char *out, size_t out_cap, int timeout_ms)
{
    char cmd[128];
    snprintf(cmd, sizeof(cmd), "vmhostsnapshot %s %s", op, VMHOST_SNAP_NAME);
    return hmp_run(cmd, out, out_cap, timeout_ms);
}

/** 连上 QMP（拿不到 socket 路径或连不上时返回 false）。 */
static bool snap_qmp_connect(void)
{
    char qmp[ARG_CAP];
    if (!vm_qemu_qmp_path(qmp, sizeof(qmp))) {
        return false;
    }
    return vm_qmp_connect(qmp);
}

/**
 * 停机前保存快照：冻住 guest → save → 写标记。
 * 全程失败都只是记日志 —— 停机流程不能因为快照失败而卡住。
 */
static void snap_try_save(void)
{
    if (s_snap_cmd_missing || s_snap_state_file[0] == '\0' || !snap_enabled()) {
        return;
    }
    if (!snap_qmp_connect()) {
        LOGW("快照：连不上 QMP，跳过保存");
        return;
    }

    /* 显示没在工作就别存。
       实测：在 guest 显示初始化之前（刚 boot_completed、还没 post 过帧）存下来的
       快照，恢复后 guest 一直不出帧 —— QMP screendump 显示
       "Guest has not initialized the display (yet)."，frame post 计数停在 2，
       用户看到的就是黑屏。这里要求最近 10 秒内真的出过帧。 */
    {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        const uint64_t now_ms =
                (uint64_t) ts.tv_sec * 1000u + (uint64_t) ts.tv_nsec / 1000000u;
        const uint64_t last_frame_ms = vm_frame_relay_last_frame_ms();
        if (last_frame_ms == 0 || now_ms - last_frame_ms > 10000u) {
            LOGW("快照：guest 最近 10s 没有出帧（显示可能未初始化），"
                 "跳过保存以免恢复后黑屏");
            return;
        }
    }

    /* 1) 先冻住 guest：快照必须落在静止点，磁盘与 RAM 才同点 */
    if (vm_qmp_request("stop", NULL, NULL, 0, 5000) < 0) {
        LOGW("快照：QMP stop 未成功，跳过保存");
        return;
    }

    /* 2) 保存 */
    char out[4096];
    const int rc = snap_hmp("save", out, sizeof(out), SNAP_SAVE_TIMEOUT_MS);
    if (rc == 2) {
        s_snap_cmd_missing = true;
        LOGI("本版引擎没有 vmhostsnapshot 命令，跳过快照（不影响停机）");
        return;
    }
    if (rc != 0) {
        LOGE("快照保存失败（rc=%d）：%s", rc, out);
        return;
    }

    /* HMP 层的失败是以**文本**回来的：QMP 信封仍然是 {"return": "..."}，
       只有 human-monitor-command 的返回值里才写着
       "vmhostsnapshot: save 'x' failed: ..."。只看 QMP 信封会把失败当成功
       （实测踩到：引擎记下"已保存"，盘上其实什么都没有）。 */
    if (strstr(out, "failed") != NULL) {
        LOGE("快照保存失败（HMP）：%s", out);
        return;
    }

    /* 3) 写标记：下次启动据此发 load */
    FILE *fp = fopen(s_snap_state_file, "wb");
    if (fp != NULL) {
        fputs(SNAP_STATE_MAGIC, fp);
        fclose(fp);
        LOGI("快照已保存：%s", s_snap_state_file);
    } else {
        LOGW("快照已保存但标记文件写不出来：%s", s_snap_state_file);
    }
}

/** 启动后尝试恢复：等 QMP 起来 → load；失败删标记并放行 guest。 */
static void *snap_load_thread(void *arg)
{
    (void) arg;

    /* 连接和请求都要重试。QEMU 刚 spawn 出来时它的 QMP socket 可能还没 bind
       好；更坑的是可能连到上一次运行残留的 socket —— 实测 connect 会成功、
       紧接着 write 就失败（EPIPE），一次就放弃会让恢复永远失败。 */
    char out[4096];
    int rc = -1;
    for (int attempt = 0; attempt < 8; attempt++) {
        if (!vm_qmp_is_connected()) {
            if (!snap_qmp_connect()) {
                usleep(1000 * 1000);
                continue;
            }
        }
        out[0] = '\0';
        rc = snap_hmp("load", out, sizeof(out), SNAP_LOAD_TIMEOUT_MS);
        if (rc == 0) {
            /* 同 save：HMP 的失败藏在返回值文本里，不能只看 QMP 信封。 */
            if (strstr(out, "failed") != NULL) {
                rc = 1;
            }
            break;
        }
        /* 连接坏了（-1）就断开重连再试；命令不存在（2）/执行失败（1）不重试。 */
        if (rc != -1) {
            break;
        }
        vm_qmp_disconnect();
        usleep(1000 * 1000);
    }

    if (rc == 0) {
        LOGI("已从快照恢复（%s）", VMHOST_SNAP_NAME);
        /* 恢复成功也要放行 guest。QEMU 是以 -S（暂停）起来的，而
           load_snapshot() 只在「load 之前 VM 已经在跑」时才自己 vm_start()
           （migration/savevm.c 的 saved_vm_running 分支）—— 我们这条路径不满足，
           实测恢复后 QEMU CPU 0%、console.log 不增长，表现就是黑屏。
           这里补一发 cont，和失败分支共用同一套重连/重试。 */
        for (int attempt = 0; attempt < 5; attempt++) {
            if (!vm_qmp_is_connected() && !snap_qmp_connect()) {
                usleep(1000 * 1000);
                continue;
            }
            if (vm_qmp_request("cont", NULL, NULL, 0, 5000) >= 0) {
                LOGI("快照恢复后已放行 guest");
                break;
            }
            vm_qmp_disconnect();
            usleep(1000 * 1000);
        }
        return NULL;
    }

    LOGE("快照恢复失败（rc=%d）：%s", rc, out);
    if (rc == 2) {
        s_snap_cmd_missing = true;
    }
    unlink(s_snap_state_file);          /* 坏快照不留：下次直接冷启动 */

    /* 有快照标记时 QEMU 是以 -S（暂停）起来的：这里必须把 guest 放行，
       否则它会一直停着（表现就是黑屏）。同样要重试 + 重连 —— 连不上就再来一次。 */
    for (int attempt = 0; attempt < 5; attempt++) {
        if (!vm_qmp_is_connected() && !snap_qmp_connect()) {
            usleep(1000 * 1000);
            continue;
        }
        if (vm_qmp_request("cont", NULL, NULL, 0, 5000) >= 0) {
            LOGI("已放行 guest（本次按冷启动继续）");
            break;
        }
        vm_qmp_disconnect();
        usleep(1000 * 1000);
    }
    return NULL;
}

/**
 * /dev/kvm 是否真能打开。这是「切 KVM 后端」的最后一道核对：
 * 节点存在 ≠ 可用（应用沙箱里 SELinux 可能拒绝，占位节点 open 返回 ENODEV）。
 * 引擎进程无特权时这里会失败，从而安全回退 TCG，绝不会带病上 KVM。
 */
static bool kvm_dev_available(void)
{
    int fd = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        LOGW("kvm: open /dev/kvm 失败（%s），回退 TCG", strerror(errno));
        return false;
    }
    close(fd);
    return true;
}

/* --------------------------------------------------------------- guest 首次 provisioning
 *
 * 裁剪过的 system.img 里没有 Setup Wizard：全新 /data 第一次启动时
 * SurfaceFlinger 只画一个黑屏 + 光标，launcher 永远不起来（实测帧全黑）。
 * 手动置 device_provisioned=1 + user_setup_complete=1 再 start HOME
 * 就能直接进桌面（帧平均亮度从 0 变成 150）。这里在首次启动后自动做一次。
 *
 * 触发点：console.log 里出现 sys.boot_completed=1（等最多 40 分钟，TCG 冷启动
 * 可能十几分钟）。命令通过 console.sock（userdebug 的 ttyS0 shell）送进 guest。
 * 完成后在实例目录写 .guest_provisioned，之后不再执行。
 */
typedef struct VmProvisionArgs {
    char sock[ARG_CAP];
    char log[ARG_CAP];
    char marker[ARG_CAP];
} VmProvisionArgs;

static bool prov_log_has_boot_completed(const char *path) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        return false;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return false;
    }
    const long sz = ftell(f);
    const long start = sz > 65536 ? sz - 65536 : 0;
    if (sz < 0 || fseek(f, start, SEEK_SET) != 0) {
        fclose(f);
        return false;
    }
    char buf[65537];
    const size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';
    return strstr(buf, "sys.boot_completed=1") != NULL;
}

/* 一个连接内分几次写（tty 输入缓冲很小，一次性写会丢字符）。 */
static bool prov_send_commands(const char *sock) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return false;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", sock);
    if (connect(fd, (struct sockaddr *) &addr, sizeof(addr)) != 0) {
        close(fd);
        return false;
    }
    static const char *const kCmds[] = {
        "settings put global device_provisioned 1\n",
        "settings put secure user_setup_complete 1\n",
        "am start -a android.intent.action.MAIN -c android.intent.category.HOME\n",
    };
    for (size_t i = 0; i < sizeof(kCmds) / sizeof(kCmds[0]); i++) {
        ssize_t off = 0;
        const ssize_t len = (ssize_t) strlen(kCmds[i]);
        while (off < len) {
            const ssize_t w = write(fd, kCmds[i] + off, (size_t) (len - off));
            if (w <= 0) {
                close(fd);
                return false;
            }
            off += w;
        }
        usleep(700 * 1000);
    }
    close(fd);
    return true;
}

static void *vm_provision_thread(void *raw) {
    VmProvisionArgs *a = (VmProvisionArgs *) raw;
    if (a == NULL) {
        return NULL;
    }
    if (a->marker[0] != '\0' && file_ok(a->marker)) {
        free(a);
        return NULL;
    }
    bool booted = false;
    for (int i = 0; i < 1200; i++) {          /* 2s * 1200 = 40min 上限 */
        if (prov_log_has_boot_completed(a->log)) {
            booted = true;
            break;
        }
        usleep(2 * 1000 * 1000);
    }
    if (!booted) {
        free(a);
        return NULL;
    }
    /* boot_completed 只是 SystemServer 报完成，SystemUI/launcher 往往还要几十秒
       才把首屏画出来（TCG 下更久）。太早发 am start HOME 会打断首启流程，
       实测会出现一直停在 "Phone is starting…"。给 30 秒缓冲。 */
    sleep(30);
    bool ok = false;
    for (int attempt = 0; attempt < 8 && !ok; attempt++) {
        ok = prov_send_commands(a->sock);
        if (!ok) {
            usleep(2 * 1000 * 1000);
        }
    }
    if (ok) {
        FILE *m = fopen(a->marker, "wb");
        if (m != NULL) {
            fputs("1\n", m);
            fclose(m);
        }
        LOGI("guest 首次 provisioning 已写入（device_provisioned / user_setup_complete / HOME）");
    } else {
        LOGW("guest provisioning 失败：连不上 %s", a->sock);
    }
    free(a);
    return NULL;
}

static int spawn_qemu_child(const VmQemuParams *p, const char *exe_path, const char *lib_dir)
{
    const int mem = (p->memory_mb > 0) ? p->memory_mb : 2048;
    const int cores = (p->cores > 0) ? p->cores : 4;
    const bool p9_sar = guest_is_p9_api28(p);

    /* aemu 快照的标记文件（<dataDir>/snapshot.state）：存在 = 上次保存成功 */
    snap_state_path_from(p->userdata_img_path, s_snap_state_file,
                         sizeof(s_snap_state_file));

    /* 后端选择：请求了 KVM 且 /dev/kvm 真能打开 → 硬件加速；否则 TCG（现状）。
       MTTCG 相关注释保留在下方 TCG 分支，KVM 分支用 host CPU。 */
    const bool want_kvm = p->backend_name &&
                          strcmp(p->backend_name, "KVM") == 0 &&
                          kvm_dev_available();
    const bool p71 = guest_is_p71_api25(p);
    /* p9/p71 的显示/输入都走 classic ranchu goldfish；p11/p13 才用
       virtio-gpu + virtio-input。 */
    const bool goldfish_input = p71 || p9_sar;
    const bool goldfish_display = p71 || p9_sar;
    vm_qmp_set_legacy_touch(goldfish_input);
    if (goldfish_display) {
        setenv("VMHOST_GOLDFISH_FB", "1", 1);
        setenv("VMHOST_GOLDFISH_GRALLOC", "1", 1);
        if (p9_sar && !p71) {
            /* p9 的旧 guest 用 goldfish_fb 做最终显示；GOLDFISH_GRALLOC 已
               修复 color buffer。保持单写者，避免 post callback/桥双写
               干扰 frame.shm 和 SystemUI 启动。 */
            unsetenv("VMHOST_GFX_POST");
            LOGI("p9: goldfish_fb + GOLDFISH_GRALLOC（单写者）");
        } else {
            unsetenv("VMHOST_GFX_POST");
        }
        LOGI("%s: goldfish_fb 软件帧缓冲模式（frame.shm）",
             p9_sar ? "p9" : "p71");
    } else {
        unsetenv("VMHOST_GOLDFISH_FB");
        unsetenv("VMHOST_GOLDFISH_GRALLOC");
        unsetenv("VMHOST_GFX_POST");
    }

    s_argc = 0;
    s_child_mode = true;
    s_restoring = false;   /* 只有在下面真的挂上 -incoming 时才置位 */
    add_arg("%s", "qemu-system-aarch64");
    if (want_kvm) {
        LOGI("kvm: 使用 KVM 加速（-accel kvm -cpu host）");
        add_arg("%s", "-accel");
        add_arg("%s", "kvm");
    } else {
        if (p->backend_name && strcmp(p->backend_name, "KVM") == 0) {
            LOGW("kvm: 请求了 KVM 但不可用，已回退 TCG");
        }
        /* MTTCG（多线程 TCG）。
           实测与源码核实（真机 cc96ded5，见 docs/方案B排障交接.md §21）：
           1) `thread=multi` 被本版 QEMU 接受，且 MTTCG 确实生效：本仓 QEMU 的
              configure 对 aarch64 目标就是 `mttcg="yes"`（aarch64-softmmu/
              config-target.mak 里有 TARGET_SUPPORTS_MTTCG=y），运行时 cpus.c 的
              qemu_tcg_init_vcpu() 会为每个 vCPU 建独立线程 —— `-smp 6` 时可观察
              到 6 条 "CPU n/TCG" 线程，且能抓到两条 vCPU 线程同时忙。
              注意：boot 前中期 `top -H` 里常只见 1 条 vCPU 线程忙，那是 guest
              boot 流程天然串行的**负载形状**，不代表 MTTCG 没开。 */
        add_arg("%s", "-accel");
        add_arg("%s", "tcg,thread=multi");
    }

    /* 有快照时用「暂停启动」：aemu 的 Snapshotter::load() 要求 guest 还没开始
       执行 —— 我们 spawn 完就去 load，若此时 guest 已经在跑，状态会打架。
       load 成功由 Snapshotter 自己把 VM 跑起来；失败则由 snap_load_thread
       发 `cont` 放行，退回冷启动。没有快照时这条不加，行为与以前完全一致。 */
    if (file_ok(s_snap_state_file)) {
        add_arg("%s", "-S");
        LOGI("检测到快照标记，QEMU 以 -S（暂停）启动，随后尝试 load");
    }

    /* 翻译块缓存（TB cache）大小，单位 MB。
       本版 QEMU 是**顶层参数** `-tb-size n`：qemu-options.hx 里有
       DEF("tb-size", HAS_ARG, QEMU_OPTION_tb_size, ...)、vl.c 的
       QEMU_OPTION_tb_size 分支把它读进全局 tcg_tb_size、accel/tcg/tcg-all.c
       的 tcg_init() 再 tcg_exec_init(tcg_tb_size * 1024 * 1024)。
       **不是** `-accel tcg,tb-size=` 那种新写法 —— 早先按新写法加进去报
       "Invalid parameter 'tb-size'"，于是误判成"本版不支持"，实际只是语法错。
       默认只有 32MB：完整 Android 访客的翻译块很快把缓存挤爆，之后每遇到
       新代码就要冲掉重翻，启动与切应用都会明显变慢。这里给到 512MB
       （aarch64 上 MAX_CODE_GEN_BUFFER_SIZE 是 size_t 上限，不受限）。 */
    add_arg("%s", "-tb-size");
    add_arg("%d", 512);
    if (p71) {
        /* p71 的 Linux 3.18 只认 legacy virtio-mmio。p9 的 4.4 内核支持
           modern virtio，不要动它。 */
        add_arg("%s", "-global");
        add_arg("%s", "virtio-mmio.force_legacy=on");
    }
    if (goldfish_input) {
        /* p9/p71 的输入走 ranchu 自带的 goldfish-events。打开单点触摸/键盘；
           关闭 multitouch，让 QMP 的 ABS_X/Y + 左键落到传统 BTN_TOUCH 路径。 */
        add_arg("%s", "-global");
        add_arg("%s", "goldfish-events.have-touch=on");
        add_arg("%s", "-global");
        add_arg("%s", "goldfish-events.have-multitouch=off");
        add_arg("%s", "-global");
        add_arg("%s", "goldfish-events.have-keyboard=on");
        LOGI("%s: goldfish-events 输入已启用", p9_sar ? "p9" : "p71");
    }
    add_arg("%s", "-M");
    add_arg("%s", "ranchu");
    add_arg("%s", "-cpu");
    if (want_kvm) {
        add_arg("%s", "host");
    } else {
        /* TCG 下给访客暴露哪套 CPU 特性。
           `cortex-a57` 是 ARMv8.0 基线：没有 LSE 原子、没有 crc/crypto 指令，
           访客（内核 5.4 / ART / 包扫描）只能用一堆普通指令模拟这些操作。
           `max` 打开本版 QEMU 支持的全部特性，访客内核按 ID 寄存器自行选用，
           重哈希（sha/crc）与锁竞争路径能少执行大量指令。
           真机 A/B 不必重编 APK：`setprop debug.vmhost.cpu <型号>` 即可覆盖，
           清空该属性（`setprop debug.vmhost.cpu ''`）回到默认值。 */
        char cpu_model[64];
        cpu_model[0] = '\0';
        if (__system_property_get("debug.vmhost.cpu", cpu_model) <= 0 ||
            cpu_model[0] == '\0') {
            snprintf(cpu_model, sizeof(cpu_model), "%s", "cortex-a57");
        }
        add_arg("%s", cpu_model);
    }
    add_arg("%s", "-smp");
    add_arg("%d", cores);
    add_arg("%s", "-m");
    add_arg("%d", mem);
    add_arg("%s", "-kernel");
    add_arg("%s", p->kernel_path);
    if (!p9_sar && file_ok(p->initrd_path)) {
        add_arg("%s", "-initrd");
        add_arg("%s", p->initrd_path);
    }
    /* 与实验 exp47 完全一致的 cmdline。注意两点：
       - rdinit=/dumper：probe ramdisk 里的 PID1（dumper 只是 exec /init），
         与 exp47 同一条已验证的启动路径；
       - 不要 root=/dev/vda：会干扰 first-stage 的 switch_root
         （实测报 "Unable to move mount at '/dev'" → InitFatalReboot）；
       - audit=0 很关键：permissive 下 avc 会刷出几千行，占串口 I/O 又吃 CPU。 */
    add_arg("%s", "-append");
    if (p9_sar) {
        /* p9 的 system.img 是 system-as-root：让内核直接把 vda1 挂成 /。
           此时 QEMU 侧不下发 system fstab 节点（VMHOST_SAR=1），
           init 只负责 vendor/data，避免对 / 再 mount 一次得到 EBUSY。 */
        add_arg("%s",
                "console=ttyAMA0 root=/dev/vda1 ro rootwait rootfstype=ext4 init=/init "
                "androidboot.hardware=ranchu androidboot.selinux=permissive "
                "androidboot.veritymode=disabled androidboot.force_normal_boot=1 "
                "ignore_loglevel panic=0 printk.devkmsg=on audit=0");
    } else {
        add_arg("%s",
                "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive "
                "androidboot.veritymode=disabled androidboot.force_normal_boot=1 "
                "rdinit=/init ignore_loglevel panic=0 printk.devkmsg=on audit=0");
    }

    /* 盘序必须与 exp47（ranchu 实测）一致。ranchu 机器上 virtio-blk 的 vdX 字母
       与挂载顺序**相反**：先挂 data 得到 vdf、最后挂 system 得到 vda，
       实测映射 vda=system vdb=vendor vdc=product vdd=system_ext vde=metadata
       vdf=data，正好满足访客 fstab。顺序错/缺一块都会 InitFatalReboot。 */
    if (p9_sar) {
        /* p9 的 vendor fstab 是 FDE（不是 FBE）：
             /dev/block/vdc /data ... forceencrypt=/dev/block/vdd
           vdd 是加密 footer/key 盘，不能省。把它排在 data 之前添加，
           反序后才得到 data=vdc、encryptionkey=vdd（system=vda、vendor=vdb）。
           优先用实例目录里的副本：FDE key 绝不能跨实例共享。 */
        char enc_path[ARG_CAP];
        bool enc_ok = image_sibling(p->userdata_img_path, "encryptionkey.img",
                                    enc_path, sizeof(enc_path));
        if (!enc_ok) {
            enc_ok = image_sibling(p->kernel_path, "encryptionkey.img",
                                   enc_path, sizeof(enc_path));
        }
        if (enc_ok) {
            add_blk_dev("d0enc", enc_path, false);
        } else {
            LOGW("p9: 缺少 encryptionkey.img，/data 的 forceencrypt 会失败");
        }
    }
    if (file_ok(p->userdata_img_path))   add_blk_dev("d1data", p->userdata_img_path, false);
    /* p9 只有 data/vendor/system (+ encryptionkey) 四块盘，vendor fstab
       固定写 data=/dev/block/vdc。实例目录若遗留 p11 的 metadata/product/
       system_ext，会把 data 挤到别的 vdX；这里对 SAR 访客强制只挂这些盘。 */
    if (!p9_sar && file_ok(p->metadata_img_path)) {
        add_blk_dev("d2meta", p->metadata_img_path, false);
    }
    if (!p9_sar && file_ok(p->system_ext_img_path)) {
        add_blk_dev("d3sext", p->system_ext_img_path, true);
    }
    if (!p9_sar && file_ok(p->product_img_path)) {
        add_blk_dev("d4prod", p->product_img_path, true);
    }
    if (file_ok(p->vendor_img_path))     add_blk_dev("d5vend", p->vendor_img_path, true);
    if (file_ok(p->system_img_path))     add_blk_dev("d6sys",  p->system_img_path, true);

    add_arg("%s", "-device");
    add_arg("%s", "virtio-rng-device");

    /* virtio-gpu 必须走 **PCI**（virtio-gpu-pci），不能走 virtio-mmio。
       guest 的 virtio-gpu 驱动是 Android/gfxstream 魔改版（virtio_gpu(O)），
       它在 `VIRTIO_GPU_F_RESOURCE_BLOB` 特性下会做 PCI 一致性内存初始化：
           pdev = <vdev 的 PCI 父设备>;
           ... 读 pdev->resource[4] ...
           pci_request_region(pdev, 4, "virtio-gpu-coherent");
       挂在 virtio-mmio 上时父设备不是 PCI 设备 → pdev == NULL →
       virtio_gpu_init 在 `ldr x8,[x0,#0x5c8]` 上 NULL 解引用，guest 内核 panic。
       Android 模拟器本来就是 virtio-gpu-pci + gfxstream，这里保持一致。 */
    if (!goldfish_display) {
        add_arg("%s", "-device");
        add_arg("%s", "virtio-gpu-pci");
    }

    /* 输入设备：virtio-input（virtio-tablet-device + virtio-keyboard-device）。
       此前因 ranchu 的 virtio-mmio 传输是 legacy（VIRT_VERSION=1，无
       force-legacy 开关），virtio-input 这类 spec 1.0 设备在 guest 端绑不上
       驱动（"version 2 must provide VIRTIO_F_VERSION_1"），被迫改走 PCI xHCI
       + USB HID。现已给 hw/virtio/virtio-mmio.c 加了 modern 传输支持：
       force_legacy 默认 false、VERSION=2、pre_plugged 通告
       VIRTIO_F_VERSION_1，且 DEVICE_FEATURES 正确暴露高 32 位（bit32 在其中）。
       virtio-tablet 提供绝对坐标（Android 识别为触摸/指针），virtio-keyboard
       提供按键。 */
    if (!goldfish_input) {
        add_arg("%s", "-device");
        add_arg("%s", "virtio-tablet-device");
        add_arg("%s", "-device");
        add_arg("%s", "virtio-keyboard-device");
    }

    /* QMP socket：输入注入的**跨进程**通道。
       B1 模式下 QEMU 在子进程、输入代码在父进程，而 ui_vmhost.c 的 s_con 只在
       子进程的 graphic_console_init() 里被赋值，父进程恒为 NULL —— 父进程直接调
       vmhost_input_touch() 只会撞上 `if (s_con == NULL) return;` 被静默丢弃。
       改用 QMP 后，父进程把 input-send-event 发给子进程，事件在子进程内路由到
       上面两个 virtio-input 设备。语法用 2.12 时代的 `server,nowait`
       （`server=on,wait=off` 是 4.0+ 才有的写法）。 */
    {
        char qmp_path[ARG_CAP];
        qmp_path[0] = '\0';
        if (p->serial_log_path != NULL) {
            snprintf(qmp_path, sizeof(qmp_path), "%s", p->serial_log_path);
            char *slash = strrchr(qmp_path, '/');
            if (slash != NULL) {
                snprintf(slash + 1, sizeof(qmp_path) - (size_t) (slash + 1 - qmp_path),
                         "qmp.sock");
            } else {
                qmp_path[0] = '\0';
            }
        }
        if (qmp_path[0] != '\0') {
            /* 先清掉上次运行残留的 socket 文件：QEMU 自己会 bind，但残留的
               inode 会让"刚 spawn 就去连"的那条路径连到一个已经死掉的 socket
               上（实测：connect 成功、write 立刻失败，load 被误判成失败）。 */
            unlink(qmp_path);
            add_arg("%s", "-qmp");
            add_arg("unix:%s,server,nowait", qmp_path);
        } else {
            LOGW("拿不到日志目录，QMP 未开启（输入注入将不可用）");
        }
        /* 再开一个本机 TCP 的 QMP，只为排查：adb forward tcp:4444 tcp:4444 之后
           可以直接用 QMP（info qtree / input-send-event）查 QEMU 内部的设备与输入
           路由，不必改代码重装。 */
        add_arg("%s", "-qmp");
        add_arg("tcp:127.0.0.1:4444,server,nowait");
    }

    /* 注意：B1 子进程模式**先不带网络**。
       这台 AOSP QEMU 上 `-netdev user,id=net0` 会解析失败并直接报错退出
       （Parameter 'type' expects a netdev backend type），而 exp47 验证过的
       配置本来也没有网卡（配合 vendor 的 ranchu-net 补丁，无 eth0 也能正常
       启动到 boot_completed）。网络接入放到后续单独做。 */

    add_arg("%s", "-no-reboot");

    /* 快照的 VM state 需要一块"支持快照"的块设备：QEMU 的
       bdrv_all_find_vmstate_bs() 只认 qcow2 这类驱动，而我们的盘全是 raw
       （官方 emulator 是靠 drive-share 把镜像转成 qcow2 overlay 才满足这个前提）。
       这里专门挂一个小的 qcow2 vmstate 盘：设备状态落在它里面，guest RAM 走
       aemu 的 QEMUFileHooks 落到 ram.img。文件不存在时 QEMU 会自己创建。 */
    if (p->userdata_img_path != NULL) {
        char vmstate_path[ARG_CAP];
        snprintf(vmstate_path, sizeof(vmstate_path), "%s", p->userdata_img_path);
        char *slash = strrchr(vmstate_path, '/');
        if (slash != NULL) {
            snprintf(slash + 1,
                     sizeof(vmstate_path) - (size_t) (slash + 1 - vmstate_path),
                     "vmstate.qcow2");
            /* **只在文件存在时才挂**：QEMU 不会自己创建 qcow2，文件缺失时它会
               直接 "Could not open ...: No such file" 退出 —— 那会让整个 VM
               起不来。缺了这块盘只是"快照不可用"，冷启动必须照常工作。 */
            if (file_ok(vmstate_path)) {
                add_arg("%s", "-drive");
                add_arg("if=none,id=vmstate,file=%s,format=qcow2", vmstate_path);
            } else {
                LOGW("没有 %s：本次不挂 vmstate 盘（快照保存会失败，冷启动不受影响）",
                     vmstate_path);
            }
        }
    }

    /* 快照恢复：若实例目录里存在 snapshot.bin，则用 -incoming 加载它，
       把上次"已经跑起来的 VM"（含 guest RAM 与设备状态）直接恢复，
       省掉整段冷启动。快照的保存走 QMP 的 migrate（见 vm_snapshot.c）。
       注意：恢复时 QEMU 的命令行必须与保存时一致（同样的设备/内存/镜像），
       这里的参数正是同一套拼装逻辑，所以天然一致。 */
    {
        char snap[ARG_CAP];
        snap[0] = '\0';
        if (p->userdata_img_path != NULL) {
            snprintf(snap, sizeof(snap), "%s", p->userdata_img_path);
            char *slash = strrchr(snap, '/');
            if (slash != NULL) {
                snprintf(slash + 1, sizeof(snap) - (size_t) (slash + 1 - snap),
                         "snapshot.bin");
            } else {
                snap[0] = '\0';
            }
        }
        if (snap[0] != '\0' && file_ok(snap)) {
            /* 快照恢复：QEMU 自己监听 unix socket（它是 server），
               App 作为 client 稍后连上去喂数据（见 snap_feed_thread）。 */
            snprintf(s_snap_file, sizeof(s_snap_file), "%s", snap);
            snprintf(s_snap_sock, sizeof(s_snap_sock), "%s", snap);
            char *sl = strrchr(s_snap_sock, '/');
            if (sl != NULL) {
                snprintf(sl + 1, sizeof(s_snap_sock) - (size_t) (sl + 1 - s_snap_sock),
                         "mig.sock");
            }
            snap_prepare(s_snap_sock);
            add_arg("%s", "-incoming");
            add_arg("unix:%s", s_snap_sock);
            s_restoring = true;
            LOGI("检测到快照，QEMU 以 -incoming unix:%s 恢复（快照 %s）",
                 s_snap_sock, snap);
        }
    }

    add_arg("%s", "-display");
    add_arg("%s", "none");
    if (p->serial_log_path != NULL) {
        /* 串口从 "-serial file:" 改成 unix socket + logfile：
           - 日志照旧全量写 <logs>/console.log（调试不受影响）；
           - 同时留一个可连的 socket，接上去就是 guest 的 console shell
             （userdebug 镜像的 init.rc 有 `on init && property:ro.debuggable=1
             → start console`，也就是 ttyS0 上的 /system/bin/sh）。
           有了它才能在 guest 里做性能调优（wm size / 关动画 / 停掉没有硬件
           支撑的 phone、bluetooth 服务），也能直接 dumpsys 看渲染路径。
           连接方式：adb shell "nc -U <logs>/console.sock"（app 私有目录，
           用 run-as 或 root）。 */
        char cons_sock[ARG_CAP];
        snprintf(cons_sock, sizeof(cons_sock), "%s", p->serial_log_path);
        char *slash = strrchr(cons_sock, '/');
        if (slash != NULL) {
            snprintf(slash + 1, sizeof(cons_sock) - (size_t) (slash + 1 - cons_sock),
                     "console.sock");
            unlink(cons_sock);
            add_arg("%s", "-chardev");
            add_arg("socket,id=vmhostconsole,path=%s,server,nowait,"
                    "logfile=%s,logappend=on",
                    cons_sock, p->serial_log_path);
            add_arg("%s", "-serial");
            add_arg("%s", "chardev:vmhostconsole");
        } else {
            add_arg("%s", "-serial");
            add_arg("file:%s", p->serial_log_path);
        }
    }
    s_argv[s_argc] = NULL;

    dump_args();

    const pid_t pid = fork();
    if (pid < 0) {
        LOGE("fork 失败：%s", strerror(errno));
        return -1;
    }
    if (pid == 0) {
        /* 子进程：QEMU 的 stdout/stderr 落到实例日志目录，便于现场排查 */
        char err_log[ARG_CAP];
        err_log[0] = '\0';
        if (p->serial_log_path != NULL) {
            snprintf(err_log, sizeof(err_log), "%s", p->serial_log_path);
            char *slash = strrchr(err_log, '/');
            if (slash != NULL) {
                snprintf(slash + 1, sizeof(err_log) - (size_t) (slash + 1 - err_log),
                         "qemu-stderr.log");
            }
        }
        if (err_log[0] != '\0') {
            const int fd = open(err_log, O_CREAT | O_WRONLY | O_APPEND, 0644);
            if (fd >= 0) {
                dup2(fd, STDOUT_FILENO);
                dup2(fd, STDERR_FILENO);
                if (fd > STDERR_FILENO) {
                    close(fd);
                }
            }
        }
        /* AOSP QEMU 依赖同目录的 glib/pixman/... ，必须显式给库搜索路径 */
        setenv("LD_LIBRARY_PATH", lib_dir, 1);
        /* 访客显示分辨率：gfxstream glue（vmhost_gfx_glue.cpp）从环境变量读，
           未设置时用它自己的编译期默认 720x1280。运行期可调，便于对比不同
           分辨率下的合成开销。 */
        if (p->display_width > 0 && p->display_height > 0) {
            char dim[32];
            snprintf(dim, sizeof(dim), "%d", p->display_width);
            setenv("VMHOST_GFX_W", dim, 1);
            snprintf(dim, sizeof(dim), "%d", p->display_height);
            setenv("VMHOST_GFX_H", dim, 1);
        }
        /* 管道服务日志：打印访客的 pipe 请求有没有走到 aemu 的 AndroidPipe 服务
           （含首包的 "pipe:<name>" 服务名）。当年用它定位"访客 EGL 连不上宿主"，
           但它是**每次 recv/send 打一行**：只要有一条 pipe 在轮询，日志就会疯长
           —— 实测一条卡住的 pipe 刷出 570 万行 / 190MB（约 120KB/s，一天 10GB），
           既吃存储又吃 IO。所以默认关闭，需要时
           `setprop debug.vmhost.pipe_log 1` 再开。 */
        {
            char v[PROP_VALUE_MAX] = {0};
            if (__system_property_get("debug.vmhost.pipe_log", v) > 0 &&
                v[0] == '1') {
                setenv("VMHOSTPIPE_SVC", "1", 1);
            }
        }
        /* 块设备传输方式：默认 MMIO（virtio-blk-device），p9/p71 的 4.4 内核
           在 ranchu 上需要 PCI 才能枚举到盘。 */
        {
            char v[PROP_VALUE_MAX] = {0};
            if (__system_property_get("debug.vmhost.blk_pci", v) > 0 &&
                v[0] == '1') {
                setenv("VMHOST_BLK_PCI", "1", 1);
            }
        }
        /* 逐包/逐次的宿主诊断同样默认关闭 —— 它们比 pipe 日志更凶：
           VMHOST_GLES1_OP 是"每个 GLES 包一行"、VMHOST_GLES2_LOWFREQ 是所谓
           "低频"调用（实测 2.5 分钟 21 万行），VMHOST_MUTEXDBG 每条 mutex 析构
           一次还带符号解析（2.5 分钟 3 万行）。三个开关各对应一个属性。 */
        {
            char v[PROP_VALUE_MAX] = {0};
            if (__system_property_get("debug.vmhost.gles_log", v) > 0 &&
                v[0] == '1') {
                setenv("VMHOST_GLES_LOG", "1", 1);
            }
            v[0] = '\0';
            if (__system_property_get("debug.vmhost.mutex_log", v) > 0 &&
                v[0] == '1') {
                setenv("VMHOST_MUTEX_LOG", "1", 1);
            }
        }
        /* 崩溃诊断：aemu 的 Thread::maskAllSignals() 用 sigfillset 把 SIGSEGV 也屏蔽了，
           QEMU 自带的崩溃处理器因此永不触发，现场只剩"日志突然中断"。
           libsigfix.so 拦截 pthread_sigmask/sigprocmask，把崩溃信号从屏蔽集里剔掉。 */
        {
            char preload[ARG_CAP];
            if (snprintf(preload, sizeof(preload), "%s/libsigfix.so", lib_dir) <
                (int) sizeof(preload) && file_ok(preload)) {
                setenv("LD_PRELOAD", preload, 1);
            }
        }
        /* D1a：把截图回传目录（serial_log 所在目录，即 <dataDir>/logs）传给
           gfxstream glue，它会在该目录轮询 frame.request 并回写 frame.ppm/seq。 */
        if (p->serial_log_path != NULL) {
            char frame_dir[ARG_CAP];
            snprintf(frame_dir, sizeof(frame_dir), "%s", p->serial_log_path);
            char *slash = strrchr(frame_dir, '/');
            if (slash != NULL) {
                *slash = '\0';
                setenv("VMHOST_FRAME_DIR", frame_dir, 1);
            }
        }
        /* aemu 快照目录：模拟器那边是由
              getSnapshotBaseDir() = avdInfo_getContentPath(avdInfo) + "/snapshots"
           推出来的。我们不是 emulator 前端、没有 AVD，所以由 glue 里的
           avdInfo_getContentPath shim 读这个环境变量，让快照落进实例目录。 */
        if (p->userdata_img_path != NULL) {
            char snap_dir[ARG_CAP];
            snprintf(snap_dir, sizeof(snap_dir), "%s", p->userdata_img_path);
            char *slash = strrchr(snap_dir, '/');
            if (slash != NULL) {
                *slash = '\0';
                setenv("VMHOST_SNAP_DIR", snap_dir, 1);
            }
        }
        execve(exe_path, s_argv, environ);
        _exit(127);   /* 只有 exec 失败才会到这 */
    }

    s_child_pid = pid;
    LOGI("已拉起子进程 QEMU（ranchu 模式）pid=%d exe=%s", pid, exe_path);

    /* 上次留下的快照：起线程等 QMP 就绪后发 load。
       成功 → 直接恢复；失败 → 线程自己删标记并放行，本次按冷启动继续。 */
    if (file_ok(s_snap_state_file)) {
        pthread_t th;
        if (pthread_create(&th, NULL, snap_load_thread, NULL) == 0) {
            pthread_detach(th);
        } else {
            LOGW("快照恢复线程创建失败，本次按冷启动继续");
        }
    }

    /* 父进程：若本次是快照恢复，起一个线程连上 QEMU 的迁移 socket 并喂快照 */
    if (s_snap_sock[0] != '\0') {
        pthread_t th;
        if (pthread_create(&th, NULL, snap_feed_thread, NULL) == 0) {
            pthread_detach(th);
        } else {
            LOGE("快照中转线程创建失败");
        }
    }

    /* 首次开机 provisioning（全新 /data 没有 Setup Wizard 会黑屏，见上面的注释） */
    if (p->serial_log_path != NULL) {
        VmProvisionArgs *prov = (VmProvisionArgs *) calloc(1, sizeof(*prov));
        if (prov != NULL) {
            snprintf(prov->log, sizeof(prov->log), "%s", p->serial_log_path);
            snprintf(prov->sock, sizeof(prov->sock), "%s", p->serial_log_path);
            char *slash = strrchr(prov->sock, '/');
            if (slash != NULL) {
                snprintf(slash + 1,
                         sizeof(prov->sock) - (size_t) (slash + 1 - prov->sock),
                         "console.sock");
            } else {
                prov->sock[0] = '\0';
            }
            prov->marker[0] = '\0';
            if (s_snap_state_file[0] != '\0') {
                snprintf(prov->marker, sizeof(prov->marker), "%s", s_snap_state_file);
                char *ms = strrchr(prov->marker, '/');
                if (ms != NULL) {
                    snprintf(ms + 1,
                             sizeof(prov->marker) - (size_t) (ms + 1 - prov->marker),
                             ".guest_provisioned");
                } else {
                    prov->marker[0] = '\0';
                }
            }
            pthread_t th;
            if (prov->sock[0] != '\0' && prov->marker[0] != '\0' &&
                pthread_create(&th, NULL, vm_provision_thread, prov) == 0) {
                pthread_detach(th);
            } else {
                free(prov);
            }
        }
    }
    return 0;
}

int vm_qemu_start(const VmQemuParams *p)
{
    pthread_mutex_lock(&s_lock);
    if (s_started) {
        pthread_mutex_unlock(&s_lock);
        LOGW("已经启动过，忽略");
        return -1;
    }
    if (p == NULL || !file_ok(p->kernel_path)) {
        pthread_mutex_unlock(&s_lock);
        LOGE("内核不存在或不可读：%s", p && p->kernel_path ? p->kernel_path : "(null)");
        return -1;
    }
    if (!file_ok(p->system_img_path)) {
        pthread_mutex_unlock(&s_lock);
        LOGE("system.img 不存在或不可读：%s",
             p->system_img_path ? p->system_img_path : "(null)");
        return -1;
    }

    /* p13 uses standalone ext4 partitions and a complete first-stage fstab in
       its ramdisk. Keep the legacy DT fstab for GPT guests such as p9. */
    const bool physical_layout = image_is_plain_ext4(p->system_img_path);
    setenv("VMHOST_DT_FSTAB", physical_layout ? "none" : "legacy", 1);
    const bool p9_sar = guest_is_p9_api28(p);
    if (p9_sar) {
        setenv("VMHOST_SAR", "1", 1);
    } else {
        unsetenv("VMHOST_SAR");
    }
    LOGI("guest disk layout: %s (VMHOST_DT_FSTAB=%s, SAR=%d)",
         physical_layout ? "physical-ext4" : "gpt",
         physical_layout ? "none" : "legacy", p9_sar ? 1 : 0);

    s_started = true;
    s_running = true;
    s_argc = 0;
    s_serial_log[0] = '\0';
    if (p->serial_log_path != NULL) {
        snprintf(s_serial_log, sizeof(s_serial_log), "%s", p->serial_log_path);
    }

    /* 若随包分发的 AOSP QEMU(ranchu) 在 nativeLibraryDir 里，就走子进程模式 ——
       那是目前唯一验证过能让这套访客跑到 boot_completed 的方式（见文件中部说明）。 */
    {
        char lib_dir[ARG_CAP];
        if (self_lib_dir(lib_dir, sizeof(lib_dir))) {
            bool tried = false;
            for (size_t i = 0;
                 i < sizeof(kQemuChildNames) / sizeof(kQemuChildNames[0]); i++) {
                char exe[ARG_CAP];
                snprintf(exe, sizeof(exe), "%s/%s", lib_dir, kQemuChildNames[i]);
                if (!file_ok(exe)) {
                    continue;
                }
                tried = true;
                if (spawn_qemu_child(p, exe, lib_dir) == 0) {
                    pthread_mutex_unlock(&s_lock);
                    return 0;
                }
                LOGW("%s 拉起失败，继续尝试其它候选", exe);
            }
            if (tried) {
                LOGW("子进程模式启动失败，退回进程内嵌方式");
            } else {
                LOGI("nativeLibraryDir(%s) 里没有 QEMU 可执行体，"
                     "使用进程内嵌 QEMU（-M virt）。"
                     "提示：AOSP QEMU 需由 build_qemu_aosp.sh 安装为 "
                     "jniLibs/<abi>/%s", lib_dir, kQemuChildNames[0]);
            }
        } else {
            LOGW("无法定位 nativeLibraryDir，使用进程内嵌 QEMU");
        }
    }

    const int mem = (p->memory_mb > 0) ? p->memory_mb : 2048;
    const int cores = (p->cores > 0) ? p->cores : 4;

    add_arg("%s", "qemu-system-aarch64");
    add_arg("%s", "-M");
    add_arg("%s", "virt");
    add_arg("%s", "-cpu");
    add_arg("%s", "cortex-a57");
    add_arg("%s", "-smp");
    add_arg("%d", cores);
    add_arg("%s", "-m");
    add_arg("%d", mem);
    add_arg("%s", "-kernel");
    add_arg("%s", p->kernel_path);

    if (file_ok(p->initrd_path)) {
        add_arg("%s", "-initrd");
        add_arg("%s", p->initrd_path);
    }

    /* 上游 QEMU 没有 ranchu 机器类型，用通用 virt 平台 + virtio 设备。
       Android 11 的 dm-verity 会拦 system.img，先用 permissive 把链路跑通。 */
    add_arg("%s", "-append");
    add_arg("%s",
            "console=ttyAMA0 earlycon=pl011,0x09000000 "
            "androidboot.hardware=ranchu androidboot.selinux=permissive "
            "androidboot.veritymode=disabled root=/dev/vda");

    /* 磁盘布局必须与访客 rootfs 里的 fstab 完全一致：访客用的是**固定设备路径**
       （不依赖 by-name/super），而 virtio-blk-pci 的 vdX 字母就是这里的挂载顺序。
       访客 fstab（在 ramdisk 的 fstab.ranchu 里）：
         /dev/block/vda /system   /vdb /vendor   /vdc /product
         /vdd /system_ext        /vde /metadata  /vdf /data
       顺序错一块或漏一块，first-stage init 都会报
       "Failed to mount required partitions early" 然后 InitFatalReboot。 */
    add_arg("%s", "-drive");
    add_arg("file=%s,if=virtio,format=raw,readonly=on", p->system_img_path);          /* vda */

    if (file_ok(p->vendor_img_path)) {
        add_arg("%s", "-drive");
        add_arg("file=%s,if=virtio,format=raw,readonly=on", p->vendor_img_path);      /* vdb */
    }
    if (file_ok(p->product_img_path)) {
        add_arg("%s", "-drive");
        add_arg("file=%s,if=virtio,format=raw,readonly=on", p->product_img_path);     /* vdc */
    }
    if (file_ok(p->system_ext_img_path)) {
        add_arg("%s", "-drive");
        add_arg("file=%s,if=virtio,format=raw,readonly=on", p->system_ext_img_path);  /* vdd */
    }
    if (file_ok(p->metadata_img_path)) {
        add_arg("%s", "-drive");
        add_arg("file=%s,if=virtio,format=raw", p->metadata_img_path);                /* vde，可写 */
    }
    if (file_ok(p->userdata_img_path)) {
        add_arg("%s", "-drive");
        add_arg("file=%s,if=virtio,format=raw", p->userdata_img_path);                /* vdf，可写 */
    }

    /* 网络：QEMU 内置的用户态 NAT（libslirp）。
       访客通过 DHCP 拿到 10.0.2.15，网关 10.0.2.2，DNS 10.0.2.3；
       slirp 在 QEMU 进程内把访客的 TCP/UDP 直接转成宿主 socket，
       因此**不需要**宿主侧的 VpnService 就能上网。
       （VpnService 那条路留给以后需要「访客流量走宿主网络栈」的场景。）

       romfile= 是必须的：virtio-net-pci 默认带 efi-virtio.rom（x86 的 PXE
       选项 ROM），QEMU 会去 <prefix>/share/qemu 找这个文件并更新 ROM 的 PCI
       ID；我们把 QEMU 嵌进 .so 后没有那个目录，于是报
       "failed to find romfile" 然后 exit()。而 aarch64 根本不用 x86 选项 ROM，
       传空串即可跳过加载（见 hw/pci/pci.c: `!strlen(romfile)` 直接 return）。 */
    if (p->enable_network) {
        add_arg("%s", "-netdev");
        add_arg("%s", "user,id=net0");
        add_arg("%s", "-device");
        add_arg("%s", "virtio-net-pci,netdev=net0,romfile=");
    }

    /* 输入设备。
       virtio-multitouch 提供触摸屏（绝对坐标 + 多指），virtio-keyboard 提供按键。
       这些设备在 realize 时会自己 qemu_input_handler_bind()，
       所以即使没有 UI 前端（我们用的是 -display none），
       qemu_input_queue_mtt / qemu_input_event_send_key_qcode 也能正确路由到设备。 */
    add_arg("%s", "-device");
    add_arg("%s", "virtio-multitouch-pci");
    add_arg("%s", "-device");
    add_arg("%s", "virtio-keyboard-pci");

    /* 显示暂时由引擎自己渲染占位画面，串口日志落盘以便真机排查 */
    add_arg("%s", "-display");
    add_arg("%s", "none");

    if (p->serial_log_path != NULL) {
        add_arg("%s", "-serial");
        add_arg("file:%s", p->serial_log_path);
    }

    /* 不启用图形加速相关依赖，避免 NDK 环境下的多余符号 */
    add_arg("%s", "-no-reboot");
    s_argv[s_argc] = NULL;

    dump_args();
    pthread_mutex_unlock(&s_lock);

    if (pthread_create(&s_thread, NULL, qemu_thread_main, NULL) != 0) {
        LOGE("创建 QEMU 线程失败");
        pthread_mutex_lock(&s_lock);
        s_started = false;
        s_running = false;
        pthread_mutex_unlock(&s_lock);
        return -1;
    }
    return 0;
}

/** QEMU 主循环是否已经返回（线程即将结束）。 */
static bool vm_qemu_is_finished(void)
{
    pthread_mutex_lock(&s_lock);
    const bool done = s_finished;
    pthread_mutex_unlock(&s_lock);
    return done;
}

bool vm_qemu_stop(int timeout_ms)
{
    pthread_mutex_lock(&s_lock);
    const bool started = s_started;
    const pid_t child = s_child_pid;
    pthread_mutex_unlock(&s_lock);

    if (!started) {
        return true;   /* 从没启动过 */
    }

    /* 子进程模式：AOSP QEMU 没有 vmhost 停机通道，按信号停。
       SIGTERM 先给一次机会，超时再 SIGKILL 兜底。 */
    if (child > 0) {
        /* 停机前抓一份快照（供下次秒开）。必须先冻住 guest，
           所以 save 走的是「QMP stop → vmhostsnapshot save」。 */
        snap_try_save();
        LOGI("请求子进程 QEMU 停机（pid=%d，最多等 %d ms）", child, timeout_ms);
        kill(child, SIGTERM);
        const int step_ms = 20;
        for (int waited = 0; waited < timeout_ms && child_alive(); waited += step_ms) {
            usleep((useconds_t) step_ms * 1000);
        }
        if (child_alive()) {
            LOGW("子进程 QEMU 未在 %d ms 内退出，SIGKILL", timeout_ms);
            kill(child, SIGKILL);
            waitpid(child, NULL, 0);
        } else {
            LOGI("子进程 QEMU 已退出");
        }
        s_child_pid = -1;
        /* 必须清掉启动标记。否则同一进程内「退出实例 → 再次进入」的第二次启动
           会命中 vm_qemu_start 里的 s_started 检查，被当成"已经启动过，忽略"，
           结果 QEMU 永远起不来（表现是黑屏、logs 里只有 frame.request 没有
           console.log）。真机实测：on_window_gone 停机后再 onStart 就会踩到。 */
        pthread_mutex_lock(&s_lock);
        s_started = false;
        s_running = false;
        pthread_mutex_unlock(&s_lock);
        return true;
    }

    if (!vm_qemu_is_finished()) {
        LOGI("请求 QEMU 停机（最多等 %d ms）", timeout_ms);
        vmhost_control_request_shutdown();
    }

    /* 轮询等待主循环返回。用轮询而不是 pthread_timedjoin_np，
       是为了不依赖 bionic 的非标准扩展。 */
    const int step_ms = 20;
    for (int waited = 0; waited < timeout_ms && !vm_qemu_is_finished(); waited += step_ms) {
        usleep((useconds_t) step_ms * 1000);
    }

    if (!vm_qemu_is_finished()) {
        LOGW("QEMU 未在 %d ms 内退出，放弃等待（进程退出时会被系统回收）", timeout_ms);
        return false;
    }

    /* join 只能做一次，且必须在锁外做，否则会与线程收尾互相等待 */
    pthread_mutex_lock(&s_lock);
    const bool need_join = !s_joined;
    if (need_join) {
        s_joined = true;
    }
    pthread_mutex_unlock(&s_lock);

    if (need_join) {
        pthread_join(s_thread, NULL);
    }
    LOGI("QEMU 已退出");
    pthread_mutex_lock(&s_lock);
    s_started = false;
    s_running = false;
    pthread_mutex_unlock(&s_lock);
    return true;
}

bool vm_qemu_is_child_process(void)
{
    /* 注意不要用 child_alive()：它会 waitpid 回收子进程，有副作用。 */
    pthread_mutex_lock(&s_lock);
    const bool child = (s_child_pid > 0);
    pthread_mutex_unlock(&s_lock);
    return child;
}

bool vm_qemu_qmp_path(char *out, size_t out_len)
{
    if (out == NULL || out_len == 0) {
        return false;
    }

    pthread_mutex_lock(&s_lock);
    bool ok = (s_serial_log[0] != '\0');
    if (ok) {
        /* 与 spawn_qemu_child() 里拼 -qmp unix:<...>/qmp.sock 保持同一套推导 */
        char path[ARG_CAP];
        snprintf(path, sizeof(path), "%s", s_serial_log);
        char *slash = strrchr(path, '/');
        if (slash != NULL) {
            snprintf(slash + 1, sizeof(path) - (size_t) (slash + 1 - path), "qmp.sock");
            snprintf(out, out_len, "%s", path);
        } else {
            ok = false;
        }
    }
    pthread_mutex_unlock(&s_lock);
    return ok;
}

bool vm_qemu_is_running(void)
{
    pthread_mutex_lock(&s_lock);
    const bool child_mode = s_child_mode;
    const bool running = s_running;
    pthread_mutex_unlock(&s_lock);

    /* 子进程模式**必须以子进程存活为准**。
       曾经这里回落到 s_running —— 那个标志只在 stop/reset 里清，子进程崩了它
       还是 true，于是"QEMU 已停止运行"那条分支永远不会走，僵尸也收不掉，
       快照恢复失败也就没人回退（实测踩到）。child_alive() 会在回收子进程后
       返回 false，正是我们要的判据。 */
    if (child_mode) {
        return child_alive();
    }
    return running;
}

bool vm_qemu_has_started(void)
{
    pthread_mutex_lock(&s_lock);
    const bool started = s_started;
    pthread_mutex_unlock(&s_lock);
    return started;
}

/**
 * 本次启动是不是「快照恢复」、并且已经确定失败了。
 *
 * 判据很直接：走的是 -incoming 恢复，而子进程已经不在了。真机实测：
 * 拿一份完整的迁移流喂回去，QEMU 在 RAM 段就报
 * `Unknown ramblock "", cannot accept migration` 然后 exit(1) ——
 * 这条流不是它认的格式（ranchu/gfxstream 侧还有 aemu 的快照钩子）。
 * 调用方拿到 true 就该把快照删掉、按冷启动重来，否则实例永远黑屏。
 */
bool vm_qemu_restore_failed(void)
{
    if (s_child_pid > 0 && child_alive()) {
        return false;   /* 还活着，谈不上失败 */
    }
    pthread_mutex_lock(&s_lock);
    const bool failed = s_restoring;
    pthread_mutex_unlock(&s_lock);
    return failed;
}

/** 子进程退出后复位启动状态，让上层能再走一次 vm_qemu_start（冷启动）。 */
void vm_qemu_reset(void)
{
    pthread_mutex_lock(&s_lock);
    s_started = false;
    s_running = false;
    s_finished = false;
    s_joined = false;
    s_child_mode = false;
    s_child_pid = -1;
    s_restoring = false;
    s_snap_sock[0] = '\0';
    s_snap_file[0] = '\0';
    pthread_mutex_unlock(&s_lock);
}
