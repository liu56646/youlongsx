/*
 * Android/aarch64 coroutine backend for AOSP QEMU (emu / QEMU 2.12).
 *
 * 为什么需要这个后端
 * ------------------
 * QEMU 自带的两个 POSIX 后端（sigaltstack / ucontext）都依赖
 * sigsetjmp()/siglongjmp() 在**不同栈**之间切换：
 *
 *   - sigaltstack 后端：新建协程时把 SIGUSR2 投递到 sigaltstack 上，
 *     在信号处理器的栈上 sigsetjmp，再从这个已返回的信号帧里 siglongjmp 出去；
 *   - ucontext 后端：即使有 swapcontext()，协程启动那一步仍用
 *     sigsetjmp(old_env) + 协程侧 siglongjmp(old_env, 1) 回到调用者。
 *
 * bionic 的 longjmp 在 arm64 上用 PAC（paciasp/autiasp，以 SP 作为 modifier）
 * 保护返回地址。跨栈 longjmp 时 paciasp 与 autiasp 的 SP 不同，鉴权必然失败；
 * 在支持 FEAT_FPAC（鉴权失败直接报异常）的 SoC 上，内核把这次失败投递成
 * **SIGILL**。实测（Android 16 / arm64 真机）崩溃现场正是：
 *
 *   SIGNAL=4(ILL) si_code=2  PC 落在 libc siglongjmp 的 autiasp 指令上
 *
 * 触发点是访客内核探测到 virtio-blk 之后第一次真正读盘（挂载 system.img），
 * 块层拉起协程做异步 I/O 时。
 *
 * 本后端做什么
 * ------------
 * 用一段纯 asm 保存/恢复被调用者保存寄存器与 SP 来切栈，完全不使用
 * setjmp/longjmp，也不碰信号，因此天然规避上面那个 PAC 冲突。
 * 语义与 coroutine-ucontext.c 保持一致：同一线程内协作式切换，
 * 任一时刻只有一个协程在跑。
 *
 * 保存区布局（帧基址 sp = 保存后 SP，共 160 字节）
 *   0   : x19,x20    16  : x21,x22    32  : x23,x24
 *   48  : x25,x26    64  : x27,x28    80  : x29,x30
 *   96  : d8,d9      112 : d10,d11    128 : d12,d13   144 : d14,d15
 * 注意 x29,x30 是一对，偏移 80 处是 x29，x30 在偏移 88。
 */

#include "qemu/osdep.h"
#include "qemu/coroutine_int.h"
#include <pthread.h>
#include <sys/syscall.h>

#if !defined(__aarch64__)
#error "coroutine-android.c 目前只实现了 aarch64"
#endif

#define CO_FRAME_SIZE 160
#define CO_X19_OFF    0
#define CO_X30_OFF    88

typedef struct {
    Coroutine base;
    void *stack;
    size_t stack_size;
    void *sp;          /* 本上下文被挂起时保存的栈指针（指向上面的保存区） */
    int action;        /* 别人切回我时投递的 CoroutineAction */
} CoroutineAndroid;

/* asm 实现 */
void co_ctx_switch(void **from_sp, void *to_sp);
void co_start_trampoline(void);

/* 新协程真正开始执行的地方，由 co_start_trampoline 用 bl 调入（永不返回） */
static void __attribute__((used)) co_coroutine_start(void *arg);

static __thread CoroutineAndroid leader;
static __thread Coroutine *current;

__asm__(
".text\n"
".align 4\n"
".global co_ctx_switch\n"
".type co_ctx_switch, %function\n"
"co_ctx_switch:\n"
"    sub  sp, sp, #160\n"
"    stp  x19, x20, [sp, #0]\n"
"    stp  x21, x22, [sp, #16]\n"
"    stp  x23, x24, [sp, #32]\n"
"    stp  x25, x26, [sp, #48]\n"
"    stp  x27, x28, [sp, #64]\n"
"    stp  x29, x30, [sp, #80]\n"
"    stp  d8,  d9,  [sp, #96]\n"
"    stp  d10, d11, [sp, #112]\n"
"    stp  d12, d13, [sp, #128]\n"
"    stp  d14, d15, [sp, #144]\n"
"    mov  x2, sp\n"
"    str  x2, [x0]\n"
"    mov  sp, x1\n"
"    ldp  x19, x20, [sp, #0]\n"
"    ldp  x21, x22, [sp, #16]\n"
"    ldp  x23, x24, [sp, #32]\n"
"    ldp  x25, x26, [sp, #48]\n"
"    ldp  x27, x28, [sp, #64]\n"
"    ldp  x29, x30, [sp, #80]\n"
"    ldp  d8,  d9,  [sp, #96]\n"
"    ldp  d10, d11, [sp, #112]\n"
"    ldp  d12, d13, [sp, #128]\n"
"    ldp  d14, d15, [sp, #144]\n"
"    add  sp, sp, #160\n"
"    ret\n"
".size co_ctx_switch, .-co_ctx_switch\n"
"\n"
".align 4\n"
".global co_start_trampoline\n"
".type co_start_trampoline, %function\n"
"co_start_trampoline:\n"
"    .inst 0xd50324df\n"            /* bti jc：开启 BTI 时是合法落点，否则为空操作 */
"    mov  x0, x19\n"                /* 新协程指针由初帧的 x19 带入 */
"    bl   co_coroutine_start\n"
"    brk  #0\n"                     /* co_coroutine_start 不应返回 */
".size co_start_trampoline, .-co_start_trampoline\n"
);

static void co_coroutine_start(void *arg)
{
    CoroutineAndroid *self = arg;
    Coroutine *co = &self->base;

    while (true) {
        co->entry(co->entry_arg);
        qemu_coroutine_switch(co, co->caller, COROUTINE_TERMINATE);
    }
}

Coroutine *qemu_coroutine_new(void)
{
    CoroutineAndroid *co = g_malloc0(sizeof(*co));
    uintptr_t top;
    uint64_t *frame;

    co->stack_size = COROUTINE_STACK_SIZE;
    co->stack = qemu_alloc_stack(&co->stack_size);

    /* 在协程栈顶伪造一帧：恢复后 x30 = co_start_trampoline，x19 = co */
    top = ((uintptr_t)co->stack + co->stack_size) & ~(uintptr_t)0xf;
    frame = (uint64_t *)(top - CO_FRAME_SIZE);
    memset(frame, 0, CO_FRAME_SIZE);
    frame[CO_X19_OFF / 8] = (uint64_t)(uintptr_t) co;
    frame[CO_X30_OFF / 8] = (uint64_t)(uintptr_t) co_start_trampoline;
    co->sp = frame;

    return &co->base;
}

void qemu_coroutine_delete(Coroutine *co_)
{
    CoroutineAndroid *co = DO_UPCAST(CoroutineAndroid, base, co_);

    qemu_free_stack(co->stack, co->stack_size);
    g_free(co);
}

/*
 * 交接日志：VMHOST_CO_TRACE=1 时把“与 leader 之间”的协程切换（块层的
 * yield/enter 路径）打到 stderr。用于排查“切出去后没人切回来”的丢唤醒。
 */
static int co_trace_enabled = -1;
static long co_trace_count = 0;
static pthread_mutex_t co_trace_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned long co_trace_seq = 0;

static void co_trace(const char *phase, Coroutine *from, Coroutine *to, int action)
{
    if (co_trace_enabled < 0) {
        co_trace_enabled = getenv("VMHOST_CO_TRACE") ? 1 : 0;
    }
    if (!co_trace_enabled) {
        return;
    }
    long tid = (long)syscall(SYS_gettid);
    pthread_mutex_lock(&co_trace_lock);
    unsigned long seq = ++co_trace_seq;
    fprintf(stderr, "COTRACE seq=%lu tid=%ld %s from=%p to=%p action=%d cur=%p leader=%p\n",
            seq, tid, phase, (void *)from, (void *)to, action, (void *)current,
            (void *)&leader.base);
    pthread_mutex_unlock(&co_trace_lock);
    co_trace_count++;
}

CoroutineAction __attribute__((noinline))
qemu_coroutine_switch(Coroutine *from_, Coroutine *to_,
                      CoroutineAction action)
{
    CoroutineAndroid *from = DO_UPCAST(CoroutineAndroid, base, from_);
    CoroutineAndroid *to = DO_UPCAST(CoroutineAndroid, base, to_);

    /* 自切（from == to）直接返回，既不做上下文保存/恢复，也不动 TLS */
    if (from_ == to_) {
        return action;
    }

    co_trace("OUT", from_, to_, (int)action);
    current = to_;
    to->action = action;
    co_ctx_switch(&from->sp, to->sp);
    /* 恢复后不再改写 current：与 coroutine-ucontext 保持一致，
       避免在跨线程恢复时把该线程的 TLS 改错（会导致 qemu_coroutine_self()
       返回错的协程，进而出现 self==co 的自切乱象）。 */
    co_trace("IN ", from_, to_, (int)action);
    return (CoroutineAction) from->action;
}

Coroutine *qemu_coroutine_self(void)
{
    if (!current) {
        current = &leader.base;
    }
    return current;
}

bool qemu_in_coroutine(void)
{
    return current && current->caller;
}
