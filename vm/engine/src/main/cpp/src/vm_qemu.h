#ifndef VM_QEMU_H
#define VM_QEMU_H

#include <stdbool.h>

/**
 * QEMU 启动参数。
 *
 * 设计要点：我们**不包含 QEMU 的任何头文件**，只通过下面三个外部符号与
 * QEMU 交互（声明见 qemu/include/sysemu/sysemu.h）：
 *
 *   void qemu_init(int argc, char **argv);
 *   int  qemu_main_loop(void);
 *   void qemu_cleanup(int status);
 *
 * 这样可以避免依赖 QEMU 的生成头（config-host.h / qemu-version.h 等），
 * 也不必把 QEMU 的头文件目录带进我们的工程。
 */
typedef struct {
    const char *kernel_path;      /**< 访客内核，如 <imageDir>/kernel */
    const char *initrd_path;      /**< ramdisk，如 <imageDir>/ramdisk.img，可为 NULL */
    const char *system_img_path;  /**< system.img */
    const char *vendor_img_path;  /**< vendor.img，可为 NULL */
    const char *product_img_path; /**< product.img，可为 NULL */
    const char *system_ext_img_path; /**< system_ext.img，可为 NULL */
    const char *metadata_img_path;   /**< metadata 盘（可写），可为 NULL */
    const char *userdata_img_path;/**< 可写数据盘，可为 NULL */
    const char *serial_log_path;  /**< 访客串口日志落盘路径，可为 NULL */
    int         memory_mb;        /**< 内存，<=0 时取 2048 */
    int         cores;            /**< vCPU 数，<=0 时取 4 */
    bool        enable_network;   /**< 是否挂 virtio-net + QEMU 用户态 NAT（slirp） */
} VmQemuParams;

/**
 * 在独立线程里启动 QEMU。
 * QEMU 自带事件循环，会阻塞该线程直到退出。
 * @return 0 表示线程已起来；-1 表示参数不合法或已启动过
 */
int vm_qemu_start(const VmQemuParams *params);

/**
 * 请求停机并等待 QEMU 线程退出。
 *
 * 先请 QEMU 走正常退出路径（主循环返回 → qemu_cleanup() 刷写镜像），
 * 再最多等 timeout_ms 毫秒回收线程。可重复调用。
 *
 * @return true 表示 QEMU 已退出（或本来就没启动）
 */
bool vm_qemu_stop(int timeout_ms);

/** QEMU 是否正在运行。 */
bool vm_qemu_is_running(void);

/**
 * QEMU 是否跑在独立子进程里（B1 模式）。
 *
 * 子进程模式下访客帧缓冲在**另一个进程**的内存里，进程内的显示后端
 * （vmhost_display_*）永远取不到帧，必须改用帧回传文件握手
 * （vm_frame_relay.h）。引擎据此决定要不要打开回传。
 */
bool vm_qemu_is_child_process(void);

#endif /* VM_QEMU_H */
