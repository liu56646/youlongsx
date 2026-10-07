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
