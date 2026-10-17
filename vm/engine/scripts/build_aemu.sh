#!/usr/bin/env bash
#
# 交叉编译 aemu 宿主侧最小子集为 Android/arm64 静态库。
#
# 背景：
#   emu-34 的 AOSP QEMU 只带 android/ glue 与部分 android-emu .cpp，
#   第 1 步需要的 host-common（AndroidPipe / HostGoldfishPipe / 地址空间 /
#   goldfish sync+dma / VmLock）在独立的 aemu 仓库里。本脚本用 NDK 把它
#   编成静态库，供后续接进 qemu-system-aarch64。
#
# 只用 BUILD_STANDALONE 打开最小子集（等价于 aemu 自带的
# build-config/qemu-android，但不走那套机制，避免它无条件
# `add_library(lz4_static ALIAS lz4)` 对不存在目标的依赖）。
#
# 用法：
#   ./build_aemu.sh
#   CONFIGURE_ONLY=1 ./build_aemu.sh      # 只 configure，快速看报错
#
set -euo pipefail

WORKDIR="${WORKDIR:-/root/vmbuild}"
SRC_DIR="${SRC_DIR:-$WORKDIR/aemu}"
BUILD_DIR="${BUILD_DIR:-$WORKDIR/aemu-build-arm64-v8a}"

NDK_VER="${NDK_VER:-r28}"
NDK_DIR="$WORKDIR/android-ndk-$NDK_VER"
TOOLCHAIN="$NDK_DIR/build/cmake/android.toolchain.cmake"
API_LEVEL="${API_LEVEL:-28}"
JOBS="${JOBS:-$(nproc)}"

LOG="$BUILD_DIR/build.log"

[ -d "$SRC_DIR/host-common" ] || {
    echo "找不到 aemu 源码：$SRC_DIR（先跑 vm/build-aosp-exp/fetch_aemu.sh）" >&2
    exit 1
}
[ -f "$TOOLCHAIN" ] || { echo "找不到 NDK cmake toolchain：$TOOLCHAIN" >&2; exit 1; }

mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------- 源码补丁
# aemu 新版把"暂停渲染器"这一步从地址空间设备挪到了 virtio-gpu 的
# stream_renderer_snapshot_presave_pause()（见 gfxstream 的
# virtio-gpu-gfxstream-renderer-goldfish.cpp）。本移植没有接那条 virtio-gpu
# 钩子，而设备保存顺序里 goldfish_address_space 排在 goldfish_pipe 前面 ——
# 结果是保存 opengles 管道时渲染线程**从没被暂停过**（mState 还是 Empty），
# RenderThread::save() 只能死等：实测完全开机的 guest 保存必卡，9 条渲染线程
# 各等 5s 超时才勉强走完（整次 save 多花 45s，之前更是直接 180s HUP 超时）。
# 恢复官方原本的那行：地址空间设备保存时统一 pauseAllPreSave()。
# resume 交给 opengles pipe 的 postSave -> resumeAll()（globalPostSave 保持
# 注释 —— 若在那里放行，会早于随后 goldfish_pipe 里对 opengles 管道的保存）。
patch_aemu_graphics_global_presave() {
    local f="$SRC_DIR/host-common/address_space_graphics.cpp"
    [ -f "$f" ] || { echo "找不到 $f" >&2; return 1; }
    if grep -q "VMHOST_FIX_GLOBAL_PRESAVE" "$f"; then
        echo "==> patch: aemu ASG globalPreSave（已打过，跳过）"
        return 0
    fi
    python3 - "$f" <<'VMHOST_PY'
import io, sys
p = sys.argv[1]
src = io.open(p, encoding='utf-8').read()
old = """    void preSave() {
        // mConsumerInterface.globalPreSave();
    }
"""
new = """    void preSave() {
        /* VMHOST_FIX_GLOBAL_PRESAVE: 官方新版把这行注释掉、改由 virtio-gpu 的
           stream_renderer_snapshot_presave_pause() 触发 pauseAllPreSave()。
           本移植没接那条 virtio-gpu 钩子，而设备保存顺序里
           goldfish_address_space 在 goldfish_pipe 之前 —— opengles 管道保存时
           渲染线程从没被暂停过（mState 仍为 Empty），RenderThread::save() 死等。
           恢复这行；resume 仍由 opengles pipe 的 postSave -> resumeAll() 负责。 */
        mConsumerInterface.globalPreSave();
    }
"""
if old not in src:
    sys.stderr.write("!! aemu globalPreSave 锚点未命中\n")
    sys.exit(1)
io.open(p, 'w', encoding='utf-8').write(src.replace(old, new, 1))
VMHOST_PY
    echo "==> patch: aemu ASG globalPreSave 恢复官方语义"
}

patch_aemu_graphics_global_presave

echo "==> 源码   $SRC_DIR"
echo "==> 构建   $BUILD_DIR"
echo "==> ABI    arm64-v8a / android-$API_LEVEL"
echo "==> 日志   $LOG"

# ---------------------------------------------------------------- configure
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STANDALONE=ON \
    -DGFXSTREAM_BASE_LIB=aemu-base \
    -DGFXSTREAM_HOST_COMMON_LIB=aemu-host-common \
    -DAEMU_BASE_USE_LZ4=OFF \
    -DENABLE_VKCEREAL_TESTS=OFF \
    -DAEMU_COMMON_USE_PERFETTO=OFF \
    >"$LOG" 2>&1 || {
    echo "!! configure 失败，末尾日志：" >&2
    tail -40 "$LOG" >&2
    exit 1
}
echo "==> configure ok"
grep -E "Proceeding with version|Configuring done" "$LOG" | tail -3

if [ "${CONFIGURE_ONLY:-0}" = "1" ]; then
    echo "==> 仅 configure，按要求退出"
    exit 0
fi

# ---------------------------------------------------------------- build
echo "==> ninja -j$JOBS"
if ! ninja -C "$BUILD_DIR" -j"$JOBS" >>"$LOG" 2>&1; then
    echo "!! 构建失败，错误摘录：" >&2
    grep -nE "error:|Error|FAILED" "$LOG" | tail -40 >&2
    exit 1
fi

# ---------------------------------------------------------------- 产出
echo "==> 产物静态库："
find "$BUILD_DIR" -maxdepth 2 -name '*.a' -exec ls -lh {} \; | sort -k9
echo "完成。"
