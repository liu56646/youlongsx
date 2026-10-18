# aemu 快照（quickboot）移植指南

> 目标：用 **Android 模拟器自己的快照框架**实现「秒开」，而不是把一条裸迁移流喂回 QEMU。
> 前置实测见 [改动说明-启动提速(前台服务+大核).md](../../../docs/改动说明-启动提速(前台服务+大核).md) §6。
>
> **建议顺序：先换 QEMU 基座（emu-34 → emu-36），再做本移植。** 理由见 §3 阶段 0：
> 这套快照代码本身就在 QEMU 树里（`android/android-emu/`），换基座等于换掉它，
> 先移植一遍再换树是白做。

---

## 0. 为什么裸迁移流不行

2026-10-16 真机实测：QMP `migrate` 导出的整机状态（270 MB/s、696MB）用 `-incoming`
喂回去，QEMU 在 RAM 段直接报：

```
qemu-system-aarch64: Unknown ramblock "", cannot accept migration
qemu-system-aarch64: load of migration failed: Invalid argument
```

原因是模拟器把 savevm 这条路**改过**：VM state 走 **protobuf 包装**
（`qemu_file_set_pb(f, s_protobuf)`）、RAM 走 aemu 的分段/Icebox 处理
（`qemu_file_set_hooks(f, sSaveFileHooks)`），并且靠 `s_snapshot_callbacks`
（`qemu_set_snapshot_callbacks`）在两侧同步启停。live migration 那条路径写出来的流
不是这个格式，所以加载端对不上。

## 1. 模拟器 quickboot 的真实链路

```
emulator 前端（launcher / gRPC VmOperations）
      |
      v
android-qemu2-glue/qemu-vm-operations-impl.cpp       <- 编排（QEMU 进程内）
      |  Snapshotter / Snapshot::getSnapshotById(name)
      v
android/android-emu/android/snapshot/*               <- aemu 侧实现
   Snapshotter.cpp  Snapshot.cpp  Quickboot.cpp
   RamSaver.cpp  RamLoader.cpp  Icebox.cpp  GapTracker.cpp
   Hierarchy.cpp  Compressor/Decompressor  PathUtils.cpp
      |
      v
migration/savevm.c: qemu_savevm(name) / qemu_loadvm(name)    <- QEMU 侧（我们已有）
   . qemu_file_set_pb(...)        VM state 走 protobuf
   . qemu_file_set_hooks(...)     走 aemu 的 RAM 分段钩子
   . bdrv_all_find_vmstate_bs()   需要一块**支持快照的块设备**（qcow2）承载 VM state
   . s_snapshot_callbacks         save/load 前后通知 aemu
      |
      v
hw/display/virtio-gpu.c: virgl_renderer_save_snapshot(f)     <- GPU/宿主渲染器状态
      |
      v
snapshot/libgfxstream-snapshot.a: TextureSaver / TextureLoader  <- 纹理
```

快照落盘位置由 `android/snapshot/PathUtils.cpp` 的 `getSnapshotBaseDir()` 决定
（emulator 侧是 `<avd>/snapshots/<name>/`）。

## 2. 我们现在有什么、缺什么（nm 实测证据）

`libqemu_exec.so`（现役构建产物）里**已经有**：

| 符号 | 说明 |
|---|---|
| `save_snapshot` / `load_snapshot` | `migration/savevm.c` 的入口 |
| `qemu_savevm` / `hmp_savevm` | savevm 实现 + HMP 命令（`hmp-commands.hx` 里 `savevm` 注册过） |
| `qemu_set_snapshot_callbacks` | aemu 回调挂钩点 |
| `virgl_renderer_save_snapshot` | `hw/display/virtio-gpu.c` 里的 GPU 状态调用点 |

**缺**：

| 缺的东西 | 现状 |
|---|---|
| `android-qemu2-glue/qemu-vm-operations-impl.cpp` | 未编译。`build_qemu_aosp.sh` 刻意不开 `CONFIG_ANDROID`（脚本 188–206 行注释：开了会把整个 emulator 前端拖进来） |
| `android/android-emu/android/snapshot/*`（Snapshotter / Quickboot / RamSaver / RamLoader …） | 未编译 |
| 它们的底座 `android/android-emu/android/base/*` | 未编译 |
| protobuf / lz4 | 未引入（`s_protobuf` 要前者，Compressor 要后者） |
| qcow2 的 vmstate 块设备 | 现在所有盘都是 `format=raw`，`bdrv_all_can_snapshot()` 直接过不了 |
| 触发入口 | 我们既没有 emulator 前端，也没有 gRPC/console agent |

另外：`snapshot/libgfxstream-snapshot.a`（已链接）里**只有** `TextureLoader` /
`TextureSaver` 两个目标（`ar t` 可验证），不是整套框架。

### 2.1 依赖链探测结果（2026-10-16，NDK clang++ 逐个编译）

这些源码混用**两套 include 前缀**，对应两棵不同的 base 树：

| 代码里的 include | 实际提供者 |
|---|---|
| `aemu/base/...`（如 `Optional.h`） | `$AEMU_DIR/base/include`（外部 aemu 仓库，`build_qemu_aosp.sh` 已经带了这条 `-I`） |
| `android/base/...`（如 `system/System.h`） | `qemu-aosp/android/emu/base/include`（QEMU 树里那份 vendored base） |
| `android/snapshot/...` | `qemu-aosp/android/android-emu` |

按上面三条 `-I` 补全后，`Snapshot.cpp` / `Snapshotter.cpp` / `PathUtils.cpp` /
`RamSaver.cpp` / `RamLoader.cpp` / `Quickboot.cpp` **六个文件全部只卡在同一个点**：

```
$AEMU_DIR/base/include/aemu/base/logging/Log.h:25:10:
fatal error: 'absl/strings/str_format.h' file not found
```

即：**abseil 是目前最外面的那块缺失依赖**。`~/vmbuild` 里既没有 absl 源码也没有
absl 静态库（`find` 可验证），所以阶段 1 除了 aemu 源码本身，还要：

1. 取一份 abseil（或复用 emulator 侧的 prebuilt），交叉编译成 Android/arm64 静态库；
2. 确认它能把 `Log.h` 里用到的 `absl::StrFormat` 那部分撑起来（必要时只编
   `str_format` 相关的子集）。

好消息：**只差这一层**——上面六个文件在补上 absl 之前，已经不再报"找不到 aemu 头"了。

### 2.2 新基座上这些 Hook 还在

对已 fetch 的 `origin/emu-36-1-release` 做了同样的检查：

- `android/android-emu/android/snapshot/*` 仍在（同一批文件名）；
- `migration/savevm.c` 仍有 `qemu_set_snapshot_callbacks`（:2345）、
  `save_snapshot`（:2383）、`hmp_savevm`（:2390）、`bdrv_all_find_vmstate_bs()`
  （:2439 / :2707 / :2895）。

所以移植点在换基座后是稳定的，先做基座升级不会白费。

## 3. 移植路线

### 阶段 0：先换 QEMU 基座（emu-34 → emu-36）

emu 分支里 `android/android-emu/` 就是 aemu 的 vendored 副本，换树等于换掉整套快照
代码。先移植再换树 = 做两遍。换基座步骤见
[QEMU基座升级-移植指南.md](./QEMU基座升级-移植指南.md)。

### 阶段 1：把 aemu 快照子集编成静态库

照 `build_aemu.sh` 的路子新写一个 `build_aemu_snapshot.sh`：

1. 先只求**能编过**：`Snapshot.cpp` / `Snapshotter.cpp` / `PathUtils.cpp` /
   `RamSaver.cpp` / `RamLoader.cpp`，缺什么补什么（预期会依次拖出
   `android/base/*`、`android/emulation/*` 的一部分）。
2. include 根要造出 `aemu/` 前缀（对应 `android/android-emu/android/`）。
3. 接 protobuf（`android/emu/protos/snapshot.proto`）与 lz4。
4. 产物：`libaemu-snapshot.a`，供 QEMU 链接（沿用 `--start-group` 写法）。

### 阶段 2：加触发入口

**方案 A（推荐）**：给 QEMU 加一个自己的 monitor 命令：

```
vmhostsnapshot save <name>
vmhostsnapshot load <name>
```

内部直接调 `android::snapshot::Snapshotter`。引擎手里已经有 qmp.sock，
用 `human-monitor-command` 就能触发，不必把整个 gRPC 前端拖进来。

**方案 B**：把 `qemu-vm-operations-impl.cpp` 原样编进来（更"原生"，
但要连带 gRPC/protobuf 一整条链）。

### 阶段 3：存储与目录

- VM state 需要一块 **qcow2** 设备（`bdrv_all_find_vmstate_bs()` 的要求），
  或者按 aemu 的做法把 RAM / VM state 落到快照目录的文件里。
- 快照目录落在实例目录内（`<dataDir>/snapshots/<name>/`），与 `PathUtils.cpp` 对齐。

### 阶段 4：引擎接线

- **保存**：必须在**静止点**做（用户点停止 / 退出实例时）——先 QMP `stop` 冻住 guest，
  再 save，然后才退出 QEMU。否则磁盘已经往前走而快照 RAM 还停在过去，ext4 会坏
  （结论见启动提速文档 §6）。
- **恢复**：启动时 load；失败自动删档回退冷启动——**这条护栏已经落地**
  （`vm_engine_on_qemu_exit()` + `vm_qemu_restore_failed()`）。
- 快照失效条件写进 meta：guest 内存 / vCPU 数 / 分辨率 / 镜像指纹 / 引擎版本。

### 阶段 5：验收

1. 二次启动到可见桌面 **< 20s**；
2. 恢复后桌面图标、正在运行的应用与保存时一致（不是回到开机动画）；
3. 连续 save/load 10 次不崩、不黑屏；
4. 冷启动路径不受影响（删掉快照即可复现原行为）。

## 4. 风险

1. **⚠️ 宿主渲染器状态存不下来（已从"未知"变成"确证"，2026-10-16）。**
   我们走的是 `virtio-gpu + gfxstream(stream_renderer)`，而
   `hw/display/virtio-gpu.c` 里 `virgl_renderer_save_snapshot()` /
   `load_snapshot()` 这两处调用在 `CONFIG_STREAM_RENDERER` 下被**明确写成
   `// NOT IMPLEMENTED`** —— 宿主 GL 纹理/上下文根本没被序列化。
   （legacy pipe 路径那个 `pipe_virgl_renderer_save_snapshot()` 也只是簿记，
   不存宿主纹理；官方那条完整链路走的是 `OpenglEsPipe`
   的 `preSave/preLoad → RendererImpl::save/load → FrameBuffer::onSave/onLoad`
   + `textures.bin`，和我们这套 renderer 不是同一条。）
   证据与细节见 [aemu快照-GPU状态可行性.md](../../../docs/aemu快照-GPU状态可行性.md)。

   也就是说：**在解决这一条之前，即使把快照存/取跑通，恢复后宿主侧纹理也是丢的**
   （大概率黑屏/花屏）。两条出路：
   (a) 把宿主 GL 状态的 save/load 在 stream_renderer 上补出来（改 gfxstream，量大）；
   (b) 换到官方那条本来就支持宿主状态快照的渲染后端（等于换显示架构）。
2. **磁盘一致性。** 快照必须与磁盘同点（见阶段 4）。若要支持"运行中随时存"，
   得给 /data 加 qcow2 overlay 并一起提交，复杂度再上一个台阶。
3. **包体与内存开销。** protobuf + lz4 + aemu base 会明显增大 `libqemu_exec.so`。
4. **与现网行为的组合**：`cache=unsafe` + 被系统强杀会留脏状态（已实测踩到过一次）。

## 5. 立即可做的小步

1. ~~在 emu-36 树上重复文件/符号检查~~ —— **已完成**，结论见 §2.2（同布局、同 hook）。
2. **取 abseil 并交叉编译成 Android/arm64 静态库**（当前最外层缺口，见 §2.1）。
3. 写 `build_aemu_snapshot.sh`，把 §2.1 列的六个文件编过（include 三条 `-I` 已确定）。
4. 定下阶段 3 的存储形态（qcow2 vmstate 设备 vs 快照目录文件）。
5. 起基座升级：`emu-36-1-release` 已 fetch 到本地 remote ref（`.git` 70M → 304M），
   按 [QEMU基座升级-移植指南.md](./QEMU基座升级-移植指南.md) 逐步重对补丁锚点。

---

## 6. 进展快照（2026-10-16 当天，多 agent 并行）

### 已完成 ✅

| 事项 | 状态 / 证据 |
|---|---|
| abseil（Android/arm64 静态库） | ✅ `~/vmbuild/abseil-build-arm64-v8a`（tag `20240116.2`），探针链接通过；脚本 `vm/build-aosp-exp/build_abseil.sh` |
| lz4（Android/arm64 静态库） | ✅ `~/vmbuild/lz4-build-arm64-v8a`（v1.9.4）；脚本 `vm/build-aosp-exp/build_lz4.sh` |
| protobuf + proto 代码生成 | ✅ `~/vmbuild/proto-gen`（emu 下 17 组 `.pb.h/.cc`，含 `snapshot.pb.*` / `studio_stats.pb.*`）；脚本 `vm/build-aosp-exp/build_protobuf.sh` |
| **`libaemu-snapshot.a`** | ✅ **22 个编译单元全部通过**，3.4MB，`~/vmbuild/aemu-snapshot-build-arm64-v8a/libaemu-snapshot.a`；脚本 `vm/engine/scripts/build_aemu_snapshot.sh`。已有符号：`Snapshotter::get/initialize/save/load`、`Quickboot::get/initialize/save/load/finalize`、`RamSaver/RamLoader` |
| QEMU 侧触发入口 | ✅ `build_qemu_aosp.sh` 新增 `patch_vmhostsnapshot()`：注册 HMP `vmhostsnapshot save\|load <name>`（幂等、锚点已验证） |
| 引擎侧接线 | ✅ `vm_qmp_request()`（QMP 请求/应答）+ `vm_qemu.c` 的 `snap_try_save()` / `snap_load_thread()`：停机前 `stop→save`、启动时 `load`，失败自动删标记回退冷启动；已编入 `libvmengine.so` |

**Icebox 被有意排除**（不接 BoringSSL）：证据是 `android-emu.cmake:195` 把 `Icebox.cpp` 归入
`android_emu_dependent_src`（依赖组），而核心快照在 `android-emu-common`；`Snapshotter.cpp` /
`Quickboot.cpp` 里没有任何 Icebox 引用，已编对象的未定义符号里也没有 `android::icebox::`。
依赖方向是反的（Icebox 调快照 API，不是快照调 Icebox）。

### 还没做 / 下一步 ⏭

1. **⚠️ 硬伤一：宿主 GPU 状态存不下来**（见 §4 风险 1 与
   [aemu快照-GPU状态可行性.md](../../../docs/aemu快照-GPU状态可行性.md)）。
2. **⚠️ 硬伤二：base 必须换成 vendored 那份**——见 §8，这是当前链接收敛不了的根因。
3. 定存储形态（qcow2 vmstate 设备还是快照目录文件）。

---

## 8. 链接期结论：base 要用 vendored 的 `android-emu-base`，别再叠外部 `libaemu-base.a`

### 现象（真实构建到最终链接）

`libaemu-snapshot.a` 和外部 aemu 的库混链后，符号是**两头都缺**：

```
ld.lld: error: duplicate symbol: android::base::pj(...)
   libaemu-snapshot.a(PathUtils.o)   vs   libaemu-base.a(PathUtils.cpp.o)     ← 重复
ld.lld: error: undefined symbol: android::base::ContiguousRangeMapper::add(...)  ← 缺
ld.lld: error: undefined symbol: android_strdup / strDup / android_eintr_wrapper_fatal
                              / dirScanner_* / tempfile_path / PathUtils::recompose
ld.lld: error: undefined symbol: avdInfo_getBuildProperties                     ← 缺
   （补 android/emu/avd/src/android/avd/info.c 时又撞 avdInfo_getContentPath
     与我们 glue shim 的重复定义，且它还需要 android/avd/avd-info.h）
```

一路补源码补到 15 个 TU 仍然在连锁 —— 典型的**"vendored 的头/编译模型 + 外部库的实现"**。

### 根因（有文件行号证据）

- 快照源码属于 `android-emu` 目标：`android/android-emu/android-emu.cmake:140-160`（源）、
  `:215-220`（建 target）、`:247-260`（**链 `android-emu-base`**）。
- 官方加进来的是 QEMU 树内 vendored base：
  `android/CMakeLists.txt:6-9` → `add_subdirectory(android-emu-base)`；
  实现源清单在 `android/android-emu-base/CMakeLists.txt:15-114`，
  子库在 `android/emu/base/{memory,logging}/CMakeLists.txt`。
- `android-emu-base-headers`（`android/emu/base/CMakeLists.txt:2-5`）是**vendored 头 +
  外部 aemu 头**的混合 —— 所以"两套 include 前缀都存在"是官方设计，但**实现只该有一份**。
- 外部 aemu 在官方构建里是另一条链（`android/third_party/CMakeLists.txt:319-327`
  引入 `hardware/google/aemu`，提供 `aemu-base` / `aemu-host-common`），
  而且官方用的是**与 QEMU 树配对的那个 revision**，不是我们现在这个独立 checkout。

### 最小改动建议（下一步做这个）

1. 新建构建步骤，按 `android/android-emu-base/CMakeLists.txt:15-114` +
   `android/emu/base/{memory,logging}/CMakeLists.txt` 编出
   `libandroid-emu-base.a` / `libandroid-emu-base-memory.a` / `libandroid-emu-base-logging.a`；
2. 最终链接里把外部 `libaemu-base.a` **从"快照的 base 提供者"位置上撤掉**，改链上面三个，
   并把 `SNAPSHOT_SUPPORT_SRCS` 里那批 base/memory/logging/path 的 .o 删掉；
3. **先审计 `libaemu-host-common.a` 的未解析 `android::base::*`**：如果 vendored base 能全满足，
   就整条只用 vendored；否则要把 host-common 与 base 的边界重新打包 ——
   不能把两份 base 无条件塞进同一个 `--start-group`（前面已经撞过重复定义）。
4. include 顺序调整为：vendored `android/emu/base/include` + `android/android-emu-base` + `android/android-emu`
   优先，外部 `$AEMU_DIR/base/include` 只在需要 `aemu/base/*` 头时兜底。

### 风险

- 我们的 `~/vmbuild/aemu` 与 QEMU 树配对的 `hardware/google/aemu` revision 可能不同，
  `libaemu-host-common.a` 是照外部 revision 编的；换 base 后可能需要一并重编 host-common。
- vendored `android-emu-base-logging` 与外部 `liblogging-base.a` 有重叠，不能同时无条件进组。

### 8.1 换 base 实测结果（2026-10-16，已做完）

**✅ 重复定义问题根治了。** 做了这几件事：

1. 新增 `vm/engine/scripts/build_android_emu_base.sh`：按 vendored 清单编出
   `libandroid-emu-base.a`（83 个 TU）/`-memory.a`/`-logging.a`，放在
   `~/vmbuild/android-emu-base-build-arm64-v8a/lib/`。
   过程中有意排除两个 TU（都在脚本里写了理由）：
   `android/base/Backtrace.cpp`（要 libunwind，NDK 没有，全树无人引用）、
   `android/base/Uuid.cpp`（要宿主 libuuid，只有它自己的 unittest 用）。
   并补了 `-DAEMU_TCMALLOC_ENABLED=0`（官方非 TCMalloc 配置就是这个值）。
2. `build_qemu_aosp.sh`：删掉那 15 个手补的 `SNAPSHOT_SUPPORT_SRCS`，链接行里把外部
   `libaemu-base.a`/`liblogging-base.a` 换成 vendored 三个库，并加了清理旧行的 sed 规则。
3. 验证过 **host-common 需要的 28 个 `android::base::*` 符号（MemStream / SubAllocator /
   MessageChannel / Stream…）vendored base 全都有** —— 所以不用重编 host-common。

链接结果：**不再出现任何 duplicate symbol**（之前的 `android::base::pj` 那类全消失），
错误只剩 undefined symbol。

**🔶 剩下 68 个 undefined symbol，全部来自"模拟器前端那一圈"。**
用 `--error-limit=0` 拿到完整清单后按定义位置归类：

| 类别 | 需要的源（真实定义处） | 性质 |
|---|---|---|
| feature flag | `android/emu/feature/src/android/featurecontrol/FeatureControl*.cpp` | 语义相关，最好用真的 |
| metrics 上报 | `android/emu/metrics/src/android/metrics/MetricsReporter.cpp`、`DependentMetrics.cpp` | 纯遥测，可 stub |
| 崩溃/挂起检测 | `android/emu/crashreport/src/...`、`android-emugl/combined/impl/base/HealthMonitor.cpp` | 可 stub |
| tracing | `android/emu/tracing/android/base/Tracing.cpp` | 可 stub |
| studio 集成 | `android/emu/studio-config/src/android/metrics/StudioConfig.cpp` | 可 stub |
| AVD/hw-config | `android/emu/avd/src/android/avd/{info.c,hw-config.c,util.c}` | 注意：`info.c` 会撞我们 glue 里的 `avdInfo_getContentPath` shim，得二选一 |
| adb | `android/android-emu/android/adb-server.cpp`、`android/emu/adb/interface/src/.../AdbInterface.cpp` | 可 stub |
| 动态库/工具 | `android/android-emugl/shared/emugl/common/shared_library.cpp`、`android/emu/protobuf/src/android/protobuf/LoadSave.cpp`、`android/emu/cmdline/src/.../bufprint_config_dirs.cpp` | 真的更省事 |
| 快照 C API | `android/android-emu/android/snapshot/interface.cpp`（`androidSnapshot_setRamFileDirty` 等） | **必须是真的** |

**两条路可选**：

- **(A) 补前端切片 + 少量 stub（推荐先试）**：约 12–15 个 TU；遥测/tracing/studio/crashreport
  这几类写 no-op stub（它们与快照正确性无关），feature/avd/protobuf/snapshot-interface 用真实实现。
  风险：stub 的语义要与真实实现一致（尤其 feature flag，别把影响快照格式的开关写死成 false）。
- **(B) 干脆按模拟器的方式构建**（打开 `CONFIG_ANDROID`、用 emulator 自己的 CMake 目标）：
  一次性解决所有前端依赖，但要推翻现在这套"最小嵌入"构建，量级大得多。

### 8.2 B 方案的实测结论：**不可行**（2026-10-17）

按 B 去核实时发现两件硬事实：

1. **emulator 的构建只支持桌面宿主**：`android-qemu2-glue/config/` 下的 host tag 只有
   `linux-x86_64 / linux-aarch64 / darwin-x86_64 / darwin-aarch64 / windows-*`，
   **没有 android 之类的 tag**；顶层 `CMakeLists.txt:24-35` 明确写着要走
   `android/build/cmake/toolchain.cmake`、推荐用 `android/scripts/rebuild`。
   也就是说：emulator 前端是"在你 PC 上跑的桌面程序"，**不存在 Android/arm64 的构建配置**。
2. 它还要 `prebuilts/android-emulator-build/qemu-android-deps/<tag>`（prebuilt 依赖树）与
   完整 AOSP 树里的 `${AOSP_ROOT}/external/webrtc/...`（libyuv/jsoncpp），
   这些都是我们环境里没有的。

顺带量了一下"官方 BoM"的规模：`android/android-emu/android-emu.cmake` 单个目标列了
**270 个源文件**，依赖 20 来个兄弟目标（avd / metrics / crashreport / feature / curl / net / gps / hardware …）。
所以 B 在本项目里不是"更彻底"，而是**换一个不存在的构建目标**。

**结论**：走"官方 BoM + 能在 Android 上活下来的子集"。实际做法就是 §8.1 的 (A)，
但源清单一律从官方 CMake/cmake 文件里取，而不是拍脑袋列。

### 8.3 当前链接进度（2026-10-17）

| 阶段 | 未定义符号 | 重复定义 |
|---|---|---|
| 换 vendored base 之前 | 68 | 有（`android::base::pj` 等） |
| 换 vendored base 之后 | 69 | **0** ✅ |

重复定义已彻底清零；剩下的 68→69 个符号全部落在**模拟器 AVD/环境 + 遥测**这一带，
而且已经聚类清楚（下一批要处理的）：

| 簇 | 提供者 | 处理方式 |
|---|---|---|
| `android::base::{getUnixTimeUs,sleepMs,sleepUs,getCpuCoreCount,cpuTime,getHighResTimeUs,getEnvironmentVariable,setEnvironmentVariable,pathExists}` | `android-emugl/combined/impl/base/System.cpp` | 用真的 |
| `emugl_logger`、`logging::LogMessage::*` | `android-emugl/combined/impl/base/logging.cpp` | 用真的 |
| `emugl::CreateHealthMonitor`、`HealthMonitor<>::*` | `android-emugl/combined/impl/base/HealthMonitor.cpp` | 用真的 |
| `android::base::{beginTrace,endTrace,traceCounter,enableTracing,disableTracing,initializeTracing,setGuestTime}` | `android/emu/tracing/android/base/Tracing.cpp` | 用真的 |
| `avdInfo_*`（约 20 个） | `android/emu/avd/src/android/avd/info.c` | **用真的**：给一个最小 `AvdInfo`（contentPath 指向 `<dataDir>`），这样 `getSnapshotBaseDir()` 自然落到实例目录，我们 glue 里那个 `avdInfo_getContentPath` shim 就可以撤掉 |
| `path_getAvdContentPath / path_getAvdSystemPath / path_getSdkRoot`、`androidHwConfig_stripDefaults`、`getResizableActiveConfigId`、`resizableEnabled` | `android/emu/avd/src/android/avd/{util.c,hw-config.c}` | 用真的 |
| `android::ConfigDirs::*` | `android/emu/cmdline/src/.../bufprint_config_dirs.cpp` | 用真的或按实例目录 shim |
| `MetricsReporter::*`、`CrashReporter::*`、`HangDetector::*`、`studio::*`、`android_metrics_fill_common_info`、`android_adb_reset_connection`、`OutputLog` | metrics / crashreport / studio-config / adb-server | **stub（no-op）**，与快照正确性无关，但每个 stub 必须写清"为什么可以 no-op" |

另外这次还顺手解掉一个上游自带的冲突：外部 aemu 的 `libaemu-host-common.a` 里带着
**两份旧的 feature-control 实现**（`feature_control.cpp.o` / `FeatureControlOverride.cpp.o`），
与模拟器树的真实现重复定义 `setFeatureEnabledCallback`。现在链接用的是一份
**摘掉这两个旧成员的归档副本**（`libaemu-host-common-nofc.a`，由脚本生成，不动 build_aemu.sh 的产物）。

### 8.4 真机运行时验证（2026-10-17）

链接通过后上真机跑，拿到了非常干净的诊断链：

1. **新二进制能正常启动并 boot 到 `boot_completed`**（guest 时间 391s，与旧二进制同量级）
   —— 说明 vendored base + 前端切片 + 各个 shim 在运行时是站得住的。
2. 引擎的保存路径也确实被触发：停机时发 `QMP stop` → `vmhostsnapshot save default_boot`。
3. 但 save 直接 SIGSEGV（pc=0）。用崩溃 dump 里的 maps 算出偏移、再用符号表反查：
   崩在 **`Snapshotter::save()` 内部**。
4. 反汇编 + 对照 `Snapshotter.cpp` 定位到根因：

   ```cpp
   OperationStatus Snapshotter::save(bool isOnExit, const char* name) {
       CrashReporter::get()->hangDetector().pause(true);
       ...
       mVmOperations.snapshotSave(name, this, nullptr);   // ← 崩在这一句
   ```

   `mVmOperations` 是一张**函数指针表**（`host-common/vm_operations.h` 的 `QAndroidVmOperations`），
   在官方构建里由 **`android-qemu2-glue/qemu-vm-operations-impl.cpp`** 注册
   （`Snapshotter.cpp:263` 的 `mVmOperations = vmOperations;`）。
   我们为了不拖进 gRPC/前端而没编那个文件 → 表全空 → 调用即 pc=0。

   同一个原因在启动阶段也咬过一次：`FeatureControlImpl::init()` 调
   `getConsoleAgents()->settings->hw()`，而我们的 agent 表当时只填了 `avdInfo`
   → 也是 pc=0。**现在 agent 表里 38 个函数指针全部填了安全实现**（见
   `vmhost_snapshot_glue.cpp`），这一类"空函数指针"问题只剩 `mVmOperations` 这一处。

**下一步（就差这最后一块）**：在我们的 glue 里实现一张最小的 `QAndroidVmOperations`
并注册给 Snapshotter：

- `snapshotSave(name, snapshotter, saveCompatible)` → 调 QEMU 侧 `save_snapshot(name, &err)`
- `snapshotLoad(name, snapshotter, loadCompatible)` → `load_snapshot(name, &err)`
- `setSnapshotCallbacks` / `setSnapshotProtobuf` / `setExiting` / `setFailureReason` → 记下或 no-op
- `vmStop` / `vmStart` / `vmIsRunning` / `vmReset` → 映射到 QEMU 的 `vm_stop` / `vm_start` / `runstate_is_running`
- `snapshotList` / `snapshotDelete` / `snapshotRemap` / `snapshotExport` / `snapshotLastLoaded`
  → 最小实现（删除快照要真的删目录，其余返回空/失败即可）
- 其余（`mapUserBackedRam`、`hostmem*`、`setDisplay`、音频那批）→ 走 QEMU 侧既有实现或 no-op

然后在 `vmhost_snapshot_save/load()` 里，调 `Snapshotter` 之前先
`Snapshotter::setVmOperations(ops)`（或等价的注册入口），再重跑
「停机 save → 启动 load」的真机验证。

### 8.5 继续推进后的实测（2026-10-17 当天）

做完 §8.4 说的那块之后：

- **`vmhost_vm_operations.cpp` 已实现并注册**：`Snapshotter::initialize(ops, windowAgent)`
  在第一次 save/load 前调用；`snapshotSave/load` 转发到 QEMU 的
  `save_snapshot()/load_snapshot()`；`setSnapshotCallbacks` **已按操作分组
  （save/load/del）转发到 QEMU 的 `qemu_set_snapshot_callbacks()`**；
  `setSnapshotProtobuf` 转发到 `qemu_set_snapshot_protobuf()`。
- 真机验证：**新二进制照常启动并 boot 到 `boot_completed`**（544s），停机时引擎
  走到 save，日志打出 `快照已保存`，`snapshot.state` 也写出来了。
- **但快照目录是空的**，而且整个 save 只花了 ~100ms —— 说明真正的 RAM 落盘没发生。

原因已经定位清楚，是**第二处只由前端注册的东西**：

| 缺的东西 | 谁提供 | 后果 |
|---|---|---|
| `migrate_set_file_hooks(&sSaveHooks, &sLoadHooks)` | `android-qemu2-glue/qemu-vm-operations-impl.cpp:667/731`（我们没编这个文件） | QEMU 的 `qemu_savevm()` 退化成"写快照块设备"的老路径；我们的盘全是 `format=raw`，`bdrv_all_find_vmstate_bs()` 直接找不到设备 → 什么都没写 |

还有一个**我们自己的坑**要一起修：`Snapshotter::save()` 在 `mSaver == nullptr`
时按源码注释是"trivially succeed"，所以上面那次失败被报成了成功。我们的
C ABI 包装必须**自己校验结果**（例如 save 之后检查
`<dataDir>/snapshots/<name>/` 里确实出现了非空文件），不能只信返回码。

**下一步（就这两件）**：

1. 把 `qemu-vm-operations-impl.cpp:667-800` 里的 `sSaveHooks` / `sLoadHooks`
   （aemu 的 `QEMUFileHooks`：把 save/load 流交给 aemu 的 RamSaver/RamLoader）
   搬进 `vmhost_vm_operations.cpp`，并在初始化时调一次
   `migrate_set_file_hooks(&sSaveHooks, &sLoadHooks)`。
2. 在 `vmhost_snapshot_save()` 里加"落盘校验"：目录里没有非空文件就返回失败，
   让引擎如实报错、并让"坏快照自动回退"那条护栏真正起作用。

---

## 8.6 做完上面两件后又挖出三个真问题（2026-10-17）

**① 引擎把 HMP 的失败当成了成功。**
`human-monitor-command` 的失败是**文本**形式回来的：QMP 信封仍是
`{"return": "vmhostsnapshot: save 'x' failed: ..."}`。引擎原来只看 QMP 信封，
于是 glue 明明返回了失败，引擎还是写下 `snapshot.state` 并打印"快照已保存"
（盘上什么都没有）。现在 `snap_try_save()` 和 load 线程都会检查返回文本里的
`failed`。**这是"假成功"的真正来源。**

**② QEMU 的 `savevm` 需要一块"支持快照"的块设备，而我们的盘全是 raw。**
`bdrv_all_find_vmstate_bs()`（`block/snapshot.c:547`）只认 `bdrv_can_snapshot()`
为真的设备（qcow2 这类）。官方模拟器是靠 `android-qemu2-glue/drive-share.cpp`
把镜像转成 `*.qcow2` overlay 才满足这个前提；我们直接挂 raw，于是
`qemu_savevm()` 一开头就 "No block device can accept snapshots" 返回。

解法（已落地）：给快照专挂一块小的 qcow2。

- `vm/app/src/main/assets/vmstate.qcow2`：宿主机 `qemu-img create -f qcow2` 造的
  **512MB 虚拟大小**空镜像（实际 ~190KB；qcow2 与架构无关，设备端可用）。
- `VmDiskStore.ensureVmstate()`：实例缺这块盘时从 assets 复制；
  `VmLauncher.start()` 在拉起实例前调用（失败不阻断启动，只是快照不可用）。
- 引擎 `vm_qemu.c` 增加
  `-drive if=none,id=vmstate,file=<dataDir>/vmstate.qcow2,format=qcow2`。
  **注意 QEMU 不会自己创建 qcow2 文件** —— 文件不存在时直接
  `Could not open ...: No such file or directory` 并退出（实测），所以必须先复制模板。

真机验证：加上这块盘之后 **QEMU 能正常启动、guest 正常 boot**（不再启动即退）。

**③ load 路径的 socket 竞态。**
引擎在 spawn QEMU 之后立刻去 load，可能连到上一次运行残留的 `qmp.sock` ——
`connect()` 成功、紧接着 `write` 就失败（EPIPE），一次就放弃会让恢复永远失败。
现在：spawn 前 `unlink(qmp.sock)`；load 线程对连接与请求做最多 8 次重试（每次重连）。

## 8.7 当前状态（2026-10-17）

- 代码链路**已经完整**：QEMUFileHooks / VmOperations / 回调转发 / qcow2 vmstate 盘 /
  落盘自检 / 重试，全部实现，`build_qemu_aosp.sh` exit=0。
- 真机已验证到：**带 vmstate 盘的 QEMU 能启动、guest 能 boot**。
- **最后一步还没验证完**：save 是否真的写出 `ram.bin`、load 是否秒开 ——
  正要验证时测试机 USB 掉线（`adb devices` 为空），需要重新连上设备再跑一次。

---

## 8.8 真机端到端结果（2026-10-17，设备恢复后）

### ✅ save 已经打通

```
快照已保存：/data/user/0/com.vm.app/files/vms/vm_1/snapshot.state
snapshots/default_boot/
  ram.bin        488,218,441   ← guest RAM 真的落盘了
  snapshot.pb            145   ← 快照元信息
  textures.bin            16
  hardware.ini / compatible.pb  0
vmstate.qcow2    196,616 → 983,040   ← VM state 写进了 qcow2
```

一路上靠三件事才走到这里（都已在正文记过）：
`bdrv_all_can_snapshot()` 跳过 raw 盘（`patch_snapshot_skip_raw`）、
qcow2 vmstate 盘、以及 `windowAgent().getRotation()` 等三个窗口指针补全。

### ⚠️ load 卡在 `goldfish_pipe` 的设备状态

```
快照恢复失败（rc=1）：
  error while loading state for instance 0x0 of device 'goldfish_pipe'
  Error -5 while loading VM state
  Snapshotter::load('default_boot') failed: error (2)
```

**注意：guest RAM 是恢复成功的** —— 失败后引擎按设计发 `cont` 放行，console 里
guest 时间直接是 108.9s（快照里的时间点），说明内存镜像确实被灌回去了；
挂掉的只是 pipe 设备那一小段状态。

根因方向（与仓库里 `build_qemu_aosp.sh` 那条被撤销的 `patch_goldfish_pipe_savevm`
注释一致）：`goldfish_pipe_load_v2()`（`hw/misc/goldfish_pipe.c:1662`）一开头要把
快照里记录的 `signalled_pipe_buffer` / `open_command` 用
`map_guest_buffer()`（内部 `cpu_physical_memory_map`）映射回宿主地址空间，
映射失败就直接 `-EIO` 退出整次恢复。这些缓冲区是**宿主侧 pipe 服务**持有的对象，
跨进程恢复时拿不到。

**下一步两条路**（都还没做）：

1. **让 pipe 状态"可失败"**：在 `goldfish_pipe_load_v2()` 里，映射失败时不要
   `return -EIO` 终止整次恢复，而是把 pipe 设备置为"无管道"的干净状态并返回 0，
   让 guest 侧驱动重新建立管道。改动小，风险是 guest 对"管道凭空消失"的容忍度。
2. **按模拟器的做法恢复 pipe 状态**：官方 quickboot 里 pipe 状态是可迁移的，
   它依赖宿主 pipe 服务在恢复时把 guest 缓冲区重新挂上（对应
   `mapUserBackedRam`/地址空间设备那套，我们已经接了 `qemu_user_backed_ram_map`，
   但显然还有一环没对上）。改动大，但语义正确。

**当前产品行为**：load 失败 → 删标记 + 放行 guest → **退回冷启动**，
app 照常可用（只是没有"秒开"）。所以"装 APK 直接用"这一条是成立的。

---

## 8.9 pipe 状态按模拟器做法恢复 + load 真正跑通（2026-10-17 晚）

### 根因：glue 里的六个 pipe 钩子是空桩

8.8 里猜的"跨进程拿不到宿主缓冲区"不是根因。真正的原因是
`qemu_patches/vmhost_pipe_glue.cpp` 的 `GoldfishPipeServiceOps` 里，
`guest_pre_load / guest_post_load / guest_pre_save / guest_post_save /
guest_load / guest_save` **六个回调全是空实现**（`guest_load` 直接
`return nullptr`）。QEMU 设备侧 `goldfish_pipe_load_v2()` 拿到
`host_pipe == NULL && force_close == 0`，只能按失败处理 → `-EIO` →
整次恢复失败。诊断打印能直接对上：

```
VMHOSTPIPE_LOAD dev_v=2 drv_v=4 sig_size=64 sig_addr=0xf99f3010   ← 两个 map 都成功
VMHOSTPIPE_LOAD open_cmd_addr=0xf99f3000
VMHOSTPIPELOAD service=[QemuMiscPipe] found=1                      ← aemu 侧找到了 service
VMHOSTPIPE_LOAD2 pipe id=0 has_host=1 host_pipe=0x0 force_close=1  ← 空桩的锅
```

### 修法（照抄官方 `android-qemu2-glue/emulation/android_pipe_device.cpp`）

`QEMUFile*` 包成 `android::qemu::QemuFileStream` 再转交 aemu 的
`android_pipe_guest_*`。两个版本差异要注意：

1. **`Stream*` 有两套**。aemu 的 C 头（`android_pipe_device.h`）用的是
   `aemu/base/utils/stream.h` 里那个**不透明的 `::Stream`**，而 `QemuFileStream`
   派生自 C++ 的 `android::base::Stream`。两边指向同一对象，靠
   `reinterpret_cast<::Stream*>(&stream)` 互转即可 —— aemu 自己的
   `base/CStream.cpp:asBaseStream()` 和 `HostGoldfishPipe.cpp` 的 `cStream`
   都是这么做的。上游新版有 `asCStream()` 这个 helper，我们这版没有，所以
   glue 里自带了一个 `vmhost_as_c_stream()`。
2. `dma_save_mappings` / `dma_load_mappings` 同样要接
   （`android_goldfish_dma_ops.save_mappings(&stream)`，这两个接口收的是
   `android::base::Stream*`，不用转）。

编译上要给 glue 补 `-I$SRC_DIR/android-qemu2-glue`（找
`base/files/QemuFileStream.h`）、`-I$PROTO_GEN_DIR`、`-I$PROTOBUF_INCLUDE_DIR`、
`-I$ABSEIL_DIR`（`QemuFileStream.cpp` 会经 aemu 的 `Log.h` 拉 absl），并把
`QemuFileStream.cpp` 单独编成 `.o` 一起链。

### load 跑通，但恢复完是暂停态

修完立刻见效：

```
VMHOSTPIPELOAD service=[QemuMiscPipe] found=1
VMHOSTPIPE_LOAD2 pipe id=0 has_host=1 host_pipe=0x0 force_close=1   ← 官方语义：该 service 不可迁移，强制关闭
已从快照恢复（default_boot）
```

`force_close=1` 是**正常路径**：aemu 的 `AndroidPipe::loadFromStream()` 对
"服务不支持保存状态"的管道就是返回 NULL + `force_close=1`，QEMU 设备侧据此
把这条 pipe 关掉，guest 驱动重新建连。guest console 里会看到
`goldfish_pipe ... backend error -4 on read`（被强制关闭的那条），随后
qemud 自己重开（宿主侧能看到 `qemud_create` / `send` 继续工作）。

但恢复完 **guest 不动**：QEMU CPU 0%、`console.log` 不再增长。原因是
`load_snapshot()`（`migration/savevm.c`）只在「load 之前 VM 已经在跑」时才
自己 `vm_start()`（`saved_vm_running` 分支），而我们是拿 `-S` 起的 QEMU，
这条不成立。引擎侧 `snap_load_thread` 原来只在**失败**分支发 `cont`，现在
成功分支也补一发（同一套重连/重试），日志是 `快照恢复后已放行 guest`。

### 实测时间

```
12:12:32.228  QMP 已连接
12:12:34.430  已从快照恢复（default_boot）
12:12:34.431  快照恢复后已放行 guest
12:12:48      qemu 进程 CPU 118%，console.log 在增长
```

即 **QEMU 起来到 guest 开始跑大约 3 秒**（对比冷启动 150s+）。

### ⚠️ 还没解决：guest 完全启动后 save 会卡死

- guest 只启动 2.5 分钟（RAM 非零页 512MB）时 save **2.4 秒完成**，
  `on_end done`，`ram.bin/snapshot.pb/textures.bin/vmstate.qcow2` 全都对。
- guest 完全启动（`sys.boot_completed=1`，RAM 非零页 1.31GB）时 save 卡住，
  HMP 180s 超时、引擎按设计杀进程，快照作废（ram.bin 只有半截）。
- 加了 `patch_savevm_diag` / `patch_savevm_tail_diag` 两层探针后定位到：

```
VMHOSTSNAP ram_save_complete: before FINISH
VMHOSTSNAP savingComplete rc=0          ← aemu 的 RamSaver::join() 正常返回
VMHOSTSNAP ram_save_complete: after FINISH   ← 之后就没输出了
```

`ram_control_after_iterate(f, RAM_CONTROL_FINISH)` 之后只剩
`rcu_read_unlock()`（`util/rcu.c:408`，无锁，不会阻塞）和
`qemu_put_be64(f, RAM_SAVE_FLAG_EOS)`。后者在 QEMUFile 缓冲满时会走
`qemu_fflush` → `bdrv_pwritev` 写 vmstate.qcow2。二级探针就是为这一步加的，
下一次复现（冷启动到 boot_completed 约 13 分钟）就能确认到底是 EOS 的 flush
还是更后面的 `qemu_savevm_state_cleanup()`。

**当前产品行为**：这条不影响"能装 APK 直接用"——冷启动照常，启动中途/早期
保存的快照也能秒开；只有"完全开机后保存"会失败并回退冷启动。

---

## 8.10 完全开机后保存/恢复全部打通（2026-10-17 深夜）

8.9 剩下的那个"完全开机后 save 卡死"有两个独立原因，都已经修掉。

### 原因一：渲染线程从没被暂停过

探针把范围收窄到 `goldfish_pipe` 设备里**第 2 条 pipe**（`svc=opengles`）的
`guest_save`。链子是：

```
EmuglPipe::onSave → RenderChannelImpl::onSave → RenderThread::save
                  → waitForSnapshotCompletion()   ← 死等 mState == Finished
```

`mState` 只有在 `pausePreSnapshot()` 被调过之后才会走到 `Finished`。而
`pausePreSnapshot()` 的调用者是 `RendererImpl::pauseAllPreSave()`；本版
gfxstream 把这一步从 ASG（地址空间图形）挪到了 virtio-gpu 的
`stream_renderer_snapshot_presave_pause()`，**而我们的移植没有接那条
virtio-gpu 钩子**（`nm` 里连符号都没有）。设备保存顺序里
`goldfish_address_space` 在 `goldfish_pipe` 之前，但 ASG 的
`globalPreSave()` 在 aemu 里被注释掉了：

```cpp
    void preSave() {
        // mConsumerInterface.globalPreSave();      ← 官方新版注释掉了
    }
```

于是 opengles 管道的渲染线程从没被暂停，`waitForSnapshotCompletion()` 只能
死等 —— 实测 9 条渲染线程全部超时（`state=0`，即 `Empty`），整次 save 多花
45s，早期版本更是直接顶到 HMP 的 180s 超时、快照作废。

**修法（两层）**：

1. `build_aemu.sh` 里的 `patch_aemu_graphics_global_presave`：把那一行恢复成
   `mConsumerInterface.globalPreSave();`（→ `pauseAllPreSave()`）。地址空间
   设备保存时统一暂停渲染器；resume 仍由 opengles pipe 的 `postSave →
   resumeAll()` 负责 —— **`globalPostSave` 必须保持注释**，否则放行会早于
   随后 goldfish_pipe 里对 opengles 管道的保存，又回到死等。
2. `build_gfxstream.sh` 里的 `RenderThread::waitForSnapshotCompletion` 加 5s
   超时兜底（`VMHOST_SNAP_TIMEOUT`）。渲染线程万一真的卡在某次 GL 调用里，
   超时后按"没有渲染线程状态"降级（`save()` 写 0，`RenderThread` 的
   load 侧本来就把 0 当"没有状态、直接退出"），而不是让整次 save 挂死。

### 原因二：空名字的匿名 RAMBlock

修完上面那条，save 能完整跑完（`on_end done`、`snapshot.state` 也写了），
但**恢复**报：

```
Unknown ramblock "", cannot accept migration
error while loading state for instance 0x0 of device 'ram'
```

完全开机的 guest 里，gfxstream/gralloc 会创建一批 **idstr 为空**的
user-backed RAMBlock（`VMHOST_RAMBLOCK id= host=0x... used=3690496`，6 个
3.5MB + 4 个 8KB）。它们被写进 RAMBlock 名单，恢复时
`qemu_ram_block_by_name("")` 必然查不到 → 整次 load 失败。它们是宿主侧重建的
临时共享区，本来就不该进快照。

**修法（两边对称）**：

1. 保存侧（`vmhost_vm_operations.cpp`）：`ramOps.registerBlock` 遇到空名字的
   block 不注册给 aemu，并把"注册过的 block offset"记下来；
   `vmhost_ram_save_page` 对不在表里的 block 直接丢弃该页（仍然返回
   `RAM_SAVE_CONTROL_DELAYED` + `bytes_sent=size`，即"这页我处理了"）。
   这一步必须做：aemu 的 `RamLoader::readIndex()` 是按**顺序**读索引、按名字
   匹配的，保存侧多注册一个块就会让后面全部错位。
2. 恢复侧（`build_qemu_aosp.sh` 的 `patch_ram_load_skip_unknown`）：
   `ram_load` 的 `RAM_SAVE_FLAG_MEM_SIZE` 分支里，查不到的块**跳过并告警**，
   不再 `ret = -EINVAL` 终止整次恢复。

### 实测结果

```
完全开机（sys.boot_completed=1，RAM 非零页 1.3GB）后停机保存：
  VMHOSTSNAP complete_precopy done
  VMHOSTSNAP qemu_savevm_state done ret=0
  VMHOSTSNAP qemu_fclose done size=451796
  VMHOSTSNAP bdrv_all_create_snapshot ret=0
  VMHOSTSNAP on_end done
  快照已保存：…/vm_1/snapshot.state
  ram.bin 1.31GB / snapshot.pb / textures.bin / vmstate.qcow2 983,040 全齐
```

**结论：冷启动 → 完全开机 → 保存 → 秒开恢复这条主链路已经完整。**

### 最后一步提速：没被暂停过的渲染线程不等

上面第 1 条（aemu `globalPreSave`）在真机上没能让 opengles 管道的渲染线程真的被
暂停 —— 9 条线程的 `mState` 仍然是 `Empty`，于是每条白等 5s 超时，整次 save
46s。与其继续追"为什么 pauseAllPreSave 没覆盖到它们"，这里做了一件更稳的事：

`RenderThread::save()` 入口先看 `mState`：

```cpp
        if (mState == SnapshotState::Empty) {
            /* 没被 pausePreSnapshot() 碰过 → 永远等不到 Finished，
               直接按"没有渲染线程状态"降级（写 0）。 */
            success = false;
        } else {
            waitForSnapshotCompletion(&lock);
            success = mState == SnapshotState::Finished;
        }
```

配合 5s 超时兜底（真的被暂停过但卡在 GL 调用里时用），语义上是干净的：**没暂停
= 状态不一致 = 不保存**，load 侧本来就把 0 当"无状态、渲染线程直接退出"。

最终真机数字（同一时钟域，logcat 时间戳）：

```
保存：14:07:07.829 收到停机 → 14:07:09.743 快照已保存     ≈ 1.9s
      （ram.bin 1.33GB，9 条渲染线程全部走"未暂停直接跳过"，0 次超时）
恢复：14:07:57.821 QEMU 拉起 → 14:08:01.288 已从快照恢复  ≈ 3.5s
      → 立刻放行 guest，qemu 进程 CPU 103%，console.log 继续增长
      （冷启动同样内容要 ~13 分钟）
```

---

## 8.11 让"秒开"真的等于可用：渲染器状态 + 日志洪泛（2026-10-17 收尾）

8.10 之后恢复是"能跑"了，但还有三处**看起来能用、实际上废**的问题，全部修掉。

### 问题一：qemu-stderr.log 一天能写 10GB

`vm_qemu.c` 里 `setenv("VMHOSTPIPE_SVC", "1", 1)` 是当年定位"访客 EGL 连不上
宿主"留下的调试开关，**一直开着**：它是每次 recv/send 打一行，只要有一条 pipe
在轮询就会疯长 —— 实测 570 万行 / 190MB，约 120KB/s。

同类还有两处更凶的：

| 日志 | 来源 | 量级 |
|---|---|---|
| `VMHOST_GLES1_OP` | gles1 解码器，**每个 GLES 包一行** | 2.5 分钟 10 万行 |
| `VMHOST_GLES2_LOWFREQ` | gles2 解码器，"低频"调用 | 2.5 分钟 11 万行 |
| `VMHOST_MUTEXDBG` | libsigfix 的 mutex 追踪，每条 destroy 还带 dladdr 符号解析 | 2.5 分钟 3 万行 |

**修法**：三处各自加运行时开关，**默认关**；引擎按属性导出环境变量：

```
setprop debug.vmhost.pipe_log  1   → VMHOSTPIPE_SVC
setprop debug.vmhost.gles_log  1   → VMHOST_GLES_LOG（gles1 + gles2 逐包打印）
setprop debug.vmhost.mutex_log 1   → VMHOST_MUTEX_LOG
```

改完实测：冷启动全程 `qemu-stderr.log` 从 35MB+ 降到 **14KB**。

### 问题二：地址空间设备状态根本没进快照

官方的 `android-qemu2-glue/emulation/android_address_space_device.cpp`（71 行）负责把
aemu 的地址空间设备状态挂到 QEMU 设备的 save/load 回调上。本移植没编这个文件，
于是 `goldfish_address_space_set_service_ops()` 从来没人调，后果有两个：

1. 快照里没有 ASG（地址空间图形）上下文/渲染线程状态；
2. `AddressSpaceGraphicsContext::globalStatePreSave()` 不会被调用 →
   `RendererImpl::pauseAllPreSave()` 也不跑 → opengles 管道的渲染线程从没被
   `pausePreSnapshot()` 碰过（`mState` 恒为 `Empty`）→ 状态只能降级成"无状态"。

**修法**：在 `vmhost_pipe_glue.cpp` 里照官方那个文件接上
`goldfish_address_space_set_service_ops()`（save/load 两个回调，用 `QemuFileStream`
桥接；struct 布局与 `include/hw/pci/goldfish_address_space.h` 的
`GoldfishAddressSpaceOps` 一致，为免拉 QEMU 头这里本地声明）。
接上之后渲染线程**全部正常暂停**（"未暂停降级"与"超时"计数都归零）。

### 问题三：我们自己注册的两个 service 不支持快照 → 管道被强关

恢复日志里 25 条管道有 4 条 `force_close=1`，正是我们注册的
`QemuMiscPipe` 与 `qemud`：它们没实现 `canLoad()`，aemu 的
`AndroidPipe::loadFromStream()` 对 `canLoad()==false` 的服务一律
`*pForceClose = 1`（设备侧随后把这条管道标记为 closed）。
guest 的客户端不知道宿主已经把管道关了，继续读写 → 设备返回
`GOLDFISH_PIPE_ERROR_IO`(-4) → guest 内核日志里
`goldfish_pipe ... backend error -4 on read/write` 每 10 秒刷一批，客户端空转。

**修法**：两个 service 都加 `canLoad() == true` + `load(hwPipe, args, stream)`，
按 `args` 重建管道（客户端标识都在 args 里，随管道一起存/取；管道本身没有需要
跨快照保留的状态）。这与官方 `AndroidMessagePipe::Service` 的语义一致。
改完 `force_close` 归零、guest 的 `backend error` 归零。

### 问题四：渲染器全局状态没进快照 → 恢复后每条 GL 命令都打在空上下文上

即使上面三条都修好，恢复后 guest 的 GL 依然是废的：

```
GLESv2Imp.cpp:glDrawArrays:1601 error null ctx
FB::flushEmulatedEglWindowSurfaceColorBuffer: window handle 0x9 not found
FrameBuffer.cpp:3371: Failed to find process owned resources for puid 4294967295
```

实测恢复后 5 分钟刷出 **18 万行 / 30MB**，guest 界面等于黑屏，直到它自己把图形
栈重启（十几分钟后才恢复）。

根因：**渲染器全局状态**（EGL 上下文 / window surface / color buffer）没有进快照。
官方 emu 树里这段是活的 —— `android/android-emu/android/opengl/OpenglEsPipe.cpp`
的 opengles service：

```cpp
        void preSave(Stream* stream) override {
            if (const auto& renderer = android_getOpenglesRenderer()) {
                renderer->pauseAllPreSave();
                stream->putByte(1);
                stream->putBe32(OPENGL_SAVE_VERSION);
                renderer->save(stream, Snapshotter::get().saver().textureSaver());
            } else {
                stream->putByte(0);
            }
        }
        void preLoad(Stream* stream) override {
            const bool hasRenderer = stream->getByte();
            ...
            renderer->load(stream, Snapshotter::get().loader().textureLoader());
        }
```

而我们构建用的 gfxstream 版同名文件**把这段注释掉了**（新架构改由 virtio-gpu 的
`stream_renderer_snapshot_*` 钩子触发，但那些钩子在本移植里没有任何调用方，
`grep -rn stream_renderer_snapshot_save` 只命中 end2end 测试）。

**修法**：`build_gfxstream.sh` 的 `patch_opengles_renderer_snapshot` 把这段接回去
（不搬 `writeScreenshot`）。为此给 gfxstream 构建补了 shim：
`android/snapshot`、`android/base`、`android/{avd,utils,...}`、`absl`、
protobuf 生成头、`lz4.h` —— 那些 snapshot 头会一路拉到 aemu 的 logging/protobuf/lz4。

### 全部修完后的实测（2026-10-17 15:58）

```
冷启动（guest 自带 ANR/低内存，启动偏慢）→ 保存 → 恢复：

保存：15:55:13 收到停机 → 15:55:14.259 快照已保存    ≈ 1.3s
      （ram.bin 1.37GB + textures.bin 213KB + vmstate.qcow2；渲染器状态）
      VMHOSTSNAP renderer preSave: pause=0ms save=20ms
      VMHOSTSNAP renderer postSave: resume=0ms
恢复：15:58:17.669 QEMU 拉起 → 15:58:21.344 已从快照恢复 ≈ 3.7s

恢复后 30 秒 / 2 分钟两次采样，全部为 0：
  GL 空上下文报错（error null ctx）        0   （修前 5 分钟 18 万行）
  窗口/资源报错（process owned resources） 0   （修前 8.8 万行）
  guest 侧 goldfish_pipe backend error -4  0
  被强制关闭的管道（force_close=1）        0   （修前 4 条）
  qemu-stderr.log 大小                    13KB（修前 190MB+ / 一天 10GB）
```

**结论**：现在"秒开"是真的可用 —— 恢复 3.7 秒、渲染器状态完整、guest 侧无报错、
日志不再疯长。诊断开关全部改成 `setprop debug.vmhost.{pipe,gles,mutex}_log 1`
才打开，默认干净。

## 8.12 完全开机快照复核（2026-10-18，验证进行中）

本节补充 8.10/8.11 的验收条件：仅有 load 返回成功、console 增长以及四类
GL/pipe 错误为零，不能证明图形恢复可用。还必须检查
`fail loading a RenderThread`、渲染线程保存超时，以及恢复后的新帧和输入响应。

首次复核沿用设备原有保存点，没有回滚 userdata、覆盖 vmstate 或清理快照。
完全开机快照 load 耗时 1.8 秒；cont 后 console 继续增长，超过两分钟采样未出现
GL 空上下文、窗口资源、pipe backend -4、force_close 错误，但出现 **11 条
`fail loading a RenderThread`**，本次不计为可用恢复。
证据：`dist/boot-optimization/snap-full-first-load-{console.log,qemu.err,qemu.out}`。

代码复核发现 ASG globalPreSave 与 opengles preSave 都会调用
`pauseAllPreSave()`。原 `RenderThread::pausePreSnapshot()` 无条件重建 mStream、
重置状态为 StartSaving；第二次调用可能破坏已经完成或正在保存的状态。
`build_gfxstream.sh` 增加 `VMHOST_SNAP_PAUSE_ONCE` 补丁：非 Empty 状态直接返回。
此修改的真机保存耗时及恢复效果尚待后续采样确认。

App 停机改为先执行 `NativeActivity.onDestroy()`，等 native android_main 保存并退出
后再停止实例前台服务，保持保存期间的服务与 WakeLock。原先先 stopService 的顺序
存在保存期间被降级的窗口；这与零字节 ram.bin 的历史现象相符，但不能单凭历史
截断日志断言当时一定由系统回收导致。另外，成功 load 后在 cont 前消费
snapshot.state，保存跳过或失败时也不保留旧标记，防止下次把旧 RAM 与已经推进的
磁盘配对。QMP stop/cont 仅在返回 0 时判成功。

本机另有独立的锁屏干扰：实例服务 isForeground=true 时，厂商系统仍可能把
`/sys/fs/cgroup/apps/uid_10341/pid_<app>/cgroup.events` 置为 `frozen 1`，
`dumpsys power` 同时显示 `youlong:vm-instance DISABLED`。因此前台服务不能保证
厂商锁屏策略下仍在执行。测试期间解锁并临时保持接电亮屏；测试结束恢复原设置。
不修改安全锁，不把临时锁屏显示标志留在交付源码。

09:43 的 App 退出复核发现另一独立缺陷：native 在 2ms 内记录保存成功，
而同期手工 QMP 保存需要 6.14s。输入注入为 fire-and-forget，同一个 QMP socket
可能残留其应答；原 vm_qmp_request 把下一条非 event 消息直接当作本次应答，
因此 stop/save 可以提前返回并让引擎杀掉尚未保存完成的 QEMU。该次错误标记已
移除，没有尝试加载。修复为同步请求生成唯一字符串 ID，只接收同 ID 回复。
`vm/engine/tests/test_qmp_protocol.py` 通过 Linux/WSL 编译实际 C 客户端，使用
本地假 QMP 服务验证遗留输入回复、错误 ID、迟到回复与真正错误的区分。

另补历史证据：系统日志 01:00:55.721 取消实例 FGS 通知，01:00:56.193
以 SwipeUpClean force-stop 整个包，随后杀掉 :vm1 及 QEMU 子进程。
原始片段见 `dist/boot-optimization/app-historical-swipe-kill.log`。
保留 FGS 的修改针对正常退出期间的降级窗口，不承诺能抵抗厂商显式 force-stop。

### 请求 ID 修复后的阶段结果（尚未通过图形验收）

09:59 正常退出：native 收到销毁 09:59:22.683，真正保存完成 09:59:27.433，
耗时 **4.75s**；QEMU 随后正常退出。轮询记录显示保存期间实例服务一直
`isForeground=true`。ram.bin 更新为 1,332,395,353 字节、textures.bin 213,548
字节，vmstate 与 snapshot.pb 均在同一保存时刻更新。重启到新帧 **4.719s**，
没有 `fail loading a RenderThread` 或逐线程保存超时。

重复保存的计时：renderer preSave pause=0ms/save=38ms，postSave resume=0ms，
说明原先逐线程 5 秒等待已消除。但恢复后出现纯 GLES 线程反复查询 Vulkan
ProcessResources 的错误日志。该指针只用于 VkDecoder，修复为只有 m_vkInfo 存在
才查表。更新后的恢复到新帧 5.344s，当前 QEMU 进程的上述四类 GL/pipe 错误、
窗口句柄错误、渲染线程加载失败和保存超时均为 0。

**不能据此宣布可用秒开**：冷启动帧含 `Phone is starting...` 文字，恢复帧只有
活动进度条，文字缺失，仍在调查纹理/显示状态。连续十轮“无黑屏且输入可用”验收
尚未执行。诊断构建在 SaveableTexture::getTexImage 记录前 64 次纹理读回的
尺寸、格式及所用读回路径，避免逐帧日志。已从当前磁盘重新冷启动采样，没有
回滚 userdata 或用 vmstate 模板覆盖保存文件。

注意 App 的 console.log **和 qemu-stderr.log 都是追加写入**。console 按最后一次
`Linux version` 截取本轮冷启动；stderr 按最后一次 `VMHOST_PIN` 启动边界截取本轮
QEMU。不能直接统计整个文件，否则会把旧版错误带进新一轮验收结果。
阶段证据均在 `dist/boot-optimization/app-id-fixed-*`、`app-vk-*` 及
`texture-read-diagnostic-save.txt`（dist 被 gitignore，不随提交分发）。

### 缺字定位与 GLES 纹理读回（验证进行中）

10:24 从当前磁盘冷启动至 boot_completed 后重新保存，耗时 6.657s（包含
轮询）；新保存点包含 GL_ALPHA 128×1、1024×1024 纹理。暂停加载耗时
2.781s，尚未 cont 时最后一帧文字完整；cont 后 5 秒文字消失。证据：
`texture-fresh-probe.txt`、`probe-before-cont.png`、`probe-after-cont-5s.png`。

本机 GLES 没有 glGetTexImage；SaveableTexture 原实现直接把 Alpha/Luminance
纹理挂到 FBO 并 glReadPixels。Adreno 真机探针确认这些格式的 FBO 不完整，
读回报 GL_INVALID_FRAMEBUFFER_OPERATION，RGBA/RGB 则正常。
新增 `qemu_patches/vmhost_snapshot_texture.h`，在 ES3 宿主上下文中把
2D、level 0、UNSIGNED_BYTE 的 Alpha/Luminance/Luminance+Alpha 纹理
采样到 RGBA，再取回原格式分量，并恢复修改的 GL 状态；快照格式不变。
编译/链接或读回失败时停止保存进程，不发布成功标记。

`tests/test_snapshot_texture.cpp` 直接使用同一 helper 在真机离屏 EGL 上验证：
7×5 非对齐宽度、逐字节变化的三种输入均完整读回，裁剪/颜色写入状态还原，
GL error=0，三项 PASS。完整 App 冷启动→保存→恢复字体与十轮回归仍待验证。

构建可重复性补充：此前构建树里的 VMHOST_MIG_ZERO / VMHOST_MIG_ZERO_LOAD
没有进入仓库脚本。现在由 `qemu_patches/patch_snapshot_mmio.py` 在保存与加载
两端一致排除无 host 内存的设备地址空间，实际内容仍由图形/地址空间钩子处理。
已验证干净 QEMU 源码锚点、重复应用幂等，以及对本机既有补丁不产生二次修改。

10:44 的 App 完整开机保存约 6.719s，候选包重启首帧 5.359s；但运行后仍缺字，
**Alpha 读回修复尚不足以通过图形验收**。解析 TextureSaver 的 LZ4 流后确认
1024×1024 atlas 含 1398 个非零像素，且保存→恢复→再次保存的原始字节
SHA256 均为 `14afe17b997cea1baa388c0356bfb1a9cb1f846415f6d51445e46f925f29e5a4`。
即字体内容现已正确保存/恢复，还需定位绘制程序或上下文状态。新增有界的
ProgramData 恢复诊断，打印链接结果、源码长度和 uniform 参数，验证进行中。
此外 GLES translator 的 glFramebufferTexture2D 0x502 / glReadPixels 0x506
在本轮冷启动也存在，不能把它们误记为加载后才新增；原四类计数不覆盖此类错误。

11:03 在真实桌面（Gallery/F-Droid 图标、名称和 Google 搜索栏均完整）保存，
正常退出约 7.438s。新增窗口像素恢复探针后，首次 load 在 stale window 的
ColorBuffer 查找处崩溃，尚未 cont，故磁盘仍对应原保存点；只补回 marker 后重试。
原因是窗口 33 仍引用已关闭的 ColorBuffer 34，drawCtx/readCtx 均为 0。
release 版本的 assert 不保护空查找结果。现在显式空指针判断，将此窗口恢复为
未附加 buffer；窗口像素恢复分支仍需实际绘制验证，不能据此宣布缺字完全解决。

15:38 修复版真实 App 加载桌面首帧 4.641s，桌面文字/图标完整，八项已列错误
均为 0。但接着十轮测试的第一次 stop 没有保存：原“最近 10 秒必须有新帧”
判断把静止桌面误认为显示未初始化。改为本次运行至少收到过一帧，并在
vm_frame_relay_set_dir 中清零时间戳。此次 guest 已经 cont，不能重新配对旧 RAM；
15:40 起保留当前 userdata/vmstate，重新冷启动建立保存点，未恢复基线或删除快照。
十轮回归尚未通过，不得以恢复首帧替代完整验收。

最终候选移除未证明必要的窗口像素填充和 VAO 修改，以及 texture/program
诊断输出；窗口补丁仅保留对已关闭 ColorBuffer 引用的空指针保护。
ProgramData 已确认链接及 uniform 正常，桌面快照加载时也没有执行像素填充分支，
因此不将这两项实验作为缺字修复。Alpha 纹理修复仍由三格式逐字节真机测试覆盖。

### 8.13 2026-10-18：最终候选桌面快照十轮真机回归

最终候选构建日志 `gfx-final-build.log`、`qemu-final-build.log`、
`app-final-build.log`；APK 已安装到 cc96ded5。未重置 userdata、vmstate 或
snapshots。15:40 的冷启动正常到达 boot_completed，约 16:09 桌面完整出现。
冷启动本身仍慢；本轮收益来自已开机桌面的 Quickboot。

中途另做一次启动提示界面的保存/恢复：保存 7.562s，前台服务 11 次采样
全部 isForeground=true，恢复首帧 5.125s，30 秒及超过 2 分钟错误计数为 0。
但 “Phone is starting…” 文字在 cont 后消失，仅进度条继续刷新；
字体 atlas 和 223×21 文字缓存内容均非零，清缓存未解决。
**启动途中快照仍有缺字问题，不能把桌面回归等同于所有阶段图形恢复已修复。**

16:09:54–16:13:39 完成十次真实 App 正常退出保存→进程重启→加载：

| 指标 | 最小 | 中位数 | 最大 |
| --- | --- | --- | --- |
| stop 请求到 QEMU 退出、有效 marker 写入 | 4.859s | 5.508s | 8.828s |
| App 启动请求到新首帧 | 5.078s | 5.422s | 6.172s |

每轮保存期间前台服务共 83 次采样全部保持前台；每轮加载后 console 增长，
画面尺寸 720×1280，桌面文字/图标完整。第一轮先让桌面静止超过 10 秒，
已验证不再被旧的帧年龄判断跳过保存。八类错误十轮全部为 0：null ctx、
process owned resources、window handle not found、backend error -4、
force_close=1、RenderThread 加载失败、等待超时、not paused (Empty)。
renderer 保存无 45s 等待，示例 pause=0ms/save=72ms/resume=0ms。

第十轮后用与 App 相同的 QMP tablet 事件点击桌面图标，打开 WebView Browser
Tester，标题文字正常；再点击 guest Home 返回桌面，文字/图标仍完整。
证据 `app-final-touch-10s-frame.png`、`app-final-touch-home-frame.png`。
十轮数据 `app-alpha-ten-results.json`，完整记录 `app-final-ten-run.txt`，
逐轮截图汇总 `quickboot-cycles-contact.png`。这些证据位于忽略目录
`dist/boot-optimization/`；测试脚本不恢复任何磁盘基线。

另一次独立恢复 16:15:41 首帧，16:18:02 超过两分钟采样：console 继续增长，
桌面文字完整，八项计数仍为 0（`app-final-desktop-2min-*`）。随后正常退出保存
5.485s，留下有效 `snapshot.state`；ram.bin=1,609,490,576、textures.bin=6,289,061、
vmstate.qcow2=38,207,488 字节，均为 App 属主。最后 force-stop App，无 QEMU 进程，
清理测试 forward，恢复接电保持亮屏原值 0。下次 App 启动可直接恢复该桌面保存点。
交付 `dist/boot-optimization/quickboot-release.apk`，SHA256 为
`8faa89e17bd6c0cf526e02fdfcbcf7aefd075af809eaa73f18b7cd31398e57fd`。

### 8.14 2026-10-18：桌面 Quickboot 第二轮加速

在保留桌面快照与磁盘同点的前提下继续优化；本轮未恢复 userdata 基线，
未替换 vmstate 模板，也未清理 snapshots。先给 C ABI load 桥接加入
`VMHOSTSNAP load_profile`，记录总耗时、RAM 耗时、尺寸及压缩/按需标志。
基线 total=4007ms、RAM=3225ms，RAM 约 1.61GB、未压缩、同步加载。

1. `patch_snapshot_ram_read.py` 在未压缩且无 MemoryAccessWatch 时，将磁盘连续的
   非零页合并为最多 256 个 iovec 的 preadv。guest 地址可不连续；磁盘有间隙时
   另起一批。零页检查/清零、压缩、按需路径和文件格式保持原逻辑。
   `vmhost_snapshot_readv.h` 处理 EINTR、部分读取与 EOF；失败返回加载错误。
   第一轮约 38.1 万页仅需 6793 次批次读取，load=3383ms、RAM=2779ms。
   构建时由 `build_aemu_snapshot.sh` 幂等应用补丁并复制 helper，避免仅修改外部源码。
2. 原启动连接 QMP 失败后固定等待 1 秒，且普通输入连接自身也节流 1 秒。
   新增恢复专用连接入口，间隔 50ms，连接轮询上限约 8 秒，坏请求最多 8 次；
   普通输入维持原节流。首次实测 App 请求到首帧 3.593s，再次 3.594s。

验证命令（Linux/WSL）：

```sh
g++ -std=c++17 -Wall -Wextra -Werror vm/engine/tests/test_snapshot_readv.cpp -o /tmp/vmhost-test-readv
/tmp/vmhost-test-readv
python3 vm/engine/tests/test_qmp_protocol.py
```

读取测试覆盖 256 个不连续目的缓冲、非零文件偏移、逐字节比较、边界哨兵、
EINTR、部分读取和截断文件。QMP 三项测试覆盖输入遗留回复、超时迟到回复，
以及恢复连接可在普通输入 1 秒节流结束前成功。

构建日志 `ram-readv-build.log`、`qemu-readv-build.log`、
`app-readv-fastqmp-build.log`；APK 已安装至 cc96ded5。
当时交付 `dist/boot-optimization/quickboot-release.apk` SHA256：
`e1dbbafe43bb771133cf47fa552f5a42755948e1397936eabd55c71545a06988`。

第二轮连续回归在第 7 轮因黑屏主动停止，**尚不能报告十轮通过**。
前六轮桌面首帧与文字正常；第六轮运行中 guest system_server(518) 消失，
zygote(275) 收到 SIGKILL，随后 launcher/SystemUI 报 DeadSystemException。
第七轮 load 返回成功、console 增长、八类图形错误均为 0，但截图全黑，
说明仅检查 load 成功与图形错误不足以判定可用。证据 `app-fast-ten-run.txt`、
`app-fast-ten-results.json`、`app-fast-cycle-06-load-console.log`、
`app-fast-cycle-07-load-frame.png`。原因未定，不能断言与本轮优化无关。
此时保留正在恢复服务的 guest，未回滚或删除磁盘/快照。

### 8.15 2026-10-18：第七轮黑屏根因与单核冷启动问题

对保存后的 ram.bin 只读检索，获得明确日志：

```text
Killing 'system_server' (518) to check forward scheduling progress in Z state for '[crash_dump64]' (1232)
```

这是 guest llkd 因僵尸 crash_dump64 杀其父进程，与 Java Watchdog 是两套机制。
原 AmController 只覆盖后者。首次 `stop llkd` 失败，init 明确提示找不到该服务；
调试构建实际服务名为 `llkd-1`（发布构建为 `llkd-0`）。随后 `su 0 stop llkd-1`
得到 init 发送 SIGKILL 的日志，后续 `getprop init.svc.llkd-1` 确认为 stopped。
仅设 `llk.enable=false` 不等于停止已经运行的服务。
官方定义参考 [llkd.rc](https://chromium.googlesource.com/aosp/platform/system/core/+/b738b7d23a4d50a4b0352dc77ff96d356110072e/llkd/llkd.rc)。
相关证据 `guest-fast-ram-crash-strings.txt`、`guest-fast-ram-scan.txt`、
`guest-cpu-online.txt`；后者同时确认 guest online CPU 为 `0`。

进一步核对最新冷启动 console（不只是宿主 top）：

```text
psci: no cpu_on method, not booting CPU1
... CPU2–CPU5 同样错误 ...
smp: Brought up 1 node, 1 CPU
SMP: Total of 1 processors activated.
```

**此前 -smp 6 与六个 TCG 线程不代表 guest 真的有六核在线。**
本版 `hw/arm/ranchu.c` 仍保留旧的 `No PSCI for TCG yet` 分支，
只在 KVM 模式创建 /psci；但 `target/arm/cpu.c` 已明确 TCG 实现 PSCI 0.2。
`patch_ranchu_psci.py` 为 TCG 也创建 /psci，并与 virt 板一样，在 realize 前
设置 CPU 的 HVC psci-conduit。KVM 分支保持原实现。
构建脚本幂等应用，`qemu-psci-build.log`、`app-psci-build.log` 编译通过。
**六核真正启动和冷启动耗时仍需真机冷启动验证，不能先写性能结论。**

17:59:48 正常停止当前仍处于 Phone is starting 的 guest，9.578s 后成功保存。
开始将 userdata.img、vmstate.qcow2、snapshots 和 snapshot.state 整组备份至
`C:\Users\liu\.codex\tmp\vmhost-cc96ded5\pre-psci-20261018.tar`，
避免冷启动推进磁盘后无法与旧 RAM 配对。此次不是恢复 userdata 基线，
也没有替换 vmstate 模板。

备份完成并经 tar 目录及 marker 校验：5,998,582,272 字节，SHA256
`c5cd38162d973eaf9d180ba1ab07a215f1af267be2bd3016f052ad7d37f88306`。
另外单独保存同点 metadata.img（16,777,216 字节）到同目录
`pre-psci-metadata.img`，SHA256
`b5acec3392dffd86233bc4874f2cfb80538f4624333bb49deb83c10b47cdc213`。
需要回退时必须恢复完整 tar 加 metadata，不能单独恢复 marker 或 userdata。

PSCI 补丁还把 /psci 节点的生成移到 CPU realize 之后；原 create_fdt 在 CPU 对象
创建前调用，不能在其中直接读取 qemu_get_cpu(0)->psci_version。
独立无磁盘内核测试 `psci_smoke.sh` 使用 512MB 内存，不挂 vm_1 的任何盘，
在约 0.15s guest 时间确认 CPU1–5 全部 Booted、Total of 6 processors activated。
证据 `psci-smoke-console.log`。测试完成用 monitor quit 正常结束。

18:04:49 安装补丁 APK 后开始真实 App 冷启动。仅将旧 snapshot.state 改名为
snapshot.state.pre-psci，保留完整旧快照文件；旧标记此后不能直接改回，
因为冷启动会推进磁盘。后续正常退出保存将建立新的同点快照。
冷启动时间起点保存在 `psci-cold-start.json`。

### 8.16 2026-10-18：Clang 原子操作探测误判

六核冷启动在 zygote 前后严重变慢，并出现 RCU stall。检查实际构建产物发现
`config-host.h` 同时缺少 CONFIG_ATOMIC64 和 CONFIG_ATOMIC128。`config.log`
明确记录 Clang 不认识旧探测所用的 `__atomic_load_8`、`__atomic_load_16` 等
GCC 尺寸后缀写法；这不代表 ARM64 宿主没有这些能力。
`cputlb.c` 因此不编译对应 helper，客体 64/128 位原子操作回退到 EXCP_ATOMIC，
`cpu_exec_step_atomic()` 通过 start_exclusive 暂停全部 vCPU 后执行单步。

`patch_atomic_probe.py` 将探测改为编译器通用的 `_n`/无尺寸后缀 builtin。
构建脚本使用 configure 文件哈希使旧缓存只在需要时重新探测；没有直接强开能力。
重建后 CONFIG_ATOMIC64、CONFIG_ATOMIC128 均由探测自动启用。
`test_atomic_probe.c` 在 cc96ded5 原生执行通过：两种宽度均 lock-free，
4 线程各 10 万次更新结果正确，128 位高低半部 load/store 完整保留。
构建证据 `qemu-atomic-build.log`、`app-atomic-build.log`。

18:23 左右先通过 QMP stop 暂停当前未到桌面的 guest，再 save default_boot：
3.656s 成功，query-status 确认 paused，ram.bin=631790933，textures.bin=30047，
日志 qemu_savevm_state ret=0、on_end done。随后 QMP quit，确认 QEMU 已退出，
才 force-stop App、安装新 APK、写同点 marker 并恢复。未在保存后 cont，
因此没有让磁盘推进后重用旧 RAM。证据 `app-pre-atomic-checkpoint.txt`。
恢复 load_profile total=2680ms，随后 guest 继续执行。

此前约 uptime 947–952s 通过 guest sysfs 下线 CPU2–5，仅剩 0–1；
换入修正原子操作的新引擎后，约 uptime 1205s 再次上线到 0–5，串口确认。
这次启动经历中途热插拔和检查点换引擎，**不能当作干净冷启动耗时对比**。
llkd 在后续 init 阶段又启动过一次；约 uptime 1176s 再次明确 stop llkd-1，
收到 init 杀进程和 stopped 状态。此项目前只作用于当前 guest 运行/快照，
尚未改发布镜像的冷启动配置。

补充实测与发布边界：

- 使用自制静态 /init 和 512MB RAM，在 cc96ded5 先后启动两个无磁盘、
  六核 QEMU；测试期间先正常停止并 force-stop App，未同时运行 App QEMU。
  四线程各 1000 次 64/128 位并发更新，修复前 530.328ms，修复后 30.898ms，
  约 17.16 倍；双方结果正确且确认六核激活。包含内核启动的宿主观测分别
  14.531s / 8.391s。它是专项实验，不能换算为完整 Android 冷启动倍数。
  两次均通过 guest poweroff 正常退出，未挂 vm_1 的盘。
  证据 `atomic-bench-results.json`、`atomic-bench-old-console.log`、
  `atomic-bench-new-console.log`。
- 新六核 Android 冷启动经过多次热插拔与中途换引擎，性能结论不充分。
  因此最终 ranchu TCG PSCI 节点为显式实验开关：环境 VMHOST_TCG_PSCI=1，
  App 对应 `setprop debug.vmhost.tcg_psci 1`；默认 0，保留原冷启动在线单核行为。
  已有快照仍恢复其保存的 DT 与在线状态；切换开关不会改变快照中的 guest DT。
  HVC conduit 在 TCG CPU 上保留，以便兼容实验保存的状态。KVM 沿用既有路径。
- 当前 guest 于 uptime 2070s 左右退回在线单核；停止调试串口回放服务 logcatd
  （没有停止 logd），并确认 boot_completed=1、llkd-1=stopped。
  曾对 guest com.android.phone 执行一次 force-stop 排查蜂窝 HAL 等待，没有改包
  启用状态；未对宿主电话进程操作，也没有修改镜像内容。
  18:43:54 截图确认真实桌面；随后实际打开 WebView Browser Tester 并返回 Home，
  18:49:19 桌面状态栏/导航栏/文字完整，八类图形/快照错误全部为 0。
- 18:50:05 从可用桌面正常 App 退出，10.969s 成功保存，marker 有效。
  18:51:40 安装最终带实验开关的 APK 后，4.859s 恢复新帧。
  构建 `qemu-atomic-gated-build.log`、`app-atomic-gated-build.log` 均成功。
  随后的十次 App 保存/恢复已完成，结果及最终 APK 边界见 §8.17。

### 8.17 2026-10-18：桌面回归完成与最终产物

18:52–18:56，修正原子操作探测、批量读取 RAM、缩短恢复连接等待的版本，
连续十次正常 App 保存→重启→恢复全部通过。每轮都执行 guest 串口命令，
检查 console 增长、帧序号、桌面文字及八类图形/快照错误，避免仅以 load
返回成功判断可用。首帧 4.344–4.797s，中位数 4.4145s；App 停止至 QEMU
退出 5.531–5.594s，中位数 5.570s（不含退出后的日志拉取）。80 次服务采样
在保存期间均为 isForeground=true，未再出现原先九次、每次五秒的渲染等待。
证据 `app-atomic-ten-run.txt`、`app-atomic-ten-results.json`、
`app-atomic-cycle-*-lifecycle.json`。原先失败的第七轮仍保留在 §8.14，
此次十轮成功是在停止 guest llkd-1、重新取得可用桌面后的独立回归。

十轮后实际点击 WebView Browser Tester 并返回桌面，截图正常；随后两分钟
观察中 console 增长 20,875 字节，60s、120s 截图及八类错误检查全部正常。
证据 `atomic-final-soak.json`、`atomic-final-soak-run.txt`。
guest 最终健康检查确认 boot_completed=1、llkd-1/logcatd=stopped、online=0；
com.android.phone 已自行恢复运行，没有禁用包。此处停止调试服务的状态由
当前 RAM 快照保存，尚未永久修改未来 Android 冷启动的 init 配置。

最终冷启动开关检查发现，通用 ARM `arm_load_dtb` 还会依据 HVC conduit
补出 /psci，仅控制 ranchu 自己的节点生成不够。补丁增加 modify_dtb 回调，
在通用修正完成后，TCG 默认路径移除 /psci，显式实验开关为 1 时保留。
修正后的最终 APK 无磁盘内核测试确认：默认 1 核、实验开启 6 核，原子操作
结果均正确；前后 userdata、metadata、vmstate、RAM、marker 的大小/mtime
逐项完全相同。测试未挂载 vm_1 磁盘。证据 `final-cold-smoke-results.json`。
该测试只证明引擎冷启动分支正确，不代表完整 Android 冷启动已完成性能回归。

这一 DT 回调修正后的最终 APK 又完成五次桌面恢复：19:05/19:07 两次首帧
6.063s、5.453s；21:44–21:45 三轮连续保存/恢复首帧 5.719s、5.015s、5.750s，
串口心跳、文字截图及八类错误检查均通过。
证据 `app-atomic-corrected-final-load-*`、`app-atomic-corrected-verify-load-*`、
`app-corrected-final-three-run.txt`、`app-corrected-final-three-results.json`。
最终版不能直接标为“稳定 4.4 秒”：三轮 load_profile 总耗时
4693/4187/4351ms，其中 RAM 3982/3494/3653ms，RAM 文件约 1.71GB；
更早十轮中的一个样本为 total=3467ms、RAM=3044ms。
闲置后还观察到宿主 QEMU VmSwap=1,729,608kB，首次保存耗时 9.781s，
之后两次为 4.219/5.640s；三轮后 VmSwap=0。
宿主大核 scaling_max_freq 当时为 1,401,600kHz（约 1.40GHz），
未更改系统温控或清理其他应用。日志证实读取阶段有波动，不能仅凭这些
观测认定单一原因，也不能保证每次恢复都低于五秒。

最终 `dist/boot-optimization/quickboot-release.apk` 与设备已安装版本一致，
SHA256：`b65364086df67478d98a41717162030a6cb288e081ddc322f2d9a399e692dadd`。
构建日志 `qemu-atomic-final-build.log`、`app-atomic-final-build.log`。
六核 PSCI 仍为默认关闭的实验功能；完整 Android 冷启动不宣称加速倍数。

21:47:29 从经过点击/返回检查的桌面正常停止，7.641s 完成保存并退出 QEMU。
最终 marker=vmhost-snapshot-v1，RAM=1,727,837,785、textures=4,893,823、
vmstate.qcow2=48,955,392 字节，相关文件及 frame.shm 属主均为 App 10341。
确认无 QEMU/前台服务后才 force-stop App，移除本轮 4444/4446 转发，保留其他
转发；接电保持亮屏恢复为原值 0。没有恢复 userdata 或覆盖 vmstate 模板。
证据 `app-corrected-final-handoff-run.txt`、`quickboot-final-stopped-state.txt`。

### 8.18 2026-10-18：外部镜像入口后的快照回归

本轮新增外部镜像独立导入、Android sparse 转换、镜像布局检查和电脑端转换工具，
详见 `vm/docs/外部安卓镜像导入.md`。没有将外部文件写入 vm_1 的基础镜像或磁盘。
22:30 安装外部镜像功能的 APK，SHA256
`e409d2a70d1e10132a62a7ab6d1ae610093c604e9fc09ae4289abff3171acd11`，
产物为 `dist/external-images/youlong-external-images.apk`；此前 quickboot-release.apk
作为历史验证产物保留，没有覆盖。新 APK 恢复 vm_1 首帧 5.390s，串口心跳、
boot_completed 与桌面截图正常，八类错误为 0。22:31:56 正常退出，6.234s 保存成功。
最终 RAM=1,729,015,570、textures=4,892,572、vmstate=48,955,392 字节，
marker 有效、属主仍为 10341，QEMU 已退出，接电保持亮屏恢复为 0。
没有恢复任何旧 userdata/vmstate/marker。证据 `external-image-final-*`。
