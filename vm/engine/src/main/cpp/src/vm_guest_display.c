/*
 * 访客画面桥接。
 *
 * QEMU 侧的自定义显示后端（ui/vmhost.c）把访客帧缓冲留在进程内，
 * 这里每帧把它取过来上传成 GL 纹理，再由 vm_render.c 绘制。
 *
 * 分工：QEMU 线程只负责写帧；本文件运行在 android_main 的渲染线程上，
 * 负责取帧 + 上传，所有 GL 调用都发生在有 EGL 上下文的那条线程。
 */

#include "vm_guest_display.h"

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
static uint8_t     *s_stage;      /* 取帧用的暂存缓冲 */
static size_t       s_stage_cap;
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

bool vm_guest_display_poll(void)
{
#ifdef VM_WITH_QEMU
    int w = 0;
    int h = 0;

    if (!vmhost_display_get_size(&w, &h)) {
        return s_have_frame;
    }

    if (!ensure_stage((size_t) w * (size_t) h * 4u)) {
        return s_have_frame;
    }

    int fw = 0;
    int fh = 0;
    uint64_t seq = 0;
    if (!vmhost_display_copy_frame(s_stage, s_stage_cap, &fw, &fh, &seq)) {
        /* 多半是尺寸刚变、缓冲不够，下一帧重试 */
        return s_have_frame;
    }

    if (s_have_frame && seq == s_last_seq && fw == s_width && fh == s_height) {
        return true;   /* 没有新帧 */
    }

    if (!vm_guest_display_init()) {
        return false;
    }

    glBindTexture(GL_TEXTURE_2D, s_texture);

    const bool size_changed = (fw != s_width || fh != s_height || !s_have_frame);
    if (size_changed) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, fw, fh, 0,
                     GL_RGBA, GL_UNSIGNED_BYTE, s_stage);
        s_width = fw;
        s_height = fh;
        LOGI("访客画面 %dx%d", fw, fh);
    } else {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, fw, fh,
                        GL_RGBA, GL_UNSIGNED_BYTE, s_stage);
    }

    s_last_seq = seq;
    s_have_frame = true;
    return true;
#else
    if (!s_warned_no_backend) {
        s_warned_no_backend = true;
        LOGW("本次构建未链接 QEMU，显示后端不可用");
    }
    return false;
#endif
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
    free(s_stage);
    s_stage = NULL;
    s_stage_cap = 0;
    s_have_frame = false;
}
