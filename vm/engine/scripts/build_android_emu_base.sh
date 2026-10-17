#!/usr/bin/env bash
#
# 交叉编译 QEMU 树内 **vendored** 的 android-emu-base（含 memory / logging 子库）
# 为 Android/arm64 静态库。
#
# 为什么需要它（详见 vm/engine/scripts/aemu快照移植指南.md §8）：
#   模拟器的快照子集（`android-emu` target）在官方构建里链的是 QEMU 树内这份
#   vendored base（`android/android-emu-base/CMakeLists.txt` 的源清单 +
#   `android/emu/base/{memory,logging}/CMakeLists.txt`），而不是外部 aemu 仓库
#   编出来的 `libaemu-base.a`。两者**同处 `android::base` 命名空间**，混链必然
#   先撞重复定义、再连锁缺符号。我们已经实测踩过这条路。
#
# 产物（约定路径，build_qemu_aosp.sh 按这里找）：
#   $BUILD_DIR/lib/libandroid-emu-base.a
#   $BUILD_DIR/lib/libandroid-emu-base-memory.a
#   $BUILD_DIR/lib/libandroid-emu-base-logging.a
#
# 用法：
#   ./build_android_emu_base.sh
#
set -euo pipefail

WORKDIR="${WORKDIR:-/root/vmbuild}"
SRC_ROOT="${SRC_ROOT:-$WORKDIR/qemu-aosp/android}"
BUILD_DIR="${BUILD_DIR:-$WORKDIR/android-emu-base-build-arm64-v8a}"
AEMU_DIR="${AEMU_DIR:-$WORKDIR/aemu}"
ABSEIL_DIR="${ABSEIL_DIR:-$WORKDIR/abseil}"

NDK_VER="${NDK_VER:-r28}"
TOOLCHAIN="$WORKDIR/android-ndk-$NDK_VER/toolchains/llvm/prebuilt/linux-x86_64"
TARGET="${TARGET:-aarch64-linux-android28}"
CC="${CC:-$TOOLCHAIN/bin/clang}"
CXX="${CXX:-$TOOLCHAIN/bin/clang++}"
AR="${AR:-$TOOLCHAIN/bin/llvm-ar}"

LOG="$BUILD_DIR/build.log"
MAIN_OBJ="$BUILD_DIR/obj/base"
MEM_OBJ="$BUILD_DIR/obj/memory"
LOG_OBJ="$BUILD_DIR/obj/logging"
LIB_DIR="$BUILD_DIR/lib"

[ -d "$SRC_ROOT/android-emu-base" ] || {
    echo "找不到 vendored base：$SRC_ROOT/android-emu-base" >&2; exit 1; }
[ -f "$TOOLCHAIN/bin/clang++" ] || {
    echo "找不到 NDK toolchain：$TOOLCHAIN" >&2; exit 1; }

mkdir -p "$MAIN_OBJ" "$MEM_OBJ" "$LOG_OBJ" "$LIB_DIR"
: > "$LOG"

echo "==> 源码   $SRC_ROOT"
echo "==> 构建   $BUILD_DIR"
echo "==> ABI    arm64-v8a / android-28"
echo "==> 日志   $LOG"

# 公共 include：vendored 头在前，外部 aemu 头只给 `aemu/base/*` 兜底。
INCLUDES=(
    "-I$SRC_ROOT/emu/base/include"
    "-I$SRC_ROOT/android-emu-base"
    "-I$AEMU_DIR/base/include"
    # StringUtils.cpp 等要 host-common/GfxstreamFatalError.h（外部 aemu 那份）
    "-I$AEMU_DIR/host-common/include"
    "-I$ABSEIL_DIR"
    # CompressingStream / DecompressingStream 要 lz4.h（我们已单独交叉编译过 lz4）
    "-I$WORKDIR/lz4-build-arm64-v8a/include"
)

# AEMU_TCMALLOC_ENABLED=0：官方 CMake 在没开 OPTION_TCMALLOC 时就是这个值，
# MemoryTracker.cpp 用 #error 强制要求显式给出（见 emu/base/memory/CMakeLists.txt）。
CFLAGS=("--target=$TARGET" -fPIC -O2 -DNDEBUG -DAEMU_TCMALLOC_ENABLED=0 "${INCLUDES[@]}")
CXXFLAGS=("--target=$TARGET" -std=c++17 -fPIC -O2 -DNDEBUG -DAEMU_TCMALLOC_ENABLED=0 "${INCLUDES[@]}")

# ---------------------------------------------------------------- 主库源清单
# 来自 $SRC_ROOT/android-emu-base/CMakeLists.txt:15-114（SOURCE_DIR 即该目录），
# 外加 LINUX 段的两个 POSIX 实现（FileSystemWatcherPosix / Thread_pthread）。
# 路径都相对 $SRC_ROOT/android-emu-base。
MAIN_SRC=(
    aemu/base/system/Memory.cpp
    aemu/base/system/System.cpp
    android/base/AlignedBuf.cpp
    android/base/async/AsyncReader.cpp
    android/base/async/AsyncSocketServer.cpp
    android/base/async/AsyncWriter.cpp
    android/base/async/DefaultLooper.cpp
    android/base/async/Looper.cpp
    android/base/async/ScopedSocketWatch.cpp
    android/base/async/ThreadLooper.cpp
    # 注意：CMake 清单里的 android/base/Backtrace.cpp 被**有意排除** ——
    # 它要 <libunwind.h>，而 libunwind 在 Android 上是平台库、NDK 里没有
    # （NDK 只带 host/musl/gnu 三元的 libunwind）；我们的链路
    # （快照 + host-common）里也没有任何地方引用 android::base::Backtrace。
    android/base/CpuTime.cpp
    android/base/CpuUsage.cpp
    android/base/Debug.cpp
    android/base/files/CompressingStream.cpp
    android/base/files/DecompressingStream.cpp
    android/base/files/Fd.cpp
    android/base/files/FileShareOpen.cpp
    android/base/files/FileSystemWatcherPosix.cpp
    android/base/files/GzipStreambuf.cpp
    android/base/files/IniFile.cpp
    android/base/files/InplaceStream.cpp
    android/base/files/MemStream.cpp
    android/base/files/PathUtils.cpp
    android/base/files/QueueStreambuf.cpp
    android/base/files/StdioStream.cpp
    android/base/files/Stream.cpp
    android/base/files/StreamSerializing.cpp
    android/base/files/TarStream.cpp
    android/base/gl_object_counter.cpp
    android/base/GLObjectCounter.cpp
    android/base/IOVector.cpp
    android/base/JsonWriter.cpp
    android/base/Process.cpp
    android/base/misc/FileUtils.cpp
    android/base/misc/HttpUtils.cpp
    android/base/misc/IpcPipe.cpp
    android/base/misc/StringUtils.cpp
    android/base/misc/Utf8Utils.cpp
    android/base/network/Dns.cpp
    android/base/network/IpAddress.cpp
    android/base/network/NetworkUtils.cpp
    android/base/perflogger/Benchmark.cpp
    android/base/perflogger/BenchmarkLibrary.cpp
    android/base/perflogger/Metric.cpp
    android/base/perflogger/WindowDeviationAnalyzer.cpp
    android/base/Pool.cpp
    android/base/ProcessControl.cpp
    android/base/ring_buffer.c
    android/base/sockets/SocketDrainer.cpp
    android/base/sockets/SocketUtils.cpp
    android/base/sockets/SocketWaiter.cpp
    android/base/Stopwatch.cpp
    android/base/StringFormat.cpp
    android/base/StringParse.cpp
    android/base/SubAllocator.cpp
    android/base/synchronization/MessageChannel.cpp
    android/base/system/System.cpp
    android/base/threads/Async.cpp
    android/base/threads/FunctorThread.cpp
    android/base/threads/internal/ParallelTaskBase.cpp
    android/base/threads/ThreadStore.cpp
    android/base/threads/Thread_pthread.cpp
    android/base/Uri.cpp
    # 注意：android/base/Uuid.cpp 也被有意排除 —— 它 include <uuid/uuid.h>
    # （libuuid 是宿主库，Android/NDK 没有）；全树只有它自己的 unittest 引用它。
    android/base/Version.cpp
    android/utils/bufprint.c
    android/utils/bufprint_system.cpp
    android/utils/dirscanner.cpp
    android/utils/eintr_wrapper.c
    android/utils/fd.cpp
    android/utils/file_io.cpp
    android/utils/looper.cpp
    android/utils/misc.c
    android/utils/panic.c
    android/utils/path.cpp
    android/utils/path_system.cpp
    android/utils/socket_drainer.cpp
    android/utils/sockets.c
    android/utils/stralloc.c
    android/utils/stream.cpp
    android/utils/string.cpp
    android/utils/system.c
    android/utils/tempfile.c
    android/utils/x86_cpuid.cpp
)

# ---------------------------------------------------------------- memory / logging
MEM_SRC=(
    android/base/memory/ContiguousRangeMapper.cpp
    android/base/memory/LazyInstance.cpp
    android/base/memory/MemoryHints.cpp
    android/base/memory/MemoryTracker.cpp
    android/base/memory/SharedMemory_posix.cpp
)

LOG_SRC=(
    android/base/logging/Log.cpp
    android/base/logging/LogConfiguration.cpp
    android/base/logging/LogFormatter.cpp
)

compile_list() {
    local tag="$1" objdir="$2" srcdir="$3"; shift 3
    local src
    for src in "$@"; do
        local base name obj
        base="$(basename "$src")"
        name="${base%.*}"
        obj="$objdir/${tag}_${name}.o"
        case "$base" in
            *.c)   # C 源：用 clang
                "$CC" "${CFLAGS[@]}" -c "$srcdir/$src" -o "$obj" ;;
            *)     # 其余按 C++ 编
                "$CXX" "${CXXFLAGS[@]}" -c "$srcdir/$src" -o "$obj" ;;
        esac || {
            echo "!! 编译失败：$srcdir/$src" >&2
            return 1
        }
    done
}

echo "==> 编主库（${#MAIN_SRC[@]} 个 TU）"
compile_list base "$MAIN_OBJ" "$SRC_ROOT/android-emu-base" "${MAIN_SRC[@]}" >>"$LOG" 2>&1 || {
    echo "!! 主库编译失败，末尾日志：" >&2; tail -30 "$LOG" >&2; exit 1; }
rm -f "$LIB_DIR/libandroid-emu-base.a"
"$AR" rcs "$LIB_DIR/libandroid-emu-base.a" "$MAIN_OBJ"/*.o

echo "==> 编 memory 子库（${#MEM_SRC[@]} 个 TU）"
compile_list mem "$MEM_OBJ" "$SRC_ROOT/emu/base/memory/src" "${MEM_SRC[@]}" >>"$LOG" 2>&1 || {
    echo "!! memory 编译失败，末尾日志：" >&2; tail -30 "$LOG" >&2; exit 1; }
rm -f "$LIB_DIR/libandroid-emu-base-memory.a"
"$AR" rcs "$LIB_DIR/libandroid-emu-base-memory.a" "$MEM_OBJ"/*.o

echo "==> 编 logging 子库（${#LOG_SRC[@]} 个 TU）"
compile_list log "$LOG_OBJ" "$SRC_ROOT/emu/base/logging/src" "${LOG_SRC[@]}" >>"$LOG" 2>&1 || {
    echo "!! logging 编译失败，末尾日志：" >&2; tail -30 "$LOG" >&2; exit 1; }
rm -f "$LIB_DIR/libandroid-emu-base-logging.a"
"$AR" rcs "$LIB_DIR/libandroid-emu-base-logging.a" "$LOG_OBJ"/*.o

echo "==> 产物："
ls -la "$LIB_DIR"/*.a

echo "==> 关键符号自检（应能看到 System/PathUtils/MemStream/SubAllocator/logging）"
"$TOOLCHAIN/bin/llvm-nm" -C --defined-only "$LIB_DIR/libandroid-emu-base.a" 2>/dev/null \
    | grep -E "android::base::(System::get|PathUtils::pj|MemStream|SubAllocator)" | head -8 || true
"$TOOLCHAIN/bin/llvm-nm" -C --defined-only "$LIB_DIR/libandroid-emu-base-logging.a" 2>/dev/null \
    | grep -E "OutputLog|__emu_log_print_str" | head -4 || true

echo "==> 完成"
