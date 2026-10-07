/*
 * 访客画面桥接。
 *
 * 引擎要能同时支持两种 QEMU 承载方式，帧的来源不一样：
 *
 *   1) QEMU 进程内嵌（上游 QEMU 静态链进 libvmengine.so）：
 *      QEMU 侧的自定义显示后端（ui/vmhost.c）把访客帧缓冲留在本进程内存里，
 *      这里每帧通过 vmhost_display_copy_frame() 取过来上传成 GL 纹理。
 *
 *   2) QEMU 独立子进程（B1 模式，libqemu_exec.so 随包分发）：
 *      帧缓冲在**另一个进程**里，进程内后端永远取不到帧，必须走
 *      frame.request / frame.ppm 文件握手（vm_frame_relay.c）。
 *
 * 分工：QEMU 线程只负责写帧；本文件运行在 android_main 的渲染线程上，
 * 负责取帧 + 上传，所有 GL 调用都发生在有 EGL 上下文的那条线程。
 */

#include "vm_guest_display.h"
#include "vm_frame_relay.h"

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <android/log.h>
#include <GLES2/gl2.h>

#ifdef VM_WITH_QEMU
#include "vmhost_display.h"
#endif

#define TAG "VmGuestDpy"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

static unsigned int s_texture;
#ifdef VM_WITH_QEMU
static uint8_t     *s_stage;      /* 取帧用的暂存缓冲（仅进程内嵌 QEMU 用） */
static size_t       s_stage_cap;
#endif
static int          s_width;
static int          s_height;
static uint64_t     s_last_seq;
static bool         s_have_frame;
static bool         s_warned_no_backend;

bool vm_guest_display_init(void)
{
    if (s_texture != 0) {
        return true;
    }
    glGenTextures(1, &s_texture);
    if (s_texture == 0) {
        LOGW("glGenTextures 失败");
        return false;
    }
    glBindTexture(GL_TEXTURE_2D, s_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    LOGI("纹理已创建 tex=%u", s_texture);
    return true;
}

#ifdef VM_WITH_QEMU
static bool ensure_stage(size_t need)
{
    if (s_stage_cap >= need && s_stage != NULL) {
        return true;
    }
    uint8_t *fresh = (uint8_t *) realloc(s_stage, need);
    if (fresh == NULL) {
        LOGW("暂存缓冲分配失败（需要 %zu 字节）", need);
        return false;
    }
    s_stage = fresh;
    s_stage_cap = need;
    return true;
}
#endif /* VM_WITH_QEMU */

bool vm_guest_display_poll(void)
{
    const uint8_t *src = NULL;
    int fw = 0;
    int fh = 0;
    uint64_t seq = 0;

#ifdef VM_WITH_QEMU
    /*
     * 路径 1：QEMU 进程内嵌。
     * 帧由 QEMU 侧的自定义显示后端（ui/vmhost.c）留在本进程内存里，
     * 直接拷出来即可，不需要任何 IPC。
     */
    {
        int w = 0;
        int h = 0;
        if (vmhost_display_get_size(&w, &h) &&
            ensure_stage((size_t) w * (size_t) h * 4u) &&
            vmhost_display_copy_frame(s_stage, s_stage_cap, &fw, &fh, &seq)) {
            src = s_stage;
        }
    }
#endif

    /*
     * 路径 2：QEMU 跑在独立子进程（B1 模式，即 libqemu_exec.so 随包分发时）。
     * 此时帧缓冲在**另一个进程**里，上面的进程内后端永远是空的 ——
     * 只能走 frame.request / frame.ppm 文件握手（vm_frame_relay.c）。
     * 这正是此前「沙箱不回显」的缺口。
     */
    if (src == NULL) {
        if (!vm_frame_relay_enabled()) {
            if (!s_warned_no_backend) {
                s_warned_no_backend = true;
#ifdef VM_WITH_QEMU
                LOGW("显示后端不可用：进程内无帧，且未配置帧回传目录");
#else
                LOGW("本次构建未链接 QEMU，且未配置帧回传目录，显示后端不可用");
#endif
            }
            return s_have_frame;
        }
        if (!vm_frame_relay_poll(0, 0, &src, &fw, &fh, &seq)) {
            return s_have_frame;   /* 还没有新帧：保留上一帧，避免闪黑 */
        }
    }

    if (s_have_frame && seq == s_last_seq && fw == s_width && fh == s_height) {
        return true;   /* 没有新帧 */
    }

    if (!vm_guest_display_init()) {
        return false;
    }

    if (fw <= 0 || fh <= 0 || src == NULL) {
        return s_have_frame;
    }

    glBindTexture(GL_TEXTURE_2D, s_texture);

    const bool size_changed = (fw != s_width || fh != s_height || !s_have_frame);
    if (size_changed) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, fw, fh, 0,
                     GL_RGBA, GL_UNSIGNED_BYTE, src);
        s_width = fw;
        s_height = fh;
        LOGI("访客画面 %dx%d", fw, fh);
    } else {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, fw, fh,
                        GL_RGBA, GL_UNSIGNED_BYTE, src);
    }

    s_last_seq = seq;
    s_have_frame = true;
    return true;
}

unsigned int vm_guest_display_texture(void)
{
    return s_have_frame ? s_texture : 0u;
}

int vm_guest_display_width(void)
{
    return s_width;
}

int vm_guest_display_height(void)
{
    return s_height;
}

void vm_guest_display_destroy(void)
{
    if (s_texture != 0) {
        glDeleteTextures(1, &s_texture);
        s_texture = 0;
    }
#ifdef VM_WITH_QEMU
    free(s_stage);
    s_stage = NULL;
    s_stage_cap = 0;
#endif
    s_have_frame = false;
}
