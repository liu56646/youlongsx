#ifndef VMHOST_DISPLAY_H
#define VMHOST_DISPLAY_H

/*
 * vmhost 自定义显示后端 —— 引擎侧与 QEMU 侧共享接口。
 *
 * 这个头文件同时存在于两个地方，必须保持完全一致：
 *   1. engine/src/main/cpp/src/vmhost_display.h        （引擎侧）
 *   2. <qemu>/include/ui/vmhost_display.h              （QEMU 侧，由 build_qemu.sh 拷入）
 *
 * 设计：QEMU 侧持有最新的一帧（RGBA8888，内存布局 R,G,B,A），
 * 引擎侧每帧调用 vmhost_display_copy_frame() 取走并上传为 GL 纹理。
 * 这样引擎完全不需要包含任何 QEMU 头文件。
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 取走最新一帧。
 *
 * @param dst     目标缓冲，需至少能放下 width*height*4 字节
 * @param cap     dst 容量（字节）
 * @param width   输出：画面宽
 * @param height  输出：画面高
 * @param seq     输出：帧序号，单调递增；可与上次比较判断是否有新帧
 * @return        取到帧返回 true
 *
 * 像素格式固定为 RGBA8888，行紧密排列（stride == width * 4）。
 */
bool vmhost_display_copy_frame(uint8_t *dst, size_t cap,
                               int *width, int *height, uint64_t *seq);

/** 当前访客画面尺寸；尚无帧时返回 false。 */
bool vmhost_display_get_size(int *width, int *height);

#ifdef __cplusplus
}
#endif

#endif /* VMHOST_DISPLAY_H */
