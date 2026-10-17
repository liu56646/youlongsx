#!/usr/bin/env bash
#
# Build the protobuf 3.21.12 host compiler and the Android arm64-v8a
# static library needed by the aemu snapshot subset.
#
# Usage:
#   ./build_protobuf.sh
#   PROTOBUF_TAG=v3.21.12 ./build_protobuf.sh
#
set -euo pipefail

WORKDIR="${WORKDIR:-$HOME/vmbuild}"
SRC_DIR="${SRC_DIR:-$WORKDIR/protobuf}"
HOST_BUILD_DIR="${HOST_BUILD_DIR:-$WORKDIR/protobuf-build-host}"
TARGET_BUILD_DIR="${TARGET_BUILD_DIR:-$WORKDIR/protobuf-build-arm64-v8a}"
GEN_DIR="${GEN_DIR:-$WORKDIR/proto-gen}"
AEMU_PROTO_GLOB_ROOT="${AEMU_PROTO_GLOB_ROOT:-$WORKDIR/qemu-aosp/android/emu}"

NDK_VER="${NDK_VER:-r28}"
NDK_DIR="${NDK_DIR:-$WORKDIR/android-ndk-$NDK_VER}"
TOOLCHAIN="${TOOLCHAIN:-$NDK_DIR/build/cmake/android.toolchain.cmake}"
API_LEVEL="${API_LEVEL:-28}"
ABI="${ABI:-arm64-v8a}"

PROTOBUF_TAG="${PROTOBUF_TAG:-v3.21.12}"
PROTOBUF_REPO="${PROTOBUF_REPO:-https://github.com/protocolbuffers/protobuf.git}"
JOBS="${JOBS:-$(nproc)}"

HOST_LOG="$HOST_BUILD_DIR/build.log"
TARGET_LOG="$TARGET_BUILD_DIR/build.log"
HOST_PROTOC="$HOST_BUILD_DIR/protoc"
TARGET_LIB="$TARGET_BUILD_DIR/lib/libprotobuf.a"
TARGET_INCLUDE="$TARGET_BUILD_DIR/include"
HOST_CXX="${HOST_CXX:-c++}"

CXX="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${API_LEVEL}-clang++"
READMEELF="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"

command -v git >/dev/null || { echo "找不到 git" >&2; exit 1; }
command -v cmake >/dev/null || { echo "找不到 cmake" >&2; exit 1; }
command -v ninja >/dev/null || { echo "找不到 ninja" >&2; exit 1; }
command -v "$HOST_CXX" >/dev/null || { echo "找不到宿主 C++ 编译器：$HOST_CXX" >&2; exit 1; }
[ -f "$TOOLCHAIN" ] || {
    echo "找不到 NDK cmake toolchain：$TOOLCHAIN" >&2
    exit 1
}
[ -x "$CXX" ] || {
    echo "找不到 NDK C++ 编译器：$CXX" >&2
    exit 1
}
[ -d "$AEMU_PROTO_GLOB_ROOT" ] || {
    echo "找不到 aemu proto 根目录：$AEMU_PROTO_GLOB_ROOT" >&2
    exit 1
}

mapfile -t PROTO_DIRS < <(
    find "$AEMU_PROTO_GLOB_ROOT" -type d -name protos -print | sort
)
mapfile -t PROTO_FILES < <(
    find "$AEMU_PROTO_GLOB_ROOT" -path "*/protos/*.proto" -type f -print | sort
)
[ "${#PROTO_DIRS[@]}" -gt 0 ] || {
    echo "没有发现 proto 目录：$AEMU_PROTO_GLOB_ROOT" >&2
    exit 1
}
[ "${#PROTO_FILES[@]}" -gt 0 ] || {
    echo "没有发现 proto 文件：$AEMU_PROTO_GLOB_ROOT" >&2
    exit 1
}

if [ ! -e "$SRC_DIR" ]; then
    echo "==> 克隆 protobuf $PROTOBUF_TAG"
    git clone --branch "$PROTOBUF_TAG" --depth 1 "$PROTOBUF_REPO" "$SRC_DIR"
elif [ ! -d "$SRC_DIR/.git" ]; then
    echo "源码目录存在但不是 git 仓库：$SRC_DIR" >&2
    exit 1
fi

if ! git -C "$SRC_DIR" rev-parse -q --verify "refs/tags/$PROTOBUF_TAG^{commit}" >/dev/null; then
    git -C "$SRC_DIR" fetch --depth 1 origin \
        "refs/tags/$PROTOBUF_TAG:refs/tags/$PROTOBUF_TAG"
fi

EXPECTED_COMMIT="$(git -C "$SRC_DIR" rev-parse "$PROTOBUF_TAG^{commit}")"
CURRENT_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$CURRENT_COMMIT" != "$EXPECTED_COMMIT" ]; then
    if ! git -C "$SRC_DIR" diff-index --quiet HEAD --; then
        echo "protobuf 工作区有未提交改动，拒绝切换版本：$SRC_DIR" >&2
        exit 1
    fi
    git -C "$SRC_DIR" checkout --detach "$PROTOBUF_TAG"
fi

ACTUAL_TAG="$(git -C "$SRC_DIR" describe --tags --exact-match HEAD 2>/dev/null || echo unknown)"
ACTUAL_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"

mkdir -p "$HOST_BUILD_DIR" "$TARGET_BUILD_DIR" "$GEN_DIR"

echo "==> 源码   $SRC_DIR"
echo "==> 版本   $ACTUAL_TAG ($ACTUAL_COMMIT)"
echo "==> 宿主   $HOST_BUILD_DIR"
echo "==> 目标   $TARGET_BUILD_DIR"
echo "==> ABI    $ABI / android-$API_LEVEL"

# ---------------------------------------------------------------- host protoc
echo "==> configure 宿主 protoc"
cmake -S "$SRC_DIR" -B "$HOST_BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_CONFORMANCE=OFF \
    -Dprotobuf_BUILD_EXAMPLES=OFF \
    -Dprotobuf_BUILD_PROTOC_BINARIES=ON \
    -Dprotobuf_BUILD_SHARED_LIBS=OFF \
    -Dprotobuf_BUILD_LIBUPB=OFF \
    -Dprotobuf_WITH_ZLIB=OFF \
    >"$HOST_LOG" 2>&1 || {
    echo "!! 宿主 configure 失败，末尾日志：" >&2
    tail -60 "$HOST_LOG" >&2
    exit 1
}

echo "==> ninja -j$JOBS protoc"
if ! ninja -C "$HOST_BUILD_DIR" -j"$JOBS" protoc >>"$HOST_LOG" 2>&1; then
    echo "!! 宿主 protoc 构建失败，错误摘录：" >&2
    grep -nE "error:|Error|FAILED" "$HOST_LOG" | tail -60 >&2
    exit 1
fi

echo "==> protoc --version"
"$HOST_PROTOC" --version

# ---------------------------------------------------------------- target library
echo "==> configure 目标 libprotobuf"
cmake -S "$SRC_DIR" -B "$TARGET_BUILD_DIR" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$TARGET_BUILD_DIR" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_INCLUDEDIR=include \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_CXX_STANDARD=17 \
    -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_CONFORMANCE=OFF \
    -Dprotobuf_BUILD_EXAMPLES=OFF \
    -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
    -Dprotobuf_BUILD_SHARED_LIBS=OFF \
    -Dprotobuf_BUILD_LIBUPB=OFF \
    -Dprotobuf_WITH_ZLIB=OFF \
    >"$TARGET_LOG" 2>&1 || {
    echo "!! 目标 configure 失败，末尾日志：" >&2
    tail -60 "$TARGET_LOG" >&2
    exit 1
}

echo "==> ninja -j$JOBS"
if ! ninja -C "$TARGET_BUILD_DIR" -j"$JOBS" >>"$TARGET_LOG" 2>&1; then
    echo "!! 目标 libprotobuf 构建失败，错误摘录：" >&2
    grep -nE "error:|Error|FAILED" "$TARGET_LOG" | tail -60 >&2
    exit 1
fi

echo "==> cmake --install"
if ! cmake --install "$TARGET_BUILD_DIR" >>"$TARGET_LOG" 2>&1; then
    echo "!! 目标安装失败，末尾日志：" >&2
    tail -60 "$TARGET_LOG" >&2
    exit 1
fi

[ -f "$TARGET_LIB" ] || {
    echo "安装后找不到静态库：$TARGET_LIB" >&2
    exit 1
}
[ -f "$TARGET_INCLUDE/google/protobuf/message.h" ] || {
    echo "安装后找不到 protobuf 头文件：$TARGET_INCLUDE" >&2
    exit 1
}

# ---------------------------------------------------------------- generated code
PROTO_PATH_ARGS=()
for proto_dir in "${PROTO_DIRS[@]}"; do
    PROTO_PATH_ARGS+=(--proto_path="$proto_dir")
done

for proto_file in "${PROTO_FILES[@]}"; do
    proto_base="$(basename "$proto_file" .proto)"
    rm -f "$GEN_DIR/$proto_base.pb.h" "$GEN_DIR/$proto_base.pb.cc"
done

echo "==> protoc --cpp_out=$GEN_DIR (${#PROTO_FILES[@]} protos)"
{
    printf '%q ' "$HOST_PROTOC" \
        "${PROTO_PATH_ARGS[@]}" \
        --cpp_out="$GEN_DIR" \
        "${PROTO_FILES[@]}"
    printf '\n'
} >"$GEN_DIR/generate.log"

"$HOST_PROTOC" \
    "${PROTO_PATH_ARGS[@]}" \
    --cpp_out="$GEN_DIR" \
    "${PROTO_FILES[@]}" \
    >>"$GEN_DIR/generate.log" 2>&1 || {
    echo "!! protoc 生成失败，日志：" >&2
    cat "$GEN_DIR/generate.log" >&2
    exit 1
}

for proto_file in "${PROTO_FILES[@]}"; do
    proto_base="$(basename "$proto_file" .proto)"
    for suffix in pb.h pb.cc; do
        [ -f "$GEN_DIR/$proto_base.$suffix" ] || {
            echo "protoc 未生成 $GEN_DIR/$proto_base.$suffix" >&2
            exit 1
        }
    done
done

# ---------------------------------------------------------------- generated cc probe
STUDIO_STATS_CC="$GEN_DIR/studio_stats.pb.cc"
STUDIO_STATS_OBJ="$TARGET_BUILD_DIR/studio_stats.pb.o"
STUDIO_STATS_LOG="$TARGET_BUILD_DIR/studio_stats_compile.log"

[ -f "$STUDIO_STATS_CC" ] || {
    echo "缺少生成文件：$STUDIO_STATS_CC" >&2
    exit 1
}

echo "==> NDK clang++ -c studio_stats.pb.cc"
{
    printf '%q ' "$CXX" \
        --target="aarch64-linux-android$API_LEVEL" \
        -std=c++17 -fPIC \
        -I"$GEN_DIR" -I"$TARGET_INCLUDE" \
        -c "$STUDIO_STATS_CC" \
        -o "$STUDIO_STATS_OBJ"
    printf '\n'
} >"$STUDIO_STATS_LOG"

if ! {
    "$CXX" \
        --target="aarch64-linux-android$API_LEVEL" \
        -std=c++17 -fPIC \
        -I"$GEN_DIR" -I"$TARGET_INCLUDE" \
        -c "$STUDIO_STATS_CC" \
        -o "$STUDIO_STATS_OBJ" \
        >>"$STUDIO_STATS_LOG" 2>&1
}; then
    echo "!! studio_stats.pb.cc NDK 编译失败，日志：" >&2
    tail -80 "$STUDIO_STATS_LOG" >&2
    exit 1
fi

# ---------------------------------------------------------------- target probe
PROBE_SRC="$TARGET_BUILD_DIR/snapshot_probe.cpp"
PROBE_BIN="$TARGET_BUILD_DIR/snapshot_probe"
PROBE_LOG="$TARGET_BUILD_DIR/snapshot_probe.log"
HOST_PROBE_BIN="$HOST_BUILD_DIR/snapshot_probe"
HOST_PROBE_LOG="$HOST_BUILD_DIR/snapshot_probe.log"

cat >"$PROBE_SRC" <<'EOF'
#include "snapshot.pb.h"

#include <stdio.h>
#include <string>

int main() {
    GOOGLE_PROTOBUF_VERIFY_VERSION;
    emulator_snapshot::Snapshot snapshot;
    snapshot.set_version(1);
    snapshot.set_logical_name("android-arm64-probe");

    std::string encoded;
    if (!snapshot.SerializeToString(&encoded) || encoded.empty()) {
        return 1;
    }

    emulator_snapshot::Snapshot decoded;
    if (!decoded.ParseFromString(encoded) || decoded.version() != 1) {
        return 1;
    }

    puts("snapshot_probe: ok");
    return 0;
}
EOF

echo "==> 编译并运行宿主探针"
{
    printf '%q ' "$HOST_CXX" \
        -std=c++17 \
        -I"$GEN_DIR" -I"$SRC_DIR/src" \
        "$PROBE_SRC" "$GEN_DIR/snapshot.pb.cc" \
        "$HOST_BUILD_DIR/libprotobuf.a" -pthread \
        -o "$HOST_PROBE_BIN"
    printf '\n'
} >"$HOST_PROBE_LOG"

if ! {
    "$HOST_CXX" \
        -std=c++17 \
        -I"$GEN_DIR" -I"$SRC_DIR/src" \
        "$PROBE_SRC" "$GEN_DIR/snapshot.pb.cc" \
        "$HOST_BUILD_DIR/libprotobuf.a" -pthread \
        -o "$HOST_PROBE_BIN" \
        >>"$HOST_PROBE_LOG" 2>&1
}; then
    echo "!! 宿主探针编译链接失败，日志：" >&2
    tail -80 "$HOST_PROBE_LOG" >&2
    exit 1
fi

if ! "$HOST_PROBE_BIN"; then
    echo "!! 宿主探针运行失败" >&2
    exit 1
fi

echo "==> 编译并链接 arm64 探针"
{
    printf '%q ' "$CXX" \
        --target="aarch64-linux-android$API_LEVEL" \
        -std=c++17 -fPIC \
        -I"$GEN_DIR" -I"$TARGET_INCLUDE" \
        "$PROBE_SRC" "$GEN_DIR/snapshot.pb.cc" \
        "$TARGET_LIB" -static-libstdc++ -llog \
        -o "$PROBE_BIN"
    printf '\n'
} >"$PROBE_LOG"

if ! {
    "$CXX" \
        --target="aarch64-linux-android$API_LEVEL" \
        -std=c++17 -fPIC \
        -I"$GEN_DIR" -I"$TARGET_INCLUDE" \
        "$PROBE_SRC" "$GEN_DIR/snapshot.pb.cc" \
        "$TARGET_LIB" -static-libstdc++ -llog \
        -o "$PROBE_BIN" \
        >>"$PROBE_LOG" 2>&1
}; then
    echo "!! 探针编译链接失败，日志：" >&2
    tail -80 "$PROBE_LOG" >&2
    exit 1
fi

# ---------------------------------------------------------------- evidence
echo "==> ls -la $GEN_DIR"
ls -la "$GEN_DIR"
echo "==> file $TARGET_LIB"
file "$TARGET_LIB"
echo "==> file $PROBE_BIN"
file "$PROBE_BIN"
echo "==> file $STUDIO_STATS_OBJ"
file "$STUDIO_STATS_OBJ"
if [ -x "$READMEELF" ]; then
    echo "==> llvm-readelf probe"
    "$READMEELF" -h "$PROBE_BIN" | grep -E 'Class:|Machine:|Type:'
fi
echo "==> 探针编译链接通过"
echo "==> 完成"
