# 游龙沙箱 LibOS 路线图

> 版本：v1.1（2026-10-16）
> 范围：把「光速虚拟机」LibOS 愿景（三层架构）与游龙沙箱现有引擎对齐，明确差距与分阶段推进计划。
> 关联文档：[技术方案设计.md](./技术方案设计.md) · [opengles宿主渲染器实施方案.md](./opengles宿主渲染器实施方案.md) · [方案B排障交接.md](./方案B排障交接.md)
>
> v1.1 变更：按代码实际状态校正基线；已落地的条目（宿主 GLES 渲染、共享内存帧回传、
> 输入 fire-and-forget、后端探测与自动选择、云端分发）移入 §5.1，不再留在待办里。

---

## 1. 目标与愿景

愿景（来自产品方案「光速虚拟机」）：

- **三层架构**：硬件抽象层（HAL，KVM 兼容模块，ARM 指令给物理 CPU 执行，免二进制翻译）→ 虚拟化管理层（轻量 Hypervisor，内存 <50MB）→ 客户机系统层（完整 Android，支持 4.4~10+）。
- **性能目标**：接近真机；GPU 直通渲染 +300%；LZ4 动态内存压缩内存 -42%；冷启动 300ms 级。

本路线图的工程目标：**在不推翻现有引擎的前提下，逐阶段吸收方案中可落地的能力，并如实标注与愿景的差距**。

---

## 2. 技术校核结论（重要前提）

| 方案组件 | 技术现实 | 游龙沙箱现状 | 结论 |
|---|---|---|---|
| 三层架构 | 合理分层 | 已有（QEMU 引擎 / 后端探测 / guest 镜像） | 已是现状 |
| KVM 兼容模块 | KVM 是 CPU 虚拟化扩展**原生执行**，非"翻译" | 后端探测 + 引擎 accel 分支（`-accel kvm` / `tcg`，启动时自动选择） | 已实现 |
| 轻量 Hypervisor <50MB | QEMU TCG 常驻内存远超 50MB | QEMU 引擎 | P1 换 crosvm 或精简 |
| 系统调用拦截（gVisor/Sentry 式） | 与 KVM **互斥**；只能跑单应用 | 无 | **不采用**（跑不了完整 Android） |
| HAL 模拟 | 半虚拟化方向 | virtio-gpu + goldfish address space | 已是现状 |
| GPU 直通 / host 渲染 | 需要 GPU host 渲染/直通 | 宿主 GLES 渲染（gfxstream）已打通，帧走共享内存回传 | host 渲染已完成；直通留 P2 |
| LZ4 动态内存压缩 | 独立优化，不依赖虚拟化路线 | 无 | P1 |
| 冷启动 300ms | 营销指标；完整 Android 达不到 | TCG 冷启动十几分钟 | 不设此验收线 |

**核心决策：游龙沙箱维持 KVM 路线（guest 完整内核 + 半虚拟化 HAL），不转向 gVisor 式用户态内核。** 理由：完整 Android（init/zygote/binder/SurfaceFlinger/HAL 服务）依赖大量内核特性，用户态虚拟内核路线无法承载。

---

## 3. 现有引擎基线（已验证）

- 引擎：自研/移植 AOSP QEMU（`emu-34-release`，底子 QEMU 2.12），纯 TCG 全虚拟化，`libqemu_exec.so` 编入 KVM accel。
- 后端：探测框架（AVF/Gunyah/GenieZone/KVM/TCG）做多信号交叉验证并给置信度；启动时按探测结论**自动选后端**（KVM 优先，否则 TCG），引擎侧再核对 `/dev/kvm` 能否真正打开、失败自动回退。早期的**手动「LibOS 开关」已取消**。
- 设备：virtio-rng / virtio-gpu-pci / virtio-tablet / virtio-keyboard / goldfish-pipe / goldfish-address-space（PCI 0x607D:0xF153）。
- 内核：GKI 5.15.41（p13）重编，virtio/goldfish 全 `=y`；`goldfish_address_space` 驱动移植完成。
- 镜像：**只有 p11 完整可跑并登记在 `VmGuestCatalog.ALL`**；p9 / p13 / p71 实测均在 init 阶段起不来（ramdisk 缺对应内核版本的 `virtio_blk.ko`、p9/p13 是 GPT + super 动态分区、p9 只认设备树 fstab、p71 无 vendor 分区），已从版本目录移除，仅保留界面提示。
- 显示：virtio-gpu + **宿主 GLES 渲染（gfxstream）**；帧回传走**共享内存零拷贝**（3 缓冲轮转 + seq，失败自动回退文件协议，`VMHOST_FRAME_SHM=0` 可强制回退）。
- 输入：virtio-tablet / virtio-keyboard + QMP 注入，命令通道 fire-and-forget（不再逐条等应答）；触摸端到端已打通。
- 网络：slirp NAT + host VPN（VmNetworkService）。
- 冷启动：migration 快照恢复（跳过整个冷启动）。
- 云端：GitHub Releases（gh-proxy），镜像自动下载，App 内自动更新。

---

## 4. 差距分析（现状 vs LibOS 愿景）

| 维度 | LibOS 愿景 | 现状 | 差距 |
|---|---|---|---|
| 指令执行 | ARM 原生执行（KVM） | 有 KVM 后端，但真机探测不到可用 `/dev/kvm`，实际全走 TCG 翻译 | 中等（受宿主 KVM 可用性限制） |
| Hypervisor 内存 | <50MB | QEMU TCG 常驻数百 MB | 大（P1） |
| GPU | 直通 +300% | 宿主 GLES 渲染已打通，但非直通，帧仍需回传后上传 | 中（直通留 P2） |
| 内存 | LZ4 压缩 -42% | 无压缩 | 中（P1） |
| 多版本 | 4.4~10+ | 仅 p11；p9/p13/p71 卡在 init | 中（P0） |
| 冷启动 | 300ms | TCG 十几分钟，靠快照恢复找补 | 极大（不设此验收） |

---

## 5. 路线图

### 5.1 已完成（v1.1 移出待办）

| 原编号 | 事项 | 落地情况 | 依据 |
|---|---|---|---|
| P0-1 | **宿主 GLES 渲染（gfxstream）** | 已打通并连续出帧；黑屏、画面上下颠倒、「跑约 17 分钟必崩」、Adreno SIGSEGV 均已修复。功能目标达成，帧率仍受 TCG 限制 | [方案B排障交接.md](./方案B排障交接.md) §16 / §17 / §19 / §20 · [opengles宿主渲染器实施方案.md](./opengles宿主渲染器实施方案.md) |
| — | **帧回传：文件 → 共享内存** | 64 字节头 + 3 缓冲轮转，读端零拷贝直传 `glTexSubImage2D`；失败自动回退文件协议 | [改动说明-共享内存帧回传.md](./改动说明-共享内存帧回传.md) |
| — | **输入注入 fire-and-forget** | 触摸不再逐条等 QMP 应答，消除每帧最多 200ms 的阻塞 | [改动说明-输入延迟(fire-and-forget).md](<./改动说明-输入延迟(fire-and-forget).md>) |
| — | **触摸端到端打通** | QMP 注入链路验证通过，`ro.hw_timeout_multiplier=10` 让访客 UI 就绪从 4.4h 降到 ~25min | [方案B排障交接.md](./方案B排障交接.md) §22 / §23 |
| P0-3 | **后端探测 + 自动选择** | `VmBackendProbe` 多信号交叉验证给置信度；启动按结论自动选后端（KVM 优先，否则 TCG），状态栏显示「当前 / 推荐」后端。原手动「LibOS 开关」已取消，改为自动 + 展示 | `core-vm`：`VmBackend.kt` / `VmBackendProbe.kt` / `VmBackendStore.kt` / `VmDeviceCheck.kt` |
| — | **宿主参数调优** | QEMU 钉最高主频核（实测 1.43x）、guest 内存 3072MB、6 vCPU、`-tb-size 512`（MTTCG 常开） | [方案B排障交接.md](./方案B排障交接.md) §18 / §21 |
| — | **云端分发与自动更新** | 镜像缺失自动从 GitHub Releases 下载（gh-proxy 加速），App 内自动检查并安装新版本 | `VmImageProvider.kt` / `VmUpdater.kt` |
| — | **启动期不被降级（前台服务 + 大核）** | 实例常驻前台服务 + PARTIAL_WAKE_LOCK：cpuset 从 `background`(0-3, 3.53GHz) 变为 `foreground`(6-7, 4.32GHz)，锁屏/切后台不再掉速或停住 | [改动说明-启动提速(前台服务+大核).md](./改动说明-启动提速(前台服务+大核).md) |
| — | **坏快照自动回退（+两个僵尸/存活检查 bug）** | 恢复启动的 QEMU 早退 → 删 `snapshot.bin` 并按冷启动重来；顺带修掉「子进程模式下 `vm_qemu_is_running()` 恒为 true」与「无窗口时存活检查不执行」 | [改动说明-启动提速(前台服务+大核).md](./改动说明-启动提速(前台服务+大核).md) §7 |

### 5.2 P0 — 低成本高收益（当前即可推进，不动架构）

| # | 事项 | 说明 | 验收 |
|---|---|---|---|
| P0-1b | **启动提速：quickboot 快照（走 aemu 框架）** | 裸迁移流已被证伪（`Unknown ramblock ""`）：模拟器的 savevm 走 protobuf 包装 + aemu 分段钩子 + snapshot 回调，不是 live migration 格式。**移植路线已定**：QEMU 侧 `save_snapshot`/`qemu_savevm`/`hmp_savevm`/`qemu_set_snapshot_callbacks`/`virgl_renderer_save_snapshot` 都已在我们产物里，缺的是 aemu 侧（`android/android-emu/android/snapshot/*` + `base/*`）、protobuf/lz4、qcow2 vmstate 盘、触发入口。见 [aemu快照移植指南.md](../vm/engine/scripts/aemu快照移植指南.md) | 二次启动到可见桌面 < 20s |
| P0-1c | **QEMU 基座升级（已重新定性）** | **2026-10-16 实测更正**：`emu-XX-release` 那一线（含 emu-35-6 / emu-36-1）`QEMU_VERSION` 全是 **2.12.0**、构建系统仍是 configure+make —— 换过去**不会有 TCG 提速**，只有更新的 aemu/gfxstream。真·现代 QEMU 在 **`emu-dev`**（meson+ninja，`version: files('_VERSION')`），但它**没有 ranchu 机器、也没有 aemu 快照子系统**，要自己把 ranchu+goldfish+gfxstream 整套搬过去（量级：周）。锚点清单见 [emu36-升级锚点清单.md](./emu36-升级锚点清单.md)（emu-36 那条线 10/11 补丁直接可用，**很便宜**） | 二选一：(a) emu-36 只拿新 aemu/gfxstream（便宜、无速度收益）；(b) emu-dev 真正提速（大工程，单独立项） |
| P0-2 | **p9 / p13 / p71 镜像适配** | 三者均卡在 init：ramdisk 缺对应内核版本的 `virtio_blk.ko`（p11 是专门配的 40 个 .ko）、p9/p13 是 GPT + super 动态分区而引擎挂的是整盘、p9 的 first-stage init 只认设备树 fstab、p71 连 vendor 分区都没有。已从 `VmGuestCatalog.ALL` 移除 | 版本可创建/启动，并重新登记进 `ALL` |

### 5.3 P1 — 中期（性能/内存架构优化）

| # | 事项 | 说明 | 验收 |
|---|---|---|---|
| P1-1 | **LZ4 动态内存压缩** | 引擎侧 balloon/压缩（ZRAM 思路），多开降内存 | 多开内存占用下降 |
| P1-2 | **crosvm 替换 QEMU** | 轻量 Hypervisor 目标 <50MB；需移植 virtio/goldfish 设备与 KVM 路径 | crosvm 可启动 p11 |
| P1-3 | 多版本镜像体系 | 4.4/7.1/9/11/13 统一打包、自动下载、一键创建 | 版本列表 ≥3 |

### 5.4 P2 — 远期（接近愿景）

| # | 事项 | 说明 | 验收 |
|---|---|---|---|
| P2-1 | GPU 直通 | 在 crosvm/KVM 基础上做 GPU 直通或全 virgl host 渲染 | 渲染接近真机 |
| P2-2 | 单应用 LibOS 沙箱（可选探索） | 若需要"极速单应用"，可另起 gVisor 式轻量容器（与完整 Android 并行） | 独立产品线 |

---

## 6. 风险与约束

1. **宿主 KVM 可用性**：当前真机 `/dev/kvm` 打不开（节点存在但内核未注册 misc 设备，`open` 返回 ENODEV，属 ueventd 静态占位），KVM 实际走不通、全量回退 TCG。已有自动回退，不会因此启动失败；需带可用 KVM 的宿主（Linux 盒子 / 开发板）验证。
2. **TCG 性能天花板**：纯软件翻译的启动与流畅度有限，"300ms 冷启动"在完整 Android 路线下不设验收。若不换执行方式，能指望的最大单点收益是**换掉 QEMU 2.12 基座**（见 [QEMU基座升级-移植指南.md](../vm/engine/scripts/QEMU基座升级-移植指南.md)）。
3. **多版本镜像适配**：p9 / p13 / p71 的阻塞点各不相同（内核模块、分区布局、first-stage init），短期内不存在"打个补丁就都能跑"的路径。
4. **crosvm 迁移成本**：设备/渲染/HAL 栈全量移植，工作量最大，P1 需单独评估。
5. **gVisor 式路线不采用**：无法承载完整 Android，仅作为 P2 可选单应用探索。

---

## 7. 建议推进顺序

1. **P0-1b aemu 快照移植**（见 [aemu快照移植指南.md](../vm/engine/scripts/aemu快照移植指南.md)）
   —— 唯一能把「开启 150 秒」压到十秒级的路，且**不依赖换基座**（快照代码本来就在 emu-34 树里）。
   当前进度：abseil ✅、QEMU 侧 `vmhostsnapshot` HMP 补丁 ✅、引擎侧 save/load 接线 ✅（已编入产物）、
   `build_aemu_snapshot.sh` 推进到 lz4 卡点。
2. **P0-1c 基座升级（单独立项决策）** —— emu-36 线**无 TCG 收益**（仍是 2.12）；
   真要提速得上 `emu-dev` 并把 ranchu/gfxstream 搬过去。见
   [QEMU基座升级-移植指南.md](../vm/engine/scripts/QEMU基座升级-移植指南.md) 开头的"实测更正"。
3. **P0-2 镜像适配**（p13 → p9 → p71；扩版本覆盖，不改善性能）
4. **P1-1 内存压缩**（独立可做，多开收益直接）
5. **P1-2 crosvm**（大项，单独立项评估）
