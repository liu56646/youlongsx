/*
 * 探针 v3：作为 initramfs 的 rdinit。
 *   PID1 本体 exec /init 走正常启动；
 *   fork 出的 PID2 观察者：先在本命名空间挂 proc，再 setns 进 init 的 mount
 *   命名空间，然后直接 dump /proc/1（wchan/stack/syscall/stat/fd）以及
 *   /dev/block，用来看二阶段 init 到底卡在哪。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/syscall.h>
#include <sched.h>
#include <sys/fcntl.h>

static int OUT = -1;

static void w(const char *s) { if (OUT >= 0) write(OUT, s, strlen(s)); }

static void pf(const char *fmt, ...)
{
    char b[1200];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b, sizeof b, fmt, ap);
    va_end(ap);
    w(b);
}

static void cat(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) { pf("DUMP: open %s fail(errno=%d)\n", path, errno); return; }
    char b[1500];
    ssize_t n = read(fd, b, sizeof b - 1);
    if (n > 0) {
        b[n] = 0;
        for (char *p = b; *p; p++) if (*p == '\n') *p = '|';
        pf("DUMP: %s: %s\n", path, b);
    } else {
        pf("DUMP: %s: <read=%zd errno=%d>\n", path, n, errno);
    }
    close(fd);
}

static void ls(const char *path, int depth)
{
    DIR *d = opendir(path);
    if (!d) { pf("DUMP: opendir %s fail(errno=%d)\n", path, errno); return; }
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char full[1024];
        snprintf(full, sizeof full, "%s/%s", path, e->d_name);
        char link[1024];
        ssize_t n = readlink(full, link, sizeof link - 1);
        if (n > 0) { link[n] = 0; pf("DUMP: %s -> %s\n", full, link); }
        else pf("DUMP: %s\n", full);
        if (depth > 0 && e->d_type == DT_DIR) ls(full, depth - 1);
    }
    closedir(d);
}

static void reopen_kmsg(void)
{
    int fd = open("/dev/kmsg", O_WRONLY);
    if (fd >= 0) { OUT = fd; pf("DUMP: 已在新命名空间重开 /dev/kmsg\n"); }
    else pf("DUMP: 重开 /dev/kmsg 失败 errno=%d\n", errno);
}

static void cat_n(const char *path, int maxlines)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) { pf("DUMP: open %s fail(errno=%d)\n", path, errno); return; }
    char b[4096];
    ssize_t n = read(fd, b, sizeof b - 1);
    if (n > 0) {
        b[n] = 0;
        int line = 0;
        pf("DUMP: %s:\n", path);
        char *p = b;
        while (p && *p && line < maxlines) {
            char *nl = strchr(p, '\n');
            if (nl) *nl = 0;
            pf("DUMP:   %s\n", p);
            line++;
            p = nl ? nl + 1 : NULL;
        }
    }
    close(fd);
}

static void dump_pid1(void)
{
    cat("/proc/1/comm");
    cat("/proc/1/wchan");
    cat("/proc/1/syscall");
    cat_n("/proc/1/status", 4);     /* 含 State: 行 */
}

/*
 * 读 /proc/1/syscall：解析出阻塞的系统调用与参数；若是 openat/open 之类，
 * 直接从 /proc/1/mem 把 pathname 指针指向的字符串读出来，定位卡在哪。
 */
static void dump_pid1_syscall_path(void)
{
    int fd = open("/proc/1/syscall", O_RDONLY);
    if (fd < 0) { pf("DUMP: open /proc/1/syscall fail(errno=%d)\n", errno); return; }
    char b[256] = {0};
    ssize_t n = read(fd, b, sizeof b - 1);
    close(fd);
    if (n <= 0) { pf("DUMP: /proc/1/syscall 读空 (n=%zd)\n", n); return; }
    b[n] = 0;
    for (char *p = b; *p; p++) if (*p == '\n') *p = 0;
    pf("DUMP: /proc/1/syscall: %s\n", b);
    if (strstr(b, "running")) return;

    unsigned long nr = 0, a0 = 0, a1 = 0, a2 = 0;
    if (sscanf(b, "%lu %lx %lx %lx", &nr, &a0, &a1, &a2) < 3) return;

    unsigned long path_ptr = 0, flags = 0;
    const char *name = NULL;
    switch (nr) {
    case 56:  name = "openat";  path_ptr = a1; flags = a2; break;   /* openat(dirfd,path,flags) */
    case 61:  name = "open";    path_ptr = a0; flags = a1; break;
    case 48:  name = "faccessat"; path_ptr = a1; flags = a2; break;
    case 49:  name = "chdir";   path_ptr = a0; break;
    case 34:  name = "mkdirat"; path_ptr = a1; break;
    case 437: name = "openat2"; path_ptr = a1; break;
    case 80:  name = "fstat";   break;
    case 78:  name = "readlinkat"; path_ptr = a1; break;
    default:  break;
    }
    if (!name || !path_ptr) {
        pf("DUMP: syscall=%lu 不是路径类，跳过取路径\n", nr);
        return;
    }
    pf("DUMP: >>> init 卡在 %s，flags=0x%lx，path 指针=0x%lx\n", name, flags, path_ptr);

    int mem = open("/proc/1/mem", O_RDONLY);
    if (mem < 0) { pf("DUMP: open /proc/1/mem fail(errno=%d)\n", errno); return; }
    char path[300] = {0};
    ssize_t r = pread(mem, path, sizeof path - 1, (off_t)path_ptr);
    if (r > 0) {
        path[r] = 0;
        pf("DUMP: >>>>>> init 正在打开: %s\n", path);
    } else {
        pf("DUMP: pread(/proc/1/mem, 0x%lx) 失败 r=%zd errno=%d\n", path_ptr, r, errno);
    }
    close(mem);
}
static void dump_all_comms(void)
{
    DIR *d = opendir("/proc");
    if (!d) { pf("DUMP: opendir /proc fail(errno=%d)\n", errno); return; }
    struct dirent *e;
    int n = 0;
    int logd = 0, vold = 0, apexd = 0, sm = 0, hwsm = 0, zygote = 0, ss = 0;
    int sf = 0, bootanim = 0, netd = 0, ueventd = 0, adbd = 0, auditd = 0;
    while ((e = readdir(d))) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        n++;
        char p[160], b[64] = {0};
        snprintf(p, sizeof p, "/proc/%s/comm", e->d_name);
        int fd = open(p, O_RDONLY);
        if (fd >= 0) { ssize_t r = read(fd, b, sizeof b - 1); if (r > 0) b[r] = 0; close(fd); }
        pf("DUMP: pid=%s comm=%s\n", e->d_name, b);
        if (strstr(b, "logd")) logd = 1;
        if (strstr(b, "vold")) vold = 1;
        if (strstr(b, "apexd")) apexd = 1;
        if (strstr(b, "servicemanager")) sm = 1;
        if (strstr(b, "hwservicemanager")) hwsm = 1;
        if (strstr(b, "zygote")) zygote = 1;
        if (strstr(b, "system_server")) ss = 1;
        if (strstr(b, "surfaceflinger")) sf = 1;
        if (strstr(b, "bootanim")) bootanim = 1;
        if (strstr(b, "netd")) netd = 1;
        if (strstr(b, "ueventd")) ueventd = 1;
        if (strstr(b, "adbd")) adbd = 1;
        if (strstr(b, "auditd")) auditd = 1;
    }
    closedir(d);
    pf("DUMP: [汇总] 总数=%d ueventd=%d logd=%d servicemanager=%d hwservicemanager=%d "
       "vold=%d apexd=%d netd=%d zygote=%d system_server=%d surfaceflinger=%d bootanim=%d "
       "adbd=%d auditd=%d\n",
       n, ueventd, logd, sm, hwsm, vold, apexd, netd, zygote, ss, sf, bootanim, adbd, auditd);
}

/* ===== GPU 诊断（方案 B 排障）：virtio 设备绑定 / drm 节点 / 内核日志 ===== */
static void gpu_diag(void)
{
    struct dirent *e;
    DIR *d = opendir("/sys/bus/virtio/devices");
    if (d) {
        while ((e = readdir(d))) {
            if (e->d_name[0] == '.') continue;
            char p[256], tgt[256];
            snprintf(p, sizeof p, "/sys/bus/virtio/devices/%s", e->d_name);
            ssize_t n = readlink(p, tgt, sizeof tgt - 1);
            tgt[n > 0 ? n : 0] = 0;
            snprintf(p, sizeof p, "/sys/bus/virtio/devices/%s/driver", e->d_name);
            ssize_t dn = readlink(p, tgt, sizeof tgt - 1);
            if (dn > 0) { tgt[dn] = 0; pf("DUMP: virtio dev %s -> driver %s\n", e->d_name, tgt); }
            else pf("DUMP: virtio dev %s -> NO_DRIVER (errno=%d)\n", e->d_name, errno);
        }
        closedir(d);
    } else {
        pf("DUMP: opendir /sys/bus/virtio/devices fail errno=%d\n", errno);
    }

    d = opendir("/dev/dri");
    if (d) {
        while ((e = readdir(d))) {
            if (e->d_name[0] != '.') pf("DUMP: /dev/dri/%s\n", e->d_name);
        }
        closedir(d);
    } else {
        pf("DUMP: 无 /dev/dri (errno=%d)\n", errno);
    }

    /* drm_core_init(fs_initcall) 是否执行：成功会创建 /sys/class/drm */
    d = opendir("/sys/class/drm");
    if (d) {
        pf("DUMP: /sys/class/drm 存在 => drm_core_init 已创建 drm_class\n");
        while ((e = readdir(d))) {
            if (e->d_name[0] != '.') pf("DUMP:   /sys/class/drm/%s\n", e->d_name);
        }
        closedir(d);
    } else {
        pf("DUMP: /sys/class/drm 不存在 (errno=%d) => drm_core_init 未创建 drm_class\n", errno);
    }

    int k = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
    if (k >= 0) {
        char b[1024];
        ssize_t r;
        int cnt = 0;
        while ((r = read(k, b, sizeof b - 1)) > 0 && cnt < 400) {
            b[r] = 0;
            pf("KMSG %s", b);
            cnt++;
        }
        close(k);
        pf("DUMP: kmsg 尾部 %d 条\n", cnt);
    } else {
        pf("DUMP: open /dev/kmsg fail errno=%d\n", errno);
    }
}

int main(int argc, char **argv)
{
    (void)argc; (void)argv;

    /* ramdisk 里的 dev/console 可能是 touch 出来的普通文件（cpio 打包丢设备节点），
       写进去到不了串口 —— 先修成字符设备 c 5 1 再打开。 */
    {
        struct stat st;
        if (stat("/dev/console", &st) == 0 && S_ISREG(st.st_mode)) {
            unlink("/dev/console");
        }
        if (access("/dev/console", F_OK) != 0) {
            mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));
        }
        /* 顺带把 /dev/kmsg 也补齐（c 1 11），dmesg 读/写通道备用 */
        if (access("/dev/kmsg", F_OK) != 0) {
            mknod("/dev/kmsg", S_IFCHR | 0600, makedev(1, 11));
        }
    }
    if (access("/dev/kmsg", F_OK) != 0) {
        mount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755");
    }
    OUT = open("/dev/console", O_WRONLY);
    if (OUT < 0) OUT = open("/dev/kmsg", O_WRONLY);
    if (OUT < 0) OUT = 2;

    pid_t pid = fork();
    if (pid == 0) {
        pf("DUMP: 观察者启动 pid=%d\n", getpid());

        /* 必须先把自己隔离到一个新 mount ns，否则我们挂的 proc/sys 会污染
           init 的命名空间，导致它自己挂载失败直接 abort */
        if (unshare(CLONE_NEWNS) != 0)
            pf("DUMP: unshare 失败 errno=%d\n", errno);
        mkdir("/proc", 0755);
        if (mount("proc", "/proc", "proc", 0, NULL) != 0)
            pf("DUMP: 挂 proc 失败 errno=%d\n", errno);
        mkdir("/sys", 0755);
        mount("sysfs", "/sys", "sysfs", 0, NULL);

        /* 不需要 setns：procfs 是按 PID namespace 共享的，同 PID ns 下
           /proc/1 就是 init；它挂的 /dev 通过 /proc/1/root/dev 看。 */
        usleep(600 * 1000);

        for (int i = 0; i < 90; i++) {
            /* /proc 有时会在后期读不到，缺了就重新挂一次，保证观测面不丢 */
            if (access("/proc/1", F_OK) != 0) {
                mkdir("/proc", 0755);
                mount("proc", "/proc", "proc", 0, NULL);
            }
            pf("DUMP: ===== iter %d =====\n", i);
            dump_pid1();
            dump_pid1_syscall_path();
            if (i == 4 || i == 20 || i == 50) {
                gpu_diag();
            }
            pf("DUMP: --- /proc/1 目录（cwd/exe/root/fd）---\n");
            ls("/proc/1", 0);
            pf("DUMP: --- 全部进程 ---\n");
            dump_all_comms();
            sleep(2);
        }
        while (1) pause();
    }

    /*
     * 关键：绝不能把我们的日志 fd 泄漏给 /init —— init 会把它传给**所有** service，
     * 而 /dev 之后会被换成 tmpfs，这个 fd 指向的旧 inode 就变成 "(deleted)"；
     * ART 在 system_server 里检查继承来的 fd，遇到
     *   "JNI FatalError called: (system_server) Not whitelisted (3): /dev/console (deleted)"
     * 就直接 abort → zygote 退出 → 无限重启，启动永远走不完。
     * 实测：init 的 fd 3 正是这里 open("/dev/console") 落下来的。
     */
    if (OUT > 2) {
        fcntl(OUT, F_SETFD, FD_CLOEXEC);
    }

    char *av[] = {"/init", NULL};
    execv("/init", av);
    return 127;
}
