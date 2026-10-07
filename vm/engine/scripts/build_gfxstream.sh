#!/usr/bin/env bash
#
# 交叉编译 gfxstream 宿主渲染器（GL 路径）为 Android/arm64 静态库。
#
# 目的：让 `pipe:opengles` AndroidPipe 服务可用（android_getOpenglesRenderer 非空），
# 从而让 guest 的 hwcomposer(EmuHWC2) 能建立 gfxstream 宿主连接，停止
# SurfaceFlinger 的 onrestart 连锁崩溃。
#
# 关键决策（详见 docs/opengles宿主渲染器实施方案.md）：
#   1. 以 gfxstream 仓库为 cmake 根，BUILD_STANDALONE=ON 对着已编好的 aemu；
#   2. 必须定义 -DANDROID：否则 EglGlobalInfo.cpp 会走 GLX -> libGL.so.1 + X11；
#   3. 用宿主设备自带的系统 EGL/GLES（dlopen libEGL.so / libGLESv2.so），
#      配套 gfxstream_deps.cmake 预置依赖 target，绕开 ANGLE / SwiftShader 预编译；
#   4. 排除三个 X11 源文件（Linux 分支默认会带上，aarch64 上编不过）。
#
# 产物：
#   $BUILD_DIR/host/libgfxstream_backend_static.a
#   $BUILD_DIR/host/gl/gl-host-common/libgfxstream-gl-host-common.a
#
# 用法：
#   ./build_gfxstream.sh
#   CONFIGURE_ONLY=1 ./build_gfxstream.sh
#
set -euo pipefail

WORKDIR="${WORKDIR:-/root/vmbuild}"
SRC_DIR="${SRC_DIR:-$WORKDIR/gfxstream}"
BUILD_DIR="${BUILD_DIR:-$WORKDIR/gfxstream-build-arm64-v8a}"

AEMU_DIR="${AEMU_DIR:-$WORKDIR/aemu}"
AEMU_LIB_DIR="${AEMU_LIB_DIR:-$WORKDIR/aemu-build-arm64-v8a}"

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"

NDK_VER="${NDK_VER:-r28}"
NDK_DIR="$WORKDIR/android-ndk-$NDK_VER"
TOOLCHAIN="$NDK_DIR/build/cmake/android.toolchain.cmake"
API_LEVEL="${API_LEVEL:-28}"
JOBS="${JOBS:-$(nproc)}"

LOG="$BUILD_DIR/build.log"
DEPS_CMAKE="$TOOLS_DIR/gfxstream_deps.cmake"

[ -d "$SRC_DIR/host" ] || {
    echo "找不到 gfxstream 源码：$SRC_DIR" >&2; exit 1; }
[ -d "$AEMU_DIR/host-common" ] || {
    echo "找不到 aemu 源码：$AEMU_DIR" >&2; exit 1; }
for _lib in host-common/libaemu-host-common.a base/libaemu-base.a \
            host-common/liblogging-base.a snapshot/libgfxstream-snapshot.a; do
    [ -f "$AEMU_LIB_DIR/$_lib" ] || {
        echo "找不到 aemu 静态库：$AEMU_LIB_DIR/$_lib（先跑 build_aemu.sh）" >&2; exit 1; }
done
[ -f "$DEPS_CMAKE" ] || { echo "找不到 $DEPS_CMAKE" >&2; exit 1; }
[ -f "$TOOLCHAIN" ] || { echo "找不到 NDK cmake toolchain：$TOOLCHAIN" >&2; exit 1; }

mkdir -p "$BUILD_DIR"
echo "==> 源码   $SRC_DIR"
echo "==> 构建   $BUILD_DIR"
echo "==> aemu   $AEMU_DIR ($AEMU_LIB_DIR)"
echo "==> ABI    arm64-v8a / android-$API_LEVEL"
echo "==> 日志   $LOG"

# ------------------------------------------------------- 0. 源码重置 + 补丁
# 每次从 git 干净版本重新打补丁，保证幂等。
if git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "==> 从 git 恢复待打补丁的 CMakeLists"
    git -C "$SRC_DIR" checkout -- \
        host/CMakeLists.txt \
        host/gl/glestranslator/EGL/CMakeLists.txt \
        host/apigen-codec-common/CMakeLists.txt 2>/dev/null || true
fi

# 1) 非 WIN32/APPLE/QNX 一律用 NativeSubWindow_x11.cpp；换成 Android 版
f="$SRC_DIR/host/CMakeLists.txt"
sed -i 's|set(stream-server-core-platform-sources NativeSubWindow_x11.cpp)|set(stream-server-core-platform-sources NativeSubWindow_android.cpp) # VMHOST_NO_X11|' "$f"
grep -q "VMHOST_NO_X11" "$f" \
    && echo "==> patch: host/CMakeLists.txt 用 NativeSubWindow_android.cpp" \
    || { echo "!! NativeSubWindow 补丁未命中" >&2; exit 1; }

# 2) EGL translator 的 linux 源里去掉 GLX / X11ErrorHandler
f="$SRC_DIR/host/gl/glestranslator/EGL/CMakeLists.txt"
perl -0pi -e 's{set\(egl-translator-linux-sources\n    CoreProfileConfigs_linux\.cpp EglOsApi_egl\.cpp EglOsApi_glx\.cpp X11ErrorHandler\.cpp\)}{set(egl-translator-linux-sources\n    CoreProfileConfigs_linux.cpp EglOsApi_egl.cpp) # VMHOST_NO_X11}' "$f"
grep -q "VMHOST_NO_X11" "$f" \
    && echo "==> patch: EGL translator 去掉 EglOsApi_glx/X11ErrorHandler" \
    || { echo "!! EGL translator 补丁未命中" >&2; exit 1; }

# 3) apigen-codec-common 去掉 X11Support.cpp
f="$SRC_DIR/host/apigen-codec-common/CMakeLists.txt"
sed -i 's|set(apigen-codec-common-platform-sources X11Support.cpp)|set(apigen-codec-common-platform-sources) # VMHOST_NO_X11|' "$f"
grep -q "VMHOST_NO_X11" "$f" \
    && echo "==> patch: apigen-codec-common 去掉 X11Support.cpp" \
    || { echo "!! apigen-codec-common 补丁未命中" >&2; exit 1; }

# 4) GLDispatch.cpp：去掉 GL ES3 入口的版本门控。
#    原版按传入 version 门控加载 ES3/ES3.1 入口，但这张表只加载一次（m_isLoaded
#    早退），"先到者"的 version 未必反映宿主真实能力 —— 实测宿主是 GLES 3.2，
#    表却按 GLES_1_1 先加载，glBindVertexArray 等 ES3 入口全为 NULL，GLES1
#    翻译器在 egl2egl 模式下用 CoreProfileEngine 调它们时 pc=0 崩溃。
#    详见 docs/方案B排障交接.md §9.1。
f="$SRC_DIR/host/gl/glestranslator/GLcommon/GLDispatch.cpp"
if grep -q "VMHOST_FIX" "$f"; then
    echo "==> patch: GLDispatch 版本门控（已打过，跳过）"
else
    python3 - "$f" <<'VMHOST_PY'
import io, sys
p = sys.argv[1]
src = io.open(p, encoding='utf-8').read()
old = """    if (version >= GLES_3_0) {
        LIST_GLES3_ONLY_FUNCTIONS(LOAD_GLEXT_FUNC)
        LIST_GLES3_ONLY_FUNCTIONS(LOAD_GLEXT_FUNC_DEBUG_LOG_WRAPPER)

        LIST_GLES3_EXTENSIONS_FUNCTIONS(LOAD_GLEXT_FUNC)
        LIST_GLES3_EXTENSIONS_FUNCTIONS(LOAD_GLEXT_FUNC_DEBUG_LOG_WRAPPER)
    }

    if (version >= GLES_3_1) {
        LIST_GLES31_ONLY_FUNCTIONS(LOAD_GLEXT_FUNC)
        LIST_GLES31_ONLY_FUNCTIONS(LOAD_GLEXT_FUNC_DEBUG_LOG_WRAPPER)
    }"""
new = """    /* VMHOST_FIX: 原版按 version 门控；但本表只加载一次，"先到者"的 version
       未必反映宿主真实能力（实测宿主 GLES 3.2、表按 GLES_1_1 先加载），
       ES3 入口全为 NULL，CoreProfileEngine 一调就 pc=0。改为一律尝试解析：
       宿主不支持的入口 getProc 本就返回 NULL，与门控结果一致。 */
    LIST_GLES3_ONLY_FUNCTIONS(LOAD_GLEXT_FUNC)
    LIST_GLES3_ONLY_FUNCTIONS(LOAD_GLEXT_FUNC_DEBUG_LOG_WRAPPER)

    LIST_GLES3_EXTENSIONS_FUNCTIONS(LOAD_GLEXT_FUNC)
    LIST_GLES3_EXTENSIONS_FUNCTIONS(LOAD_GLEXT_FUNC_DEBUG_LOG_WRAPPER)

    LIST_GLES31_ONLY_FUNCTIONS(LOAD_GLEXT_FUNC)
    LIST_GLES31_ONLY_FUNCTIONS(LOAD_GLEXT_FUNC_DEBUG_LOG_WRAPPER)"""
if old not in src:
    sys.stderr.write("!! GLDispatch 补丁未命中\n")
    sys.exit(1)
io.open(p, 'w', encoding='utf-8').write(src.replace(old, new, 1))
VMHOST_PY
    grep -q "VMHOST_FIX" "$f" \
        && echo "==> patch: GLDispatch 去掉 ES3 入口的版本门控" \
        || { echo "!! GLDispatch 补丁未生效" >&2; exit 1; }
fi

# ---------------------------------------------------------------- 1. configure
# 宿主侧需要 <cutils/native_handle.h>（AOSP 头，NDK 没有；仓内自带一份）。
# 只把这一个头拷进 shim 目录，避免把 android_stub 整目录挂上来遮蔽 NDK 头。
SHIM_DIR="$BUILD_DIR/vmhost-shim"
mkdir -p "$SHIM_DIR/cutils"
cp -f "$SRC_DIR/guest/mesa/include/android_stub/cutils/native_handle.h" \
      "$SHIM_DIR/cutils/native_handle.h"

echo "==> configure"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STANDALONE=ON \
    -DDEPENDENCY_RESOLUTION=AOSP \
    -DUSE_ANGLE_SHADER_PARSER=OFF \
    -DASTC_CPU_DECODING=OFF \
    -DENABLE_VKCEREAL_TESTS=OFF \
    -DWITH_BENCHMARK=OFF \
    -DBUILD_GRAPHICS_DETECTOR=OFF \
    -DCMAKE_C_FLAGS="-DANDROID" \
    -DCMAKE_CXX_FLAGS="-DANDROID" \
    -DCMAKE_PROJECT_INCLUDE="$DEPS_CMAKE" \
    -DVMHOST_AEMU_DIR="$AEMU_DIR" \
    -DVMHOST_AEMU_LIB_DIR="$AEMU_LIB_DIR" \
    -DVMHOST_GFXSTREAM_ROOT="$SRC_DIR" \
    -DVMHOST_EXTRA_INCLUDE="$SHIM_DIR" \
    >"$LOG" 2>&1 || {
    echo "!! configure 失败，末尾日志：" >&2
    tail -40 "$LOG" >&2
    exit 1
}
echo "==> configure ok"

if [ "${CONFIGURE_ONLY:-0}" = "1" ]; then
    echo "==> 仅 configure，按要求退出"
    exit 0
fi

# ---------------------------------------------------------------- 2. build
TARGETS=(gfxstream_backend_static gfxstream-gl-host-common)
echo "==> ninja -j$JOBS ${TARGETS[*]}"
if ! ninja -C "$BUILD_DIR" -j"$JOBS" "${TARGETS[@]}" >>"$LOG" 2>&1; then
    echo "!! 构建失败，错误摘录：" >&2
    grep -nE "error:|FAILED" "$LOG" | tail -40 >&2
    exit 1
fi

# ---------------------------------------------------------------- 3. 产出
echo "==> 产物静态库："
for t in host/libgfxstream_backend_static.a host/gl/gl-host-common/libgfxstream-gl-host-common.a; do
    ls -lh "$BUILD_DIR/$t" 2>/dev/null || echo "  ?? 缺 $t"
done
echo "完成。"
