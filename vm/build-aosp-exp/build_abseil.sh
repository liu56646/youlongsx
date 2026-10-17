#!/usr/bin/env bash
#
# Cross-compile the abseil-cpp subset needed by the aemu snapshot work.
#
# The aemu emu-34 snapshot is from early 2024, so this pins the matching
# Abseil stable release. The str_format_internal target pulls in str_format
# plus the base/strings/container static-library dependencies it needs.
#
# Usage:
#   ./build_abseil.sh
#   ABSEIL_TAG=20240116.2 ./build_abseil.sh
#
set -euo pipefail

WORKDIR="${WORKDIR:-$HOME/vmbuild}"
SRC_DIR="${SRC_DIR:-$WORKDIR/abseil}"
BUILD_DIR="${BUILD_DIR:-$WORKDIR/abseil-build-arm64-v8a}"

NDK_VER="${NDK_VER:-r28}"
NDK_DIR="${NDK_DIR:-$WORKDIR/android-ndk-$NDK_VER}"
TOOLCHAIN="${TOOLCHAIN:-$NDK_DIR/build/cmake/android.toolchain.cmake}"
API_LEVEL="${API_LEVEL:-28}"
ABI="${ABI:-arm64-v8a}"

ABSEIL_TAG="${ABSEIL_TAG:-20240116.2}"
ABSEIL_REPO="${ABSEIL_REPO:-https://github.com/abseil/abseil-cpp.git}"
NINJA_TARGET="${NINJA_TARGET:-str_format_internal}"
JOBS="${JOBS:-$(nproc)}"

LOG="$BUILD_DIR/build.log"

command -v git >/dev/null || { echo "找不到 git" >&2; exit 1; }
command -v cmake >/dev/null || { echo "找不到 cmake" >&2; exit 1; }
command -v ninja >/dev/null || { echo "找不到 ninja" >&2; exit 1; }
[ -f "$TOOLCHAIN" ] || {
    echo "找不到 NDK cmake toolchain：$TOOLCHAIN" >&2
    exit 1
}

if [ ! -e "$SRC_DIR" ]; then
    echo "==> 克隆 abseil $ABSEIL_TAG"
    git clone --branch "$ABSEIL_TAG" --depth 1 "$ABSEIL_REPO" "$SRC_DIR"
elif [ ! -d "$SRC_DIR/.git" ]; then
    echo "源码目录存在但不是 git 仓库：$SRC_DIR" >&2
    exit 1
fi

if ! git -C "$SRC_DIR" rev-parse -q --verify "refs/tags/$ABSEIL_TAG^{commit}" >/dev/null; then
    git -C "$SRC_DIR" fetch --depth 1 origin \
        "refs/tags/$ABSEIL_TAG:refs/tags/$ABSEIL_TAG"
fi

EXPECTED_COMMIT="$(git -C "$SRC_DIR" rev-parse "$ABSEIL_TAG^{commit}")"
CURRENT_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$CURRENT_COMMIT" != "$EXPECTED_COMMIT" ]; then
    if ! git -C "$SRC_DIR" diff-index --quiet HEAD --; then
        echo "abseil 工作区有未提交改动，拒绝切换版本：$SRC_DIR" >&2
        exit 1
    fi
    git -C "$SRC_DIR" checkout --detach "$ABSEIL_TAG"
fi

ACTUAL_TAG="$(git -C "$SRC_DIR" describe --tags --exact-match HEAD 2>/dev/null || echo unknown)"
ACTUAL_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"

mkdir -p "$BUILD_DIR"

echo "==> 源码   $SRC_DIR"
echo "==> 版本   $ACTUAL_TAG ($ACTUAL_COMMIT)"
echo "==> 构建   $BUILD_DIR"
echo "==> ABI    $ABI / android-$API_LEVEL"
echo "==> 目标   $NINJA_TARGET"
echo "==> 日志   $LOG"

# ---------------------------------------------------------------- configure
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DABSL_BUILD_TESTING=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_CXX_STANDARD=17 \
    -DABSL_PROPAGATE_CXX_STD=ON \
    >"$LOG" 2>&1 || {
    echo "!! configure 失败，末尾日志：" >&2
    tail -40 "$LOG" >&2
    exit 1
}
echo "==> configure ok"
grep -E "Configuring done|Generating done|compiler identification" "$LOG" | tail -3

# ---------------------------------------------------------------- build
echo "==> ninja -j$JOBS $NINJA_TARGET"
if ! ninja -C "$BUILD_DIR" -j"$JOBS" "$NINJA_TARGET" >>"$LOG" 2>&1; then
    echo "!! 构建失败，错误摘录：" >&2
    grep -nE "error:|Error|FAILED" "$LOG" | tail -40 >&2
    exit 1
fi

# ---------------------------------------------------------------- probe
PROBE_SRC="$BUILD_DIR/str_format_probe.cpp"
PROBE_BIN="$BUILD_DIR/str_format_probe"
PROBE_LOG="$BUILD_DIR/str_format_probe.log"
CXX="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${API_LEVEL}-clang++"

[ -x "$CXX" ] || {
    echo "找不到 NDK C++ 编译器：$CXX" >&2
    exit 1
}

cat >"$PROBE_SRC" <<'EOF'
#include "absl/strings/str_format.h"

#include <string>

int main() {
    const std::string value = absl::StrFormat("x=%d", 1);
    return value == "x=1" ? 0 : 1;
}
EOF

mapfile -t ABSL_LIBS < <(find "$BUILD_DIR" -name 'libabsl*.a' -print | sort)
[ "${#ABSL_LIBS[@]}" -gt 0 ] || {
    echo "构建目录中没有找到 libabsl*.a" >&2
    exit 1
}

echo "==> 编译探针 $PROBE_SRC"
{
    printf '%q ' "$CXX" \
        --target="aarch64-linux-android$API_LEVEL" \
        -std=c++17 -fPIC -I"$SRC_DIR" "$PROBE_SRC" -o "$PROBE_BIN" \
        -Wl,--start-group "${ABSL_LIBS[@]}" -Wl,--end-group
    printf '\n'
} >"$PROBE_LOG"

if ! {
    "$CXX" \
        --target="aarch64-linux-android$API_LEVEL" \
        -std=c++17 -fPIC -I"$SRC_DIR" "$PROBE_SRC" -o "$PROBE_BIN" \
        -Wl,--start-group "${ABSL_LIBS[@]}" -Wl,--end-group \
        >>"$PROBE_LOG" 2>&1
}; then
    echo "!! 探针编译失败，日志：" >&2
    tail -60 "$PROBE_LOG" >&2
    exit 1
fi

# ---------------------------------------------------------------- 产出
echo "==> 静态库："
find "$BUILD_DIR" -name 'libabsl*.a' -exec ls -lh {} \; | sort -k9
echo "==> 探针："
file "$PROBE_BIN"
echo "==> 完成"
