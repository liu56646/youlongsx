# opengles 宿主渲染器实施方案（步骤 ③）

> 目标：让 guest 的 `pipe:opengles` 被真正服务，使 `hwcomposer` 能建立 gfxstream 宿主连接，
> 从而停止 `SurfaceFlinger` 被连累重启的链式崩溃。
>
> 本文是**实施方案**，不含代码改动。所有结论区分「已确认（有文件行号）」与「待实测」。

---

## 1. 问题与验收

### 1.1 现象

真机（Android 16 / arm64）跑 Android 11 guest（`p11_arm64`），启动到 ~100s 后：

```
[ 56s] init: starting service 'vendor.gralloc-3-0'
[ 56s] init: starting service 'vendor.hwcomposer-2-3'
[103s] init: Service 'vendor.hwcomposer-2-3' (pid 258) received signal 6
[103s] Command 'restart surfaceflinger' action=onrestart → succeeded
```

`SurfaceFlinger` 是被 `hwcomposer` 的 `onrestart` 连累重启的，**不是它自己崩**。

### 1.2 根因（已确认）

| 证据 | 位置 |
|---|---|
| HWC 服务链接 `libEGL.so` + `libOpenglSystemCommon.so` + `lib_renderControl_enc.so` | `strings vendor.img:/bin/hw/android.hardware.graphics.composer@2.3-service` |
| 模块 `hwcomposer.ranchu.so`（EmuHWC2）同样链上述库，字符串含 **`EmuHWC2: Failed to get host connection`**、`HostConnection::createUnique`、`/dev/goldfish_sync` | `/vendor/lib64/hw/hwcomposer.ranchu.so` |
| guest 只有 gfxstream 一套 EGL，无软件 GL 退路 | `/vendor/lib64/egl/` 仅 `libEGL_emulation.so` / `libGLESv1_CM_emulation.so` / `libGLESv2_emulation.so` |
| 宿主侧 `pipe:opengles` 未注册 → 连接串返回 `-1` | `VMHOSTPIPESVC send a=-1`（`g24.err`，opengles 重试 7 次） |

⇒ HWC 启动时必须经 `HostConnection` 建立到宿主 gfxstream 的连接（即 `pipe:opengles`），
失败即致命 abort（`SI_QUEUE`）。**没有靠 framebuffer / 软件渲染绕过的路径。**

### 1.3 验收判据

| 编号 | 判据 |
|---|---|
| A1 | `pipe:opengles` 的连接串返回**非 -1**（`VMHOSTPIPESVC send` 不再是 -1） |
| A2 | 宿主侧 `android_getOpenglesRenderer()` 返回**非空**（glue 打点确认） |
| A3 | guest 不再出现 `Service 'vendor.hwcomposer-2-3' ... received signal 6` |
| A4 | guest 日志中 `starting service 'surfaceflinger'` 只出现 **1 次**（不再被 onrestart 循环） |

---

## 2. 技术路线（含关键否决项）

### 2.1 总路线

以 **gfxstream 仓库**（`platform/hardware/google/gfxstream`，分支 `emu-34-release`，
HEAD `4673362`，与现有 qemu 树同批）为 CMake 根，用 `BUILD_STANDALONE=ON` 对着**已有的 aemu** 构建，
产出静态库后接进 QEMU 可执行体。

宿主 GL 走 **宿主设备自带的系统 EGL/GLES**（`dlopen("libEGL.so")` / `dlopen("libGLESv2.so")`），
不使用 ANGLE / SwiftShader。

### 2.2 关键否决项（必须遵守）

| 否决项 | 原因 |
|---|---|
| **不要**打开 QEMU 的 `OPTION_GFXSTREAM_BACKEND` / `GFXSTREAM` | `android/android-emugl/combined/CMakeLists.txt:2-3,7-22,161,214-216` 会强制 `prebuilt(ANGLE)`/`prebuilt(VULKAN)`/`SWIFTSHADER_DEPENDENCIES`/`USE_ANGLE_SHADER_PARSER`/`ANGLE::ANGLE` —— 与「无预编译依赖」直接冲突 |
| **不要**编入 QEMU 的 `android/android-emu/android/opengles.cpp` 与 `android/android-emu/android/opengl/OpenglEsPipe.cpp` | 它们与 gfxstream 树里的同名实现（`android_getOpenglesRenderer` / `EmuglPipe` / `android_*OpenglesEmulation`）**符号重复定义**，静态链接下必须二选一 |
| **不要**调用 `android_initOpenglesEmulation()` | `host/gl/gl-host-common/opengles.cpp:125-128` 直接 `GFXSTREAM_ABORT("Not meant to call ... in the new build.")` |
| **必须**定义 `-DANDROID` | `host/gl/glestranslator/EGL/EglGlobalInfo.cpp:70-81`：未定义 `ANDROID` 时会走 `EglOS::Engine::getHostInstance()` → GLX → 依赖 `libGL.so.1` + X11，手机上必失败 |

### 2.3 最小 target 清单（已确认）

**GFX 侧（显式链接 2 个）**

| target | 作用 | 定义位置 |
|---|---|---|
| `gfxstream_backend_static` | `RendererImpl` / `RenderLibImpl` / `RenderChannelImpl` / `RenderThread` / `FrameBuffer` / `ColorBuffer` / `PostWorker` … | `host/CMakeLists.txt:67-72`，源清单 `:22-47` |
| `gfxstream-gl-host-common` | `android_getOpenglesRenderer` / `OpenglEsPipe`(pipe 服务) / `emugl_config` | `host/gl/gl-host-common/CMakeLists.txt:29-54`（**仅 `BUILD_STANDALONE=ON`**） |

其余（`gfxstream-gl-server`、`OpenGLESDispatch`、`renderControl_dec`、`gles1_dec`/`gles2_dec` 等）
由上面两个 target 的 PUBLIC 依赖自动带入。

**aemu 侧（4 个 .a，已有）**：`aemu-base`、`aemu-host-common`、`logging-base`、`gfxstream-snapshot`

**运行期只需 3 个调用**（写在新的宿主 glue 里）：

```cpp
auto renderLib = new gfxstream::RenderLibImpl();
android_setOpenglesEmulation(renderLib, nullptr, nullptr);   // opengles.cpp:117
android_startOpenglesRenderer(w, h, /*useSubWindow=*/true, /*glesVersion*/28,
                              &vmOps, &winAgent, &multiDisplayAgent, &maj, &min);
android_init_opengles_pipe();                                // OpenglEsPipe.cpp:589
```

**不需要** `goldfish_address_space` / `goldfish_sync` **设备**：
`RecvMode` 默认 `Android`（`OpenglEsPipe.cpp:66-72`），通道是纯内存 `RenderChannelImpl`
（`host/RenderChannelImpl.cpp:48-67`）。ASG（地址空间图形）只在 guest 打开 ASG 设备时才走
（`include/render-utils/Renderer.h:77-90`）。**但** `goldfish_sync_*` /
`get_address_space_device_control_ops` / `registerOnLastRefCallback` 这些**符号**必须能链接到
（已在 `libaemu-host-common.a` 里，需 `nm` 复核）。

---

## 3. 分阶段实施

### 阶段 1：gfxstream 构建探测（风险最高，先做）

> 目标：先把两个 `.a` 编出来，**不改 QEMU**。

1.1 **配置**（新脚本 `vm/engine/scripts/build_gfxstream.sh`）

```
-DANDROID · NDK r28 aarch64-android28 · CMAKE_BUILD_TYPE=Release · BUILD_SHARED_LIBS=OFF
-DBUILD_STANDALONE=ON
-DUSE_ANGLE_SHADER_PARSER=OFF -DASTC_CPU_DECODING=OFF
-DENABLE_VKCEREAL_TESTS=OFF -DWITH_BENCHMARK=OFF -DBUILD_GRAPHICS_DETECTOR=OFF
```
aemu 的接入方式二选一（推荐前者）：
- **把 aemu 作为 `add_subdirectory` 一起配置**（满足 `aemu_common` / `*.headers` INTERFACE target 契约，
  include 路径才会传播）；注意避开 `AEMU_COMMON_BUILD_CONFIG=qemu-android`（其 `add_library(lz4_static ALIAS lz4)`
  对不存在的 target 报错）
- 或手工预置 `aemu_common` / `aemu-base.headers` / `aemu-host-common.headers` / `gfxstream-snapshot.headers`
  INTERFACE target（`third-party/CMakeLists.txt:316-327` 有硬性存在性检查，缺失即 FATAL_ERROR）

1.2 **绕开 ANGLE**：在 include gfxstream 之前自行定义 INTERFACE target `gfxstream_egl_headers`，
指向仓库自带头文件 `common/opengl/include`（含 `EGL/egl.h`、`GLES2/gl2.h`、`GLES3/gl3.h`）。
判定点在 `third-party/CMakeLists.txt:239 if(NOT TARGET gfxstream_egl_headers)`。

1.3 **排除 X11 源**（预计首个编译失败点）：

| 文件 | 现状 | 处理 |
|---|---|---|
| `host/CMakeLists.txt:55` | 非 WIN32/APPLE/QNX 一律进 `NativeSubWindow_x11.cpp` | 换成 `host/NativeSubWindow_android.cpp`（**该文件存在但没有任何 CMakeLists 引用**） |
| `host/gl/glestranslator/EGL/CMakeLists.txt:20-21` | 含 `EglOsApi_glx.cpp`、`X11ErrorHandler.cpp` | 从源清单移除 |
| `host/apigen-codec-common/CMakeLists.txt:7-8` | 含 `X11Support.cpp` | 从源清单移除 |

1.4 **产出与判据**

```
libgfxstream_backend_static.a
libgfxstream-gl-host-common.a
```
- 判据 P1：两个 `.a` 产出
- 判据 P2：`llvm-nm` 在 `gfxstream-gl-host-common.a` 里能查到 `android_getOpenglesRenderer`、
  `android_init_opengles_pipe`
- 判据 P3：`llvm-nm --undefined-only` 里不出现 `X11` / `glX` / `libGL.so` 相关未定义符号

### 阶段 2：接进 QEMU（静态链接）

2.1 `build_qemu_aosp.sh` 追加 gfxstream 的两个 `.a` 到 `LIBS`（复用现有 `--start-group` 机制）
2.2 新增宿主 glue：`vm/engine/scripts/qemu_patches/vmhost_gfx_glue.cpp`
   - 实现 `VmLock`/`DmaMap` 已有；本文件只做「建 RenderLibImpl → setOpenglesEmulation →
     startOpenglesRenderer → init_opengles_pipe」，并用 `extern "C" int vmhost_gfx_init(void)` 暴露
   - 在 `vmhost_pipe_init()` 之后调用（`vl.c` 的两处入口已有 `vmhost_pipe_init()`，同位置追加）
2.3 确认 QEMU 侧**没有**编入 `android/android-emu/android/opengles.cpp` 与
   `android/android-emu/android/opengl/OpenglEsPipe.cpp`（当前 `CONFIG_ANDROID` 关闭、本就不编，需显式 grep 复核）
2.4 判据：链接通过；`llvm-nm` 中 `android_getOpenglesRenderer` 唯一；启动时 glue 打点显示 renderer 非空

### 阶段 3：真机验证与排障

3.1 部署新二进制 → 跑 `vm/build-aosp-exp/exp24.sh`（`VMHOSTPIPE_SVC=1`）
3.2 按 §1.3 的 A1–A4 判定
3.3 若渲染器初始化失败，优先排查：
   - `EglOsApi_egl.cpp:152` 用裸 soname `dlopen("libEGL.so")` —— 可能受 linker namespace 限制
   - `emugl_config.cpp:300-303` 在 headless/黑名单时会切 `swiftshader_indirect`
     （需确保未设 `ANDROID_EMU_HEADLESS`、不触发黑名单）
   - 环境变量 `ANDROID_EGL_ON_EGL`（`opengles.cpp:110-112`）控制 `sEgl2egl`

### 阶段 4（本期不承诺）

`goldfish_address_space` PCI 设备补进 `ranchu` 机器、ASG 路径、`QemuMiscPipe`、输入回传。

---

## 4. 风险与预案

| 级别 | 风险 | 影响 | 预案 |
|---|---|---|---|
| 高 | **X11 源默认进 aarch64 构建** | 编译直接失败（无 X11 头/库） | 阶段 1.3 的三处替换/移除 |
| 高 | **忘了 `-DANDROID`** | 走 GLX/`libGL.so.1`，真机必崩 | 构建脚本显式加 `-DANDROID`，并在 `.a` 里 grep 验证无 glX 符号 |
| 高 | **符号重复定义**（QEMU 与 gfxstream 两套 `android_*Opengles*`） | 链接失败 | 阶段 2.3 复核，只保留 gfxstream 一套 |
| 中 | `gfxstream_backend_static` 连带 `gfxstream-vulkan-server` / `magma-server` / flatbuffers，在 NDK r28 上一次性通过概率未知 | 编译/链接失败 | 先按默认编；若失败，裁剪 `RendererImpl` 对 vulkan/magma 的引用（需改 CMake） |
| 中 | aemu 符号缺口（如已踩过的 `VmLock.cpp` 不在 standalone 清单） | 链接期 undefined | 阶段 2 完成后对 `.a` 做一次 `--undefined-only` 全量核对 |
| 中 | 裸 `dlopen("libEGL.so")` 的命名空间解析 | 运行期 renderer 建不起来 | 实测；必要时显式指定绝对路径或改 `SharedLibrary::open` 调用方式 |
| 低 | `emugl_config` 黑名单切 swiftshader | renderer 起不来 | 确保环境变量干净；必要时改配置 |

---

## 5. 验证命令备忘

```bash
# 构建 gfxstream 子集（WSL，新脚本）
cd /mnt/k/youlongsx/vm/engine/scripts && JOBS=8 bash build_gfxstream.sh

# 构建整机
cd /mnt/k/youlongsx/vm/engine/scripts && JOBS=8 PIPE_TRACE=1 bash build_qemu_aosp.sh

# 推设备并跑实验（务必先杀干净，否则 data.img 被占）
adb push k:/youlongsx/vm/build-aosp-exp/qemu-system-aarch64 /data/local/tmp/vmaosp/
adb shell "pkill -9 -f '[e]xp24.sh'; pkill -9 -f '[q]emu-system-aarch64'; sleep 4"
adb shell "rm -f /data/local/tmp/g24.err /data/local/tmp/g24.log /data/local/tmp/exp24.txt"
adb shell "nohup sh /data/local/tmp/exp24.sh >/dev/null 2>&1 & echo started"
# ~150s 后
adb shell "grep -aE 'qemud_|send_data|send a=|recv a=' /data/local/tmp/g24.err | head -40"
adb shell "grep -aE 'hwcomposer|surfaceflinger|signal 6' /data/local/tmp/g24.log | head"
```

---

## 6. 关键代码位置索引（证据）

### gfxstream 仓库 `/root/vmbuild/gfxstream`

| 内容 | 位置 |
|---|---|
| `android_get/setOpenglesRenderer` 定义 | `host/gl/gl-host-common/opengles.cpp:463 / 465` |
| `android_setOpenglesEmulation` / `android_startOpenglesRenderer` | `host/gl/gl-host-common/opengles.cpp:117 / 130` |
| `android_initOpenglesEmulation`（**禁止调用**） | `host/gl/gl-host-common/opengles.cpp:125-128` |
| `EmuglPipe`（`Service("opengles")`） | `host/gl/gl-host-common/opengl/OpenglEsPipe.cpp:81-83`，注册 `:576-579` |
| `createRenderChannel`（Renderer 为空则返回 nullptr） | `host/gl/gl-host-common/opengl/OpenglEsPipe.cpp:164-171 / 263` |
| `RecvMode`（默认 `Android`） | `host/gl/gl-host-common/opengl/OpenglEsPipe.cpp:66-72` |
| `gfxstream::Renderer` 抽象基类 | `include/render-utils/Renderer.h:63` |
| `RendererImpl` | `host/RendererImpl.h:36`，`host/RendererImpl.cpp:124-154` |
| 引擎选择（`ANDROID` → EGL 引擎） | `host/gl/glestranslator/EGL/EglGlobalInfo.cpp:70-81` |
| 系统 EGL/GLES dlopen | `host/gl/glestranslator/EGL/EglOsApi_egl.cpp:63-73 / 149-166 / 191-210` |
| `BUILD_STANDALONE` 设置项 | `CMakeLists.txt:26-32` |
| `gfxstream_egl_headers` 判定点 | `third-party/CMakeLists.txt:239-264` |
| aemu 硬性存在性检查 | `third-party/CMakeLists.txt:316-327` |
| 平台源（X11 问题） | `host/CMakeLists.txt:48-56` |
| `gfxstream_backend_static` | `host/CMakeLists.txt:67-103` |

### QEMU 树 `/root/vmbuild/qemu-aosp`

| 内容 | 位置 |
|---|---|
| ANGLE/SwiftShader 预编译整合（**不要走**） | `android/android-emugl/combined/CMakeLists.txt:2-3 / 7-22 / 161 / 214-216` |
| 旧 emugl 的同类依赖 | `android/android-emugl/host/libs/libOpenglRender/CMakeLists.txt:1-2 / 8-24 / 217` |
| `prebuilt()` 实现 | `android/build/cmake/prebuilts.cmake:88-136` |
| 同名符号冲突源 | `android/android-emu/android/opengles.cpp`、`android/android-emu/android/opengl/OpenglEsPipe.cpp` |
| 已接好的宿主 glue（本方案的基础） | `vm/engine/scripts/qemu_patches/vmhost_pipe_glue.cpp` |

---

## 7. 结论

步骤 ③ 的**唯一可行路径**是移植 gfxstream 宿主渲染器，且：
- 构建风险集中在**「系统 EGL + 无预编译依赖」的适配**（X11 源、`-DANDROID`、ANGLE 绕开）；
- 渲染器一旦建起来，`pipe:opengles` 的最小闭包**不需要** goldfish_address_space/sync **设备**
  （默认走 goldfish pipe 直传模式）；
- 必须先做**阶段 1 的构建探测**，其结果决定后续是否可行。
