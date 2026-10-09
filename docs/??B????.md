# 方案 B 排障交接（virtio-gpu + gfxstream）

> 创建日期：2026-10-06
> 目的：跨对话延续排障进度，避免上下文丢失后重新勘察。

## 1. 目标

让 guest（Android 11，Linux 5.4.86-android11-2，ranchu/arm64）的 `virtio_gpu` 驱动
成功 probe，走 **gfxstream stream_renderer** 渲染路径（方案 B），最终让 App
显示虚拟机画面。宿主：小米真机（adb `cc96ded5`，Android 16，TCG 无 KVM），
QEMU 为自编 AOSP qemu 2.12（`/dev/vexp/qemu-system-aarch64`）。

## 2. 已确认的铁证（结论级）

1. **host 侧 100% 正常**：`patch_virtio_mmio_trace.py`（alldev 版）打印的完整
   MMIO trace 显示：guest 完成 features 协商（写 DRIVER_FEATURES=0x3000001b），
   QEMU 正常处理 `STATUS=0x83`（`has_v1=0` 不触发 `virtio_validate_features`，
   status 正确更新为 0x83 并返回）。
2. **guest 写 `STATUS=0x83` = `VIRTIO_CONFIG_S_FAILED`(0x80) | DRIVER | ACKNOWLEDGE**，
   这是 virtio core `virtio_dev_probe` 的 `goto err → add_status(FAILED)` 路径，
   即 **probe 失败**，之后 guest 无任何后续 MMIO（无回读、无 QUEUE_SEL/notify）。
   （注意：FEATURES_OK 是 0x08，0x83 里的 0x80 是 FAILED，不是 FEATURES_OK！）
3. **排除 VIRTIO_F_VERSION_1 检查**：blk(dev=2) 协商的 features（0x30000e74）
   同样无 VERSION_1（高 32 位=0），但 blk probe 成功；GPU(dev=16) features
   0x3000001b 亦无 VERSION_1。所以不是 VERSION_1 强制检查导致。
4. **反汇编 guest `virtio-gpu.ko`**（WSL `/tmp/rd1/lib/modules/virtio-gpu.ko`）：
   `virtio_gpu_probe` @0x1120，开头 0x1148 的 `ldr w8,[0x2000]; cbz → -EINVAL`
   是误读（0x2000 是 .text 起始，读的是机器码，非 0，不触发）。第一个有效调用
   是 **`drm_dev_alloc`**（0x1160，x0=&virtio_gpu_driver，x1=&vdev->dev），
   **失败时无任何打印**，直接 `return err` → 这即是 probe 静默失败点。
5. **guest 串口无任何 DRM 输出**（grep drm 只有 drmserver 等）→ 最可能：
   **guest 的 DRM 核心（drm 子系统，fs_initcall `drm_init`）未就绪**，导致
   `drm_dev_alloc`（内部 drm_dev_init → drm_minor_alloc）失败。

## 3. 已尝试且失败的手段

- **dumper 探针**（`-append rdinit=/dumper`，`dumper.c`）：3 轮修改输出通道
  （/dev/kmsg 优先 → /dev/console 优先）输出仍全静默。根因：initramfs 的 /dev
  无 console/kmsg 节点且 guest 内核无 devtmpfs（日志 `request_module fs-devtmpfs
  succeeded, but still no fs?`），OUT 落到 fd 2 不是串口。**已放弃 dumper**。
- **QEMU gdbstub RSP**（`-gdb tcp::1234` + `adb forward tcp:1234`，Windows 侧
  Python 连 127.0.0.1）：能连能读寄存器，但：
  - 连接即冻结 guest（读到的 PC/sp 是暂停值，且所有 vCPU 读到同一值，Hg 切换未生效）；
  - 模块基址搜索（`0xffff000008000000` 起 64MB，`rsp_find_mod.py` 搜
    `virtio_gpu_probe` 特征 `ff4301d15e8600f8fd7b02a9`）**未命中**（可能模块区
    不在该范围，或搜索区不对）。
- **WebSearch/WebFetch 拉 AOSP 5.4 virtio.c / virtio_gpu_drv.c 源码**：googlesource
  不通，搜索引擎未直接命中源码。

## 4. 关键文件与产物

| 路径 | 说明 |
|---|---|
| `k:\youlongsx\vm\build-aosp-exp\patch_virtio_gpu_stream.py` | 方案 B C 源码补丁（CONFIG_ANDROID→组合条件） |
| `k:\youlongsx\vm\build-aosp-exp\patch_virtio_gpu_capset.py` | gfxstream capset 补丁 |
| `k:\youlongsx\vm\build-aosp-exp\patch_virtio_mmio_trace.py` | MMIO 寄存器 trace（已手动改成 alldev 版：打印 dev_id+全部访问+DEVFEAT/DRVFEAT 值） |
| `k:\youlongsx\vm\build-aosp-exp\patch_vss_trace.py` | virtio_set_status/validate_features trace（VMHOSTVSS） |
| `k:\youlongsx\vm\build-aosp-exp\qemu-b17-alldev.so` | 18.4MB，含 MMIO all-dev + VSS trace，已部署 `/dev/vexp/qemu-system-aarch64` |
| `k:\youlongsx\vm\build-aosp-exp\d1a.sh` | 启动脚本，带 `-gdb tcp::1234`、`-d guest_errors`、`-serial file:d1a.log` |
| `k:\youlongsx\vm\build-aosp-exp\guest-kernel.gz` | guest 内核镜像（gzip，解压 26.9MB Image，无符号表） |
| `k:\youlongsx\vm\build-aosp-exp\rsp_pc.py` / `rsp_all.py` / `rsp_dbg.py` / `rsp_find_mod.py` | RSP 调试脚本（Windows Python 直连） |
| WSL `/tmp/rd1/lib/modules/virtio-gpu.ko` 等 | 从 guest ramdisk 提取的内核模块（可用 NDK llvm-objdump 反汇编） |
| WSL `/root/vmbuild/qemu-aosp-build-arm64-v8a/` | QEMU 增量构建目录（`make -k -j8`；helper -lutil 失败可忽略；需先 `sed -i 's/-lutil//g' config-host.mak`） |

## 5. 下一步建议（按优先级）

1. **确认 DRM 根因**：确认 guest 内核 `CONFIG_DRM`（=y/m?）、`drm_init`
   （fs_initcall）是否执行。手段：`strings guest-kernel.gz` 解压后找
   `[drm] Initialized` / `drm_dev_alloc` 相关字符串；或 gdbstub 断点
   `drm_dev_alloc`（需先解决模块基址定位）。
2. 若确认 DRM 未就绪是根因：从 guest 内核/ramdisk 层面解决（内核 cmdline、
   drm 模块加载、或换内核）。
3. 备选：若 virtio-gpu 驱动路径短期内无法打通，评估退回方案 C（host 兜底截图
   回传，`VMHOST_FRAME_DIR` + `frame.request/frame.ppm` 已就绪）或研究
   `drm_dev_alloc` 具体 errno（gdbstub 断点 + `x0`）。

## 6. 踩坑记录（避免重犯）

- PowerShell 引号嵌套会吞 `$()`/`$var`：复杂命令先写本地 `.sh` 再 `adb push` 执行，
  或拆成多条简单命令。
- `wsl` 默认发行版是 docker-desktop（无 bash），必须 `wsl -d Ubuntu`。
- WSL2 访问 Windows localhost 不通（NAT），Windows 侧有 Python 3.12.9，RSP 直连
  `127.0.0.1`。
- QEMU 增量重编：`virtio.o` 单目标编译缺 cpu.h（需完整 `make -k -j8`）；
  helper（qemu-bridge-helper 等）因 bionic 无 -lutil 失败属正常，主程序不受影响。
- 修改 `d1a.sh` 后必须重新 push 到真机 `/data/local/tmp/d1a.sh`（曾因忘 push
  导致 `-d guest_errors` 未生效）。
- guest 串口日志在真机 `/data/local/tmp/d1a.log`（全量 dmesg，`ignore_loglevel`）；
  host stderr 在 `/data/local/tmp/d1a_run.log`（VMHOSTGFX/VMHOSTGPU/VMHOSTMMIO/VMHOSTVSS）。

## 7. 2026-10-07：宿主侧回传链路已补齐，卡点收敛到子进程 SIGSEGV

### 7.1 远端已合并的修复（PR #1，commit `9bf2875` / merge `617574d`）

- **子进程可执行体终于会进包**：`build_qemu_aosp.sh` 新增安装步骤，把可执行体装成
  `jniLibs/<abi>/libqemu_exec.so`（chmod 0755）并补齐运行时依赖；`engine/build.gradle.kts`
  加 `keepDebugSymbols`，避免 AGP 把 PIE 可执行体当普通 .so 去 strip。
  （此前 `file_ok(exe)` 永远失败，每次都静默退回跑不起来的进程内嵌 `-M virt`。）
- **新增 `vm_frame_relay.{c,h}`**：引擎侧的帧回传**消费端**（此前只有生产者
  `vmhost_gfx_glue.cpp`）。含坏帧重试（同一 seq 连续 3 次解码失败就跳过并重新请求）。
- `vm_guest_display.c` 改双路径（内嵌优先、取不到回落文件回传）；`vm_qemu.{c,h}` 新增
  `vm_qemu_is_child_process()` 与候选可执行体名；`vm_engine.c` 在子进程模式下设回传目录
  `<dataDir>/logs`；`vm_activity.c` / `vm_qemu.h` 用 `VM_WITH_QEMU` 收口（骨架构建下
  原先因 `vm_qemu_stop` 未定义而 dlopen 失败）。
- `vmhost_gfx_glue.cpp`：修 `getScreenshot` 兜底路径把 RGBA(4B/px) 写进 P6(3B/px) 文件的
  bug，并加 cap 越界校验。

> 该 PR 的验证是**静态的**（作者本机无 C 工具链 / NDK / WSL，只做了语法检查与
> Python 协议对跑）；其代码已在本机重编通过（`:app:assembleDebug` BUILD SUCCESSFUL）。

### 7.2 本机真机实测（真机 cc96ded5，App 实例 `vm_1`，访客 `p11_arm64`）

| 项 | 结果 |
|---|---|
| 引擎进入回传模式 | ✅ `vm_frame_relay` 目录 = `<dataDir>/logs` |
| 子进程起来 | ✅ `已拉起子进程 QEMU（ranchu 模式）pid=…`（走 jniLibs 里的可执行体） |
| QEMU 侧截图线程 | ✅ stderr 里 `VMHOSTGFX screenshot: …` 持续输出，`frame.request` 被消费 |
| 访客图形栈 | ✅ 96s `gralloc-3-0`、97s `hwcomposer-2-3`、116s `surfaceflinger`、157s `bootanim` |
| **拿到帧** | ❌ `renderer->getScreenshot` 恒返回 `res=-1 cap=0`（post-callback 也无帧）→ 无 `frame.ppm/seq` |
| 子进程稳定性 | ❌ 访客 ~190s 时 **SIGSEGV**，之后父进程留了个僵尸（现已修，见 7.3） |

### 7.3 崩溃定位（本轮新增的诊断能力）

1. **子进程死因可见**：`vm_qemu.c: child_alive()` 现在打印 `WTERMSIG/WEXITSTATUS`，
   `vm_activity.c` 每秒轮询一次 `vm_qemu_is_running()`。实测输出：
   ```
   E VmQemu : 子进程 QEMU 被信号 11（Segmentation fault）终止
   ```
2. **崩溃处理器能触发了**：aemu 的 `Thread::maskAllSignals()` 会 `sigfillset` 把 SIGSEGV
   一起屏蔽，导致 QEMU 自带的崩溃处理器永不触发。给子进程加
   `LD_PRELOAD=<nativeLibraryDir>/libsigfix.so`（拦截 `pthread_sigmask/sigprocmask`
   把崩溃信号剔出屏蔽集，源码见 `vm/build-aosp-exp/libsigfix.c`）后即可打出 dump：
   ```
   signal=11 si_code=1 addr=0x0 tid=12921
   pc=0x0 sp=… fp=… lr=0x55a663c028
   ```
3. **符号化结果**（注意：运行时地址 → ELF 地址要减去段对齐差 0x4000）：
   `lr` → `gfxstream::gles1_decoder_context_t::decode()` @ `gles1_dec.cpp`，
   崩溃前最后一条 GLES1 操作是 **op 1149 = `OP_glShadeModel`**。
   反汇编该 case 可见调用前**确实有** `cbz x8` 非空校验，所以 `pc=0` 不是 decoder
   直接调空指针，而是**被调用者（GLES1→GLES2 翻译器）内部**又调了空指针。

### 7.4 下一步

给 `VMHOST_GLES1_CALL` 宏加调用点日志（打印 proc 名字与指针），重编 gfxstream + QEMU 后
跑一轮，用崩溃前最后一条 `VMHOST_GLES1_CALL` 定位到具体入口与指针值，再结合
`/proc/<pid>/maps` + `llvm-addr2line` 找到翻译器里那处空调用。

> 复现命令：`engine/scripts/build_gfxstream.sh`（重编静态库）→
> `engine/scripts/build_qemu_aosp.sh`（重链 QEMU 并安装进 jniLibs）。
> WSL 里 gfxstream 源码树是 `/root/vmbuild/gfxstream`（不在本仓库内）。
> 提示：`qemu-stderr.log` 是**追加**写的，复现前先删除，否则会把上一轮的
> `VMHOST QEMU CRASH` 横幅误当本次现场。

## 8. 2026-10-07（续）：崩溃根因链已打通到第三层

### 8.1 诊断能力（本轮新增，已实机验证）

- **崩溃处理器打全寄存器**（`vmhost_pipe_glue.cpp`）：新增 `regs x0..x30` 与
  `x0_obj / vptr / slot0 / slot1` 探测。探测走 `process_vm_readv`，
  坏指针只报错、不会在处理 SIGSEGV 时二次崩溃。
- **`LD_PRELOAD=libsigfix.so`**：解除 aemu `maskAllSignals()` 对 SIGSEGV 的屏蔽，
  否则 QEMU 自带崩溃处理器永远不触发（子进程只会静默消失）。
- **子进程死因可见**：`vm_qemu.c: child_alive()` 打印 `WTERMSIG/WEXITSTATUS`。
- 符号化换算：**ELF 地址 = 运行时地址 − 第一个 PT_LOAD 段的运行时基址**
  （段对齐差 0x4000；用 `/proc/self/maps` 里的第一行 r--p 起始地址当基址）。

### 8.2 第一层：GL1 直通空表（已修）

访客第一条固定管线命令 `glShadeModel` 就崩，`pc=0`。原因链：

```
GLEScmContext::shadeModel()  →  dispatcher().glShadeModel()   // GLEScontext.h:424 的静态 s_glDispatch
   ↑ 仅当 m_coreProfileEngine 为 NULL 时才走这条
GLEScmContext 构造：if (isCoreProfile()) ... else if (isGles2Gles()) ...  // 两者都不满足 → engine 为 NULL
isGles2Gles() ← initGLESx(EglGlobalInfo::isEgl2Egl())   // EglImp.cpp:112
sEgl2egl ← getenv("ANDROID_EGL_ON_EGL") == "1"          // opengles.cpp:120
```

我们的宿主正是"跑在系统 EGL/GLES 之上"（手机只有 GLES 3.2，没有 GL1），但
`ANDROID_EGL_ON_EGL` 没设 → 翻译器直通 host 的 GL1 函数表，而那张表在 GLES2-only
宿主上全是 NULL → `pc=0`。

**修复**：`vmhost_gfx_glue.cpp` 在 `android_setOpenglesEmulation()` 之前
`setenv("ANDROID_EGL_ON_EGL", "1", 1)`。

### 8.3 第二层：CoreProfileEngine 里的 ES3 空指针（当前卡点）

打开 egl2egl 后翻译器确实改走了 `CoreProfileEngine`，访客也从 ~190s 撑到 ~253s，
但崩溃点转移：

```
pc=0x0  lr=<CoreProfileEngine::getGeometryDrawState()+…>
regs x0=0x1     ← 正是 glBindVertexArray(vao=1) 的参数
```

`CoreProfileEngine.cpp:345`：`gl.glBindVertexArray(m_geometryDrawState.vao);`
（`gl` 即静态 `s_glDispatch`）→ **`glBindVertexArray` 在表里是 NULL**。
`glGenVertexArrays/glBindVertexArray` 是 ES3 入口，而这张表由
`GLEScmContext::initGlobal()` 的
`s_glDispatch.dispatchFuncs(s_maxGlesVersion, eglIface->eglGetGlLibrary(), eglIface->getProcAddress)`
填充 —— 看起来只按 `s_maxGlesVersion` 解析到 ES2 为止，ES3 项留空。

**下一步（二选一，倾向后者）**：
1. 让 `s_maxGlesVersion` 体现宿主真实版本（GLES 3.2），使 ES3 入口被解析；
2. 更稳妥：在 `dispatchFuncs()` 完成后把**仍为 NULL 的槽位填成 no-op 桩**
   （与 `gles1_dec.cpp` 里 `gles1_unimplemented` 同一思路），
   彻底消灭"宿主缺某个 GL 入口 → pc=0"这一整类崩溃；有返回值的入口需
   各自给一个安全默认值（0 / NULL），否则调用方可能拿到垃圾值。

### 8.4 顺带修掉的其它问题

- `vmhost_gfx_glue.cpp`：PPM 输出原为逐像素 `fputc`（720×1280 一帧 276 万次调用），
  改为先在内存打包 RGB、再一次性 `fwrite`（两处写 PPM 的地方都改了）。
- `vm_frame_relay.c`：新增 `REQUEST_PENDING_TIMEOUT_MS`，避免"子进程崩在删
  frame.request 之前 → pending 标志永不复位 → 再不发新请求"的静默卡死；
  PPM 原文缓冲改为复用，不再每帧 malloc/free 两三 MB。
- `engine/build.gradle.kts`：`keepDebugSymbols += "**/libqemu_exec.so"` **实测不需要**
  —— strip 后的可执行体真机照常 exec 成功，去掉后 APK 从 ~120MB 降到 **29.2MB**。
- `memoryMb/cores` 已从 `VmConfig` 读取（见 §7.1）。

## 9. 2026-10-07（三）：宿主侧回传链路完全打通，已能连续出帧

### 9.1 关键修复：GL 分发表的版本门控

`GLDispatch::dispatchFuncs()` 里 ES3/ES3.1 入口是**按传入的 version 门控加载**的
（原版 `if (version >= GLES_3_0)` / `>= GLES_3_1`），而这张表**只加载一次**
（`m_isLoaded` 早退），先到者定版本。实测宿主是 GLES 3.2，表却按 GLES_1_1 先加载
→ ES3 入口（`glBindVertexArray` / `glGenVertexArrays` …）全为 NULL
→ GLES1 翻译器在 egl2egl 模式下用 `CoreProfileEngine` 调它们，一调就 pc=0。

改为**一律尝试解析**（宿主不支持的入口 `getProc` 本就返回 NULL，与门控结果一致，
不会"假装支持"）。补丁位置：`host/gl/glestranslator/GLcommon/GLDispatch.cpp`
（搜索 `VMHOST_FIX`）。

### 9.2 实测结果（真机 cc96ded5，实例 vm_1，访客 p11_arm64）

| 项 | 结果 |
|---|---|
| 子进程稳定性 | ✅ 不再崩溃，连续跑 > 10 分钟（此前必在访客 ~190s SIGSEGV） |
| 帧回传速率 | ✅ `frame.seq` 累计 866+，约 2–4 fps |
| QEMU 侧截图 | ✅ `screenshot: post-callback 1080x1920 -> …/frame.ppm (seq=…)` |
| 引擎侧上屏 | ✅ `VmGuestDpy: 访客画面 1080x1920`（PPM 解析 + GL 纹理上传成功） |
| frame.ppm 尺寸 | ✅ 6,220,817 字节 = P6 头 + 1080×1920×3，与访客原生分辨率完全吻合 |
| **帧内容** | ❌ 全黑（粗采样 1519 个字节全为 0） |

结论：**"请求 → 截图 → 回传 → 解析 → 上屏"整条链路已经打通**，帧在稳定流动，
尺寸与格式都对。剩下的是"帧内容为空"。

### 9.3 剩余问题：帧内容是黑的（下一步）

已知事实：
- 访客**确实 post 过帧**（走的是 post-callback 路径，`s_latest_pixels` 有数据，
  否则 glue 会退回 `getScreenshot`），说明 `rcFBPost` 通了；
- 但读到的缓冲区全是 0 → 访客画进去的内容是空的；
- 访客此轮仍未 `boot_completed`（~322s 时 iorapd 一直拿不到 package manager），
  但 SurfaceFlinger(155s) 与 bootanim(201s) 都已启动；
- GLES1 操作量很大（stderr 里 17970 条 `VMHOST_GLES1_OP`）→ 访客在持续发绘制/状态命令。

待查方向（按优先级）：
1. 确认是"访客还没画"还是"绘制被吞"：查访客侧 EGL/GLES 报错
   （guest logcat 在 `console.log` 里 grep `egl` / `EmuHWC2` / `GLES`），
   以及 SurfaceFlinger 是否真的合成过（HWC 是否报 `Failed to get host connection`）。
2. 若绘制被吞：CoreProfileEngine 的绘制最终要走宿主 GL（`s_glDispatch`），
   确认着色器编译/VAO/绘制调用是否真的下发到 Adreno（可在 glue 里打开更细的
   gfxstream 日志，或直接在宿主 GL 侧加错误检查）。
3. 若纯粹是访客没画：等它把 system_server/PMS 起完（此前 B1 里程碑里靠
   `vmhost_amctl` 注入 IActivityController 才让 Watchdog 不杀 system_server，
   本 App 路径没有这个注入，值得补上）。

## 10. 2026-10-07（四）：黑帧根因锁定 —— 「渲染的 buffer ≠ 被 post 的 buffer」

### 10.1 amctl 已验证（结论：无需注入）

真机实测 `console.log`：

```
[  990.8s] vmhost_amctl: controller registered (attempt#348)
[ 1249.9s] vmhost_amctl: systemNotResponding -> keep waiting …
[ 1351.6s] vmhost_amctl: systemNotResponding -> keep waiting …
[ 1483.5s] vmhost_amctl: systemNotResponding -> keep waiting …
```

访客镜像（`system.img`）里**本来就有** `/system/etc/init/vmhost_amctl.rc`，
服务在 81s 拉起、990s 注册成功、三次把 Watchdog 的杀进程改成"继续等"，
`Entered the Android system server` 只出现 1 次。**访客不是卡死，是 TCG 慢**
（900s 时 system_server 仍在逐个解析 package）。

> 备用注入路径：`build-aosp-exp/inject_amctl_vendor.{sh}` + `vmhost_amctl_vendor.{sh,rc}`
> —— 只改 vendor.img（47MB）而不动 system.img（790MB）。踩坑：SDK 的 vendor.img
> **inode 用满**，既建不了新目录也写不了新文件（`resize2fs` 扩容只加块不加 inode），
> 需先删掉三个运行期用不到的文件（`/etc/NOTICE.xml.gz`、两个 0 字节的 `fs_config_*`）
> 腾出 inode。

### 10.2 新增的插桩体系（都在宿主侧，`VMHOST_DIAG` 前缀）

| 落点 | 输出 | 作用 |
|---|---|---|
| `gl/gles2_dec/gles2_dec.cpp` | `VMHOST_GLES2_HIST`（每 20 万条累计直方图）、`VMHOST_GLES2_RECENT`（崩溃前最后 64 条）、`VMHOST_GLES2_LOWFREQ`（低频调用参数） | 不逐条打印，避免日志爆炸 |
| `gl/ColorBufferGl.cpp` blit | `VMHOST_BLIT enter/copy_done/src/draw/exit` | 逐段定位搬运过程 |
| `gl/ColorBufferGl.cpp` readback | `VMHOST_READBACK … nonzero=N` | 判定黑帧在读侧还是写侧 |
| `gl/TextureDraw.cpp` | `VMHOST_TEXTUREDRAW program=… link_ok=…` | 排除"GLSL 编译失败"这一历史坑 |
| `qemu_patches/vmhost_pipe_glue.cpp` | 崩溃处理器补打 `regs x0..x30` + `x0_obj/vptr/slot` 探测 + 回调 `vmhost_gles2_dump_recent()` | 崩溃现场可读；`process_vm_readv` 避免二次崩溃 |

**重要认知**：`VMHOST_GLES1_OP` 那一行打印的是**到达渲染线程的所有包**（不只是 GLES1）。
所以 `10015/10016/10018/10020/10035` 是 renderControl，`2086/2111` 是 GLES2；
GLES1 是 1024–1317 段（1149=glShadeModel、1190=glDrawTexiOES…）。

### 10.3 实测结论

```
VMHOST_TEXTUREDRAW program=3 vs=1 fs=2 link_ok=1 err=0x0      ← 搬运用的 program 正常
VMHOST_BLIT enter fastBlit=0 pendingErr=0x0 clientVer=1        ← GLES1 客户端
VMHOST_BLIT copy_done m_blitTex=39 err=0x502
VMHOST_BLIT src m_blitTex=39 fboStatus=0x8cd5 nonzero=64/256    ← 源有内容、FBO 完整
VMHOST_BLIT draw m_tex=38 m_blitTex=39 fbo=4 err=0x0
VMHOST_READBACK tex=33 1080x1920 sampled=129600 nonzero=0       ← 但读回的是 0
```

- **读回侧没问题**：`bindFbo` 未失败、`glReadPixels` 无错、`nonzero=0` → 被 post 的
  ColorBuffer **纹理本身就是空的**。
- **写入侧的上游也没问题**：源纹理 `m_blitTex` 有内容（64/256），FBO COMPLETE，
  TextureDraw 的 program 链接成功、draw 无 GL 错。
- **根因**：blit 搬运的目标是 host tex **25/38/42/26/39/43**，而**被 post 并读回的是
  33/46** —— 两组完全不相交。即 **访客渲染的 buffer ≠ HWC post（我们截图）的 buffer**，
  后者从未被搬运过，所以恒为黑。
- 附带定位：每帧一次的 `0x502(INVALID_OPERATION)` 来自 **blit 作用域末尾
  `RecursiveScopedContextBind` 的析构**（恢复绑定到已删除对象），
  `glViewport` 恢复与 `unbindFbo()` 本身都干净（各 2332 次 err=0x0）。与画面无关。

### 10.4 下一步

1. **修 LOWFREQ 过滤**：`len>=20` 把 rc 包（len 12/16）滤掉了 → 改成按长度逐级打印
   `a0/a1/a2`，拿到 `rcSetWindowColorBuffer / rcFlushWindowColorBuffer / rcFBPost` 的 handle；
2. **在 blit 的 draw 之后采样 `m_tex`**（与源对照），确认搬运目标是否真的被写进内容；
3. **在宿主 `FrameBuffer::post` 打点**（posted CB 的 handle + host tex），把
   「访客 handle ↔ host tex ↔ 是否被 blit」三者对上 —— 这是修"渲染/post 两块 buffer 不一致"
   的前提。

## 11. 2026-10-07（五）：黑帧根因确证 —— `rcFBPost` 的 handle ≠ 渲染的 window surface

### 11.1 三个信号（同一次运行，真机）

```
VMHOST_POST  handle=0x8  cbHndl=0x8  tex=33  1080x1920     ← 被 post 的（截的就是它）
VMHOST_POST  handle=0xb  cbHndl=0xb  tex=46  1080x1920
VMHOST_BLIT dst m_tex=42 nonzero=64/256 err=0x0            ← blit 目标确实被写进了内容
VMHOST_BLIT dst m_tex=25 nonzero=64/256 err=0x0
VMHOST_BLIT dst m_tex=38 nonzero=64/256 err=0x0
VMHOST_GLES2_LOWFREQ op=10015 len=16 a0=0x6 a1=0xa          ← rcSetWindowColorBuffer(display=6, cb=0xa)
VMHOST_GLES2_LOWFREQ op=10015 len=16 a0=0x6 a1=0x5          ← …另一次 cb=0x5
VMHOST_GLES2_LOWFREQ op=10016 len=12 a0=0x6                 ← rcFlushWindowColorBuffer(display=6)
VMHOST_GLES2_LOWFREQ op=10018 len=12 a0=0xb                 ← rcFBPost(cb=0xb)
VMHOST_GLES2_LOWFREQ op=10018 len=12 a0=0x8                 ← rcFBPost(cb=0x8)
VMHOST_READBACK tex=33 … nonzero=0
VMHOST_READBACK tex=46 … nonzero=0
```

**结论**：访客把 window surface（渲染目标）设成 handle **0x5 / 0xa**，内容确实画进去了
（blit 目标 host tex 25/38/42 采样到 64/256 非零，与源一致）；但它 `rcFBPost` 提交的是
handle **0x8 / 0xb**（host tex **33 / 46**）——这两块**从未被渲染或搬运过**，所以读回恒为 0、
画面全黑。

即：**`rcFBPost` 的 handle 与 `rcSetWindowColorBuffer` 设置的渲染目标不是同一块**。
这不是"读不出来"，也不是"没画"，而是**post 错了 buffer**。

### 11.2 待查的修复方向（下一轮）

1. **确认上游语义**：查 gfxstream 上游 / Android emulator 的 HWC 实现，`rcFBPost(handle)`
   到底应该是"自己渲染的那块"还是"display 的独立输出块"。若上游也是这个序列，则说明
   host 侧在 `post` 时应当把 window surface 的内容 flush/blit 到被 post 的 CB
   （`FrameBuffer::post` 里对 `p_colorbuffer` 做一次 `blitFromCurrentReadBuffer`）。
2. **对照 `rcFlushWindowColorBuffer(display=6)`**：它当前落到哪个 CB？若它 flush 的是 0x5/0xa
   而非 0x8/0xb，就能解释内容为什么停在"非 post 的那两块"上；修复点即在
   `FrameBuffer::flushEmulatedEglWindowSurfaceColorBuffer` / `post` 的衔接处。
3. 备选（更快但更 dirty）：让 `rcFBPost` 直接把 window surface 的当前 CB 也 post 一次，
   验证画面是否能立刻出现（用于确认这条链路就是唯一症结）。

### 11.3 诊断插桩已仓库化（幂等补丁）

宿主侧的 VMHOST_DIAG 系列插桩已从"只手改在 WSL 源码树"改为**仓库内的幂等补丁**：

- 脚本：`vm/engine/scripts/qemu_patches/patch_vmhost_diag.py`
  （逐条 marker 判重；锚点未命中只 WARN 不中断 —— 诊断插桩不是构建必需）
- 调用：`build_gfxstream.sh` 第 5 步（在 GLDispatch 补丁之后）
- 覆盖：GLES2 命令直方图/崩溃前 64 条/低频调用参数、ColorBuffer 的
  blit(enter/copy_done/src/dst/after_viewport/after_unbind) 与 readback 内容校验、
  TextureDraw 链接结果、`FrameBuffer::post` 的 `handle ↔ host tex` 打点
- 实测幂等：首次应用 2 条、跳过 8 条；再跑一次 0 应用 / 10 跳过

## 12. 2026-10-07（六）：第 3 步验证 —— 内容确实"存在过"，但读回时已不在

### 12.1 语义澄清（第 1、2 步）

- `rcSetWindowColorBuffer(a0, a1)` / `rcFlushWindowColorBuffer(a0)` 的 **a0 是
  window surface 句柄，不是 display**（`RenderControl.cpp:929/874` 的形参名即
  `windowSurface`）。我们的日志里 a0=0x6，即"窗口 surface 6"。
- `rcFlushWindowColorBuffer(6)` → `getEmulatedEglWindowSurfaceColorBufferHandle(6)`
  → `flushEmulatedEglWindowSurfaceColorBuffer(6)` → `flushColorBufferFromGl(cb)`，
  也就是把宿主窗口 surface 的内容搬进 **该窗口绑定的 CB**（实测是 0x5 / 0x9 / 0xa，
  即 host tex 25 / 38 / 42）——这正是 `VMHOST_BLIT` 那段日志的来源。
- 而 guest 随后 `rcFBPost(0x8 / 0xb)`（host tex 33 / 46），与上面那组**不同**。

### 12.2 验证补丁（VMHOST_HACK，默认不启用）

`FrameBuffer` 里加一个 `m_lastFlushedWindowCb`：flush window surface 时记住那块 CB，
`postImpl` 的 display-0 回调改用它作为像素源。

- 开关：`VMHOST_HACK_POST_CB=1` 时由 `patch_vmhost_diag.py` 应用（默认不应用，
  避免新克隆默认带上实验行为）；实测默认 10 条、开启 13 条，均幂等。

### 12.3 结果：hack 生效，但画面**仍然全黑**

```
VMHOST_POST     handle=0x8 cbHndl=0x8 tex=33      ← guest 仍 post 8/b
VMHOST_READBACK tex=25 … nonzero=0                ← 但这次读的是 window surface CB 了
VMHOST_READBACK tex=38 … nonzero=0
VMHOST_READBACK tex=46 … nonzero=0
frame.ppm：sampled=117374 nonzero=0 mean=0 max=0   ← 整帧仍全黑
```

对比上一轮：**同一批纹理（25/38/42）在 blit 之后立刻采样是 64/256 非零**，
而到 post 回调读回时却是 0。也就是说：**内容确实写进去过，但读回时已经不在**。

两个待排除的方向：
1. **读错了纹理**：`readback()` 用 `bindFbo(&m_fbo, m_tex, m_needFboReattach)`，
   当 `m_needFboReattach == false` 时会**复用已存在的 FBO 而不重新 attach** ——
   如果这个 FBO 上挂的是别的纹理，就会读到别人的内容（现象正是"读到 0"）。
2. **内容被覆盖**：该 CB 同时是 guest 的渲染目标（window surface），
   下一帧的清屏/绘制可能把上一帧内容抹掉，与 post 的时序错开。

另外顺带修正一个**测量口径**：readback 的采样步长是每 64 字节（≈每 16 像素），
对"小面积内容"会漏检；但 `frame.ppm` 的整帧稀疏采样（117k 点，mean=0、max=0）
足以判定整帧确实是黑的。

### 12.4 下一步

1. `readback()` 里打印 `m_fbo / m_needFboReattach`，并在 `bindFbo` 的
   「复用」与「重新 attach」两条分支各打一行 → 排除"读错纹理"；
2. 把 readback 的统计从"抽样"改成"整块求 max/非零计数"（一次性、只打一行）；
3. 在 `rcFlushWindowColorBuffer` **刚结束**时也采样同一块 CB（与 post 前对照），
   确认内容是在两者之间消失的。

## 13. 2026-10-07（七）：**测量口径修正** —— 之前的"有内容"是 alpha 造成的假象

### 13.1 修正过程

前一轮的结论"内容确实写进去过、读回时已不在"是**错的**，错在我自己的统计口径：

- 我按**字节**统计非零，得到 `64/256`（8x8 块）与 `2073600/8294400`（整块）；
  这两个数**恰好等于"每像素只有 1 个字节非零"** —— 即 **A=255、RGB=0**。
- 而 `frame.ppm` 是 P6（只有 RGB，没有 alpha），所以显示为全黑 —— 这部分判断是对的。
- 反过来，早先用"每 64 字节抽 1 个"的采样，偏移恰好总落在 **R 通道**上，于是永远读到 0
  —— 这也是为什么我一度认为"读回侧没问题"。

改成**按像素统计 RGB**（排除 alpha）后，真实数据是：

```
VMHOST_BLIT src m_blitTex=47 fboStatus=0x8cd5 nonzeroRGB=0/64 err=0x0
VMHOST_BLIT dst m_tex=46 nonzeroRGB=0/64 err=0x0
VMHOST_READBACK tex=46 1080x1920 fbo=4 reattach=0 nzRGBpix=0/2073600 maxRGB=0 err=0x0
frame.ppm：非零 R 采样 = 0，maxR = 0
```

### 13.2 由此修正的结论

- **FBO ↔ 纹理映射是正确的**（`fbo=2↔tex25 / 3↔38 / 4↔46`，`attached=0` 但附件就是
  创建时挂的那块，`reattach=0` 表示无需重挂）→ **"读错纹理"假设排除**。
- **"post 错 buffer"确实存在**（guest flush 进 5/9/a，post 8/b），但**两块都是黑的**
  → 它**不是**黑帧的根因。
- 真相是：**访客渲染出来的就是不透明纯黑（RGB=0、A=255）**，那个 255 来自访客每帧一次的
  `glClear`（GLES1 流量统计里 glClear 恰好每帧 1 次）。

### 13.3 卡点回到"访客绘制没有产出 RGB"

待查（按优先级）：
1. **访客是否真的上传了纹理**：日志里 `glTexImage2D` 的尺寸/内容（可加一条低频日志，
   只打尺寸与几个字节的校验和）；
2. **绘制是否到达宿主 GL 并生效**：GLES2 直方图（`VMHOST_GLES2_HIST`）目前因未到 20 万条
   阈值而没有输出 → 把阈值调小（例如 2 万条）再跑，看每帧的
   `glDrawArrays/glDrawElements/glUseProgram/glTexImage2D` 数量是否正常；
3. **宿主 GL 侧是否有静默失败**：结合每帧一次的 `0x502`（已知来自 blit 作用域析构，
   与本问题无关）之外，再查绘制前后的 `glGetError`。

> 注：`VMHOST_HACK_POST_CB` 那套"post 时改用 window surface CB"的兜底，本轮已证明
> 不是修法；在 `patch_vmhost_diag.py` 里**默认不启用**（脚本侧已加开关），
> 当前 WSL 源码树里仍是打开状态（下次干净重建时不带 `VMHOST_HACK_POST_CB=1` 即恢复）。

## 14. 2026-10-07（八）：访客在画，但**几乎没上传过纹理**

### 14.1 插桩调整

- `VMHOST_GLES2_LOWFREQ` 支持按包长打印**最多 7 个参数**（`glTexImage2D` 的宽高在
  a3/a4，只打 3 个看不到尺寸），并把 `glTexImage2D(2153)` / `glTexSubImage2D(2158)`
  加入低频名单；
- 直方图 dump 阈值 `200000 → 20000` 条（原来整轮实验都到不了阈值，等于没有输出）。

### 14.2 实测（本次运行约 6 分钟）

```
GLES1 调用统计：
  glDrawTexiOES ×5799    glBindTexture ×3878    glDisable ×3868    glEnable ×3867
  glClear      ×1934     glScissor     ×1933    glTexImage2D ×2    glShadeModel ×1

GLES2 直方图（累计 2 万包）：
  glTexImage2D n=2 → a0=0xde1(GL_TEXTURE_2D) a2=0x1906(GL_ALPHA) a3=0x80(128) a4=0x1
  glUseProgram n=48    glUniformMatrix4fv n=48    glEnableVertexAttribArray n=48
  glDrawArrays / glDrawElements：**n=0（完全没有绘制）**
  rcBindTexture n=2743   rcSetWindowColorBuffer n=1374
  rcFlushWindowColorBuffer n=1372   rcFBPost n=1371
```

**结论**：访客**确实在绘制**（GLES1 侧 5799 次 `glDrawTexiOES`、1934 次 `glClear`），
但它**几乎没上传过纹理数据** —— 整轮只有 2 张 128×1 的 `GL_ALPHA` 贴图。
`glDrawTexiOES` 是"把纹理画到 quadrilateral 上"，采样的纹理是空的，合成结果自然全黑。

也就是说：既不是"没画"，也不是"画了没传过来"，而是**画的时候用的纹理是空的**。

### 14.3 下一步（两个互斥的可能）

1. **图层 buffer 本身是黑的**（访客侧各 App/合成源没画出东西）—— 在本阶段访客还在
   system_server 启动期（本次 369s 仍在 `CompatConfig`），可能确实没有可见内容；
2. **纹理数据的上传路径断了** —— 例如大贴图的 `glTexImage2D` 走的是共享内存/ASG 路径，
   而不是内联在 pipe 包里，导致我们只看到那两张调色板贴图。

建议的探针：**在 `rcBindTexture(cb)` 处采样被绑定那块 CB 的 RGB**（`VMHOST_BLIT src`
那套 8x8 采样已有现成代码）。若被绑定的图层 CB 里有内容 → 说明"内容在、合成没生效"；
若也是 0 → 说明访客侧根本没有产出内容（先等它把系统起完再判）。

---

# §15 2026-10-07 夜：SF 的 EGL fatal 根因与已知可用基线

## 15.1 现象
访客每次启动都在 `SurfaceFlinger::init → RenderEngine::create →
GLESRenderEngine::create` 处 `LOG_ALWAYS_FATAL("eglQueryStringImplementationANDROID(EGL_VERSION) failed")`，
init 里 `restart zygote` 级联重启（netd/cameraserver/media 跟着重启），永远到不了
`sys.boot_completed`，`frame.ppm` 一直不出帧。

## 15.2 根因（已反汇编确认，按因果顺序）
1. 访客平台 `libEGL.so` 的 `eglQueryStringImplementationANDROIDImpl` **只有一条返回 NULL
   的路径**：`validate_display()` 失败（`egl_display_t::get()` 为空、或 display 的
   "已初始化"标志为假）。它**不检查** client extensions。⇒ 真实含义是
   **访客侧 `eglInitialize` 没成功**（SF 不检查该返回值，直接去查 EGL_VERSION）。
2. 访客 `libEGL_emulation.so` 的 `eglDisplay::initialize` 失败点：dlopen
   `libGLESv1_CM_emulation`/`libGLESv2_emulation` → `HostConnection::get()` →
   `rcEncoder()` → `rcGetEGLVersion()` 必须返回 1。
3. **今天为修"surfaceless makeCurrent"加的 `MAKECURFIX` 补丁会在这条初始化路径上介入**，
   使宿主的 `android_startOpenglesRenderer` 直接返回 **-1**（宿主渲染器根本没建起来）。
   渲染器是死的 → 访客的 EGL 永远连不上 → SF 必然 fatal。
   **判据（十秒可测）**：宿主 stderr 里
   `VMHOSTGFX android_startOpenglesRenderer ret=0 gles=3.1`（正常）
   vs `ret=-1 gles=0.0`（渲染器没起来）。
4. 同理，`D16`（挂钩 `s_egl.eglMakeCurrent`，surfaceless 且 pbuffer 不可用时退化成
   "完全不绑上下文"）会制造"该线程没有 current context"，随后任何 GL 调用都会让
   Adreno 830 驱动解引用 NULL（`LDR x5,[x21,#0x38]`，x21=0）并打死整个 QEMU。
   崩溃现场 D15 探针会打印 `gl_ctx: eglGetCurrentContext=0x0 ...`。

## 15.3 处置（本次改动）
- `MAKECURFIX` 默认**不注入**（`VMHOST_MAKECURFIX=0`），源码保留备查；
- `D16` 不再安装；
- `D15` 去掉早期 `dlopen("libEGL.so")`（会改变 gfxstream 解析 EGL 符号的优先级）；
- `D14`（禁用 `getScreenshot` 兜底）保留；
- 新增可诊断性：rc 握手只读探针、EGL 上下文探针、`VMHOSTPIPE_SVC` 管道日志、崩溃打印 `gl_ctx`；
- 实例配置降到 `memoryMb=2048 / cores=4`。

## 15.4 已验证的对照与遗留
- **已知可用基线**：`/data/local/tmp/vmaosp/qemu-system-aarch64`（Oct 5 构建，112MB）。
  与 App 完全相同的镜像/命令行/环境，`ret=0 gles=3.1`，且跑到 `sys.boot_completed=1`；
  其镜像里 `eglQueryStringImplementationANDROID` 出现次数为 0。
  可直接 `cp` 覆盖 App 的 `nativeLibraryDir/libqemu_exec.so`（需 root）做 A/B。
- **未完成**：① 出帧（post callback 从未被调用，SF 健康时也不 post）；
  ② 宿主内存：设备 11GB 内存常被系统占用 ~10.4GB，`-m 4096` 时 QEMU 拿不到访客内存，
  访客会卡在早期启动（表现为宿主 CPU≈0、console 时间戳不动）；降到 2048 才有进展。
- 本轮改动已本地提交（`8478290`）。本仓库**没有配置 git remote**，上次是用
  GitHub Git Data API（`api.github.com` + PAT）推送的，推送需沿用该方式。

---

# §16 2026-10-08：**访客终于连续出帧** —— 宿主 SIGSEGV 根因与修复

## 16.1 现象与判据
访客每次跑到 **SystemUI/SurfaceFlinger 真正开始渲染的那一刻**，宿主 QEMU 进程就
`signal=11` 被打死，于是：永远走不到 `rcFBPost` / `rcFlushWindowColorBuffer`，
`VMHOST_POST` / `VMHOST_RCFLUSH` 探针一条都不响，`m_lastPostedColorBuffer` 始终无效，
`getScreenshot` 恒 `res=-1`。看起来像"访客不提交帧"，实际是**宿主渲染器先崩了**。

崩溃现场（在宿主 stderr 的崩溃转储里）：
```
signal=11 si_code=1 addr=0x38 x21=0x0
pc=<libGLESv2_adreno.so 代码段>
gl_ctx: eglGetCurrentContext=0x0 eglDrawSurface=0x0 eglReadSurface=0x0
```
即 **"该线程没有 current EGL context，却发了 GL 调用"**，Adreno 830 驱动在入口桩里
解引用 NULL（`LDR x5,[x21,#0x38]`）。

## 16.2 根因链（三条，按因果顺序）
1. **`EglOsEglDisplay::createPbufferSurface` 被整段注释掉**，恒
   `return new EglOsEglSurface(PBUFFER, 0)` —— 返回**句柄为 0 的"哑"surface**。
   访客 SF 会为 GPU 上下文建 pbuffer（`EglImp.cpp: eglCreatePbufferSurface`），拿到
   句柄 0 之后再 `eglMakeCurrent`，平台侧就退化成 `eglMakeCurrent(dpy, 0, 0, ctx)`。
   **这是崩点的直接来源**（探针实测：`readSfc=0x..870 rh=0x0 drawSfc=... dh=0x0`）。
2. `EglOsEglDisplay::makeCurrent` 在 `ctx && !readSfc` 时**直接 `return false`**，
   把调用线程留在"没有任何绑定"的状态；调用方拿到 false 继续发 GL → 同样崩。
3. **访客释放上下文后仍继续发 GL**（release 的下一批命令就是 `glUseProgram`），
   旧实现把宿主绑定清空 → 又落回"无 current context"。
   另外访客某个渲染线程**从未在本线程做过 `eglMakeCurrent`** 就直接提交命令
   （实测崩点命令由 **gles1 解码器**消费，见 `VMHOST_GLES1_OP`）。

## 16.3 修复（已脚本化、幂等、可复现）
新增 `engine/scripts/qemu_patches/patch_vmhost_surface.py`（由 `build_gfxstream.sh`
的 `5c-bis` 调用），含 4 条编辑：
- **edit 1**：加固 `EglOsEglDisplay::makeCurrent` —— 缺 surface（或直接绑定失败）时，
  用 **"先试绑、绑成功才采用"** 的 1x1 pbuffer 顶上。之所以要"试绑成功才采用"：
  pbuffer 必须与 context 的 config 兼容，否则 `eglMakeCurrent` 返回 `EGL_BAD_MATCH`
  —— 这正是**旧版内联 MAKECURFIX 补丁**（按 `eglChooseConfig` 自选 config）失败、
  把 `android_startOpenglesRenderer` 打成 -1 的原因。释放分支改为**绑本线程专属的
  dummy 上下文**而不是真的解绑。
- **edit 2**：**恢复 `createPbufferSurface` 的真实实现**（config 取自传入的
  `PixelFormat`，即访客自己选的那个 `EGLConfig`），创建失败才退回旧行为。
  实测 9/9 次全部创建成功 → 句柄不再是 0 → 前面那个兜底根本用不上。
- **edit 3 / 3b**：在 **gles2_dec 与 gles1_dec 的解码循环**里，每条命令前调用
  `vmhost_mc_ensure_current()`：本线程若没有 current context，就补绑本线程专属
  dummy（真实驱动在无 current context 时也只是静默报错，**补绑 dummy 与真机语义
  一致**；有 context 时只读一次 TLS，什么都不做）。

另外把两条**游离在脚本外的手工改动**收进构建流程（`build_gfxstream.sh`）：
- **step 0a**：`host/gl/OpenGLESDispatch/GLESv2Dispatch.cpp` 每次强制 `git checkout`。
  它曾被手工改成"优先 `dlsym` 宿主 `libGLESv2.so`"，**绕过了 gfxstream 自己的上下文
  校验**，把访客 GL 直接打到驱动上 —— 一旦该线程没有 current context 必崩。
  还原成上游顺序（`::translator::gles2::fn` 优先）后，**剩余的 SIGSEGV 消失**。
- **5d-bis**：`VMHOST_FORCE_GLES2`（把 maxVersion 压到 `GLES_MAX_VERSION_2`，
  否则 TextureDraw 的 GLSL 1.0 shader 在 Adreno ES3 上编译失败，`glAttachShader`
  0x501）从手工改动固化为脚本步骤。

## 16.4 实测结果（真机 cc96ded5 / 实例 vm_1 / 访客 p11_arm64）
- 宿主 stderr：**`VMHOST QEMU CRASH` 计数 = 0**；`VMHOST_POST = 1873`、
  `VMHOST_RCFLUSH = 1864`、`screenshot: post-callback` = 632。
- `android_startOpenglesRenderer ret=0 gles=2.0`；`VMHOST_PBUFSURF ok` = 9（全部成功）。
- 访客 kernel time 跑到 **876s 仍在运行**（此前 549s / 619s / 631s 必崩），
  `frame.seq` 持续增长到 **917**（App 侧 `frame.request`/`frame.ppm`
  回传链路连续工作，`vm_frame_relay.c` 能拿到 P6 帧）。
- 帧头 `P6 1080 1920`，尺寸正确。

## 16.5 遗留
1. **帧内容仍基本全黑**：抽检一帧非零像素仅 8751/6220797，且集中在
   `x=427..1079, y=931..963` 一块 33 行的横条（像一行文字）。
   这是 §10–§14 记录的独立问题（"渲染的 buffer ≠ 被 post 的 buffer"），
   与本次崩溃修复无关，需另开一轮。
2. 宿主内存仍是硬约束：`memoryMb=2048` 才能起来（见 §15.4）。

---

# §17 2026-10-08（二）：黑屏排查 —— **§11 的"post 错 buffer"结论被推翻**，黑屏是访客真实状态

## 17.1 结论先行
崩溃修好、渲染器健康之后重新测，结论与 §11～§14 相反：

1. **访客 post 的就是它自己合成的结果**，不存在"post 错 buffer"；
2. **读回链路是准的**（读回统计与交付的 `frame.ppm` 像素完全对得上）；
3. **黑屏的直接原因是：访客从头到尾没有显示过任何 Activity**
   （console 里 `ActivityTaskManager: START|Displayed` 计数 = 0）——
   屏幕上本来就没有东西可显示，不是被宿主丢掉了。

## 17.2 证据链（一次干净运行，真机 cc96ded5 / 实例 vm_1）
访客的提交序列（`rc` opcode 参数，窗口 surface = 0x9）稳定成环：
```
10015 rcSetWindowColorBuffer(ws=0x9, cb=0x8)
10018 rcFBPost(cb=0xc)
10016 rcFlushWindowColorBuffer(ws=0x9)
10015 rcSetWindowColorBuffer(ws=0x9, cb=0xa)   ← 0x8/0xa/0xb 三轮换
10018 rcFBPost(cb=0xd)
10016 rcFlushWindowColorBuffer(ws=0x9)
```
统计（本次运行）：
| 事件 | 计数 | 参数 |
|---|---|---|
| `rcSetWindowColorBuffer` | 345 / 344 / 344 | 都是 `ws=0x9`，cb = 0x8 / 0xa / 0xb |
| `rcFlushWindowColorBuffer` | 1034 | 都是 `ws=0x9` |
| `rcFBPost` | 519 + 518 | cb = 0xc / 0xd |
| `rcBindTexture` | 18+17+17+7 | cb = 0xb / 0xa / 0x8 / 0xd |

关键在最后一行：**访客把 0x8/0xa/0xb（它渲染进去的那三块）用 `rcBindTexture` 当纹理绑上去**，
也就是它自己用 GL 把图层采样、合成进 0xc/0xd，然后 post 0xc/0xd。
所以 **post 的正是合成结果**，`VMHOST_READBACK tex=26/30` 读的也就是这张合成图。

读回与画面的对应（同一时刻）：
```
VMHOST_READBACK tex=26 1080x1920 fbo=4 reattach=0 nzRGBpix=2917/2073600 maxRGB=255 err=0x0
frame.ppm（P6 1080x1920）按像素统计：非零像素 2917  —— 与读回数字**完全一致**
```
⇒ 读出准确；画面本身就只有 2917 个非零像素（≈0.14%），集中在屏幕正中
（`x≈360..720, y≈840..1080`，一块很暗的小斑点）。

## 17.3 §11/§12 的修正
- §11 记的"`rcFBPost` 的 handle 与 `rcSetWindowColorBuffer` 设置的渲染目标不是同一块"
  —— 现象是真的，但**结论错了**：那不是 bug，而是访客"图层(0x8/0xa/0xb) →
  合成(0xc/0xd) → post(0xc/0xd)"的标准两段式，中间那步是 `rcBindTexture` + GL 绘制。
- §12 的 `VMHOST_HACK_POST_CB`（post 时改用 window surface CB 当像素源）
  **基于错误前提**，已确认是伪修法；本次已把它从源码树还原（默认不启用）。

## 17.4 黑屏的直接原因
访客 console（`console.log`）显示：
```
[  583.3s] WindowManager: Keyguard drawn timeout. Setting mKeyguardDrawComplete
[  654.9s] OnBootPhase_600_ActivityTaskManagerService
[  825.4s] sys.boot_completed=1
[  895.5s] ssm.onStartUser-0_ActivityTaskManagerService      ← 开始切用户
[  949.9s] SystemUIBootTiming: DependencyInjection           ← SystemUI 才刚起来
[ 1022.0s] （console 时间戳到此不再前进）
```
`ActivityTaskManager: START` / `Displayed` 计数 **= 0** —— **没有任何 Activity 被启动或显示**。
即：访客 `boot_completed` 了，但 SystemUI/Launcher 的绘制还没完成，屏幕上就没有内容。
（TCG 无 KVM 下访客极慢：SystemServer 到 900s 才切用户，期间 539s / 681s 各一次 ANR dump。）

**所以"黑屏"此刻等于"访客还没画出东西"**，不是渲染/回传链路的缺陷。
早期那种"顶部一条亮带 + 底部一个方框"的帧，是开机动画阶段的正常画面。

## 17.5 新发现：宿主跑约 17 分钟后会崩（另一类崩溃，与 Adreno 无关）
在 guest ≈1022s（本轮跑了 23 万条 GL 命令）时，宿主又一次 `signal=11`：
```
signal=11 si_code=2 addr=0x75c0759000 tid=25891
pc=0x56b5764c18 lr=0x56b5764c30        ← 都在 libqemu_exec.so 内（不是 adreno）
gl_ctx: eglGetCurrentContext=0x0 ...
VMHOST_GLES2_RECENT total=230799        ← 崩溃前已处理 23 万条
```
当时用 `llvm-addr2line`（按 `r-xp` 段偏移 0x732000 换算）得到 `aemu BufferQueue::closeLocked()`
和 emugl `HealthMonitor` 的事件表，据此**猜**成"pipe BufferQueue + HealthMonitor 的堆破坏"。

> **该判断已被证伪 —— 见 §19。** 真正根因是**我们自己的诊断插桩越界读**
> （`patch_vmhost_diag.py` 注入的 `vmhost_gles2_note()` 按访客自报的 `packetLen`
> 读参数，越过了命令缓冲区末尾的页边界）。上面这两个符号是"最近符号"式的**误导性归属**：
> 关键是把 `llvm-nm` 的 **vaddr** 当成了 **file offset**（本 .so 两者差 0x4000）。
> HealthMonitor 在本工程里根本不会运行（`ENABLE_HEALTH_MONITOR=0`，`CreateHealthMonitor()`
> 直接返回 `nullptr`，运行时日志固定打 `HealthMonitor disabled.`）。

## 17.6 下一步（按优先级）
1. ~~修 17.5 的崩溃~~ → **已修，见 §19**（诊断插桩的越界读，已按 `end - ptr` 夹紧并实测通过）。
2. 让访客真正把 UI 画出来（它太慢）：观察 `Displayed` 出现后再判画面；
   必要时在 guest 侧关掉重服务（SystemUI/Launcher 之外的）以加速。
3. 复现脚本化：本次用 `VMHOST_DIAG=1` 运行即可拿到上面所有表格；
   另注意 `patch_vmhost_diag.py` 里 `vmhost_gles2_note` 的插入锚点已改成短锚点
   （原先与 `patch_vmhost_surface.py` 的锚点冲突，导致 GLES2 侧全部探针被静默丢掉）。

---

# §18 2026-10-08（三）：访客 UI 显示慢 —— **把 QEMU 钉到大核，实测 1.4x**

## 18.1 结论
**唯一实测有效的杠杆是「把 QEMU 进程钉到宿主主频最高的核」**，App 路径紧邻 A/B 实测
**1.43x**（surfaceflinger 147.1s → 102.9s）。其余能想到的加速路径全部被排除：
KVM 不可用、MTTCG 反而更慢、vCPU 数无影响、访客内存没有抖动。

## 18.2 实测数据
**A) App 路径、紧邻两次运行（同一镜像/参数，唯一的差别是钉不钉核）**

| 运行 | 钉核 | zygote | surfaceflinger | 当时大核上限 |
|---|---|---|---|---|
| A | ✓ cpu6,7 | **53.2s** | **102.9s** | 1.69 GHz（被温控压住） |
| B | ✗ | 77.4s | **147.1s** | 1.96 GHz |

B 的温控条件**更好**却慢 1.43x ⇒ 钉核收益是实打实的（干净条件下更大）。

**B) 手工 harness（`mt_ab.sh`，不钉核基线 vs 钉核，同参数）**

| 里程碑 | 不钉核 | 钉 cpu6,7 |
|---|---|---|
| servicemanager | 26.0s | 19.0s |
| zygote | 75.8s | 53.4s |
| surfaceflinger | 154.4s | 104.1s |

**C) 宿主拓扑（8 Gen 3）**：cpu0–5 = 3.53GHz，**cpu6/7 = 4.32GHz**。

## 18.3 排除掉的路径（都实测过）
| 路径 | 结果 |
|---|---|
| **KVM** | 不可用。内核 `CONFIG_KVM=y`（`kvm-arm.mode=protected`），但 `/proc/misc` 里没有 kvm、手工 `mknod /dev/kvm c 10 232` 后 `dd` 报 **No such device** —— 设备跑在 Qualcomm **Gunyah**（`/sys/class/misc/gunyah`）之下、内核在 EL1，KVM 无法初始化。 |
| **MTTCG**（`-accel tcg,thread=multi`） | **更慢**：同条件对照 SF 96s→135s，且 CPU 始终 ~107%（从未 >1 核）。 |
| **vCPU 数**（`-smp 2` vs `4`） | 无影响（SF 153.5s vs 154.4s）。⇒ 访客启动基本是**单线程**的，多核/多线程 TCG 都是白亏同步开销。 |
| **访客内存** | 无抖动迹象（console 里 `lmkd` 无杀进程、无 `am_kill`）。 |
| **`performance` governor** | 在温控下**无效甚至更慢**（温控把 `scaling_max_freq` 压到 1.69GHz，硬件上限 4.32GHz）。 |

## 18.4 关键认知：访客速度几乎线性跟随宿主**实际主频**
- 手工跑（root shell 子进程、后台调度）比 App 跑（前台 app 子进程、有 boost）
  慢 ~1.6x —— 同样的镜像与参数；根因就是调度/主频不同。
- 因此**跨时段对比不可靠**，调优必须紧邻 A/B。为此新增了
  `vm/build-aosp-exp/mt_ab.sh`（按 App 完全相同的参数手工起 QEMU，里程碑直接读访客
  内核时间戳，`taskset c0` 可指定亲和）。

## 18.5 落点（不用重打 APK）
引擎 spawn QEMU 时**只** `LD_PRELOAD` 了 `libsigfix.so`
（见 `vm/engine/src/main/cpp/src/vm_qemu.c:340`），所以它是唯一"给 QEMU 子进程加启动
修正"的注入点。在 `vm/build-aosp-exp/libsigfix.c` 里新增 `VMHOST_PIN`：
- 构造函数里逐核读 `cpuN/cpufreq/cpuinfo_max_freq`，**取主频最高的一组**（本机 = 6,7），
  调 `sched_setaffinity`；线程继承掩码，一次即覆盖 QEMU 全部线程；
- 读不到主频就**不干预**；`VMHOST_PIN_CPUS=<hex 掩码>` 可手工指定，`=0` 关闭（A/B 用）；
- 启动时在 stderr 打一行 `VMHOST_PIN 已把 QEMU 钉到主频最高的核：6,7` 便于确认。

编译：`vm/build-aosp-exp/build_sigfix.sh`（NDK clang，产物已更新到
`vm/engine/src/main/jniLibs/arm64-v8a/libsigfix.so`）；设备上替换
`nativeLibraryDir/libsigfix.so` 即可生效。

## 18.6 遗留（要做"秒开"还差什么）
钉核只把 ~14min 的启动压到 ~10min，量级没变。要真正快，只有两条结构性路线：
1. **削减访客的启动工作量**（镜像级）：访客自身计时显示 `Zygote64Timing: PreloadClasses`
   单项就要 22–35s；SystemServer/SystemUI 是后段大头（`boot_completed` 前后），
   需要按服务裁剪或换更精简的镜像；
2. **快照/恢复**（QEMU `savevm`/`loadvm`）：启动一次后保存，之后秒级恢复 ——
   收益最大，但 gfxstream/Virtio 设备的状态保存是主要风险点，属独立大工程。

## 19. 2026-10-09：§17.5「跑约 17 分钟必崩」真正根因 —— 是**我们自己的诊断插桩越界读**

### 19.1 结论先行
不是 HealthMonitor、不是 gfxstream、不是 Adreno。是 `patch_vmhost_diag.py` 注入的
`vmhost_gles2_note()` 在 GLES2 解码循环里**读越界**：

它按**访客自报**的 `packetLen` 去读命令参数（`p + 8 + 4*i`），而缓冲区末尾那个包
**只到一半**是常态（命令缓冲被拆包，`decode()` 处理不完就返回让调用方补数据），
此时 `packetLen > end - ptr`，于是读到缓冲区之外；当缓冲区末尾恰好落在**页边界**
（scudo secondary 分配后面的 guard page）时 → `SIGSEGV si_code=2`（ACCERR，读只读页）
把整个 QEMU 打死。所以表现为"特定阶段必崩"，且与访客/驱动无关。

### 19.2 证据链（日志行 460175 那次，`VMHOST_GLES2_RECENT total=289572`）
```
signal=11 si_code=2 addr=0x70007df000
pc=0x5a597b5214 lr=0x5a597b522c   x21=0x8   x25=0xb4000070007deff8（= ptr+8）
```
- **换算**：本 .so 的 ELF 是 `p_offset=0x7326d0` / `p_vaddr=0x7366d0`（差 0x4000），
  所以 `file_off = (pc - self_base) - 0x4000`，即 **0xcd5214**。
- **反汇编（vaddr 0xcd5214）**：
  ```
  cd91ec: add  x25, x1, #0x8      ; x25 = ptr + 8
  cd9214: ldr  w5, [x25, x21]     ; ← 崩溃指令：*(uint32_t*)(ptr + 8 + 4*i)
  cd9228: bl   snprintf
  ```
  x25(0xb4000070007deff8) + x21(8) = 0x70007df000，与 `addr` 逐位吻合。
- **与注入代码逐字对应**：`mov w26, #0xa0`(=160) 即 `sizeof(args)`，`bl snprintf` 即
  ```cpp
  char args[160] = {0};  int n = 0;
  for (int i = 0; i < 7; i++) {
      if (len < (uint32_t)(12 + 4 * i)) break;                 // len = 访客自报 packetLen
      n += snprintf(args + n, sizeof(args) - n, " a%d=0x%x",
                    i, *(const uint32_t*)(p + 8 + 4 * i));     // ← 越界读
  }
  ```
- **为什么 `len` 会大于实际剩余**：上游的真正校验在**我们这行之后**
  ```cpp
  uint32_t packetLen = *(uint32_t *)(ptr + 4);
  vmhost_gles2_note(opcode, packetLen, ptr);                     /* 我们插的 */
  if (end - ptr < packetLen) return ptr - (unsigned char*)buf;   /* 上游真正的校验 */
  ```

### 19.3 为什么上一轮的 HealthMonitor 判断是错的
- 本工程 `ENABLE_HEALTH_MONITOR` **从未定义**（=0）：编出来的 `libqemu_exec.so` 里
  `CreateHealthMonitor()` 就是
  `OutputLog("HealthMonitor disabled."); *out = nullptr;`（一行直接返回）。运行时同样印证：
  每次 QEMU 启动都打 `HealthMonitor.cpp:280] HealthMonitor disabled.`。
  ⇒ **根本不存在 HealthMonitor 实例**（`m_healthMonitor == nullptr`），监控线程也从不启动。
- 因此 `patch_vmhost_healthmon.py`（**已删除**）与 `FrameBuffer` 的 `m_healthMonitor(nullptr)`
  都是空操作 —— 既不引发、也修不掉这个崩溃。这与"打完补丁 pc 只差 0x10、x0 一样"完全吻合：
  pc 只是**确定性落点**，不是肇事者。
- **误判来源**：把 `llvm-nm` 的 **vaddr** 当成了 **file offset**（混用 0xcd5224 / 0xcd5214），
  正好落进 `HealthMonitor<steady_clock>::main()::lambda(Stop&)` 的地址区间，才"撞"上库里那段无关代码。

### 19.4 修法（已落地）
`patch_vmhost_diag.py`：解码循环调用点先算 `avail = end - ptr`，传 `min(packetLen, avail)`；
并自愈旧版（未夹紧）注入。
```cpp
const uint32_t vmhostAvail = (uint32_t)(end - ptr);
vmhost_gles2_note(opcode, packetLen < vmhostAvail ? packetLen : vmhostAvail, ptr);
```
这样 `note()` 里所有读取都满足 `12 + 4*i <= len <= avail`，恒在 `[ptr, end)` 内。
反汇编确认新 `libqemu_exec.so` 已生成夹紧：`cmp w8,w28` + `csel w19,w8,w28,lo`。

> 同时修了 `patch_vmhost_diag.py` 里同一个坑的另一处隐患：`vmhost_gles2_note` 之外
> 没有第二处"按自报长度读参数"的插桩（gles1 侧只打印 opcode/len，且 unpack 在
> 上游校验之后），所以这一处就是唯一的肇事点。

### 19.5 实测（真机 cc96ded5 / vm_1 / p11_arm64 / 720x1280 / 4096MB / 6 核）
| | 旧构建 | 新构建 |
|---|---|---|
| 崩溃 | `VMHOST_GLES2_RECENT total=289572` 处 `signal=11 si_code=2` | **无** |
| 崩溃标记计数（本次运行区间） | 1 | **0** |
| GL 命令数 | 卡死在 289572 | 越过 **400000** 持续增长 |
| QEMU 进程 | 亡 | **存活**（17:32 仍在跑，正是过去必崩的时刻） |

复现方式：App 的调试入口 `com.vm.app/.instance.VmNativeActivity1`
（`--es com.vm.core.extra.CONFIG <json>`），比手工 `mt_ab.sh` 更忠实
（手工 harness 会卡在 boot 早期、根本走不到 GL 流量）。

### 19.6 提醒（避免重犯）
- 解析崩溃地址时，**先看 ELF 的 `p_offset` 与 `p_vaddr` 是否相等**再决定喂给
  `llvm-nm` / `llvm-objdump --start-address` 的数值：本 .so 两者差 0x4000，且
  `llvm-nm -S` 打印的是 **vaddr**。混用会把 pc 归到完全无关的函数上。
- **在解码/解析类循环里插桩，读参数的边界必须用"缓冲区真实剩余"（`end - ptr`），
  绝不能用报文里自报的长度** —— 后者可能超出缓冲区。



