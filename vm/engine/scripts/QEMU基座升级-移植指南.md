# AOSP QEMU 基座升级 —— 移植指南（2.12 → 现代 Emulator / QEMU 7/8）

> 目标：把 `build_qemu_aosp.sh` 依赖的 AOSP QEMU 从 **emu-34（底子 QEMU 2.12）** 换到
> **现代 Android Emulator 分支（QEMU 7.x/8.x）**，从而拿到现代 TCG（TB 构造、寄存器分配、
> MTTCG 成熟度都强得多，实测同负载普遍快 1.5×~3×）。
>
> ⚠️ 本指南是**移植路线图**，不是一键脚本。版本锚点无法离线验证，必须在你的 WSL 构建循环里
> 逐个补丁"改→编→看报错→再改"。`build_qemu_aosp.sh` 已加版本闸门：版本不符会**先拦下**，
> 不会半途编出坏二进制。
>
> ## ⚠️ 2026-10-16 实测更正：**没有"既现代又带 ranchu"的分支**
>
> 上面那句"升到现代 emulator 分支拿现代 TCG"经逐分支核实后**不成立**。
> 清华 AOSP 镜像
> （`https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/platform/external/qemu`）实测：
>
> | 分支 | `QEMU_VERSION` | 构建系统 | ranchu/gfxstream/aemu快照 | 判定 |
> |---|---|---|---|---|
> | `emu-34-release`（现状） | 2.12.0 | configure+make | 全都在 | 现状 |
> | `emu-35-6-release` | 2.12.0 | configure+make | 全都在 | 同内核，**无 TCG 收益** |
> | `emu-36-1-release` | 2.12.0 | configure+make | 全都在 | 同内核，**无 TCG 收益** |
> | `emu-dev` | 现代（meson，`version: files('_VERSION')`） | **meson+ninja** | **都没有**（`hw/arm/*ranchu*`、`android/android-emu/android/snapshot` 均不在） | 真·现代 QEMU，但要自己搬 ranchu/gfxstream/快照 |
>
> 结论：
>
> - **`emu-3X-release` 那一线不是"现代 QEMU"**：它一直是 2.12 内核的 Android 老 fork，
>   只有 aemu/gfxstream 在往前走。换 emu-36-1 **不会让 TCG 变快**，
>   收益只有"更新的 aemu/gfxstream + 更新的快照子系统"。
>   好消息：锚点清单（[emu36-升级锚点清单.md](../../../docs/emu36-升级锚点清单.md)）显示
>   现有 11 个补丁 10 个直接可用、1 个可删，**搬过去很便宜**。
> - **真正的 TCG 提速要换到 `emu-dev` / 上游 QEMU 9.2**，代价是把 ranchu 机器 +
>   gfxstream 胶水 + goldfish 设备 + 快照子系统整套移植过去 —— 量级是"周"。
>
> **因此顺序统一为：先做 aemu 快照移植（10× 收益，且不依赖换树），基座升级单独决策。**
> 抓取命令（只更新 remote ref，不动工作区）：
>
> ```bash
> cd ~/vmbuild/qemu-aosp
> git fetch --no-tags origin emu-36-1-release:refs/remotes/origin/emu-36-1-release   # 仍是 2.12
> git fetch --depth=1 --filter=blob:none --no-tags \
>     origin emu-dev:refs/remotes/origin/emu-dev                                      # 真·现代 QEMU
> ```

---

## 0. 策略选择：升 AOSP emulator，不要升上游 QEMU

有两条路，强烈建议第一条：

1. **升到更新的 AOSP Emulator 分支**（`platform/external/qemu` 的 `emu-XX-release`）。理由：
   ranchu/goldfish/gfxstream/feature_control 这些"AOSP 定制"在新分支里是**上游持续维护**的，
   你只需重对**少量**自有补丁；而现代 TCG 全都在。
2. 把 ranchu + gfxstream 移植进你已能构建的**上游 QEMU 9.2**（`build_qemu.sh`）。工作量大得多——
   要自己搬整套 goldfish/ranchu + aemu glue。**不推荐**，除非你有特定理由。

**核心原则：能少带一个补丁就少带一个。** 很多你现在打的补丁，在现代分支已经是上游行为，直接删。

---

## 1. 现存补丁清单与移植要点

来源：`build_qemu_aosp.sh`。按"改动量 / 风险"从高到低：

| # | 补丁（函数） | 作用 | 现代 QEMU 的变化 | 移植要点 |
|---|---|---|---|---|
| 1 | `patch_embed_entry`（+`vmhost_crash_install`/`vmhost_pipe_init`/`vmhost_gfx_init` 挂载） | 在 `main_impl(argc,argv,on_main_loop_done)` 里插入启动钩子 | 入口大改：上游 `softmmu/main.c`→`qemu_init()`；AOSP 现代也有自己的入口包装 | **重写挂接点**。找到新树里的 main/qemu_init，把三个 vmhost 调用插在等价位置。置信度：中 |
| 2 | `patch_goldfish_pipe_savevm` | 让 goldfish_pipe 退出迁移 | 现代 AOSP 的 goldfish_pipe 已重构，`register_savevm`→`vmstate` | 若新树已不含该 savevm 路径则**直接删**；否则改用 `VMStateDescription` |
| 3 | `patch_virtio_gpu` / `patch_virtio_gpu_stream` / `patch_virtio_gpu_capset` | virtio-gpu 走 gfxstream stream_renderer + capset | 现代把 virgl 拆到 `hw/display/virtio-gpu-virgl.c`，`CONFIG_STREAM_RENDERER` 结构变了 | 对准新文件与宏；`host/virtio-gpu-gfxstream-renderer.cpp` 的 API 名也可能变。置信度：低 |
| 4 | `patch_crash_hooks` / `vmhost_pipe_glue.cpp` | 崩溃处理 + AndroidPipe 服务注册 | `qemu2::VmLock`/pipe 服务接口可能变 | 重新对齐 aemu/gfxstream 新分支的头与符号 |
| 5 | `patch_feature_include` | 把 `host-common/feature_control.h` 提前 include | `vl.c` 在现代被大幅精简/搬迁 | 新树里找等价位置；AOSP modern 可能已自带 |
| 6 | `patch_bionic` | bionic 适配（pty.h 等） | 现代 QEMU/AOSP 对 Android 适配更好 | 多数可能**不再需要**；留一个精简版兜底 |
| 7 | `patch_goldfish_pipe_arch` | pipe 架构适配 | 现代实现已不同 | 重对锚点 |
| 8 | `patch_mmap_alloc` | 内存分配适配 | `qemu_memalign`/`memory-backend` 变化 | 重对 |
| 9 | `patch_ranchu_pcie.py` / `patch_vmhost_surface.py` / `patch_vmhost_diag.py` / `patch_gfxstream_threadinfo.py` / `patch_virtio_gpu_trace.py` | ranchu PCIe、surface、诊断、trace | 视新树而定 | 逐个跑，锚点不中就改 `.py` 里的锚点串 |
| 10 | `coroutine-android.c`（`util/` 里新增） | Android 上 coroutine 后端 | 现代 QEMU 自带 ucontext coroutine，Android 支持更好 | 大概率**直接删** |
| 11 | `reset_scratch_sources` | 每轮从 git 恢复 vl.c / goldfish_pipe.c | — | 保留，路径按新树调整 |
| 12 | virtio-mmio modern 传输（注释里提到，非本脚本函数） | 让 virtio-input 等 spec1.0 设备能绑驱动 | **现代 QEMU 已原生支持 VIRTIO_F_VERSION_1** | **很可能直接删** |

---

## 2. 构建系统本身也要改（make → meson）

2.12 用 `configure`+`make`（且要 Python 2）；现代 AOSP Emulator 用 **meson + ninja**（Python 3）。
`build_qemu_aosp.sh` 的 `2. configure` / `3. build` 两段要整段重写：

- 删掉 `/opt/py2` 依赖（`wsl_setup_py2.sh` 随之可弃）。
- configure/make → `meson setup` + `ninja`；产物路径从 `aarch64-softmmu/qemu-system-aarch64` 变到
  `build/qemu-system-aarch64`（按新树实际为准）。
- 追加 glue / 静态库的方式：从"改 `config-host.mak`"改成"改 `meson.build` 或 `--extra-ldflags`"。

> 这一步和补丁移植是**并行**的；建议先让新树的**原版**能 configure+ninja 通过，再往上加补丁。

---

## 3. 别忘了 `vm_qemu.c` 里的启动参数

升级后**引擎侧命令行的写法也要同步**（这些不在 build 脚本里）：

- `-tb-size 512`（2.12 的顶层参数）→ 现代改成 **`-accel tcg,thread=multi,tb-size=512`**。
  代码注释里已经记录过这个语法差异，升级时把两处合并成新写法。
- `-accel tcg,thread=multi`：现代仍支持；可再试 `-cpu max`（回归验证 ranchu 访客）。
- 设备名（`virtio-gpu-pci` / `virtio-blk-device` / `virtio-input` 系列）现代基本一致。

---

## 4. 移植步骤（在 WSL 里迭代）

```bash
# 1) 取现代分支源码（替换旧的 $WORKDIR/qemu-aosp）
#    repo / git 取 platform/external/qemu 的 emu-<新>-release，放到 $SRC_DIR
# 2) 先让纯原版构建通过
WORKDIR=~/vmbuild ALLOW_UNVERIFIED_QEMU=1 ./build_qemu_aosp.sh   # 会一路报锚点未命中——正常
#    → 按报错把 configure/make 段改成 meson/ninja，直到“无补丁也能编出 qemu-system-aarch64”
# 3) 逐个补丁重表达：每改一个，把 QEMU_AOSP_EXPECT 设成新版本，单独跑，看锚点是否命中
# 4) 全绿后：把所有 QEMU_AOSP_EXPECT 默认值改成新版本号，删掉版本闸门的绕过
```

**验收清单**（与升级前逐条对比）：
1. `qemu-system-aarch64` 能编出、能 `-M ranchu` 起来；
2. 访客 boot 到 `boot_completed`（看 `console.log`）；
3. `pipe:opengles` 打开成功、SurfaceFlinger 起得来（看 `qemu-stderr.log` 的 VMHOSTGFX 打点）；
4. 帧回传（共享内存）出画面；
5. 记录 boot 墙钟时间、`top -H` 里 `CPU n/TCG` 线程占用 —— 与 2.12 版对比，确认 TCG 提速。

---

## 5. 风险与回退

- **风险**：virtio-gpu / gfxstream 那几个补丁（清单 #3、#4）最脆，锚点和 API 都可能变；建议**最后攻**。
- **回退**：旧树 + 旧二进制一直在 `prebuilt/qemu-aosp/`，`build_qemu_aosp.sh` 产物不进 git，
  切回 `QEMU_AOSP_BRANCH=emu-34-release` 重编即可回到现状。
- **灰度**：显示回传已在"共享内存 + 文件"双路径上，升级 QEMU 不影响这部分。

---

## 6. 一句话

升级 = **换源码线（而不是重写引擎）** + **重对约 12 个补丁锚点** + **configure/make→meson 改造**，
最后同步 `vm_qemu.c` 的 `-tb-size` 语法。收益大（TCG 1.5×~3×），但没有离线银弹——必须在你的
WSL 构建循环里逐个锚点收敛。
