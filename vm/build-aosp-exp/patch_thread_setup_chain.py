# -*- coding: utf-8 -*-
# 给 qemu-thread-posix.c 打链式 setup 回调补丁
p = '/root/vmbuild/qemu-aosp/util/qemu-thread-posix.c'
s = open(p, encoding='utf-8', errors='replace').read()

old1 = '''static bool name_threads;
static QemuThreadSetupFunc thread_setup_func;

void qemu_thread_register_setup_callback(QemuThreadSetupFunc setup_func)
{
    thread_setup_func = setup_func;
}'''
new1 = '''static bool name_threads;

/* VMHOST_FIX: 多份 setup 回调都要生效（qemu-setup.cpp 注册 looper，
   vl.c 注册 SIGSEGV 解除屏蔽），单槽位会互相覆盖，改成数组按注册顺序全调。 */
#define VMHOST_MAX_THREAD_SETUP 8
static QemuThreadSetupFunc thread_setup_funcs[VMHOST_MAX_THREAD_SETUP];
static int thread_setup_func_count;

void qemu_thread_register_setup_callback(QemuThreadSetupFunc setup_func)
{
    if (thread_setup_func_count < VMHOST_MAX_THREAD_SETUP) {
        thread_setup_funcs[thread_setup_func_count++] = setup_func;
    }
}'''
assert old1 in s, 'old1 not found'
s = s.replace(old1, new1)

old2 = '''    if (thread_setup_func)
        (*thread_setup_func)();'''
new2 = '''    for (int i = 0; i < thread_setup_func_count; i++) {
        if (thread_setup_funcs[i])
            (*thread_setup_funcs[i])();
    }'''
assert old2 in s, 'old2 not found'
s = s.replace(old2, new2)

open(p, 'w', encoding='utf-8').write(s)
print('patched OK')
