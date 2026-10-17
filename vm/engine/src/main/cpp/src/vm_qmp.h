#ifndef VM_QMP_H
#define VM_QMP_H

#include <stdbool.h>
#include <stddef.h>

/*
 * 引擎侧的最小 QMP 客户端（B1 子进程模式专用）。
 *
 * 为什么需要它：
 *   B1 模式下 QEMU 跑在**子进程**里，输入注入代码在父进程。父进程直接调
 *   vmhost_input_touch()（ui_vmhost.c）只会撞上 `if (s_con == NULL) return;`
 *   被静默丢弃 —— s_con 只在子进程的 graphic_console_init() 里被赋值。
 *   于是改走 QMP：父进程把 input-send-event 发到子进程，由子进程内部
 *   路由到 virtio-tablet / virtio-keyboard。
 *
 * 只用 unix socket 上的一来一回（line-delimited JSON），不引第三方库。
 * 所有函数线程安全（内部一把锁）；连接失败不会抛异常，只是返回 false。
 */

/** 连接并完成 qmp_capabilities 握手。幂等：已连上时直接返回 true。 */
bool vm_qmp_connect(const char *sock_path);

/** 断开（实例销毁时调用）。 */
void vm_qmp_disconnect(void);

/** 是否已连上。 */
bool vm_qmp_is_connected(void);

/**
 * 注入一次触摸。
 *
 * guest 侧只有 virtio-tablet（单指绝对指针），所以这里发的是
 * 「绝对坐标 + 左键」：
 *   按下：abs(x) → abs(y) → btn(left, down=true)
 *   移动：abs(x) → abs(y)
 *   抬起：btn(left, down=false)
 *
 * @param x, y        访客画面内像素坐标
 * @param max_x,max_y 访客画面尺寸（换算成 virtio-input 的 0..0x7FFF 绝对坐标域）
 * @param down        true=按下/移动，false=抬起
 */
void vm_qmp_touch(int x, int y, int max_x, int max_y, bool down);

/**
 * 注入一次按键（Linux keycode，见 linux/input-event-codes.h）。
 * 子进程模式下按键和触摸一样必须走 QMP，父进程直接调 vmhost_input_key()
 * 会被静默丢弃。
 */
void vm_qmp_key(int linux_keycode, bool down);

/**
 * 发一条 QMP 命令并**读回一条应答**（与输入注入的 fire-and-forget 相反）。
 *
 * 快照这类命令必须确认结果：`human-monitor-command` 跑 HMP 命令，或者
 * `stop` / `cont` 这类控制命令。整个往返持有内部锁，所以不会与输入注入
 * 交叉；代价是这一段时间输入注入会等（调用方应只在 guest 已经冻住时用）。
 *
 * @param command         QMP 命令名，如 "human-monitor-command"
 * @param arguments_json  参数对象原文（可为 NULL）
 * @param reply_out       非 NULL 时写入原始应答行（含 error 原文）
 * @param timeout_ms      等待应答上限
 * @return 0=正常应答；1=QEMU 回了 error（命令不存在/执行失败）；
 *        -1=未连接 / 超时 / 连接坏
 */
int vm_qmp_request(const char *command, const char *arguments_json,
                   char *reply_out, size_t reply_cap, int timeout_ms);

#endif /* VM_QMP_H */
