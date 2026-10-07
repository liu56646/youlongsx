#ifndef VM_GUEST_DISPLAY_H
#define VM_GUEST_DISPLAY_H

#include <stdbool.h>

/**
 * 访客画面桥接：从 QEMU 显示后端取帧并上传为 GL 纹理。
 * 必须在 GL 上下文就绪之后调用 init。
 */
bool vm_guest_display_init(void);

/** 每帧调用一次；有新帧时更新纹理。返回纹理是否可用。 */
bool vm_guest_display_poll(void);

/** 纹理名（0 表示尚无帧）。 */
unsigned int vm_guest_display_texture(void);

int vm_guest_display_width(void);

int vm_guest_display_height(void);

void vm_guest_display_destroy(void);

#endif /* VM_GUEST_DISPLAY_H */
