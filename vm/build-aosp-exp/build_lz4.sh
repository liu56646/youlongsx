#!/usr/bin/env bash
#
# Cross-compile the lz4 sources needed by the aemu snapshot work.
#
# Usage:
#   ./build_lz4.sh
#   LZ4_TAG=v1.9.4 ./build_lz4.sh
#
set -euo pipefail

WORKDIR="${WORKDIR:-$HOME/vmbuild}"
SRC_DIR="${SRC_DIR:-$WORKDIR/lz4}"
BUILD_DIR="${BUILD_DIR:-$WORKDIR/lz4-build-arm64-v8a}"

NDK_VER="${NDK_VER:-r28}"
NDK_DIR="${NDK_DIR:-$WORKDIR/android-ndk-$NDK_VER}"
API_LEVEL="${API_LEVEL:-28}"
ABI="${ABI:-arm64-v8a}"

LZ4_TAG="${LZ4_TAG:-v1.9.4}"
LZ4_REPO="${LZ4_REPO:-https://github.com/lz4/lz4.git}"

TOOLCHAIN_BIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC="$TOOLCHAIN_BIN/aarch64-linux-android${API_LEVEL}-clang"
AR="$TOOLCHAIN_BIN/llvm-ar"
NM="$TOOLCHAIN_BIN/llvm-nm"

OBJ_DIR="$BUILD_DIR/obj"
INCLUDE_DIR="$BUILD_DIR/include"
LIB_DIR="$BUILD_DIR/lib"
LIB="$LIB_DIR/liblz4.a"

PROBE_SRC="$BUILD_DIR/lz4_probe.c"
PROBE_BIN="$BUILD_DIR/lz4_probe"
LOG="$BUILD_DIR/build.log"

command -v git >/dev/null || { echo "找不到 git" >&2; exit 1; }
[ -x "$CC" ] || { echo "找不到 NDK C 编译器：$CC" >&2; exit 1; }
[ -x "$AR" ] || { echo "找不到 llvm-ar：$AR" >&2; exit 1; }
[ -x "$NM" ] || { echo "找不到 llvm-nm：$NM" >&2; exit 1; }

if [ ! -e "$SRC_DIR" ]; then
    echo "==> 克隆 lz4 $LZ4_TAG"
    git clone --branch "$LZ4_TAG" --depth 1 "$LZ4_REPO" "$SRC_DIR"
elif [ ! -d "$SRC_DIR/.git" ]; then
    echo "源码目录存在但不是 git 仓库：$SRC_DIR" >&2
    exit 1
fi

if ! git -C "$SRC_DIR" rev-parse -q --verify "refs/tags/$LZ4_TAG^{commit}" >/dev/null; then
    git -C "$SRC_DIR" fetch --depth 1 origin \
        "refs/tags/$LZ4_TAG:refs/tags/$LZ4_TAG"
fi

EXPECTED_COMMIT="$(git -C "$SRC_DIR" rev-parse "$LZ4_TAG^{commit}")"
CURRENT_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$CURRENT_COMMIT" != "$EXPECTED_COMMIT" ]; then
    if ! git -C "$SRC_DIR" diff-index --quiet HEAD --; then
        echo "lz4 工作区有未提交改动，拒绝切换版本：$SRC_DIR" >&2
        exit 1
    fi
    git -C "$SRC_DIR" checkout --detach "$LZ4_TAG"
fi

ACTUAL_TAG="$(git -C "$SRC_DIR" describe --tags --exact-match HEAD 2>/dev/null || echo unknown)"
ACTUAL_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"

rm -rf "$OBJ_DIR" "$INCLUDE_DIR" "$LIB_DIR"
mkdir -p "$OBJ_DIR" "$INCLUDE_DIR" "$LIB_DIR"

echo "==> 源码   $SRC_DIR"
echo "==> 版本   $ACTUAL_TAG ($ACTUAL_COMMIT)"
echo "==> 构建   $BUILD_DIR"
echo "==> ABI    $ABI / android-$API_LEVEL"
echo "==> 日志   $LOG"

{
    "$CC" -O3 -fPIC -I"$SRC_DIR/lib" -c "$SRC_DIR/lib/lz4.c" \
        -o "$OBJ_DIR/lz4.o"
    "$CC" -O3 -fPIC -I"$SRC_DIR/lib" -c "$SRC_DIR/lib/lz4hc.c" \
        -o "$OBJ_DIR/lz4hc.o"
} >"$LOG" 2>&1 || {
    echo "!! 编译失败，日志：" >&2
    tail -60 "$LOG" >&2
    exit 1
}

cp "$SRC_DIR/lib/lz4.h" "$SRC_DIR/lib/lz4hc.h" "$INCLUDE_DIR/"
"$AR" rcs "$LIB" "$OBJ_DIR/lz4.o" "$OBJ_DIR/lz4hc.o"
echo "==> 编译与归档 ok"

cat >"$PROBE_SRC" <<'EOF'
#include "lz4.h"

#include <stdio.h>
#include <string.h>

int main(void) {
    const char src[] = "lz4 android arm64 probe";
    char dst[128];
    const int size = LZ4_compress_default(src, dst, (int)strlen(src),
                                          (int)sizeof(dst));
    if (size <= 0) {
        return 1;
    }
    printf("LZ4_compress_default -> %d bytes\n", size);
    return 0;
}
EOF

echo "==> 编译探针 $PROBE_SRC"
{
    "$CC" -O2 -I"$INCLUDE_DIR" "$PROBE_SRC" "$LIB" -o "$PROBE_BIN"
} >>"$LOG" 2>&1 || {
    echo "!! 探针编译链接失败，日志：" >&2
    tail -60 "$LOG" >&2
    exit 1
}

echo "==> file liblz4.a"
file "$LIB"
echo "==> ls -la 产物"
ls -la "$INCLUDE_DIR" "$LIB_DIR"
echo "==> 归档成员"
"$AR" t "$LIB"
echo "==> lz4 符号"
"$NM" -g --defined-only "$LIB" | grep -E 'LZ4_(compress_default|compress_HC)' || true
echo "==> file lz4_probe"
file "$PROBE_BIN"
echo "==> 完成"
