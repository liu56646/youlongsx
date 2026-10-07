#ifndef VMHOST_CONTROL_H
#define VMHOST_CONTROL_H

/*
 * vmhost 生命周期控制 —— 引擎侧与 QEMU 侧共享接口。
 *
 * 与 vmhost_display.h / vmhost_input.h 一样，这个头文件必须两边完全一致：
 *   engine/src/main/cpp/src/vmhost_control.h   （引擎侧）
 *   <qemu>/include/ui/vmhost_control.h         （QEMU 侧，由 build_qemu.sh 拷入）
 */

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 请求 QEMU 干净退出（异步，不阻塞）。
 *
 * 语义等价于给 QEMU 进程发 SIGTERM：置上 shutdown_requested 并唤醒主循环，
 * 主循环随即返回，引擎再调用 qemu_cleanup() 收尾（关闭块设备、刷写镜像数据）。
 *
 * 注意这**不是**「给访客发 ACPI 关机」：不会等待访客响应，
 * 所以访客不配合也不会卡住。（QEMU 只有在带 `-no-shutdown` 启动时才会
 * 变成暂停而不是退出，我们没有传这个参数。）
 *
 * 线程安全，可重复调用。
 */
void vmhost_control_request_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif /* VMHOST_CONTROL_H */
