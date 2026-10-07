/*
 * HWC 崩溃回溯捕获（LD_PRELOAD 进 composer 进程）。
 *
 * 关键约束：vendor 进程的 linker namespace 里看不到 libc 的 backtrace()/execinfo
 * （实测 "cannot locate symbol backtrace"），所以这里**自带帧指针回溯**，
 * 只依赖 ucontext（信号上下文里的 x29/x30）+ 直接读栈内存。
 *
 * 输出：/metadata/hwc_crash.log（退回 /data/system/hwc_crash.log）
 *      内容 = 信号信息 + PC/SP/FP/LR + 帧指针回溯 + 崩溃进程完整 maps
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

static int g_fd = -1;

static void wr(const char *s) {
    if (g_fd >= 0) {
        size_t n = strlen(s);
        ssize_t r = write(g_fd, s, n);
        (void)r;
    }
}

static void emit_pc(uintptr_t v) {
    char b[48];
    int n = snprintf(b, sizeof b, "  0x%lx\n", (unsigned long)v);
    if (g_fd >= 0) {
        ssize_t r = write(g_fd, b, n);
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

    wr("\n########## HWC CRASH ##########\n");
    snprintf(buf, sizeof buf, "signal=%d si_code=%d tid=%ld\n",
             sig, si ? si->si_code : 0, (long)syscall(SYS_gettid));
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
    emit_pc(pc);
    if (lr) emit_pc(lr);

    uintptr_t cur = fp;
    int i;
    for (i = 0; i < 80 && cur; i++) {
        if ((cur & 0xf) != 0) break;
        if (sp && (cur < sp || cur > sp + (1u << 23))) break; /* 限定本线程栈内 */
        uintptr_t *f = (uintptr_t *)cur;
        uintptr_t next = f[0];
        uintptr_t ret = f[1];
        if (!ret) break;
        emit_pc(ret);
        if (next <= cur) break;
        cur = next;
    }
    wr("--- end backtrace ---\n");

    dump_maps();

    wr("########## END ##########\n");
    if (g_fd >= 0) fsync(g_fd);

    /* 还原默认动作再自杀，保留“因该信号而死”的语义 */
    signal(sig, SIG_DFL);
    raise(sig);
    _exit(1);
}

/*
 * 拦截 libc 的 __android_log_assert：LOG_ALWAYS_FATAL 与 CHECK 都走它。
 * 它在 abort() 之前被调用——把 tag/cond/格式化消息写进同一份日志，
 * 再调 abort()，紧跟其后的那段回溯就是它的栈。
 */
static size_t g_log_bytes = 0;

static void log_line(const char *p, int n) {
    if (g_fd < 0 || n <= 0) return;
    if (g_log_bytes > (2u << 20)) return; /* 上限 2MB，防刷爆 */
    ssize_t r = write(g_fd, p, (size_t)n);
    if (r > 0) g_log_bytes += (size_t)r;
}

__attribute__((noreturn)) void __android_log_assert(const char *cond, const char *tag,
                                                     const char *fmt, ...) {
    char msg[1500];
    int n = snprintf(msg, sizeof msg, "\n[ANDROID_LOG_ASSERT]\ntag=%s\ncond=%s\n",
                     tag ? tag : "(null)", cond ? cond : "(null)");
    if (n < 0) n = 0;
    if (fmt && (size_t)n < sizeof msg - 1) {
        va_list ap;
        va_start(ap, fmt);
        int m = vsnprintf(msg + n, sizeof msg - (size_t)n, fmt, ap);
        va_end(ap);
        if (m > 0) n += m;
    }
    log_line(msg, n);
    if (g_fd >= 0) fsync(g_fd);
    abort();
}

/*
 * 整个 liblog 家族都拦下来写文件：这台 guest 的 logd/logcat 不可用，
 * 只有这样才能看到 HWC/gralloc 在 abort 之前自己打的错误。
 */
int __android_log_write(int prio, const char *tag, const char *text) {
    char b[1024];
    int n = snprintf(b, sizeof b, "[LOG %d %s] %s\n", prio, tag ? tag : "?",
                     text ? text : "");
    if (n > (int)sizeof b - 1) n = (int)sizeof b - 1;
    log_line(b, n);
    return text ? (int)strlen(text) : 0;
}

int __android_log_buf_write(int bufId, int prio, const char *tag, const char *text) {
    char b[1024];
    int n = snprintf(b, sizeof b, "[LOG%d %d %s] %s\n", bufId, prio, tag ? tag : "?",
                     text ? text : "");
    if (n > (int)sizeof b - 1) n = (int)sizeof b - 1;
    log_line(b, n);
    return text ? (int)strlen(text) : 0;
}

int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    char b[2048];
    int n = snprintf(b, sizeof b, "[LOG %d %s] ", prio, tag ? tag : "?");
    if (fmt && n > 0) {
        va_list ap;
        va_start(ap, fmt);
        int m = vsnprintf(b + n, sizeof b - (size_t)n, fmt, ap);
        va_end(ap);
        if (m > 0) n += m;
    }
    if (n > 0 && n < (int)sizeof b - 1) b[n++] = '\n';
    if (n > (int)sizeof b - 1) n = (int)sizeof b - 1;
    log_line(b, n);
    return n;
}

int __android_log_buf_print(int bufId, int prio, const char *tag, const char *fmt, ...) {
    char b[2048];
    int n = snprintf(b, sizeof b, "[LOG%d %d %s] ", bufId, prio, tag ? tag : "?");
    if (fmt && n > 0) {
        va_list ap;
        va_start(ap, fmt);
        int m = vsnprintf(b + n, sizeof b - (size_t)n, fmt, ap);
        va_end(ap);
        if (m > 0) n += m;
    }
    if (n > 0 && n < (int)sizeof b - 1) b[n++] = '\n';
    if (n > (int)sizeof b - 1) n = (int)sizeof b - 1;
    log_line(b, n);
    return n;
}

int __android_log_vprint(int prio, const char *tag, const char *fmt, va_list ap) {
    char b[2048];
    int n = snprintf(b, sizeof b, "[LOG %d %s] ", prio, tag ? tag : "?");
    if (fmt && n > 0) {
        int m = vsnprintf(b + n, sizeof b - (size_t)n, fmt, ap);
        if (m > 0) n += m;
    }
    if (n > 0 && n < (int)sizeof b - 1) b[n++] = '\n';
    if (n > (int)sizeof b - 1) n = (int)sizeof b - 1;
    log_line(b, n);
    return n;
}

/* 记下 abort() 的直接调用点（配合后面的回溯定位） */
__attribute__((noreturn)) void abort(void) {
    char b[128];
    int n = snprintf(b, sizeof b, "\n[ABORT] caller=%p\n", __builtin_return_address(0));
    log_line(b, n);
    if (g_fd >= 0) fsync(g_fd);
    raise(SIGABRT);
    _exit(1);
}

__attribute__((constructor)) static void hwcdbg_init(void) {
    g_fd = open("/metadata/hwc_crash.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (g_fd < 0) {
        g_fd = open("/data/system/hwc_crash.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
    }
    if (g_fd < 0) g_fd = 2;

    char buf[128];
    snprintf(buf, sizeof buf, "hwcdbg: loaded pid=%ld fd=%d\n", (long)getpid(), g_fd);
    wr(buf);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_signal;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
}
