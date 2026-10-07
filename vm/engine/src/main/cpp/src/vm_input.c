/*
 * 宿主输入 → 访客输入（支持多指）
 *
 * 数据流：
 *   NativeActivity 的 AInputEvent
 *     → 本文件：按 pointer id 分配到槽位、取坐标/键码
 *     → vm_render_map_to_guest()（抵消 letterbox 等比缩放，得到访客像素坐标）
 *     → vmhost_input_touch() / vmhost_input_key()（QEMU 侧翻译成 InputEvent）
 *     → virtio-multitouch / virtio-keyboard
 *
 * 多指的两层编号：
 *   Android 的 pointer id 取值范围大（0..31）且随手指来去而变化，
 *   QEMU 的 mtt slot 只有 VMHOST_TOUCH_SLOTS 个且要求稳定，
 *   所以这里维护一张 pointer id → slot 的映射表，手指抬起时释放槽位。
 */

#include "vm_input.h"

#include <android/log.h>

#include "vm_render.h"
#include "vm_guest_display.h"

#ifdef VM_WITH_QEMU
#include "vmhost_input.h"
#endif

#define TAG "VmInput"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

/* Android pointer id 的最大取值范围（ACTION_POINTER_ID_MASK 为 0xff00） */
#define POINTER_ID_MAX 32

/* pointer id → 槽位映射：0 表示未分配，否则存 slot + 1 */
static int      s_slot_of_pointer[POINTER_ID_MAX];
static unsigned s_slot_used;

/* 最近一次已知的访客画面尺寸，供「释放全部」时构造 END 事件使用 */
static int s_last_guest_w = 1;
static int s_last_guest_h = 1;

static int find_slot(int pointer_id)
{
    if (pointer_id < 0 || pointer_id >= POINTER_ID_MAX) {
        return -1;
    }
    const int v = s_slot_of_pointer[pointer_id];
    return (v > 0) ? (v - 1) : -1;
}

static int alloc_slot(int pointer_id)
{
    if (pointer_id < 0 || pointer_id >= POINTER_ID_MAX) {
        return -1;
    }

    const int existing = find_slot(pointer_id);
    if (existing >= 0) {
        return existing;
    }

    for (int slot = 0; slot < VMHOST_TOUCH_SLOTS; slot++) {
        if ((s_slot_used & (1u << slot)) == 0) {
            s_slot_used |= (1u << slot);
            s_slot_of_pointer[pointer_id] = slot + 1;
            return slot;
        }
    }
    return -1;   /* 槽位用尽 */
}

static void release_slot(int pointer_id)
{
    const int slot = find_slot(pointer_id);
    if (slot < 0) {
        return;
    }
    s_slot_used &= ~(1u << slot);
    s_slot_of_pointer[pointer_id] = 0;
}

/** 取第 index 个指针的坐标并换算到访客坐标系。 */
static bool map_pointer(AInputEvent *event, size_t index,
                        int guest_w, int guest_h, int *gx, int *gy)
{
    const int px = (int) AMotionEvent_getX(event, index);
    const int py = (int) AMotionEvent_getY(event, index);
    if (!vm_render_map_to_guest(px, py, gx, gy)) {
        return false;
    }
    s_last_guest_w = guest_w;
    s_last_guest_h = guest_h;
    return true;
}

void vm_input_handle_motion(AInputEvent *event)
{
#ifdef VM_WITH_QEMU
    const int32_t action = AMotionEvent_getAction(event);
    const int32_t masked = action & AMOTION_EVENT_ACTION_MASK;
    const size_t count = AMotionEvent_getPointerCount(event);

    if (masked == AMOTION_EVENT_ACTION_CANCEL) {
        LOGI("触摸序列被取消，释放全部触点");
        vm_input_release_all();
        return;
    }

    const int guest_w = vm_guest_display_width();
    const int guest_h = vm_guest_display_height();
    if (guest_w <= 0 || guest_h <= 0) {
        return;   /* 还没有访客画面，无从换算 */
    }

    /* down/up 动作只针对某一个指针，索引在 action 的高位里 */
    const size_t indexed = (size_t) (action >> AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT);
    const int indexed_id = (indexed < count)
                           ? (int) AMotionEvent_getPointerId(event, indexed)
                           : -1;

    switch (masked) {
    case AMOTION_EVENT_ACTION_DOWN:
    case AMOTION_EVENT_ACTION_POINTER_DOWN: {
        if (indexed_id < 0) {
            break;
        }
        const int slot = alloc_slot(indexed_id);
        if (slot < 0) {
            LOGI("触点槽位已满，忽略 pointer id=%d", indexed_id);
            break;
        }
        int gx = 0;
        int gy = 0;
        if (!map_pointer(event, indexed, guest_w, guest_h, &gx, &gy)) {
            release_slot(indexed_id);   /* 换算失败就不占用槽位 */
            break;
        }
        LOGI("按下 pointer=%d slot=%d → 访客 (%d,%d)", indexed_id, slot, gx, gy);
        vmhost_input_touch(slot, gx, gy, guest_w, guest_h, true);
        break;
    }

    case AMOTION_EVENT_ACTION_MOVE:
        /* 一次 MOVE 事件里可能同时带着所有手指的新位置 */
        for (size_t i = 0; i < count; i++) {
            const int id = (int) AMotionEvent_getPointerId(event, i);
            const int slot = find_slot(id);
            if (slot < 0) {
                continue;   /* 没按下过（比如从别的窗口滑进来），忽略 */
            }
            int gx = 0;
            int gy = 0;
            if (!map_pointer(event, i, guest_w, guest_h, &gx, &gy)) {
                continue;
            }
            vmhost_input_touch(slot, gx, gy, guest_w, guest_h, true);
        }
        break;

    case AMOTION_EVENT_ACTION_UP:
    case AMOTION_EVENT_ACTION_POINTER_UP: {
        if (indexed_id < 0) {
            break;
        }
        const int slot = find_slot(indexed_id);
        if (slot < 0) {
            break;
        }
        int gx = 0;
        int gy = 0;
        map_pointer(event, indexed, guest_w, guest_h, &gx, &gy);
        LOGI("抬起 pointer=%d slot=%d", indexed_id, slot);
        vmhost_input_touch(slot, gx, gy, guest_w, guest_h, false);
        release_slot(indexed_id);
        break;
    }

    default:
        break;
    }
#else
    (void) event;
#endif
}

void vm_input_release_all(void)
{
#ifdef VM_WITH_QEMU
    for (int id = 0; id < POINTER_ID_MAX; id++) {
        const int slot = find_slot(id);
        if (slot < 0) {
            continue;
        }
        /* 抬起只需要 END；位置用 (0,0)，访客侧不关心 */
        vmhost_input_touch(slot, 0, 0, s_last_guest_w, s_last_guest_h, false);
        release_slot(id);
    }
    s_slot_used = 0;
#endif
}

void vm_input_handle_key(AInputEvent *event)
{
#ifdef VM_WITH_QEMU
    const int32_t action = AKeyEvent_getAction(event);
    if (action != AKEY_EVENT_ACTION_DOWN && action != AKEY_EVENT_ACTION_UP) {
        return;   /* ACTION_MULTIPLE 等不处理 */
    }

    const int keycode = AKeyEvent_getKeyCode(event);
    const bool down = (action == AKEY_EVENT_ACTION_DOWN);

    /* 重复事件（长按）按按下处理，访客侧本来就是这么期望的 */
    LOGI("按键 %d %s", keycode, down ? "按下" : "抬起");
    vmhost_input_key(keycode, down);
#else
    (void) event;
#endif
}
