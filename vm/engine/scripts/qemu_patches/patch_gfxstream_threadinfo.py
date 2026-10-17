#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VMHOST_LEAKREG：修掉 gfxstream 退出时的静态析构竞态（SIGABRT）。

背景（实测，见 docs/方案B排障交接.md §22.5）：
    关实例 / QEMU 退出时，宿主进程会以 **SIGABRT** 崩掉，logcat crash buffer 明确：
        F libc: FORTIFY: pthread_mutex_lock called on a destroyed mutex (0x…)
    符号化（NDK llvm-addr2line；注意本 .so 的 p_offset 与 p_vaddr 差 0x4000）：
        0xc94f10 -> gfxstream::RenderThread::main()        (RenderThread.cpp:600 附近退出路径)
        0xc9850c -> RenderThreadInfo::~RenderThreadInfo()  里
                    AutoLock lock(sRegistry.lock); sRegistry.threadInfos.erase(this)
    即：**进程退出时静态析构先跑**，把 `sRegistry` 里的 mutex 销毁了；而这时仍有
    RenderThread 在收尾，`~RenderThreadInfo()` 去加这把已销毁的锁 → FORTIFY abort。

    `RenderThreadRegistry` 的析构（Lock 析构 → pthread_mutex_destroy +
    unordered_set 析构）本身没有错误，问题只是**析构顺序不可控**。

修法：
    把 registry 改成**堆上分配、永不释放**（故意泄漏一个空 registry）。
    `sRegistry` 保持同名引用，文件内所有 `sRegistry.lock` / `sRegistry.threadInfos`
    用法不变。这样它永远不会被析构，上面那条竞态从根上消失。

    为什么不"先 join 所有 RenderThread 再退出"：退出路径散落在 QEMU 主流程与
    aemu/gfxstream 多层静态对象里，改动面大且难验证；泄漏一个小对象是等价且确定的。

用法：
    python3 patch_gfxstream_threadinfo.py <gfxstream 源码根目录>
"""

import io
import os
import sys

TARGETS = [
    # (相对路径, marker, 原文本, 替换文本, 说明)
    (
        "host/RenderThreadInfo.cpp",
        "VMHOST_LEAKREG",
        "static RenderThreadRegistry sRegistry;\n",
        """/* VMHOST_LEAKREG: 故意让注册表"永不析构"，修掉进程退出时的静态析构竞态。
 *
 * 实测：QEMU 退出 / 渲染器拆除时，静态析构先跑，sRegistry.lock 的 mutex 已被销毁；
 * 而仍在收尾的 RenderThread 会在 ~RenderThreadInfo() 里
 *   AutoLock lock(sRegistry.lock); sRegistry.threadInfos.erase(this);
 * 去加这把已销毁的锁 → FORTIFY abort：
 *   F libc: FORTIFY: pthread_mutex_lock called on a destroyed mutex
 * → QEMU 以 SIGABRT 退出（不是干净退出；本工程盘是 cache=unsafe，有脏盘风险）。
 *
 * 堆上分配且永不释放：析构顺序问题从根上消失，代价只是泄漏一个空 registry。
 * 保持 `sRegistry` 这个名字（引用），文件内所有 sRegistry.xxx 用法不变。
 */
static RenderThreadRegistry* sRegistryPtr = new RenderThreadRegistry();
static RenderThreadRegistry& sRegistry = *sRegistryPtr;
""",
        "RenderThreadInfo 注册表永不析构",
    ),
    (
        "host/gl/gl-host-common/opengl/GLProcessPipe.cpp",
        "VMHOST_LEAKREG",
        "static ProcessPipeIdRegistry sRegistry;\n",
        """/* VMHOST_LEAKREG: 同上 —— 这处是同一个 bug 型。
 *
 * 实测（§22.5，用 libsigfix 的 VMHOST_MUTEXDBG 对上号）：QEMU 退出时这个静态
 * registry 的 Lock 被析构（符号化结果正是
 *   gfxstream::opengl::ProcessPipeIdRegistry::~ProcessPipeIdRegistry()
 *     -> android::base::Lock::~Lock() ），
 * 而 guest 进程退出触发的 GLProcessPipe::onGuestClose → sIdExistsInRegistry()
 * 还会去 AutoLock(sRegistry.lock) → 加已销毁的锁 → FORTIFY abort → SIGABRT。
 *
 * 同样改成堆上分配、永不释放。`sRegistry` 保持同名引用，用法不变。
 */
static ProcessPipeIdRegistry* sRegistryPtr = new ProcessPipeIdRegistry();
static ProcessPipeIdRegistry& sRegistry = *sRegistryPtr;
""",
        "ProcessPipeIdRegistry 注册表永不析构",
    ),
]


def apply_one(root, rel, marker, anchor, repl, what):
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        sys.stderr.write("!! 找不到 %s\n" % path)
        return False

    with io.open(path, encoding="utf-8") as fp:
        src = fp.read()

    if marker in src:
        sys.stdout.write("==> patch: %s（已打过，跳过）\n" % what)
        return True

    if anchor not in src:
        sys.stderr.write("!! %s 锚点未命中：%s\n" % (what, path))
        return False

    with io.open(path, "w", encoding="utf-8") as fp:
        fp.write(src.replace(anchor, repl, 1))

    sys.stdout.write("==> patch: %s 已注入\n" % what)
    return True


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(
            "用法: patch_gfxstream_threadinfo.py <gfxstream 源码根目录>\n")
        return 2

    ok = True
    for rel, marker, anchor, repl, what in TARGETS:
        ok = apply_one(sys.argv[1], rel, marker, anchor, repl, what) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
