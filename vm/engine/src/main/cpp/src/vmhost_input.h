#ifndef VMHOST_INPUT_H
#define VMHOST_INPUT_H

/*
 * vmhost 输入注入 —— 引擎侧与 QEMU 侧共享接口。
 *
 * 与 vmhost_display.h 一样，这个头文件必须两边完全一致：
 *   engine/src/main/cpp/src/vmhost_input.h   （引擎侧）
 *   <qemu>/include/ui/vmhost_input.h         （QEMU 侧，由 build_qemu.sh 拷入）
 *
 * 设计：引擎只上报「宿主平台语义」的事件（触摸坐标 + Android 键码），
 * 由 QEMU 侧的后端翻译成 QEMU 的 InputEvent / QKeyCode —— 这正是 UI 后端的职责
 * （GTK 后端翻译 X11、SDL 后端翻译 SDL，我们翻译 Android）。
 */

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 注入一次触摸事件。
 *
 * @param slot       触点槽位（多指用不同 slot，0..9）
 * @param x, y       访客画面内的像素坐标
 * @param max_x,max_y 访客画面尺寸（用于换算成 virtio-input 的绝对坐标域）
 * @param down       true=按下，false=抬起
 */
void vmhost_input_touch(int slot, int x, int y, int max_x, int max_y, bool down);

/**
 * 注入一次按键。
 *
 * @param android_keycode Android 的 AKEYCODE_*（QEMU 侧负责翻译成 QKeyCode）
 * @param down            true=按下，false=抬起
 */
void vmhost_input_key(int android_keycode, bool down);

/** 触摸槽位数量上限，两侧必须一致。 */
#define VMHOST_TOUCH_SLOTS 10

#ifdef __cplusplus
}
#endif

#endif /* VMHOST_INPUT_H */
