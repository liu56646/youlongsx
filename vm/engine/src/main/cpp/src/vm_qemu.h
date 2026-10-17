#ifndef VM_QEMU_H
#define VM_QEMU_H

#include <stdbool.h>
#include <stddef.h>

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
    /**
     * 访客显示分辨率（<=0 时用 gfxstream 的编译期默认 720x1280）。
     *
     * TCG 下每帧每个像素都要 guest 的 SF/HWC 合成，像素量直接决定合成耗时，
     * 因而是"调快慢"最直接的旋钮。做成运行期参数是为了能 A/B 对比不同分辨率
     * 而不必每次重编 QEMU。
     */
    int         display_width;
    int         display_height;
    bool        enable_network;   /**< 是否挂 virtio-net + QEMU 用户态 NAT（slirp） */
    /**
     * 请求的后端名（VmBackend.name，如 "KVM" / "QEMU_TCG"）。NULL 或空串视为 TCG。
     * 引擎会再核对一次 /dev/kvm 是否真能打开，打不开自动回退 TCG。
     */
    const char *backend_name;
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

/**
 * 取 QEMU 的 QMP unix socket 路径（即 <日志目录>/qmp.sock）。
 *
 * B1 子进程模式下父进程靠它把输入事件（input-send-event）发给子进程里的
 * QEMU —— 见 vm_qmp.h。路径由 vm_qemu_start() 配置 -qmp 时确定，未启动或
 * 拿不到日志目录时返回 false。
 */
bool vm_qemu_qmp_path(char *out, size_t out_len);

/**
 * 本次启动是否走「快照恢复」并且已经失败（子进程早早退出）。
 * 调用方据此删除快照、回退冷启动，否则实例会一直黑屏。
 */
bool vm_qemu_restore_failed(void);

/** 复位启动状态，使上层可以在子进程退出后再调一次 vm_qemu_start()。 */
void vm_qemu_reset(void);

/** 本次会话是否已经拉起过 QEMU（用于判断「该盯存活了」）。 */
bool vm_qemu_has_started(void);

#endif /* VM_QEMU_H */
