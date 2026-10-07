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
