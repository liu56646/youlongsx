#!/usr/bin/env bash
#
# Cross-compile the aemu snapshot subset from the AOSP QEMU tree into a
# static library for Android/arm64.
#
# Usage:
#   ./build_aemu_snapshot.sh
#   BUILD_DIR=/tmp/aemu-snapshot-test ./build_aemu_snapshot.sh
#
set -euo pipefail

WORKDIR="${WORKDIR:-/root/vmbuild}"
SRC_DIR="${SRC_DIR:-$WORKDIR/qemu-aosp/android/android-emu/android/snapshot}"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)/qemu_patches"
python3 "$PATCH_DIR/patch_snapshot_ram_read.py" "$SRC_DIR/RamLoader.cpp"
cp "$PATCH_DIR/vmhost_snapshot_readv.h" "$SRC_DIR/vmhost_snapshot_readv.h"
BUILD_DIR="${BUILD_DIR:-$WORKDIR/aemu-snapshot-build-arm64-v8a}"

ABSEIL_DIR="${ABSEIL_DIR:-$WORKDIR/abseil}"
ABSEIL_BUILD_DIR="${ABSEIL_BUILD_DIR:-$WORKDIR/abseil-build-arm64-v8a}"

QEMU_ANDROID_DIR="${QEMU_ANDROID_DIR:-$WORKDIR/qemu-aosp/android}"
QEMU_EMU_BASE_DIR="${QEMU_EMU_BASE_DIR:-$QEMU_ANDROID_DIR/emu/base}"

LZ4_DIR="${LZ4_DIR:-$WORKDIR/lz4-build-arm64-v8a}"
LZ4_INCLUDE_DIR="$LZ4_DIR/include"
LZ4_LIB_DIR="$LZ4_DIR/lib"
LZ4_LIB="$LZ4_LIB_DIR/liblz4.a"

PROTO_GEN_DIR="${PROTO_GEN_DIR:-$WORKDIR/proto-gen}"
PROTOBUF_DIR="${PROTOBUF_DIR:-$WORKDIR/protobuf-build-arm64-v8a}"
PROTOBUF_INCLUDE_DIR="$PROTOBUF_DIR/include"
PROTOBUF_LIB_DIR="$PROTOBUF_DIR/lib"
PROTOBUF_LIB="$PROTOBUF_LIB_DIR/libprotobuf.a"

NDK_VER="${NDK_VER:-r28}"
NDK_DIR="$WORKDIR/android-ndk-$NDK_VER"
TOOLCHAIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
TARGET="${TARGET:-aarch64-linux-android28}"
CXX="${CXX:-$TOOLCHAIN/bin/clang++}"
AR="${AR:-$TOOLCHAIN/bin/llvm-ar}"
LINKER="${LINKER:-$TOOLCHAIN/bin/ld.lld}"

LIB="$BUILD_DIR/libaemu-snapshot.a"
OBJ_DIR="$BUILD_DIR/obj"
COMBINED_OBJ="$OBJ_DIR/libaemu-snapshot-combined.o"
LOG="$BUILD_DIR/build.log"

# Keep this order aligned with the snapshot dependency chain. The generated
# protobuf sources sit before Snapshot/Snapshotter so their symbols are in the
# archive before the modules that consume them.
SOURCE_FILES=(
    "$QEMU_ANDROID_DIR/third_party/murmurhash/MurmurHash3.cpp"
    "$QEMU_EMU_BASE_DIR/memory/src/android/base/memory/MemoryHints.cpp"
    "$SRC_DIR/PathUtils.cpp"
    "$SRC_DIR/RamSaver.cpp"
    "$SRC_DIR/RamLoader.cpp"
    "$PROTO_GEN_DIR/snapshot.pb.cc"
    "$PROTO_GEN_DIR/snapshot_deps.pb.cc"
    "$PROTO_GEN_DIR/studio_stats.pb.cc"
    "$PROTO_GEN_DIR/emulator_compatible.pb.cc"
    "$SRC_DIR/Snapshot.cpp"
    "$SRC_DIR/Snapshotter.cpp"
    "$SRC_DIR/Quickboot.cpp"
    "$SRC_DIR/Decompressor.cpp"
    "$SRC_DIR/Compressor.cpp"
    "$SRC_DIR/GapTracker.cpp"
    "$SRC_DIR/Hierarchy.cpp"
    "$SRC_DIR/common.cpp"
    "$SRC_DIR/Saver.cpp"
    "$SRC_DIR/TextureLoader.cpp"
    "$SRC_DIR/TextureSaver.cpp"
    "$SRC_DIR/MemoryWatch_common.cpp"
    "$SRC_DIR/MemoryWatch_linux.cpp"
    "$SRC_DIR/IncrementalStats.cpp"
    "$SRC_DIR/Loader.cpp"
)

CXXFLAGS=(
    "--target=$TARGET"
    -std=c++17
    -fPIC
    -O2
    -DNDEBUG
    -MMD
    -MP
)

INCLUDES=(
    "-I$WORKDIR/aemu/base/include"
    "-I$WORKDIR/aemu/host-common/include"
    "-I$WORKDIR/aemu/snapshot/include"
    "-I$WORKDIR/qemu-aosp/android/emu/base/include"
    "-I$WORKDIR/qemu-aosp/android/emu/avd/include"
    "-I$WORKDIR/qemu-aosp/android/emu/agents/include"
    "-I$WORKDIR/qemu-aosp/android/emu/cmdline/include"
    "-I$WORKDIR/qemu-aosp/android/emu/crashreport/include"
    "-I$WORKDIR/qemu-aosp/android/emu/files/include"
    "-I$WORKDIR/qemu-aosp/android/emu/feature/include"
    "-I$WORKDIR/qemu-aosp/android/emu/metrics/include"
    "-I$WORKDIR/qemu-aosp/android/emu/protobuf/include"
    "-I$WORKDIR/qemu-aosp/android/emu/studio-config/include"
    "-I$WORKDIR/qemu-aosp/android/emu/utils/include"
    "-I$WORKDIR/qemu-aosp/android/android-emu-base"
    "-I$WORKDIR/qemu-aosp/android/android-emu"
    "-I$WORKDIR/qemu-aosp/android/third_party/crashpad"
    "-I$WORKDIR/qemu-aosp/android/third_party/crashpad/third_party/mini_chromium/mini_chromium"
    "-I$WORKDIR/qemu-aosp/android/third_party/murmurhash"
    "-I$WORKDIR/qemu-aosp-build-arm64-v8a"
    "-I$WORKDIR/gfxstream/include"
    "-I$WORKDIR/gfxstream/host/gl/gl-host-common/include"
    "-I$ABSEIL_DIR"
    "-I$LZ4_INCLUDE_DIR"
    "-I$PROTO_GEN_DIR"
    "-I$PROTOBUF_INCLUDE_DIR"
)

# Link context for the eventual QEMU link. Creating an archive does not use
# these, but keep the agreed abseil/lz4/protobuf layout in one place for
# callers.
ABSEIL_LDFLAGS=("-L$ABSEIL_BUILD_DIR")
ABSEIL_LIBS=(
    -labsl_raw_logging_internal
    -labsl_str_format_internal
    -labsl_strings
    -labsl_base
    -labsl_int128
)
LZ4_LDFLAGS=("-L$LZ4_LIB_DIR")
LZ4_LIBS=("$LZ4_LIB")
PROTOBUF_LDFLAGS=("-L$PROTOBUF_LIB_DIR")
PROTOBUF_LIBS=("$PROTOBUF_LIB")

for path in "$SRC_DIR" "$ABSEIL_DIR" "$LZ4_INCLUDE_DIR/lz4.h" \
            "$LZ4_INCLUDE_DIR/lz4hc.h" "$LZ4_LIB" \
            "$PROTO_GEN_DIR/snapshot.pb.h" \
            "$PROTO_GEN_DIR/snapshot.pb.cc" \
            "$PROTO_GEN_DIR/snapshot_deps.pb.h" \
            "$PROTO_GEN_DIR/snapshot_deps.pb.cc" \
            "$PROTO_GEN_DIR/studio_stats.pb.h" \
            "$PROTO_GEN_DIR/studio_stats.pb.cc" \
            "$PROTO_GEN_DIR/emulator_compatible.pb.h" \
            "$PROTO_GEN_DIR/emulator_compatible.pb.cc" \
            "$PROTOBUF_INCLUDE_DIR/google/protobuf/message.h" \
            "$PROTOBUF_LIB" "$CXX" "$AR" "$LINKER"; do
    [ -e "$path" ] || {
        echo "missing required path: $path" >&2
        exit 1
    }
done

for src in "${SOURCE_FILES[@]}"; do
    [ -f "$src" ] || {
        echo "missing source: $src" >&2
        exit 1
    }
done

mkdir -p "$OBJ_DIR"
: >"$LOG"

echo "==> sources  $SRC_DIR"
echo "==> build    $BUILD_DIR"
echo "==> output   $LIB"
echo "==> target   $TARGET"
echo "==> compiler $CXX"
echo "==> abseil   $ABSEIL_DIR"
echo "==> abseil   $ABSEIL_BUILD_DIR"
echo "==> lz4      $LZ4_INCLUDE_DIR"
echo "==> lz4      $LZ4_LIB"
echo "==> protobuf $PROTO_GEN_DIR"
echo "==> protobuf $PROTOBUF_INCLUDE_DIR"
echo "==> protobuf $PROTOBUF_LIB"
echo "==> log      $LOG"

if [ ! -d "$ABSEIL_BUILD_DIR" ]; then
    echo "!! abseil build dir is not ready; expected: $ABSEIL_BUILD_DIR" >&2
fi

rm -f "$LIB" "$COMBINED_OBJ"

compiled=0
object_files=()
for src in "${SOURCE_FILES[@]}"; do
    name="$(basename "$src" .cpp)"
    obj="$OBJ_DIR/$name.o"
    dep="$OBJ_DIR/$name.d"

    rm -f "$obj" "$dep"
    echo "==> compile $(basename "$src")"

    if ! "$CXX" "${CXXFLAGS[@]}" "${INCLUDES[@]}" \
            -c "$src" -o "$obj" >>"$LOG" 2>&1; then
        echo "!! failed at $(basename "$src")" >&2
        echo "-- first error --" >&2
        grep -n -m1 "error:" "$LOG" >&2 || true
        echo "-- log tail --" >&2
        tail -40 "$LOG" >&2
        exit 1
    fi

    object_files+=("$obj")
    compiled=$((compiled + 1))
    echo "    ok $(ls -lh "$obj" | awk '{print $5}')"
done

echo "==> compiled $compiled source files"
echo "==> partial link $COMBINED_OBJ"
if ! "$LINKER" -r -m aarch64linux "${object_files[@]}" \
        -o "$COMBINED_OBJ" >>"$LOG" 2>&1; then
    echo "!! failed to partial-link objects" >&2
    tail -60 "$LOG" >&2
    exit 1
fi

if ! "$AR" rcs "$LIB" "$COMBINED_OBJ" >>"$LOG" 2>&1; then
    echo "!! failed to archive $COMBINED_OBJ" >&2
    tail -40 "$LOG" >&2
    exit 1
fi

echo "==> archive members:"
"$AR" t "$LIB"
echo "==> artifact: $LIB"
ls -lh "$LIB"
echo "==> abseil link flags: ${ABSEIL_LDFLAGS[*]} ${ABSEIL_LIBS[*]}"
echo "==> lz4 link flags: ${LZ4_LDFLAGS[*]} ${LZ4_LIBS[*]}"
echo "==> protobuf link flags: ${PROTOBUF_LDFLAGS[*]} ${PROTOBUF_LIBS[*]}"
echo "done."
