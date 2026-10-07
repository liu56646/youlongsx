# -*- coding: utf-8 -*-
# 终极修复：qemu_thread_create 用 sigfillset 屏蔽全部信号，导致 vCPU 及
# 派生子线程（gfxstream render 线程等）继承 SEGV 屏蔽，崩溃时绕过 vmhost 处理器。
# 改成 sigfillset 但排除崩溃信号 + SIGUSR2(协程) + SIGCONT，保证它们永不屏蔽。
p = '/root/vmbuild/qemu-aosp/util/qemu-thread-posix.c'
s = open(p, encoding='utf-8', errors='replace').read()

old = '''    /* Leave signal handling to the iothread.  */
    sigfillset(&set);
    pthread_sigmask(SIG_SETMASK, &set, &oldset);'''
new = '''    /* Leave signal handling to the iothread.  */
    /* VMHOST_FIX2: 崩溃信号(SEGV/BUS/ABRT/ILL/FPE)绝不能屏蔽，
       否则崩溃时 vmhost 处理器进不来（实测 SIGSEGV 被屏蔽时直接走默认
       动作，无日志、无 tombstone、exit 139）。SIGUSR2 是协程后端用的，
       SIGCONT 也保持可用。其余照旧全屏蔽。 */
    sigfillset(&set);
    sigdelset(&set, SIGSEGV);
    sigdelset(&set, SIGBUS);
    sigdelset(&set, SIGABRT);
    sigdelset(&set, SIGILL);
    sigdelset(&set, SIGFPE);
    sigdelset(&set, SIGUSR2);
    sigdelset(&set, SIGCONT);
    pthread_sigmask(SIG_SETMASK, &set, &oldset);'''
assert old in s, 'target not found'
s = s.replace(old, new)
open(p, 'w', encoding='utf-8').write(s)
print('patched OK (fix2)')
