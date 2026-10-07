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
