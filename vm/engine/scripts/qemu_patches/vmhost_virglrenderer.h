/* VMHost 最小 virglrenderer.h（方案 B 专用）。
 *
 * 真实 virglrenderer.h 在 AOSP 的 external/virglrenderer 里，本工程拿不到
 * （googlesource/GitHub 镜像均不可达）。virtio-gpu.c / virtio-gpu-3d.c 在
 * CONFIG_VIRGL 下 include 它，但 CONFIG_STREAM_RENDERER 模式下编译进代码的
 * 只有少量 virgl 类型（callbacks / gl_context / gl_ctx_param / virtio_interface
 * 指针），其余 virgl 调用全在 #else 分支不参与编译。这里给最小定义即可。
 *
 * stream_renderer API 的类型与原型由 gfxstream 头文件提供：
 *   gfxstream/virtio-gpu-gfxstream-renderer.h
 *   gfxstream/virtio-gpu-gfxstream-renderer-unstable.h
 * （编译时通过 -I<gfxstream>/host/include 引入，与 AOSP 原版行为一致——
 *   AOSP 的 virglrenderer.h 也把这两个头带进来。）
 */
#ifndef VMHOST_MINIMAL_VIRGL_RENDERER_H
#define VMHOST_MINIMAL_VIRGL_RENDERER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *virgl_renderer_gl_context;

/* 3d.c 的 virgl_create_context 里解引用 major_ver/minor_ver，补上两个字段 */
struct virgl_renderer_gl_ctx_param {
    int32_t major_ver;
    int32_t minor_ver;
    uint32_t context_flags;
};

/* 仅作 VirtIOGPU 的指针成员，不需要完整定义 */
struct virgl_renderer_virtio_interface;

/* proxy_3d_cbs / standard_3d_cbs 用到的字段（按名初始化，顺序无关） */
typedef struct virgl_renderer_callbacks {
    int version;
    void (*write_fence)(void *cookie, uint32_t fence);
    virgl_renderer_gl_context (*create_gl_context)(
        void *cookie, int scanout_idx, struct virgl_renderer_gl_ctx_param *params);
    void (*destroy_gl_context)(void *cookie, virgl_renderer_gl_context ctx);
    int (*make_current)(void *cookie, int scanout_idx,
                        virgl_renderer_gl_context ctx);
} virgl_renderer_callbacks;

/* stream_renderer API（与 AOSP 原版 virglrenderer.h 行为一致） */
#include "gfxstream/virtio-gpu-gfxstream-renderer.h"
#include "gfxstream/virtio-gpu-gfxstream-renderer-unstable.h"

#ifdef __cplusplus
}
#endif

#endif /* VMHOST_MINIMAL_VIRGL_RENDERER_H */
