# 改动说明：输入注入改 fire-and-forget（消除每帧最多 200ms 阻塞）

> 目的：消除 B1 子进程模式触摸注入里"每条事件同步等 QMP 回复"的阻塞 —— 这是滑动/点击"跟手"变差的主因之一，且与 CPU 快慢无关。
> 影响面：仅子进程模式的输入注入（`vm_qmp.c`）。进程内嵌 QEMU 的直调路径不变。

---

## 1. 问题

B1 子进程模式，触摸事件经 QMP 发给子进程里的 QEMU：
`vm_input_handle_motion` → `inject_touch` → `vm_qmp_touch` → `command_locked`。

旧 `command_locked()` 在**写出命令后会阻塞读回复**（`read_line_locked`，socket 读超时 `REPLY_TIMEOUT_MS = 200ms`）。也就是说：**每条触摸 MOVE，都要等 QEMU 回一行 JSON，最坏等满 200ms。**

而 `vm_qmp.c` 自己的注释就写着："QEMU 主循环在 TCG 高负载下可能几百毫秒才回一条。" 更要命的是——**输入回调跑的那条线程，就是跑渲染的 looper 线程**（见 `vm_activity.c` 的 `android_main`：`ALooper_pollOnce` → `source->process` → `onInputEvent` → …，紧接着同一循环里就是 `vm_render_frame()`）。

于是：**一个触摸 MOVE 卡住 → 输入卡住 + 渲染一起卡住**。高帧率滑动时事件频繁，表现就是滑动发滞、丢帧 —— 和 TCG 的 CPU 开销叠加，进一步恶化体验。

## 2. 改法

`input-send-event` **本来就不需要应答**。把 `command_locked()` 改成 **fire-and-forget**：

- 仍然 `write`；写失败 → 判定连接坏（重连）。
- 之后**用非阻塞方式（`fcntl(O_NONBLOCK)`）把已到达的数据读掉**并丢弃（`return`/`event`/`error` 都无所谓），**绝不等待**；读到 EOF 才算连接断。
- 读完恢复原来的 socket 标志。

排空的意义：QMP 是行协议，回复会到达 socket 缓冲；不排空迟早把缓冲撑满导致 `write` 阻塞。非阻塞排空既清空缓冲、又零等待。

## 3. 文件

| 文件 | 改动 |
|---|---|
| `engine/src/main/cpp/src/vm_qmp.c` | `command_locked()` 改为 fire-and-forget（写 + 非阻塞排空）；新增 `#include <fcntl.h>` |

握手（`vm_qmp_connect` 里的问候语 + `qmp_capabilities`）仍走**阻塞**读，保证连接建立正确；只有命令通道改成不等应答。

## 4. 验证

1. 触摸/滑动主观是否更跟手、更少顿挫。
2. `logcat` 里不再出现因等待导致的输入滞后（原实现下高负载时触摸响应会明显延迟）。
3. 输入注入仍生效（点击能打开图标、能滑动）——功能不变，只是不再等应答。
4. 断连行为不变：QEMU 子进程退出后，下一次 `write`/`read` 会报错并触发重连。

## 5. 备注

- 旧实现在命令被拒时会打 `QMP 命令被拒绝` 日志，现已去掉（输入注入的应答本就无需关心）。
- 顺带记录一个**既有隐患**（本次未动）：向已关闭的 socket `write` 可能触发 `SIGPIPE` 终止进程；若线上出现"某次子进程退出后 App 一起挂"，可在引擎初始化处 `signal(SIGPIPE, SIG_IGN)` 兜底。
