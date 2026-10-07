#!/usr/bin/env python3
# 方案 B（virtio-gpu + gfxstream stream_renderer）的 C 源码补丁。
#
# 目标：在不整树开启 CONFIG_ANDROID（会拖进 emulator 前端）的前提下，让
# virtio-gpu 设备走 gfxstream 的 stream_renderer（CONFIG_STREAM_RENDERER）路径。
#
# 做法：
#   1) virtio-gpu.c / virtio-gpu-3d.c 里所有 #ifdef CONFIG_ANDROID 分支
#      改成 #if defined(CONFIG_ANDROID) || defined(CONFIG_VM_VIRTIO_GPU)。
#      这两文件里的 CONFIG_ANDROID 块全是 goldfish/gfxstream 相关（头文件包含、
#      proxy_3d_cbs、realize 里的 goldfish_virtio_init + use_virgl_renderer、
#      max_outputs=11、scanout0 flush），我们的构建都要。
#   2) virtio-gpu.c: update_cursor_data_virgl 在 CONFIG_STREAM_RENDERER 分支
#      只写了个 "NOT IMPLEMENTED" 注释，data 未初始化就被使用（UB）→ 置 NULL。
#   3) virtio-gpu.c: goldfish_virtio_init() 由我们的 glue 提供（extern "C"），
#      CONFIG_ANDROID 下它的声明来自 virtio-goldfish-pipe.h；非 CONFIG_ANDROID
#      时手动补一个 extern 声明。
#
# 幂等：以 VMHOST_STREAM_RENDERER 标记判断。用法：
#   python3 patch_virtio_gpu_stream.py [qemu 源码根目录]
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SRC_DIR", "/root/vmbuild/qemu-aosp")
MARK = "VMHOST_STREAM_RENDERER"
COMBINED = "#if defined(CONFIG_ANDROID) || defined(CONFIG_VM_VIRTIO_GPU)"


def patch_file(rel, expected_android, extra):
    path = os.path.join(ROOT, rel)
    src = open(path, "r", encoding="utf-8", errors="surrogateescape").read()
    if MARK in src:
        print("%s: already patched" % rel)
        return True
    n = src.count("#ifdef CONFIG_ANDROID")
    if n != expected_android:
        print("!! %s: #ifdef CONFIG_ANDROID 命中 %d 次（期望 %d），中止" % (rel, n, expected_android))
        return False
    src = src.replace("#ifdef CONFIG_ANDROID", COMBINED)
    for old, new in extra:
        c = src.count(old)
        if c != 1:
            print("!! %s: 锚点命中 %d 次（期望 1）: %r" % (rel, c, old[:80]))
            return False
        src = src.replace(old, new, 1)
    # 标记（放文件顶部，幂等判断用）
    marker = "/* %s: virtio-gpu stream_renderer 模式（方案 B） */\n" % MARK
    src = marker + src
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(src)
    print("%s: patched OK" % rel)
    return True


# virtio-gpu.c：5 处 CONFIG_ANDROID（头文件包含 / virgl_as_proxy 全局 /
# proxy_3d_cbs / realize / max_outputs）+ 游标分支修复 + goldfish_virtio_init 声明
ok = patch_file(
    "hw/display/virtio-gpu.c",
    expected_android=5,
    extra=[
        # 游标分支：stream_renderer 下 data 未初始化 → 置 NULL
        ("    // NOT IMPLEMENTED\n#else\n    data = g->virgl->virgl_renderer_get_cursor_data",
         "    // NOT IMPLEMENTED\n    data = NULL;\n#else\n    data = g->virgl->virgl_renderer_get_cursor_data"),
        # goldfish_virtio_init 声明：virtio-goldfish-pipe.h 的 CONFIG_STREAM_RENDERER
        # 分支已声明 int goldfish_virtio_init(void)，无需手动补（也不能补，会类型冲突）。
    ],
)

# virtio-gpu-3d.c：2 处 CONFIG_ANDROID
ok3d = patch_file(
    "hw/display/virtio-gpu-3d.c",
    expected_android=2,
    extra=[],
)

sys.exit(0 if (ok and ok3d) else 2)
