/*
 * VMHost 轻量崩溃捕获（LD_PRELOAD 进 guest 的 iorapd / zygote 等进程）。
 * 崩时把「进程名 + 信号 + PC/SP/FP/LR + 帧指针回溯 + maps」追加写到 /metadata/crash.log。
 *
 * ⚠️ 两个必须遵守的约束（都是实测踩出来的）：
 *  1) **绝对不能在构造函数里常驻打开日志文件**。zygote fork 出的 system_server 会继承
 *     zygote 的所有 fd，ART 会检查继承来的 fd 是否在白名单里，非白名单直接：
 *       JNI FatalError called: (system_server) Not whitelisted (3): /metadata/crash.log
 *     → abort。CLOEXEC 也没用（fork 出来的子进程不 exec）。所以只在真正要写时才 open/close。
 *  2) 不拦 liblog 整个家族（zygote 的子进程会继承，会把所有 app 的日志吞掉），
 *     只拦 __android_log_assert —— LOG_ALWAYS_FATAL / CHECK 都走它，足以拿到 abort message。
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <unistd.h>

static int open_log(void) {
    int fd = open("/metadata/crash.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
    return fd >= 0 ? fd : 2;
}

static void wr(int fd, const char *s) {
    if (fd >= 0) {
        ssize_t r = write(fd, s, strlen(s));
        (void)r;
    }
}

static void emit(int fd, uintptr_t v) {
    char b[48];
    int n = snprintf(b, sizeof b, "  0x%lx\n", (unsigned long)v);
    if (fd >= 0) {
        ssize_t r = write(fd, b, (size_t)n);
        (void)r;
    }
}

static void on_signal(int sig, siginfo_t *si, void *ucp) {
    ucontext_t *uc = (ucontext_t *)ucp;
    char buf[512];
    char comm[64] = {0};
    int fd = open_log();

    int cf = open("/proc/self/comm", O_RDONLY);
    if (cf >= 0) {
        ssize_t r = read(cf, comm, sizeof comm - 1);
        if (r > 0) comm[r] = 0;
        close(cf);
    }
    {
        char *nl = strchr(comm, '\n');
        if (nl) *nl = 0;
    }

    wr(fd, "\n########## CRASH ##########\n");
    snprintf(buf, sizeof buf, "comm=%s pid=%d tid=%ld signal=%d si_code=%d addr=%p\n",
             comm, (int)getpid(), (long)syscall(SYS_gettid), sig,
             si ? si->si_code : 0, si ? si->si_addr : (void *)0);
    wr(fd, buf);

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
    wr(fd, buf);

    wr(fd, "--- backtrace (fp walk) ---\n");
    emit(fd, pc);
    if (lr) emit(fd, lr);
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
                emit(fd, ret);
                if (next <= cur) break;
                cur = next;
            }
        }
    }
    wr(fd, "--- end backtrace ---\n");

    {
        int mf = open("/proc/self/maps", O_RDONLY);
        if (mf >= 0) {
            char b[4096];
            ssize_t n;
            wr(fd, "--- maps ---\n");
            while ((n = read(mf, b, sizeof b)) > 0) {
                if (fd >= 0) {
                    ssize_t r = write(fd, b, (size_t)n);
                    (void)r;
                }
            }
            close(mf);
            wr(fd, "--- end maps ---\n");
        }
    }
    wr(fd, "########## END ##########\n");
    if (fd > 2) {
        fsync(fd);
        close(fd);
    }

    /*
     * 复位为默认动作并重新投递该信号，让进程以「信号致死」的真实面目退出。
     * ⚠️ 必须先把 sig 从屏蔽字里解除：进入 handler 时内核自动 block 了 sig，
     *    不解阻塞的话 raise(sig) 只会把它变成 pending（永远不会投递），
     *    接着的 _exit(1) 就会让进程看起来「干净退出(1)」——zygote 也只报
     *    "Process X exited cleanly (1)"，把真实崩溃彻底掩盖掉。
     */
    signal(sig, SIG_DFL);
    {
        sigset_t s;
        sigemptyset(&s);
        sigaddset(&s, sig);
        sigprocmask(SIG_UNBLOCK, &s, NULL);
    }
    raise(sig);
    _exit(1);
}

/* 只拦 __android_log_assert：LOG_ALWAYS_FATAL / CHECK 都走它 */
__attribute__((noreturn)) void __android_log_assert(const char *cond, const char *tag,
                                                     const char *fmt, ...) {
    char msg[1024];
    int fd = open_log();
    int n = snprintf(msg, sizeof msg, "\n[ANDROID_LOG_ASSERT] tag=%s cond=%s\n",
                     tag ? tag : "(null)", cond ? cond : "(null)");
    if (n < 0) n = 0;
    if (fmt && (size_t)n < sizeof msg - 1) {
        va_list ap;
        va_start(ap, fmt);
        int m = vsnprintf(msg + n, sizeof msg - (size_t)n, fmt, ap);
        va_end(ap);
        if (m > 0) n += m;
    }
    if (n > 0 && fd >= 0) {
        ssize_t r = write(fd, msg, (size_t)n);
        (void)r;
        fsync(fd);
    }
    if (fd > 2) close(fd);
    abort();
}

__attribute__((constructor)) static void crashlite_init(void) {
    /* 注意：这里**不打开任何文件**，避免给 zygote 的子进程多加一个 fd */

    static char altstack[SIGSTKSZ * 8];
    stack_t ss;
    memset(&ss, 0, sizeof ss);
    ss.ss_sp = altstack;
    ss.ss_size = sizeof(altstack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_signal;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
}
