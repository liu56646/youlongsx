/*
 * 实例进程的原生入口。
 * 一个实例 = 一个 :vmN 进程 = 一个 NativeActivity = 一份引擎上下文。
 */

#include <android_native_app_glue.h>
#include <android/log.h>
#include <android/input.h>
#include <android/native_window.h>

#include "vm_render.h"
#include "vm_engine.h"
#include "vm_input.h"
#ifdef VM_WITH_QEMU
#include "vm_qemu.h"
#endif

#define TAG "VmNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/* 停机等待上限。QEMU 返回前要 qemu_cleanup() 刷写镜像，给足时间但不无限等。 */
#define QEMU_STOP_TIMEOUT_MS 5000

static int32_t on_input_event(struct android_app* app, AInputEvent* event) {
    const int32_t type = AInputEvent_getType(event);

    if (type == AINPUT_EVENT_TYPE_MOTION) {
        /* 换算坐标后注入访客的 virtio-multitouch */
        vm_input_handle_motion(event);
        return 1;
    }

    if (type == AINPUT_EVENT_TYPE_KEY) {
        /* 注入访客的 virtio-keyboard */
        vm_input_handle_key(event);
        return 1;
    }

    return 0;
}

static void on_app_cmd(struct android_app* app, int32_t cmd) {
    switch (cmd) {
        case APP_CMD_INIT_WINDOW:
            if (app->window != NULL) {
                vm_render_init(app->window);
                vm_engine_on_window_ready(app);
            }
            break;

        case APP_CMD_TERM_WINDOW:
            /* 先放开所有触点：窗口没了，不能再让访客以为手指还按着 */
            vm_input_release_all();
            vm_engine_on_window_gone(app);
            vm_render_destroy();
            break;

        case APP_CMD_WINDOW_RESIZED:
            if (app->window != NULL) {
                const int w = ANativeWindow_getWidth(app->window);
                const int h = ANativeWindow_getHeight(app->window);
                LOGI("window resized %dx%d", w, h);
                vm_render_resize(w, h);
            }
            break;

        case APP_CMD_DESTROY:
            /* Activity 正在销毁：让 QEMU 走正常退出路径，
               这样 qemu_cleanup() 才会刷写 userdata 等镜像数据。 */
#ifdef VM_WITH_QEMU
            LOGI("activity 销毁，停止 QEMU");
            vm_qemu_stop(QEMU_STOP_TIMEOUT_MS);
#else
            LOGI("activity 销毁（本次构建未链接 QEMU）");
#endif
            break;

        default:
            break;
    }
}

void android_main(struct android_app* app) {
    app->onAppCmd = on_app_cmd;
    app->onInputEvent = on_input_event;

    LOGI("android_main enter");
    vm_engine_on_instance_start(app);

#ifdef VM_WITH_QEMU
    int ticks = 0;
    bool qemu_was_running = false;
#endif

    while (!app->destroyRequested) {
        int events;
        struct android_poll_source* source = NULL;

        /* 有窗口时按 ~60fps 轮询驱动渲染；无窗口时阻塞等待事件 */
        const int timeoutMillis = (app->window != NULL) ? 16 : -1;
        const int ident = ALooper_pollOnce(timeoutMillis, NULL, &events, (void**) &source);
        if (ident >= 0 && source != NULL) {
            source->process(app, source);
        }

        if (app->window != NULL) {
            vm_render_frame();
        }

#ifdef VM_WITH_QEMU
        /* 每约 1 秒确认一次 QEMU 还在不在：子进程退出若不在这里发现，
           进程会一直留成僵尸，事后只看到"日志突然停了"而不知死因。 */
        if (++ticks >= 60) {
            ticks = 0;
            const bool running = vm_qemu_is_running();
            if (running) {
                qemu_was_running = true;
            } else if (qemu_was_running) {
                qemu_was_running = false;
                LOGE("QEMU 已停止运行（退出原因见上一条 VmQemu 日志）");
            }
        }
#endif
    }

    /* 兜底停机：Activity 不一定总是走 APP_CMD_DESTROY 这条路
       （例如被系统直接回收），这里再确认一次，vm_qemu_stop 可重复调用。 */
#ifdef VM_WITH_QEMU
    vm_qemu_stop(QEMU_STOP_TIMEOUT_MS);
#endif

    vm_engine_on_instance_stop(app);
    vm_render_destroy();
    LOGI("android_main exit");
}
