/*
 * libsigfix.so — LD_PRELOAD 全局拦截（引擎 spawn QEMU 时的唯一注入点）：
 * 1) pthread_create：新线程 trampoline 里解除崩溃信号屏蔽；
 * 2) pthread_sigmask / sigprocmask：任何线程试图 BLOCK/SETMASK
 *    SIGSEGV/SIGBUS/SIGABRT/SIGILL/SIGFPE 时自动剥离，保证崩溃信号永不屏蔽，
 *    让 vmhost 崩溃处理器能触发（aemu Thread::maskAllSignals 的 sigfillset 也拦得住）。
 * 3) VMHOST_PIN：启动 vCPU 优先大核，其余线程保留可用 CPU（见文件末尾）。
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
#include <sys/syscall.h>
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
 * 4) VMHOST_MUTEXDBG：追出"谁把还在用的 mutex 提前析构了"。
 *
 * 背景（见 docs/方案B排障交接.md §22.5）：QEMU 退出时会有 4 个线程同时 SIGABRT：
 *   F libc: FORTIFY: pthread_mutex_lock called on a destroyed mutex (0x…)
 * 即某个对象的 pthread_mutex_t 已被 pthread_mutex_destroy 销毁，另一个线程还去 lock。
 * fp-walk / 扫栈都定位不到调用者，所以换一条路：**记录每个 mutex 的构造点**。
 *
 * 做法：
 *   - 拦 pthread_mutex_init   —— 记下 mutex 地址 → 构造者返回地址；
 *   - 拦 pthread_mutex_destroy —— 打印 该 mutex 的 构造点 + 析构点（都带模块内偏移），
 *     再调用真实实现。
 * 崩溃时 libc 打印的"被销毁的 mutex 地址"与这里的 destroy 行按地址一配，
 * 就能直接知道：是谁构造的（哪个类的成员 mutex）、谁销毁的、销毁发生在退出路径的哪一步。
 *
 * 开销：init/destroy 都**不是热路径**（lock/unlock 才是），所以默认常开，无需开关。
 * ------------------------------------------------------------------------- */

#include <stdint.h>

typedef int (*pthread_mutex_init_fn)(pthread_mutex_t *, const pthread_mutexattr_t *);
typedef int (*pthread_mutex_destroy_fn)(pthread_mutex_t *);

static pthread_mutex_init_fn real_pthread_mutex_init;
static pthread_mutex_destroy_fn real_pthread_mutex_destroy;

#define VMHOST_MDBG_SLOTS 4096
static struct {
    void *mtx;
    void *ra;
} g_mdbg[VMHOST_MDBG_SLOTS];
static volatile int g_mdbg_lock;

/* 本模块（libqemu_exec.so 可执行体）运行期基址，用于把 RA 换成可 addr2line 的偏移 */
static uintptr_t vmhost_mdbg_self_base(void) {
    static uintptr_t base;
    static int done;
    if (done) {
        return base;
    }
    done = 1;
    FILE *fp = fopen("/proc/self/maps", "r");
    if (fp != NULL) {
        char line[512];
        while (fgets(line, sizeof line, fp) != NULL) {
            if (strstr(line, "libqemu_exec.so") != NULL) {
                unsigned long v = 0;
                if (sscanf(line, "%lx", &v) == 1) {
                    base = (uintptr_t)v;
                }
                break;
            }
        }
        fclose(fp);
    }
    return base;
}

static void vmhost_mdbg_off(char *out, size_t cap, void *ra) {
    const uintptr_t base = vmhost_mdbg_self_base();
    const uintptr_t a = (uintptr_t)ra;
    if (base != 0 && a > base) {
        snprintf(out, cap, "0x%zx", (size_t)(a - base));
    } else {
        snprintf(out, cap, "ext(%p)", ra);
    }
}

static unsigned vmhost_mdbg_slot(const void *mtx) {
    return (unsigned)((((uintptr_t)mtx) >> 4) & (VMHOST_MDBG_SLOTS - 1));
}

static void vmhost_mdbg_put(void *mtx, void *ra) {
    while (__sync_lock_test_and_set(&g_mdbg_lock, 1)) {
    }
    unsigned i = vmhost_mdbg_slot(mtx);
    for (unsigned n = 0; n < VMHOST_MDBG_SLOTS; n++) {
        const unsigned k = (i + n) & (VMHOST_MDBG_SLOTS - 1);
        if (g_mdbg[k].mtx == NULL || g_mdbg[k].mtx == mtx) {
            g_mdbg[k].mtx = mtx;
            g_mdbg[k].ra = ra;
            break;
        }
    }
    __sync_lock_release(&g_mdbg_lock);
}

static void *vmhost_mdbg_get(void *mtx) {
    void *ra = NULL;
    while (__sync_lock_test_and_set(&g_mdbg_lock, 1)) {
    }
    unsigned i = vmhost_mdbg_slot(mtx);
    for (unsigned n = 0; n < VMHOST_MDBG_SLOTS; n++) {
        const unsigned k = (i + n) & (VMHOST_MDBG_SLOTS - 1);
        if (g_mdbg[k].mtx == NULL) {
            break;
        }
        if (g_mdbg[k].mtx == mtx) {
            ra = g_mdbg[k].ra;
            break;
        }
    }
    __sync_lock_release(&g_mdbg_lock);
    return ra;
}

int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *a) {
    if (!real_pthread_mutex_init) {
        real_pthread_mutex_init =
            (pthread_mutex_init_fn)dlsym(RTLD_NEXT, "pthread_mutex_init");
    }
    vmhost_mdbg_put(m, __builtin_return_address(0));
    return real_pthread_mutex_init(m, a);
}

/*
 * 把地址反查成"哪个映射、哪个文件" —— 直接点名肇事者所在的库/模块。
 * （只靠 ra-base 的偏移不够：肇事地址可能远在另一个共享库里。）
 */
static void vmhost_mdbg_resolve(uintptr_t a, char *out, size_t cap) {
    out[0] = '\0';
    FILE *fp = fopen("/proc/self/maps", "r");
    if (fp == NULL) {
        return;
    }
    char line[512];
    while (fgets(line, sizeof line, fp) != NULL) {
        unsigned long lo = 0, hi = 0;
        if (sscanf(line, "%lx-%lx", &lo, &hi) != 2) {
            continue;
        }
        if (a >= lo && a < hi) {
            char *nl = strchr(line, '\n');
            if (nl != NULL) {
                *nl = '\0';
            }
            const char *path = strchr(line, '/');
            snprintf(out, cap, "%s+0x%lx", path ? path : "?",
                     (unsigned long)(a - lo));
            break;
        }
    }
    fclose(fp);
}

int pthread_mutex_destroy(pthread_mutex_t *m) {
    if (!real_pthread_mutex_destroy) {
        real_pthread_mutex_destroy =
            (pthread_mutex_destroy_fn)dlsym(RTLD_NEXT, "pthread_mutex_destroy");
    }
    /* VMHOST_MUTEX_LOG：默认关闭。
       这条日志每条 destroy 都要做一次 vmhost_mdbg_resolve（dladdr 符号解析），
       实测完全开机的 guest 2.5 分钟能刷 3 万行 —— 既写爆 qemu-stderr.log，
       又让每次 mutex 析构都多花一次符号查找。需要时用
       `setprop debug.vmhost.mutex_log 1`（引擎会转成环境变量）。 */
    static int vmhost_mdbg_log = -1;
    if (vmhost_mdbg_log < 0) {
        vmhost_mdbg_log = getenv("VMHOST_MUTEX_LOG") ? 1 : 0;
    }
    if (!vmhost_mdbg_log) {
        return real_pthread_mutex_destroy(m);
    }
    void *init_ra = vmhost_mdbg_get(m);
    void *dtor_ra = __builtin_return_address(0);
    char init_s[64];
    char dtor_s[64];
    char dtor_where[256];
    vmhost_mdbg_off(init_s, sizeof init_s, init_ra);
    vmhost_mdbg_off(dtor_s, sizeof dtor_s, dtor_ra);
    vmhost_mdbg_resolve((uintptr_t)dtor_ra, dtor_where, sizeof dtor_where);
    fprintf(stderr,
            "VMHOST_MUTEXDBG destroy mutex=%p init_ra=%s destroy_ra=%s "
            "where=%s tid=%ld\n",
            (void *)m, init_ra ? init_s : "(未记录)", dtor_s, dtor_where,
            (long)syscall(SYS_gettid));
    return real_pthread_mutex_destroy(m);
}

/* ---------------------------------------------------------------------------
 * 5) VMHOST_NOEXITCTOR：进程退出时**跳过静态析构**，修掉库层静态析构竞态。
 *
 * 实测（docs/方案B排障交接.md §22.5，用本文件 4) 的 MUTEXDBG 对上号）：
 *   QEMU 退出时**主线程**会析构一批共享对象 ——
 *     android::base::Lock::~Lock()（aemu/base/…/Lock.h:100）
 *     gfxstream::opengl::ProcessPipeIdRegistry::~ProcessPipeIdRegistry()（GLProcessPipe.cpp:32）
 *     std::__ndk1::mutex::~mutex()
 *   ——而这时还有 4 个 RenderThread 在跑、并去 lock 这些**已被销毁**的 mutex：
 *     F libc: FORTIFY: pthread_mutex_lock called on a destroyed mutex (0x…)
 *   → abort() → QEMU 以 SIGABRT 退出（非干净退出；cache=unsafe 下有脏盘风险）。
 *
 * 这是"静态析构顺序"的经典竞态，散落在 aemu/gfxstream/libc++ 多处，逐一修不现实。
 * 而进程此时已经在退出：QEMU 真正需要的收尾（block flush、设备 unrealize）在
 * `qemu_cleanup()` 里已经做完，静态析构没有任何价值。所以把 `exit()` 换成
 * `_exit()` —— 直接跳过全部静态析构，竞态从根上消失。
 *
 * 只影响**进程退出**行为；正常运行路径不受影响。
 * ------------------------------------------------------------------------- */
void exit(int code) {
    fprintf(stderr, "VMHOST_NOEXITCTOR exit(%d) -> _exit（跳过静态析构）\n", code);
    _exit(code);
}

/* ---------------------------------------------------------------------------
 * 3) VMHOST_PIN：CPU 0/TCG 优先大核，不限制整个 MTTCG 进程。
 *
 * 为什么放在这个库：引擎 spawn QEMU 时只 LD_PRELOAD 了 libsigfix.so
 * （见 vm/engine/src/main/cpp/src/vm_qemu.c），所以这是唯一"不用重编 APK/引擎"
 * 就能给 QEMU 子进程加启动修正的入口。
 *
 * 启动早期主要由 CPU 0 执行，速度受宿主实际主频影响。早期测量：
 *   不钉核  ：servicemanager 26.0s / zygote 75.8s / surfaceflinger 154.4s
 *   钉到大核：servicemanager 19.0s / zygote 53.4s / surfaceflinger 104.1s  （1.48x）
 * 但当前已经启用 MTTCG：给整个进程绑核会让 6 个 vCPU 和渲染/I/O
 * 全继承 {6,7}，浪费其余核心。默认只在 QEMU 命名 CPU 0/TCG 时绑大核，
 * 其他命名线程使用启动时的允许集合；引擎必须启用 debug-threads=on。
 *
 * 选择规则：逐核读 cpuN/cpufreq/cpuinfo_max_freq，取主频最高的一组
 * （本机 = cpu6/cpu7 的 4.32GHz）；读不到就不干预。
 * 环境变量 VMHOST_PIN_CPUS=<十六进制掩码> 可手工指定；=0 表示关闭（A/B 用）。
 * VMHOST_PIN_MODE=legacy 恢复旧的全进程绑核，供同配置 A/B 使用。
 * ------------------------------------------------------------------------- */
#define VMPIN_MAX_CPU 64

static cpu_set_t vmpin_allowed;
static cpu_set_t vmpin_fast;
static int vmpin_balanced;

int pthread_setname_np(pthread_t thread, const char *name) {
    typedef int (*setname_fn)(pthread_t, const char *);
    setname_fn real_setname = (setname_fn)dlsym(RTLD_NEXT, "pthread_setname_np");
    if (!real_setname) return ENOSYS;
    const int rc = real_setname(thread, name);
    if (rc == 0 && vmpin_balanced) {
        const int boot_cpu = strcmp(name, "CPU 0/TCG") == 0 ||
                             strcmp(name, "ALL CPUs/TCG") == 0;
        const cpu_set_t *mask = boot_cpu ? &vmpin_fast : &vmpin_allowed;
        const pid_t tid = pthread_gettid_np(thread);
        if (tid > 0 && sched_setaffinity(tid, sizeof(*mask), mask) != 0) {
            fprintf(stderr, "VMHOST_PIN %s affinity failed: %s\n", name, strerror(errno));
        }
    }
    return rc;
}

static void vmpin_apply(void) {
    const char *env = getenv("VMHOST_PIN_CPUS");
    cpu_set_t allowed;
    cpu_set_t want;
    CPU_ZERO(&allowed);
    CPU_ZERO(&want);

    /*
     * 先读**本进程当前允许**的核。App 在前台/后台会被 Android 放进不同的 cpuset，
     * 后台 cpuset 里可能根本没有大核 —— 那样直接 sched_setaffinity({6,7}) 会返回
     * EINVAL（实测踩到过）。所以只在"允许集合"里挑，拿不到理想子集就退而求其次。
     */
    if (sched_getaffinity(0, sizeof(allowed), &allowed) != 0) return;

    if (env != NULL) {
        const unsigned long mask = strtoul(env, NULL, 16);
        if (mask == 0UL) {
            fprintf(stderr, "VMHOST_PIN 关闭（VMHOST_PIN_CPUS=0）\n");
            return;
        }
        for (int i = 0; i < VMPIN_MAX_CPU; i++) {
            if (((mask >> i) & 1UL) && CPU_ISSET(i, &allowed)) {
                CPU_SET(i, &want);
            }
        }
    } else {
        long freq[VMPIN_MAX_CPU];
        long best = -1;
        const int n = (int)sysconf(_SC_NPROCESSORS_ONLN);
        if (n <= 0 || n > VMPIN_MAX_CPU) {
            return;
        }
        for (int i = 0; i < n; i++) {
            freq[i] = -1;
            if (!CPU_ISSET(i, &allowed)) {
                continue;   /* 不在允许集合里，读主频也没意义 */
            }
            char path[128];
            long v = -1;
            snprintf(path, sizeof(path),
                     "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", i);
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
                CPU_SET(i, &want);
            }
        }
    }

    if (CPU_COUNT(&want) == 0) {
        fprintf(stderr, "VMHOST_PIN 允许集合内没有可用核，跳过\n");
        return;
    }

    const char *mode = getenv("VMHOST_PIN_MODE");
    if (env == NULL && (mode == NULL || strcmp(mode, "legacy") != 0)) {
        vmpin_allowed = allowed;
        vmpin_fast = want;
        vmpin_balanced = 1;
        fprintf(stderr, "VMHOST_PIN balanced: boot vCPU=%d fast cores, other threads=%d allowed cores\n",
                CPU_COUNT(&want), CPU_COUNT(&allowed));
        return;
    }

    if (sched_setaffinity(0, sizeof(want), &want) == 0) {
        char cpus[224];
        int off = 0;
        cpus[0] = '\0';
        for (int i = 0; i < VMPIN_MAX_CPU && off < (int)sizeof(cpus) - 8; i++) {
            if (CPU_ISSET(i, &want)) {
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
