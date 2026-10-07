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
#include "vmhost_control.h"

#include <pthread.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
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

/** 追加一块 virtio-blk（MMIO）。磁盘的先后顺序决定访客里的 vda/vdb/... */
static void add_blk_dev(const char *id, const char *path, bool readonly)
{
    add_arg("%s", "-drive");
    add_arg("if=none,id=%s,file=%s,format=raw%s,cache=unsafe",
            id, path, readonly ? ",readonly=on" : "");
    add_arg("%s", "-device");
    add_arg("virtio-blk-device,drive=%s", id);
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
static int spawn_qemu_child(const VmQemuParams *p, const char *exe_path, const char *lib_dir)
{
    const int mem = (p->memory_mb > 0) ? p->memory_mb : 2048;
    const int cores = (p->cores > 0) ? p->cores : 4;

    s_argc = 0;
    add_arg("%s", "qemu-system-aarch64");
    add_arg("%s", "-M");
    add_arg("%s", "ranchu");
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
    /* 与实验 exp47 完全一致的 cmdline。注意两点：
       - rdinit=/dumper：probe ramdisk 里的 PID1（dumper 只是 exec /init），
         与 exp47 同一条已验证的启动路径；
       - 不要 root=/dev/vda：会干扰 first-stage 的 switch_root
         （实测报 "Unable to move mount at '/dev'" → InitFatalReboot）；
       - audit=0 很关键：permissive 下 avc 会刷出几千行，占串口 I/O 又吃 CPU。 */
    add_arg("%s", "-append");
    add_arg("%s",
            "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive "
            "androidboot.veritymode=disabled androidboot.force_normal_boot=1 "
            "rdinit=/dumper ignore_loglevel panic=0 printk.devkmsg=on audit=0");

    /* 盘序必须与 exp47（ranchu 实测）一致。ranchu 机器上 virtio-blk 的 vdX 字母
       与挂载顺序**相反**：先挂 data 得到 vdf、最后挂 system 得到 vda，
       实测映射 vda=system vdb=vendor vdc=product vdd=system_ext vde=metadata
       vdf=data，正好满足访客 fstab。顺序错/缺一块都会 InitFatalReboot。 */
    if (file_ok(p->userdata_img_path))   add_blk_dev("d0data", p->userdata_img_path, false);
    if (file_ok(p->metadata_img_path))   add_blk_dev("d1meta", p->metadata_img_path, false);
    if (file_ok(p->system_ext_img_path)) add_blk_dev("d2sext", p->system_ext_img_path, true);
    if (file_ok(p->product_img_path))    add_blk_dev("d3prod", p->product_img_path, true);
    if (file_ok(p->vendor_img_path))     add_blk_dev("d4vend", p->vendor_img_path, true);
    if (file_ok(p->system_img_path))     add_blk_dev("d5sys",  p->system_img_path, true);

    add_arg("%s", "-device");
    add_arg("%s", "virtio-rng-device");
    add_arg("%s", "-device");
    add_arg("%s", "virtio-gpu-device");

    /* 注意：B1 子进程模式**先不带网络**。
       这台 AOSP QEMU 上 `-netdev user,id=net0` 会解析失败并直接报错退出
       （Parameter 'type' expects a netdev backend type），而 exp47 验证过的
       配置本来也没有网卡（配合 vendor 的 ranchu-net 补丁，无 eth0 也能正常
       启动到 boot_completed）。网络接入放到后续单独做。 */

    add_arg("%s", "-no-reboot");
    add_arg("%s", "-display");
    add_arg("%s", "none");
    if (p->serial_log_path != NULL) {
        add_arg("%s", "-serial");
        add_arg("file:%s", p->serial_log_path);
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
        /* 管道服务日志：打印访客的 pipe 请求有没有走到 aemu 的 AndroidPipe 服务
           （含首包的 "pipe:<name>" 服务名）。已知可用基线（exp47 的 Oct 5 构建）
           里访客会打开 7 次 `pipe:opengles`；这里用来对比 App 路径到底有没有打开，
           以定位"访客 EGL 连不上宿主"是没发起还是没被服务。 */
        setenv("VMHOSTPIPE_SVC", "1", 1);
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
        execve(exe_path, s_argv, environ);
        _exit(127);   /* 只有 exec 失败才会到这 */
    }

    s_child_pid = pid;
    LOGI("已拉起子进程 QEMU（ranchu 模式）pid=%d exe=%s", pid, exe_path);
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

bool vm_qemu_is_running(void)
{
    /* 子进程模式直接看子进程存活 */
    if (s_child_pid > 0 && child_alive()) {
        return true;
    }
    pthread_mutex_lock(&s_lock);
    bool running = s_running;
    pthread_mutex_unlock(&s_lock);
    return running;
}
