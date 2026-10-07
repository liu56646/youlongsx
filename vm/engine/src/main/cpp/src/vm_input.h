#ifndef VM_INPUT_H
#define VM_INPUT_H

#include <android/input.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 处理宿主触摸事件（含多指）：换算坐标后注入访客。 */
void vm_input_handle_motion(AInputEvent *event);

/** 处理宿主按键事件：注入访客。 */
void vm_input_handle_key(AInputEvent *event);

/**
 * 释放所有仍按着的触点。
 * 窗口销毁 / 触摸序列被取消时调用，避免访客侧出现「按下去就不放」的残留触点。
 */
void vm_input_release_all(void);

#ifdef __cplusplus
}
#endif

#endif /* VM_INPUT_H */
