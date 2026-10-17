#ifndef VM_ENGINE_H
#define VM_ENGINE_H

#include <android_native_app_glue.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 实例进程启动时调用，可在此解析 Intent 配置、初始化 QEMU 上下文。 */
void vm_engine_on_instance_start(struct android_app* app);

/** Surface 就绪：真实实现里这是"启动 QEMU 并绑定 virtio-gpu 输出"的触发点。 */
void vm_engine_on_window_ready(struct android_app* app);

/** Surface 丢失：暂停渲染。 */
void vm_engine_on_window_gone(struct android_app* app);

/** 实例退出：保存可写盘、释放 QEMU 资源。 */
void vm_engine_on_instance_stop(struct android_app* app);

/**
 * QEMU 子进程退出后的收尾：若这次是按快照恢复且失败，删掉坏快照并按冷启动重来。
 * 由 android_main 的存活检查在发现 QEMU 退出时调用。
 */
void vm_engine_on_qemu_exit(void);

#ifdef __cplusplus
}
#endif

#endif /* VM_ENGINE_H */
