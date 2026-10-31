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

/* 纯声明头（触点槽位上限 VMHOST_TOUCH_SLOTS 也在这里），无 QEMU 的骨架构建同样需要，
 * 因此不能跟着 QEMU 头一起放进 VM_WITH_QEMU 条件里。 */
#include "vmhost_input.h"

#ifdef VM_WITH_QEMU
#include "vm_qemu.h"
#include "vm_qmp.h"
#endif

#define TAG "VmInput"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

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

#ifdef VM_WITH_QEMU
/*
 * 注入一次触摸到访客。
 *
 * B1 子进程模式下 QEMU 在**另一个进程**里，本进程的 vmhost_input_touch()
 * （ui_vmhost.c）是个空壳 —— 它的 s_con 只在子进程的 graphic_console_init()
 * 里被赋值，父进程恒为 NULL，调用会被静默丢弃。所以改走 QMP 把
 * input-send-event 发给子进程（见 vm_qmp.c）。
 *
 * guest 侧只有 virtio-tablet（单指绝对指针，非多点触控），所以 QMP 路径
 * 只让 slot 0 驱动这唯一一个指针；第二根及以后的手指被忽略，避免和第一根
 * 抢位置。进程内嵌 QEMU 时保持原来的直调路径。
 */
static void inject_touch(int slot, int x, int y, int max_x, int max_y, bool down)
{
    static bool mode_logged;
    const bool child = vm_qemu_is_child_process();

    if (!mode_logged) {
        mode_logged = true;
        LOGI("触摸注入路径：%s", child ? "QMP（QEMU 在子进程）" : "进程内 QEMU 直调");
    }

    if (child) {
        if (slot != 0) {
            return;
        }
        char sock[256];
        if (!vm_qemu_qmp_path(sock, sizeof(sock))) {
            LOGW("拿不到 QMP socket 路径，触摸无法注入访客");
            return;
        }
        if (!vm_qmp_connect(sock)) {
            return;   /* vm_qmp_connect() 内部已打日志 */
        }
        vm_qmp_touch(x, y, max_x, max_y, down);
        return;
    }

    /* 进程内嵌 QEMU：直接调 QEMU 侧后端。子进程模式下这条路是空壳，
       不打日志免得误导（上面已经处理过了）。 */
    vmhost_input_touch(slot, x, y, max_x, max_y, down);
}
#endif

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
        inject_touch(slot, gx, gy, guest_w, guest_h, true);
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
            inject_touch(slot, gx, gy, guest_w, guest_h, true);
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
        inject_touch(slot, gx, gy, guest_w, guest_h, false);
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
        inject_touch(slot, 0, 0, s_last_guest_w, s_last_guest_h, false);
        release_slot(id);
    }
    s_slot_used = 0;
#endif
}

/*
 * Android keycode → Linux keycode。
 *
 * 子进程模式下按键必须走 QMP，而 QEMU 的 input-send-event 收的是 Linux
 * keycode。这里只覆盖虚拟机会用到的键：导航、音量、媒体、字母数字和常用
 * 修饰键。没有映射的键直接丢弃（总比发一个错误码好）。
 */
static int android_key_to_linux(int kc)
{
    /* 字母：Android 按字母序 A..Z（29..54），Linux 是 QWERTY 扫描码顺序 */
    static const int kLetters[26] = {
        30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50,
        49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44,
    };
    if (kc >= 29 && kc <= 54) {
        return kLetters[kc - 29];
    }
    if (kc >= 7 && kc <= 16) {           /* 0..9 */
        return (kc == 7) ? 11 : (kc - 8);
    }
    switch (kc) {
        case 3:   return 102;   /* HOME        → KEY_HOME */
        case 4:   return 158;   /* BACK        → KEY_BACK */
        case 19:  return 103;   /* DPAD_UP     → KEY_UP */
        case 20:  return 108;   /* DPAD_DOWN   → KEY_DOWN */
        case 21:  return 105;   /* DPAD_LEFT   → KEY_LEFT */
        case 22:  return 106;   /* DPAD_RIGHT  → KEY_RIGHT */
        case 23:  return 28;    /* DPAD_CENTER → KEY_ENTER */
        case 24:  return 115;   /* VOLUME_UP   → KEY_VOLUMEUP */
        case 25:  return 114;   /* VOLUME_DOWN → KEY_VOLUMEDOWN */
        case 26:  return 116;   /* POWER       → KEY_POWER */
        case 27:  return 212;   /* CAMERA      → KEY_CAMERA */
        case 57:  return 56;    /* ALT_LEFT    → KEY_LEFTALT */
        case 58:  return 100;   /* ALT_RIGHT   → KEY_RIGHTALT */
        case 59:  return 42;    /* SHIFT_LEFT  → KEY_LEFTSHIFT */
        case 60:  return 54;    /* SHIFT_RIGHT → KEY_RIGHTSHIFT */
        case 61:  return 15;    /* TAB         → KEY_TAB */
        case 62:  return 57;    /* SPACE       → KEY_SPACE */
        case 66:  return 28;    /* ENTER       → KEY_ENTER */
        case 67:  return 14;    /* DEL         → KEY_BACKSPACE */
        case 82:  return 139;   /* MENU        → KEY_MENU */
        case 84:  return 217;   /* SEARCH      → KEY_SEARCH */
        case 85:  return 164;   /* MEDIA_PLAY_PAUSE → KEY_PLAYPAUSE */
        case 86:  return 166;   /* MEDIA_STOP  → KEY_STOPCD */
        case 87:  return 163;   /* MEDIA_NEXT  → KEY_NEXTSONG */
        case 88:  return 165;   /* MEDIA_PREVIOUS → KEY_PREVIOUSSONG */
        case 111: return 1;     /* ESCAPE      → KEY_ESC */
        case 113: return 29;    /* CTRL_LEFT   → KEY_LEFTCTRL */
        case 114: return 97;    /* CTRL_RIGHT  → KEY_RIGHTCTRL */
        case 115: return 58;    /* CAPS_LOCK   → KEY_CAPSLOCK */
        case 122: return 164;   /* MEDIA_PLAY_PAUSE → KEY_PLAYPAUSE */
        case 126: return 164;   /* MEDIA_PLAY  → KEY_PLAYPAUSE */
        case 127: return 164;   /* MEDIA_PAUSE → KEY_PLAYPAUSE */
        case 164: return 113;   /* VOLUME_MUTE → KEY_MUTE */
        case 187: return 127;   /* APP_SWITCH  → KEY_COMPOSE */
        default:  return 0;
    }
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

    if (vm_qemu_is_child_process()) {
        /* 子进程模式：按键和触摸一样走 QMP，直接调 vmhost_input_key 会被丢弃 */
        const int linux_keycode = android_key_to_linux(keycode);
        if (linux_keycode <= 0) {
            return;
        }
        char sock[256];
        if (vm_qemu_qmp_path(sock, sizeof(sock)) && vm_qmp_connect(sock)) {
            vm_qmp_key(linux_keycode, down);
        }
        return;
    }
    vmhost_input_key(keycode, down);
#else
    (void) event;
#endif
}
