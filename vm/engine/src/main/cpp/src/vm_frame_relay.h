#ifndef VM_FRAME_RELAY_H
#define VM_FRAME_RELAY_H

/*
 * 帧回传客户端（B1 子进程模式）—— 引擎侧。
 *
 * 背景：B1 模式下 QEMU 跑在**独立子进程**里，访客帧缓冲留在子进程的内存中，
 * 引擎进程里的 vmhost_display_*（进程内显示后端）永远拿不到帧。这正是
 * 「沙箱不回显」的根因：宿主只能看到 vm_render.c 画的占位渐变。
 *
 * 子进程侧（scripts/qemu_patches/vmhost_gfx_glue.cpp，D1a）已经实现了一套
 * 文件握手，本模块是这套协议的**客户端**（此前缺失）：
 *
 *   引擎写 <dir>/frame.request（内容 "宽 高"，两个整数）
 *     → QEMU 侧线程截图，先写 <dir>/frame.ppm.tmp 再 rename 成 frame.ppm（P6）
 *     → 自增写 <dir>/frame.seq（十进制文本 + 换行）
 *     → 删掉 frame.request
 *   引擎轮询 frame.seq，发现变化就读 frame.ppm 并转成 RGBA8888
 *
 * 只依赖 libc，不依赖 QEMU，因此纯骨架构建下同样可以编译。
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 设置回传目录（与子进程的 VMHOST_FRAME_DIR 必须一致，即 <dataDir>/logs）。
 * 传 NULL 或空串表示禁用。目录不存在时会尝试创建。
 */
void vm_frame_relay_set_dir(const char *dir);

/** 是否已配置回传目录。 */
bool vm_frame_relay_enabled(void);

/** 回传目录（未配置时为空串），便于日志排查。 */
const char *vm_frame_relay_dir(void);

/**
 * 轮询一帧（非阻塞，可在渲染线程每帧调用）。
 *
 * 有**新**帧时返回 true，并把 *rgba 指向模块内部所有的一块 RGBA8888 缓冲
 * （行紧密排列，stride == 宽 * 4）。该缓冲在下一次成功轮询前保持有效。
 *
 * 没有新帧时返回 false，并在需要时补发一次 frame.request。若引擎已有上一帧，
 * 调用方应保留它（画面不要闪黑）。
 *
 * @param req_w / req_h 期望的最大尺寸，<=0 表示取访客原生分辨率。
 *                      （当前 QEMU 侧 post-callback 路径不缩放，仅作提示。）
 */
bool vm_frame_relay_poll(int req_w, int req_h,
                         const uint8_t **rgba, int *w, int *h, uint64_t *seq);

#ifdef __cplusplus
}
#endif

#endif /* VM_FRAME_RELAY_H */
