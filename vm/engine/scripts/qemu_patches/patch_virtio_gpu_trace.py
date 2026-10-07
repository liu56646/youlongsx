#!/usr/bin/env python3
# 排障 trace：virtio-gpu 的 set_features / 首个 ctrl 命令打点（VMHOSTGPU 前缀）。
# 幂等：VMHOST_GPU_TRACE 标记。用法：
#   python3 patch_virtio_gpu_trace.py [qemu 源码根目录]
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SRC_DIR", "/root/vmbuild/qemu-aosp")
SRC = os.path.join(ROOT, "hw/display/virtio-gpu.c")
MARK = "VMHOST_GPU_TRACE"

src = open(SRC, "r", encoding="utf-8", errors="surrogateescape").read()
if MARK in src:
    print("virtio-gpu.c: trace 已应用，跳过")
    sys.exit(0)

# set_features 打点
OLD = """static void virtio_gpu_set_features(VirtIODevice *vdev, uint64_t features)
{
    static const uint32_t virgl = (1 << VIRTIO_GPU_F_VIRGL);
    VirtIOGPU *g = VIRTIO_GPU(vdev);

    g->use_virgl_renderer = ((features & virgl) == virgl);
    trace_virtio_gpu_features(g->use_virgl_renderer);"""

NEW = """static void virtio_gpu_set_features(VirtIODevice *vdev, uint64_t features)
{
    static const uint32_t virgl = (1 << VIRTIO_GPU_F_VIRGL);
    VirtIOGPU *g = VIRTIO_GPU(vdev);

    g->use_virgl_renderer = ((features & virgl) == virgl);
    fprintf(stderr, "VMHOSTGPU set_features use_virgl=%d features=0x%llx\\n",
            g->use_virgl_renderer, (unsigned long long)features); /* VMHOST_GPU_TRACE */
    trace_virtio_gpu_features(g->use_virgl_renderer);"""

if src.count(OLD) != 1:
    print("!! set_features 锚点命中 %d 次（期望 1），中止" % src.count(OLD))
    sys.exit(2)
src = src.replace(OLD, NEW, 1)

# handle_ctrl 首个命令打点
OLD2 = """#ifdef CONFIG_VIRGL
    if (!g->renderer_inited && g->use_virgl_renderer) {
        virtio_gpu_virgl_init(g);
        g->renderer_inited = true;
    }
#endif"""

NEW2 = """#ifdef CONFIG_VIRGL
    fprintf(stderr, "VMHOSTGPU handle_ctrl: first cmd, renderer_inited=%d use_virgl=%d\\n",
            g->renderer_inited, g->use_virgl_renderer); /* VMHOST_GPU_TRACE */
    if (!g->renderer_inited && g->use_virgl_renderer) {
        int _rc = virtio_gpu_virgl_init(g);
        fprintf(stderr, "VMHOSTGPU virtio_gpu_virgl_init rc=%d\\n", _rc); /* VMHOST_GPU_TRACE */
        g->renderer_inited = true;
    }
#endif"""

if src.count(OLD2) != 1:
    print("!! handle_ctrl 锚点命中 %d 次（期望 1），中止" % src.count(OLD2))
    sys.exit(2)
src = src.replace(OLD2, NEW2, 1)

src = src.replace("/* VMHost: 方案 B 标记 */\n", "")
src = "/* %s: 排障打点 */\n" % MARK + src
open(SRC, "w", encoding="utf-8", errors="surrogateescape").write(src)
print("virtio-gpu.c: trace 补丁 OK")
