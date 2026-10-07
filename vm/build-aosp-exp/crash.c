/*
 * VMHost 实验用崩溃捕获器（LD_PRELOAD）。
 * QEMU 在设备上 SIGSEGV 后没有 tombstone，这里用信号处理器把
 * 崩溃信号 / 故障地址 / 指令指针 / 返回地址 + 主程序加载基址写到固定文件，
 * 之后再离线用 llvm-symbolizer 结合带调试信息的二进制还原函数名。
 *
 * 关键点：
 *   1) 先写 siginfo/ucontext 里的关键寄存器（异步信号安全），
 *      再尝试 _Unwind_Backtrace —— 后者在栈损坏时本身可能二次崩溃。
 *   2) 用独立信号栈（sigaltstack），防止栈溢出场景下 handler 无法运行。
 *   3) 处理完用 _exit() 直接退出，不再 re-raise，避免二次崩溃覆盖日志。
 */
#define _GNU_SOURCE
#include <signal.h>
#include <ucontext.h>
#include <unwind.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

static uintptr_t g_exe_base = 0;

static void find_exe_base(void)
{
    int fd = open("/proc/self/maps", O_RDONLY);
    if (fd < 0) return;
    char buf[8192];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return;
    buf[n] = '\0';

    char *line = buf;
    while (line && *line) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = '\0';
        if (strstr(line, "qemu-system-aarch64")) {
            unsigned long long base = 0;
            if (sscanf(line, "%llx", &base) == 1) {
                g_exe_base = (uintptr_t) base;
                return;
            }
        }
        if (!nl) break;
        line = nl + 1;
    }
}

struct bt_state {
    void **p;
    int n;
    int max;
};

static _Unwind_Reason_Code unwind_cb(struct _Unwind_Context *ctx, void *arg)
{
    struct bt_state *s = (struct bt_state *) arg;
    uintptr_t ip = _Unwind_GetIP(ctx);
    if (ip && s->n < s->max) {
        s->p[s->n++] = (void *) ip;
    }
    return _URC_NO_REASON;
}

static void wstr(int fd, const char *s)
{
    (void) write(fd, s, strlen(s));
}

static void handler(int sig, siginfo_t *info, void *uctx)
{
    int fd = open("/data/local/tmp/qemu_crash.txt",
                  O_CREAT | O_WRONLY | O_TRUNC, 0644);

    uintptr_t pc = 0, lr = 0, sp = 0, fault = 0;
    if (uctx) {
        ucontext_t *uc = (ucontext_t *) uctx;
        pc = (uintptr_t) uc->uc_mcontext.pc;
        sp = (uintptr_t) uc->uc_mcontext.sp;
        lr = (uintptr_t) uc->uc_mcontext.regs[30];
        fault = (uintptr_t) uc->uc_mcontext.fault_address;
    }

    if (fd >= 0) {
        char b[640];
        int len = snprintf(b, sizeof(b),
            "SIGNAL=%d si_code=%d si_addr=0x%llx exe_base=0x%llx\n"
            "PC=0x%llx PC_off=0x%llx\n"
            "LR=0x%llx LR_off=0x%llx\n"
            "SP=0x%llx FAULT=0x%llx\n",
            sig,
            info ? info->si_code : -999,
            (unsigned long long) (uintptr_t) (info ? info->si_addr : 0),
            (unsigned long long) g_exe_base,
            (unsigned long long) pc, (unsigned long long) (pc - g_exe_base),
            (unsigned long long) lr, (unsigned long long) (lr - g_exe_base),
            (unsigned long long) sp, (unsigned long long) fault);
        (void) write(fd, b, len);
    }

    /* 关键信息已落盘，以下尽力而为 */
    void *bt[96];
    struct bt_state st = { bt, 0, 96 };
    _Unwind_Backtrace(unwind_cb, &st);

    if (fd >= 0) {
        char b[128];
        int len = snprintf(b, sizeof(b), "unwind_frames=%d\n", st.n);
        (void) write(fd, b, len);
        for (int i = 0; i < st.n; i++) {
            uintptr_t a = (uintptr_t) bt[i];
            len = snprintf(b, sizeof(b), "#%02d abs=0x%llx off=0x%llx\n",
                           i, (unsigned long long) a,
                           (unsigned long long) (a - g_exe_base));
            (void) write(fd, b, len);
        }
        close(fd);
    }
    _exit(128 + sig);
}

__attribute__((constructor))
static void vmhost_crash_init(void)
{
    find_exe_base();

    static char altstack[SIGSTKSZ * 4];
    stack_t ss;
    ss.ss_sp = altstack;
    ss.ss_size = sizeof(altstack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
}
