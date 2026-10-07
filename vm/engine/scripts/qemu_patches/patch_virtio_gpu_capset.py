#!/usr/bin/env python3
# 方案 B（virtio-gpu stream_renderer）的 capset 通告修复。
#
# 背景：gfxstream 的 stream_renderer 只支持 gfxstream 系列 capset
# （VULKAN=3 / MAGMA=7 / GLES=8 / COMPOSER=9），但 QEMU 侧 virtio-gpu-3d.c
# 的 CONFIG_STREAM_RENDERER 分支仍按标准 VIRGL(0/1/2) 通告：
#   - get_capset_info 把 index 0 → capset_id=0 并调 stream_renderer_get_cap_set(0)
#     → renderer 报 "Incorrect capability set specified"，max_size 保持 0；
#   - get_capset 只接受 capset_id==0 → 同样失败。
# 结果：guest 内核 virtio-gpu 驱动 probe 时发现没有可用 capset → 不开 3D →
# 不建 /dev/dri render node → gfxstream guest 的 drmOpenRender 失败 → EGL 失败。
#
# 修复：把 gfxstream capset 按 index 0..3 暴露给 guest（get_capset_info），
# get_capset 接受这些 id，num_capsets 返回 4。
#
# 幂等：VMHOST_GFXSTREAM_CAPSET 标记。用法：
#   python3 patch_virtio_gpu_capset.py [qemu 源码根目录]
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SRC_DIR", "/root/vmbuild/qemu-aosp")
SRC = os.path.join(ROOT, "hw/display/virtio-gpu-3d.c")
MARK = "VMHOST_GFXSTREAM_CAPSET"

src = open(SRC, "r", encoding="utf-8", errors="surrogateescape").read()
if MARK in src:
    print("virtio-gpu-3d.c: capset 补丁已应用，跳过")
    sys.exit(0)

# 1) get_capset_info：stream 模式下按 index 暴露 gfxstream capset
OLD_INFO = """static void virgl_cmd_get_capset_info(VirtIOGPU *g,
                                      struct virtio_gpu_ctrl_command *cmd)
{
    struct virtio_gpu_get_capset_info info;
    struct virtio_gpu_resp_capset_info resp;

    VIRTIO_GPU_FILL_CMD(info);

    memset(&resp, 0, sizeof(resp));
    if (info.capset_index == 0) {
        resp.capset_id = VIRTIO_GPU_CAPSET_VIRGL;
#ifdef CONFIG_STREAM_RENDERER
        resp.capset_id = 0;
        resp.capset_max_version = 0;
        stream_renderer_get_cap_set(resp.capset_id,
                                   &resp.capset_max_version,
                                   &resp.capset_max_size);
#else
        g->virgl->virgl_renderer_get_cap_set(resp.capset_id,
                                   &resp.capset_max_version,
                                   &resp.capset_max_size);
#endif  // CONFIG_STREAM_RENDERER
    } else if (info.capset_index == 1) {
        resp.capset_id = VIRTIO_GPU_CAPSET_VIRGL2;
#ifdef CONFIG_STREAM_RENDERER
        stream_renderer_get_cap_set(resp.capset_id,
                                   &resp.capset_max_version,
                                   &resp.capset_max_size);
#else
        g->virgl->virgl_renderer_get_cap_set(resp.capset_id,
                                   &resp.capset_max_version,
                                   &resp.capset_max_size);
#endif  // CONFIG_STREAM_RENDERER
    } else {
        resp.capset_max_version = 0;
        resp.capset_max_size = 0;
    }
    resp.hdr.type = VIRTIO_GPU_RESP_OK_CAPSET_INFO;
    virtio_gpu_ctrl_response(g, cmd, &resp.hdr, sizeof(resp));
}
"""

NEW_INFO = """static void virgl_cmd_get_capset_info(VirtIOGPU *g,
                                      struct virtio_gpu_ctrl_command *cmd)
{
    struct virtio_gpu_get_capset_info info;
    struct virtio_gpu_resp_capset_info resp;

    VIRTIO_GPU_FILL_CMD(info);

    memset(&resp, 0, sizeof(resp));
#ifdef CONFIG_STREAM_RENDERER
    /* VMHOST_GFXSTREAM_CAPSET: gfxstream 只支持 gfxstream 系 capset，
       (VULKAN=3/MAGMA=7/GLES=8/COMPOSER=9)，按 index 0..3 暴露给 guest。 */
    {
        static const uint32_t kGfxstreamCapsets[] = {
            3 /* VIRTGPU_CAPSET_GFXSTREAM_VULKAN */,
            7 /* VIRTGPU_CAPSET_GFXSTREAM_MAGMA */,
            8 /* VIRTGPU_CAPSET_GFXSTREAM_GLES */,
            9 /* VIRTGPU_CAPSET_GFXSTREAM_COMPOSER */,
        };
        uint32_t n = sizeof(kGfxstreamCapsets) / sizeof(kGfxstreamCapsets[0]);
        if (info.capset_index < n) {
            resp.capset_id = kGfxstreamCapsets[info.capset_index];
            stream_renderer_get_cap_set(resp.capset_id,
                                       &resp.capset_max_version,
                                       &resp.capset_max_size);
        } else {
            resp.capset_max_version = 0;
            resp.capset_max_size = 0;
        }
    }
#else
    if (info.capset_index == 0) {
        resp.capset_id = VIRTIO_GPU_CAPSET_VIRGL;
        g->virgl->virgl_renderer_get_cap_set(resp.capset_id,
                                   &resp.capset_max_version,
                                   &resp.capset_max_size);
    } else if (info.capset_index == 1) {
        resp.capset_id = VIRTIO_GPU_CAPSET_VIRGL2;
        g->virgl->virgl_renderer_get_cap_set(resp.capset_id,
                                   &resp.capset_max_version,
                                   &resp.capset_max_size);
    } else {
        resp.capset_max_version = 0;
        resp.capset_max_size = 0;
    }
#endif  // CONFIG_STREAM_RENDERER
    resp.hdr.type = VIRTIO_GPU_RESP_OK_CAPSET_INFO;
    virtio_gpu_ctrl_response(g, cmd, &resp.hdr, sizeof(resp));
}
"""

if src.count(OLD_INFO) != 1:
    print("!! get_capset_info 锚点命中 %d 次（期望 1），中止" % src.count(OLD_INFO))
    sys.exit(2)
src = src.replace(OLD_INFO, NEW_INFO, 1)

# 2) get_capset：stream 模式接受 gfxstream capset id（不再限定 ==0）
OLD_CAPSET = """#ifdef CONFIG_STREAM_RENDERER
    // stream_renderer capset is not compatible with virgl capset (b/282011056).
    if (gc.capset_id != 0) {
        fprintf(stderr, "stream_renderer virgl_capset=%u not supported\\n", gc.capset_id);
        cmd->error = VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
        return;
    }
    stream_renderer_get_cap_set(gc.capset_id, &max_ver,
                               &max_size);
#else"""

NEW_CAPSET = """#ifdef CONFIG_STREAM_RENDERER
    /* VMHOST_GFXSTREAM_CAPSET: gfxstream capset（3/7/8/9），VIRGL 系不支持 */
    {
        static const uint32_t kGfxstreamCapsets[] = {3, 7, 8, 9};
        int ok = 0;
        for (uint32_t i = 0; i < sizeof(kGfxstreamCapsets)/sizeof(kGfxstreamCapsets[0]); i++) {
            if (gc.capset_id == kGfxstreamCapsets[i]) { ok = 1; break; }
        }
        if (!ok) {
            fprintf(stderr, "stream_renderer virgl_capset=%u not supported\\n", gc.capset_id);
            cmd->error = VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
            return;
        }
    }
    stream_renderer_get_cap_set(gc.capset_id, &max_ver,
                               &max_size);
#else"""

if src.count(OLD_CAPSET) != 1:
    print("!! get_capset 锚点命中 %d 次（期望 1），中止" % src.count(OLD_CAPSET))
    sys.exit(2)
src = src.replace(OLD_CAPSET, NEW_CAPSET, 1)

# 3) get_num_capsets：stream 模式返回 gfxstream capset 数量（4）
OLD_NUM = """#ifdef CONFIG_STREAM_RENDERER
    stream_renderer_get_cap_set(VIRTIO_GPU_CAPSET_VIRGL2,
                              &capset2_max_ver,
                              &capset2_max_size);
#else"""

NEW_NUM = """#ifdef CONFIG_STREAM_RENDERER
    /* VMHOST_GFXSTREAM_CAPSET: 暴露 4 个 gfxstream capset */
    (void)capset2_max_ver;
    (void)capset2_max_size;
    return 4;
#else"""

if src.count(OLD_NUM) != 1:
    print("!! get_num_capsets 锚点命中 %d 次（期望 1），中止" % src.count(OLD_NUM))
    sys.exit(2)
src = src.replace(OLD_NUM, NEW_NUM, 1)

src = src.replace("/* VMHost: 方案 B 标记 */\n", "")
src = "/* %s: capset 通告修复 */\n" % MARK + src
open(SRC, "w", encoding="utf-8", errors="surrogateescape").write(src)
print("virtio-gpu-3d.c: capset 补丁 OK")
