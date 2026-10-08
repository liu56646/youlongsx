/*
 * libsigfix.so — LD_PRELOAD 全局拦截（引擎 spawn QEMU 时的唯一注入点）：
 * 1) pthread_create：新线程 trampoline 里解除崩溃信号屏蔽；
 * 2) pthread_sigmask / sigprocmask：任何线程试图 BLOCK/SETMASK
 *    SIGSEGV/SIGBUS/SIGABRT/SIGILL/SIGFPE 时自动剥离，保证崩溃信号永不屏蔽，
 *    让 vmhost 崩溃处理器能触发（aemu Thread::maskAllSignals 的 sigfillset 也拦得住）。
 * 3) VMHOST_PIN：把 QEMU 进程钉到宿主主频最高的那几个核上（性能，见文件末尾）。
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int (*pthread_create_fn)(pthread_t *, const pthread_attr_t *,
                                 void *(*)(void *), void *);
typedef int (*pthread_sigmask_fn)(int, const sigset_t *, sigset_t *);
typedef int (*sigprocmask_fn)(int, const sigset_t *, sigset_t *);

static pthread_create_fn real_pthread_create;
static pthread_sigmask_fn real_pthread_sigmask;
static sigprocmask_fn real_sigprocmask;

typedef struct {
    void *(*fn)(void *);
    void *arg;
} thread_ctx_t;

/* 从 set 中剥离崩溃信号 + 协程信号 */
static void strip_crash_signals(sigset_t *set) {
    sigdelset(set, SIGSEGV);
    sigdelset(set, SIGBUS);
    sigdelset(set, SIGABRT);
    sigdelset(set, SIGILL);
    sigdelset(set, SIGFPE);
    sigdelset(set, SIGUSR2);
    sigdelset(set, SIGCONT);
}

static void unblock_crash_signals(void) {
    sigset_t un;
    sigemptyset(&un);
    sigaddset(&un, SIGSEGV);
    sigaddset(&un, SIGBUS);
    sigaddset(&un, SIGABRT);
    sigaddset(&un, SIGILL);
    sigaddset(&un, SIGFPE);
    sigaddset(&un, SIGUSR2);
    sigaddset(&un, SIGCONT);
    if (!real_pthread_sigmask) {
        real_pthread_sigmask = (pthread_sigmask_fn)dlsym(RTLD_NEXT, "pthread_sigmask");
    }
    real_pthread_sigmask(SIG_UNBLOCK, &un, NULL);
}

static void *sigfix_trampoline(void *arg) {
    thread_ctx_t *ctx = (thread_ctx_t *)arg;
    void *(*fn)(void *) = ctx->fn;
    void *a = ctx->arg;
    free(ctx);
    unblock_crash_signals();
    return fn(a);
}

int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*start_routine)(void *), void *arg) {
    if (!real_pthread_create) {
        real_pthread_create = (pthread_create_fn)dlsym(RTLD_NEXT, "pthread_create");
    }
    thread_ctx_t *ctx = (thread_ctx_t *)malloc(sizeof(thread_ctx_t));
    if (!ctx) {
        return -1;
    }
    ctx->fn = start_routine;
    ctx->arg = arg;
    int rc = real_pthread_create(thread, attr, sigfix_trampoline, ctx);
    if (rc != 0) {
        free(ctx);
    }
    return rc;
}

static int sigfix_sigmask_common(int how, const sigset_t *set, sigset_t *oldset,
                                 int is_pthread) {
    int rc;
    if (set && (how == SIG_BLOCK || how == SIG_SETMASK)) {
        sigset_t cleaned = *set;
        strip_crash_signals(&cleaned);
        if (is_pthread) {
            if (!real_pthread_sigmask) {
                real_pthread_sigmask =
                    (pthread_sigmask_fn)dlsym(RTLD_NEXT, "pthread_sigmask");
            }
            rc = real_pthread_sigmask(how, &cleaned, oldset);
        } else {
            if (!real_sigprocmask) {
                real_sigprocmask = (sigprocmask_fn)dlsym(RTLD_NEXT, "sigprocmask");
            }
            rc = real_sigprocmask(how, &cleaned, oldset);
        }
        /* 无论如何确保崩溃信号已解除（防止 SETMASK 恰好只留这些信号的情形） */
        unblock_crash_signals();
        return rc;
    }
    if (is_pthread) {
        if (!real_pthread_sigmask) {
            real_pthread_sigmask =
                (pthread_sigmask_fn)dlsym(RTLD_NEXT, "pthread_sigmask");
        }
        return real_pthread_sigmask(how, set, oldset);
    }
    if (!real_sigprocmask) {
        real_sigprocmask = (sigprocmask_fn)dlsym(RTLD_NEXT, "sigprocmask");
    }
    return real_sigprocmask(how, set, oldset);
}

int pthread_sigmask(int how, const sigset_t *set, sigset_t *oldset) {
    return sigfix_sigmask_common(how, set, oldset, 1);
}

int sigprocmask(int how, const sigset_t *set, sigset_t *oldset) {
    return sigfix_sigmask_common(how, set, oldset, 0);
}

/* ---------------------------------------------------------------------------
 * 3) VMHOST_PIN：把本进程钉到宿主主频最高的那几个核上。
 *
 * 为什么放在这个库：引擎 spawn QEMU 时只 LD_PRELOAD 了 libsigfix.so
 * （见 vm/engine/src/main/cpp/src/vm_qemu.c），所以这是唯一"不用重编 APK/引擎"
 * 就能给 QEMU 子进程加启动修正的入口。
 *
 * 为什么要钉：这个 QEMU 是**单线程 TCG**（实测全程只占 ~1 个核，其余 7 个闲置），
 * 访客的启动速度几乎线性跟随宿主**实际主频**。同一镜像同一参数实测（8 Gen 3）：
 *   不钉核  ：servicemanager 26.0s / zygote 75.8s / surfaceflinger 154.4s
 *   钉到大核：servicemanager 19.0s / zygote 53.4s / surfaceflinger 104.1s  （1.48x）
 * 线程会继承亲和掩码，所以构造函数里设一次即可覆盖 QEMU 全部线程。
 *
 * 选择规则：逐核读 cpuN/cpufreq/cpuinfo_max_freq，取主频最高的一组
 * （本机 = cpu6/cpu7 的 4.32GHz）；读不到就不干预。
 * 环境变量 VMHOST_PIN_CPUS=<十六进制掩码> 可手工指定；=0 表示关闭（A/B 用）。
 * ------------------------------------------------------------------------- */
#define VMPIN_MAX_CPU 64

static void vmpin_apply(void) {
    const char *env = getenv("VMHOST_PIN_CPUS");
    cpu_set_t set;
    CPU_ZERO(&set);

    if (env != NULL) {
        unsigned long mask = strtoul(env, NULL, 16);
        if (mask == 0UL) {
            fprintf(stderr, "VMHOST_PIN 关闭（VMHOST_PIN_CPUS=0）\n");
            return;
        }
        for (int i = 0; i < VMPIN_MAX_CPU; i++) {
            if ((mask >> i) & 1UL) {
                CPU_SET(i, &set);
            }
        }
    } else {
        long freq[VMPIN_MAX_CPU];
        long best = -1;
        int n = (int)sysconf(_SC_NPROCESSORS_ONLN);
        if (n <= 0 || n > VMPIN_MAX_CPU) {
            return;
        }
        for (int i = 0; i < n; i++) {
            char path[128];
            long v = -1;
            snprintf(path, sizeof(path),
                     "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", i);
            freq[i] = -1;
            FILE *fp = fopen(path, "r");
            if (fp != NULL) {
                if (fscanf(fp, "%ld", &v) == 1) {
                    freq[i] = v;
                    if (v > best) {
                        best = v;
                    }
                }
                fclose(fp);
            }
        }
        if (best <= 0) {
            return;   /* 拿不到主频：不干预调度 */
        }
        for (int i = 0; i < n; i++) {
            if (freq[i] == best) {
                CPU_SET(i, &set);
            }
        }
    }

    if (sched_setaffinity(0, sizeof(set), &set) == 0) {
        char cpus[224];
        int off = 0;
        cpus[0] = '\0';
        for (int i = 0; i < VMPIN_MAX_CPU && off < (int)sizeof(cpus) - 8; i++) {
            if (CPU_ISSET(i, &set)) {
                off += snprintf(cpus + off, sizeof(cpus) - (size_t)off, "%s%d",
                                off ? "," : "", i);
            }
        }
        fprintf(stderr, "VMHOST_PIN 已把 QEMU 钉到主频最高的核：%s\n", cpus);
    } else {
        fprintf(stderr, "VMHOST_PIN sched_setaffinity 失败：%s\n", strerror(errno));
    }
}

__attribute__((constructor)) static void vmpin_ctor(void) {
    vmpin_apply();
}
