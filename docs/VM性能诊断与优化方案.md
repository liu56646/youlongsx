# youlongsx VM 性能诊断与优化方案

> 对象：`K:\youlongsx\vm`（Android App + 内嵌 QEMU 的"手机里的手机"）
> 方法：阅读 `engine/src/main/cpp/src/*`（`vm_qemu.c` / `vm_engine.c` / `vm_frame_relay.c` / `vm_guest_display.c`）、`engine/scripts/build_qemu*.sh`、`core-vm`/`app` Kotlin 层
> 结论术语：**【根因】** = 直接决定速度上限；**【次因】** = 叠加拖慢；**【可选】** = 锦上添花
>
> **状态更新（2026-10-16）**：本方案的 ③（显示回传改共享内存）与 ④（参数微调）已落地，
> 第 1 项（KVM 可开性）实测结论为「真机 `/dev/kvm` 打不开，自动回退 TCG」。
> 本文保留原始诊断过程，**进度与后续顺序以 [LibOS_路线图.md](./LibOS_路线图.md) 为准**：
> 仍待做的是 ② 换 QEMU 基座（见 [QEMU基座升级-移植指南.md](../vm/engine/scripts/QEMU基座升级-移植指南.md)）与并发/内存策略。

---

## 0. 结论先行

你慢的根因只有一句话：**在 arm64 宿主上用 QEMU 的 TCG"软模拟"一台 arm64 客户机**（`vm_qemu.c`：`-accel tcg,thread=multi`、`-cpu cortex-a57`）。

宿主和客户机指令集完全相同，本可原生直跑，却被逐条翻译执行。**"启动慢 / 桌面卡 / 应用卡 / 整体慢"四个症状是同一个病。**

而且更雪上加霜的是：真正能把这套访客跑起来的是 **AOSP QEMU `emu-34`（底子是 QEMU 2.12）**（`build_qemu_aosp.sh` 头部注释），**QEMU 2.12 的 TCG 代码生成远落后于现代版本** —— 相当于"用 2018 年的翻译器，翻译本该直接执行的指令"。你另有一份 **上游 QEMU 9.2**（`build_qemu.sh`），但 `-M virt` 上访客的 EmuHWC2 会 abort，跑不到 `boot_completed`，所以被迫用旧的 2.12。

**优化优先级（按收益）：**

| 优先级 | 动作 | 预期收益 | 代价 |
|---|---|---|---|
| ① 治本 | 别再模拟 CPU：KVM（需 /dev/kvm）或"用户态内核/容器"（VPhoneOS 路线） | 10×~原生态 | 大改/需 root |
| ② 大 | TCG 基座从 **QEMU 2.12 换到现代 AOSP emulator（QEMU 7/8）** 或把 ranchu+gfxstream 移植进 9.2 | 1.5×~3× | 中 |
| ③ 中 | 显示回传 **文件→共享内存**（改 `vm_frame_relay`） | 交互明显跟手 | 小 |
| ④ 小 | 设备/参数微调 + 快照冷启动 + 限制并发实例 | 5%~20% | 极小 |

---

## 1. 现状梳理（从代码读出的事实）

**引擎形态**：`libvmengine.so` 把 QEMU 当库/子进程驱动（`vm_qemu.c`），两种承载：

- **A1 进程内嵌**：上游 QEMU 9.2 静态链入本进程，`-M virt`，`ui/vmhost.c` 自定义显示后端把帧留在**本进程内存**（`vmhost_display_copy_frame`）。
- **B1 子进程**：AOSP QEMU（ranchu）作为 `libqemu_exec.so` fork/exec 出去，帧在**另一个进程**，只能走 `frame.request/frame.rgba` **文件握手**回传（`vm_frame_relay.c`）。**目前真正能 boot 的是这条。**

**B1 启动参数**（`spawn_qemu_child`，关键项）：

```
-accel tcg,thread=multi          ← MTTCG（已开，好）
-tb-size 512                     ← 翻译块缓存 512MB（已调，好）
-M ranchu   -cpu cortex-a57      ← 模拟 CPU
-smp <cores> (默认4)  -m <mem> (默认2048)
-drive if=none,id=dN,file=...,format=raw,cache=unsafe [,readonly=on]
-device virtio-blk-device        ← 默认 MMIO；VMHOST_BLK_PCI=1 切 PCI
-device virtio-rng-device
-device virtio-gpu-pci           ← gfxstream 3D（必须 PCI，有充分理由）
-device virtio-tablet-device / virtio-keyboard-device
-device virtio-net-pci,romfile=  ← 仅 enable_network 时
-qmp unix:.../qmp.sock + tcp:127.0.0.1:4444
-display none -serial file:...   ← 画面靠 gfxstream glue 写文件回传
```

**图形**：移植 Android 模拟器 GPU 栈 —— aemu + **gfxstream(stream_renderer)**，`virtio-gpu-pci`。方向是对的（宿主 GPU），但输出是**文件帧回传**。

**存储**：raw + `cache=unsafe`（已是偏性能的激进取法）；p11 的 ramdisk 带 `virtio_blk.ko` 才能认盘。

**冷启动**：用 `migration` 快照（`-incoming unix:...`）+ `snapshot.bin` 跳过整个冷启动 —— 已做，且是**感知速度**的最大杠杆。

**多实例**：`VmConstants.MAX_INSTANCES = 4`（`:vm1~:vm4`）。

---

## 2. 瓶颈分层

### 2.1 CPU 层【根因】
- 全量 TCG 翻译执行；MTTCG 只在访客**真并行**时提速，而 Android boot 前中期天然串行（你在注释里也观察到了）。
- 基座是 **QEMU 2.12**：TB 构造、寄存器分配、host codegen 都比 9.x 差一大截。
- **即使 gfxstream GPU 直通成功，访客的 SurfaceFlinger / zygote / app 逻辑仍跑在 TCG 里** → 桌面合成与 UI 线程本身就被模拟拖垮。GPU 只解决"画"，解决不了"算"。

### 2.2 图形层【次因】
- **文件帧回传**是 IO + 拷贝的重灾：每帧把 `720×1280×4 ≈ 3.5MB` RGBA **写盘**、再**读回**、再 `glTexSubImage2D` 上传；请求/应答走 `frame.seq`/`frame.request` 轮询，还叠加 16ms 节流。
- 这条路径与 CPU 快慢无关，纯属**显示管线**开销，直接吃"跟手感"。进程内模式（共享内存）没这问题，但你用的是子进程模式。

### 2.3 存储/IO 层
- `cache=unsafe` 已很激进；但 MMIO 的 `virtio-blk-device` 比 `virtio-blk-pci` 略慢，且访客认盘依赖 ramdisk 里的 `virtio_blk.ko`。

### 2.4 内存/多实例
- 每实例 2048MB + 一个 QEMU 进程；4 实例并发在手机上会 CPU/内存/后台保活三面打架（Android 12 还有 32 进程上限）。

---

## 3. 优化方案

### 3.1（治本）别再模拟同架构 CPU

- **KVM**：你已有代码路径（`kvm_dev_available()` → `-accel kvm -cpu host`）。逻辑很稳（节点存在≠可用，会安全回退）。**问题只在准入**：非 root 的普通 Android App 几乎打不开 `/dev/kvm`（SELinux 拒绝 / 占位节点 ENODEV）。
  - 若目标设备**可 root / 可访问 /dev/kvm** → 这是性价比最高的一步，接近原生速度。
  - 建议：先在目标机型上实测 `open("/dev/kvm")`，把结果作为"能否走 KVM"的产品分档依据。
- **用户态内核 / 容器（VPhoneOS 路线）**：不模拟 CPU，让访客 Android 的每个 arm64 进程**原生运行**，只拦截/转发系统调用给宿主内核。这是**无 root 情形下唯一能做到原生态**的架构，也正是你逆向的 `libuserkernel` 路线。代价最大（要自研 syscall 兼容层、Binder/驱动映射），但天花板最高。

### 3.2（若必须留 TCG）换掉 QEMU 2.12 —— 单点最大 TCG 收益

- **首选**：把基座从 AOSP `emu-34`(QEMU 2.12) 升到**现代 Android Emulator（QEMU 7.x/8.x）**的 ranchu/goldfish 分支。现代 TCG 在同等工作负载下普遍快 1.5×~3×（更好的 TB、寄存器分配、MTTCG 成熟度）。
- **次选**：继续你已有的"移植进上游 QEMU 9.2"路线 —— 你卡在 EmuHWC2/gfxstream pipe 上；把这条打通，就同时拿到"新 TCG + 你自己可控的 vmhost 显示后端（进程内共享内存，免文件回传）"。这是"②+③一箭双雕"的方向，值得优先投入。

### 3.3（显示）文件回传 → 共享内存

- 现状：子进程写 `frame.rgba` 文件 → 父进程轮询读取。**把这一层换成 `ashmem`/`MemFd` 共享缓冲**：
  - QEMU 子进程把一帧 RGBA 写进共享内存块，用**原子递增的 seq**（或 eventfd）通知；
  - 父进程直接 mmap 读取并 `glTexSubImage2D`，**零文件 IO、零多余拷贝**。
  - 保留 `frame.request` 作为"要一帧"的控制信号即可（或直接用 eventfd 双向）。
- 收益：与 CPU 无关的"跟手感"提升，尤其滑动/输入回显。
- 备注：v2 帧文件已经是原生 RGBA8888（无色彩转换），改成共享内存后连 `read()` 那次系统调用都省掉。

### 3.4（参数/设备微调，低成本）

- **`-cpu max`** 试一下（在 TCG 下暴露更多特性，部分访客代码会走更快路径）；但**必须回归验证** ranchu 访客不炸（可能影响 guest 对 CPU 特性的假设）。不稳就退回 `cortex-a57`。
- **`-smp` 对齐宿主物理大核数**（别超过，别用 LITTLE 核去扛 vCPU）。
- **`-tb-size 512 → 1024`** 试（内存换命中率；注意总内存）。
- **磁盘**：可写盘用 `cache=unsafe`（已有）；只读盘加 `,readonly=on`（已有）；试 `discard=unmap`。默认 `virtio-blk-device` 可试 `VMHOST_BLK_PCI=1` 对比。
- **默认分辨率**：⚠️ **不要照我之前的建议降到 540×960 —— 你们已实测过，那是死路**。`VmConfig.kt` 记着：540×960 时**guest 从头到尾不 post 任何帧**（怀疑宽度 540 不是 16 的倍数，ranchu/gfxstream 显示链路不接受），且降分辨率对**启动时间**也没帮助。**结论：保持 720×1280**；真要压像素量，先确保宽高都是 16 的倍数（如 `640×1152`）再做 A/B。
- **网络**：`slirp` 用户态 NAT 在 QEMU 进程内，能不开就不开（对纯性能敏感场景）。
- **guest 版本**：越轻的 guest（Android 9 < 11 < 13）TCG 下 boot 越快；产品上按机型给不同默认 ROM。

### 3.5（冷启动 & 并发）

- **快照恢复**是"感知速度"王牌：打磨到"秒开"。注意你的注释里已踩过的坑（goldfish_pipe 退出迁移、QMP 恢复通道）。
- **限制并发实例数**：手机上同时跑多个 QEMU TCG guest 基本等于自杀；建议默认单实例前台 + 其余挂起，或按机型能力动态限流。

---

## 4. 可落地改动清单

**A. 最高优先（治本评估）**
1. 在目标机型实测 `/dev/kvm` 可开性 → 决定是否走 KVM 分档。
2. 决策：短期"升 QEMU 基座"，长期"用户态内核/容器"。

**B. 中期（代码级）**
3. 若走 TCG：把 AOSP QEMU 基座从 2.12 升到现代 emulator 分支（改动集中在 `build_qemu_aosp.sh` 的源码来源与补丁）。
4. 打通"ranchu + gfxstream 进上游 9.2"，同时换用进程内 `vmhost` 显示后端（消灭文件回传）。

**C. 近期（小改，立刻见效）**
5. `vm_frame_relay.c`：文件握手 → `ashmem` + 原子 seq / eventfd。
6. `vm_qemu.c`：A/B `-cpu max`、`-tb-size`、`VMHOST_BLK_PCI`、默认分辨率。
7. 实例并发策略（前台单跑 + 后台挂起）。

**D. 验证方法**
8. 用你已有的串口日志 `console.log` + `qemu-stderr.log` 采集 boot 到 `boot_completed` 的墙钟时间；对同一镜像做 A/B。
9. 用 `top -H` 看每条 `CPU n/TCG` 线程的占用，确认 MTTCG 是否真吃到多核。
10. 显示路径：统计"帧到达间隔"与"丢帧率"，对比文件回传 vs 共享内存。

---

## 5. 一句话总结

**你的架构方向没大错（QEMU 全系统 + gfxstream GPU + 快照），但"同架构还用 TCG 模拟"是天花板级的设计税；能拿掉就拿掉（KVM / 用户态内核）。拿不掉，就至少把 QEMU 2.12 换掉、把文件帧回传换共享内存 —— 这两步不需要动架构，却能把"能忍"变成"能用"。**
