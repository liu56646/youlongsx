/*
 * 宿主侧 QEMU 崩溃捕获（LD_PRELOAD 进设备上的 qemu-system-aarch64）。
 * 宿主 tombstoned 不产 tombstone，所以自带帧指针回溯 + maps 写到文件。
 * 输出：/data/local/tmp/qemu_crash.log
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <unistd.h>

static int g_fd = -1;

static void wr(const char *s) {
    if (g_fd >= 0) {
        size_t n = strlen(s);
        ssize_t r = write(g_fd, s, n);
        (void)r;
    }
}

static void emit(uintptr_t v) {
    char b[48];
    int n = snprintf(b, sizeof b, "  0x%lx\n", (unsigned long)v);
    if (g_fd >= 0) {
        ssize_t r = write(g_fd, b, (size_t)n);
        (void)r;
    }
}

static void dump_maps(void) {
    wr("--- maps ---\n");
    int mf = open("/proc/self/maps", O_RDONLY);
    if (mf >= 0) {
        char b[4096];
        ssize_t n;
        while ((n = read(mf, b, sizeof b)) > 0) {
            if (g_fd >= 0) {
                ssize_t r = write(g_fd, b, (size_t)n);
                (void)r;
            }
        }
        close(mf);
    }
    wr("--- end maps ---\n");
}

static void on_signal(int sig, siginfo_t *si, void *ucp) {
    ucontext_t *uc = (ucontext_t *)ucp;
    char buf[256];

    wr("\n########## QEMU CRASH ##########\n");
    snprintf(buf, sizeof buf, "signal=%d si_code=%d tid=%ld fault=%p\n",
             sig, si ? si->si_code : 0, (long)syscall(SYS_gettid),
             si ? si->si_addr : 0);
    wr(buf);

    uintptr_t pc = 0, sp = 0, fp = 0, lr = 0;
#if defined(__aarch64__)
    if (uc) {
        pc = (uintptr_t)uc->uc_mcontext.pc;
        sp = (uintptr_t)uc->uc_mcontext.sp;
        fp = (uintptr_t)uc->uc_mcontext.regs[29];
        lr = (uintptr_t)uc->uc_mcontext.regs[30];
    }
#endif
    snprintf(buf, sizeof buf, "pc=0x%lx sp=0x%lx fp=0x%lx lr=0x%lx\n",
             (unsigned long)pc, (unsigned long)sp,
             (unsigned long)fp, (unsigned long)lr);
    wr(buf);

    wr("--- backtrace (fp walk) ---\n");
    emit(pc);
    if (lr) emit(lr);
    {
        uintptr_t cur = fp;
        int i;
        for (i = 0; i < 120 && cur; i++) {
            if ((cur & 0xf) != 0) break;
            if (sp && (cur < sp || cur > sp + (1u << 23))) break;
            {
                uintptr_t *f = (uintptr_t *)cur;
                uintptr_t next = f[0];
                uintptr_t ret = f[1];
                if (!ret) break;
                emit(ret);
                if (next <= cur) break;
                cur = next;
            }
        }
    }
    wr("--- end backtrace ---\n");
    dump_maps();
    wr("########## END ##########\n");
    if (g_fd >= 0) fsync(g_fd);

    signal(sig, SIG_DFL);
    raise(sig);
    _exit(1);
}

__attribute__((constructor)) static void qc_init(void) {
    g_fd = open("/data/local/tmp/qemu_crash.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (g_fd < 0) g_fd = 2;
    wr("qemucrash: loaded\n");

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_signal;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
}
