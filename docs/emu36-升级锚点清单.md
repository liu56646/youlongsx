# QEMU 基座升级锚点清单（emu-34-release → emu-36-1-release）

- 参考脚本：`vm/engine/scripts/build_qemu_aosp.sh`
- 新树：`origin/emu-36-1-release`
- 新树 tip：`9f0811e72acfc46edc39d3d0baedd796f7d03309`（`9f0811e72a`）
- 检查方式：全程只读，未 checkout、未切分支、未修改工作区代码。

## 补丁锚点清单

| 补丁名 | 目标文件 | 锚点是否命中 | 分类 | 建议 |
|---|---|---|---|---|
| `patch_goldfish_pipe_savevm` | `hw/misc/goldfish_pipe.c` | 命中 1/1：`register_savevm_with_post_load(...)` 块与旧锚点一致 | 直接可用 | 锚点仍可用，但脚本当前已明确注释禁用；升级后继续保持禁用，不要重新启用。 |
| `patch_embed_entry` | `vl.c` | 依赖 `main_impl` 与 `qemu_thread_register_setup_callback`；前者在 `vl.c`，后者在 `include/qemu/thread.h` / `util/qemu-thread-posix.c`，均存在；清旧入口正则在干净树中不阻断 | 直接可用 | 保留追加式入口，升级后仍可复用。 |
| `patch_bionic` | `util/qemu-openpty.c` | 命中 1/1：`#if defined(__GLIBC__)` → `# include <pty.h>` | 直接可用 | 保留，继续给 bionic 补上 `pty.h` 分支。 |
| `patch_feature_include` | `vl.c` | 命中 1/1：`#include "qemu/osdep.h"` 仍在新树中存在 | 直接可用 | 保留；它会给后续 `patch_crash_hooks` 生成依赖的标记。 |
| `patch_crash_hooks` | `vl.c` | 命中 3/3：`VMHOST_FEATURE_INCLUDE` 插入点、`const int res = main_impl(...)` 主入口、`qemu_exit_notifiers_notify()` 后 `return res` 均与锚点一致 | 直接可用 | 保留，但必须排在 `patch_feature_include` 之后。 |
| `patch_virtio_gpu` | `hw/display/virtio-gpu.c` | 命中 1/1：非 virgl 分支的 `data = virgl_renderer_get_cursor_data(...)` 与旧锚点一致 | 直接可用 | 保留；新树仍在 `--disable-virgl` 路径调用该函数。 |
| `patch_goldfish_pipe_arch` | `hw/misc/goldfish_pipe.c` | 命中 1/1：`#if defined(TARGET_MIPS)... #error Unsupported architecture! #endif` 块仍存在 | 直接可用 | 保留，继续把 aarch64 的 RAM 边界固定为单段布局。 |
| `patch_ranchu_pcie` | `hw/arm/ranchu.c` | 外部脚本 A-H 共 8/8 个锚点命中；该文件相对 emu-34-release 无改动 | 直接可用 | 保留；仍用于补 PCIe/gpex 和 `goldfish_address_space`。 |
| `patch_virtio_gpu_stream` | `hw/display/virtio-gpu.c`、`hw/display/virtio-gpu-3d.c` | 命中 5/5 + 2/2 个 `#ifdef CONFIG_ANDROID`，游标额外锚点 1/1 | 直接可用 | 保留；继续把 virtio-gpu 切到 stream_renderer 路径。 |
| `patch_virtio_gpu_capset` | `hw/display/virtio-gpu-3d.c` | 未命中 0/3：`get_capset_info`、`get_capset`、`get_num_capsets` 三个旧块均已被上游重写 | 已不需要（上游已改） | 直接从升级脚本删除；若后续真机确认还需要 MAGMA/COMPOSER，再基于新树的 `VIRTGPU_CAPSET_GFXSTREAM_*` 写新补丁。 |
| `patch_mmap_alloc` | `util/mmap-alloc.c` | 命中 1/1：两处连续的 `MallocHook_SetMmapReplacement` / `MallocHook_SetMunmapReplacement` 调用仍在 | 直接可用 | 保留，继续去掉未链接的 gperftools hook。 |

统计：直接可用 10 个（其中 `patch_goldfish_pipe_savevm` 当前已禁用）、需改锚点 0 个、已不需要/可删 1 个、目标文件消失 0 个。

## 新树构建系统

不是 meson+ninja。`origin/emu-36-1-release` 根目录仍存在 `configure` 和顶层 `Makefile`，不存在 `meson.build`；在 `configure` / `Makefile` 中也没有 ninja 引用。因此这版 AOSP QEMU 仍沿用 configure + GNU make 的构建方式。

## 新树 QEMU 版本

根目录没有 `VERSION`，但 `QEMU_VERSION` 内容为 `2.12.0`。也就是说 emu-36-1-release 的 QEMU 底子仍是 2.12.0，而不是 Meson 时代的 QEMU 7/8/9。

## `-tb-size` 写法

没有变化。新树仍使用：

- `qemu-options.hx`：`DEF("tb-size", HAS_ARG, QEMU_OPTION_tb_size, "-tb-size n      set TB size\n", QEMU_ARCH_ALL)`
- `vl.c`：`case QEMU_OPTION_tb_size:` 后调用 `qemu_strtoul(optarg, NULL, 0, &tcg_tb_size)`
- `accel/tcg/translate-all.c`：相关 `tb_size` 逻辑和“`-tb-size` is not honoured”注释仍在

相对 emu-34-release，`qemu-options.hx` 和 `accel/tcg/translate-all.c` 在这条 `-tb-size` 路径上无差异；`vl.c` 的升级差异不涉及该选项。

## 移植顺序建议

先删除 `patch_virtio_gpu_capset`，然后把剩余补丁按依赖顺序落地：`patch_bionic` → `patch_feature_include` → `patch_embed_entry` → `patch_crash_hooks`；其中 `patch_crash_hooks` 必须排在 `patch_feature_include` 之后。随后执行设备/显示相关补丁：`patch_goldfish_pipe_arch` → `patch_virtio_gpu` → `patch_virtio_gpu_stream` → `patch_ranchu_pcie` → `patch_mmap_alloc`。`patch_goldfish_pipe_savevm` 继续保持在禁用状态；由于唯一失配的 capset 补丁已由上游覆盖，升级不需要先做大规模锚点改写，重点是保留现有顺序并验证 stream_renderer、ranchu PCIe 与 bionic 协程后端。
