/*
 * libsigfix.so — LD_PRELOAD 全局拦截：
 * 1) pthread_create：新线程 trampoline 里解除崩溃信号屏蔽；
 * 2) pthread_sigmask / sigprocmask：任何线程试图 BLOCK/SETMASK
 *    SIGSEGV/SIGBUS/SIGABRT/SIGILL/SIGFPE 时自动剥离，保证崩溃信号永不屏蔽，
 *    让 vmhost 崩溃处理器能触发（aemu Thread::maskAllSignals 的 sigfillset 也拦得住）。
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>

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
