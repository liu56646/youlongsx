#ifndef VM_RENDER_H
#define VM_RENDER_H

#include <android/native_window.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 初始化 EGL，并把渲染目标绑定到给定窗口。成功返回 0。 */
int  vm_render_init(ANativeWindow* window);

/** 更新绘制尺寸。 */
void vm_render_resize(int width, int height);

/** 绘制并提交一帧。 */
void vm_render_frame(void);

/** 销毁 EGL 资源，可重复调用。 */
void vm_render_destroy(void);

/**
 * 把宿主 Surface 上的像素坐标换算成访客画面坐标。
 *
 * 画面上屏时做了等比缩放 + letterbox，触摸回传必须做同样的逆变换，
 * 否则点在屏幕上的位置和访客收到的位置会对不上。
 *
 * @return false 表示当前还没有访客画面，调用方应忽略该次输入
 */
bool vm_render_map_to_guest(int px, int py, int *guest_x, int *guest_y);

#ifdef __cplusplus
}
#endif

#endif /* VM_RENDER_H */
