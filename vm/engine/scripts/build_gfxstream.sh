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

# 5) 宿主侧诊断插桩（VMHOST_DIAG 系列）：GLES2 命令直方图/环形缓冲、
#    ColorBuffer 的 blit 与 readback 探针、TextureDraw 链接结果、FrameBuffer::post 打点。
#    逐条幂等（marker 命中即跳过），锚点未命中只告警不中断 —— 诊断插桩不是构建必需。
#    用法与说明见 qemu_patches/patch_vmhost_diag.py 的文件头。
#    VMHOST_DIAG=0 可整体关闭，用于做「干净基线」对比（排除插桩本身影响行为）。
#    注意：关掉之前必须先把已打补丁的文件从 git 还原，否则只是"不重复打补丁"，
#    旧补丁仍留在源码里 —— 干净基线的还原命令：
#      git -C "$SRC_DIR" checkout -- host/gl/gles2_dec/gles2_dec.cpp \
#          host/gl/ColorBufferGl.cpp host/gl/TextureDraw.cpp \
#          host/FrameBuffer.cpp host/FrameBuffer.h host/RenderControl.cpp
if [ "${VMHOST_DIAG:-1}" = "1" ] && [ -f "$TOOLS_DIR/qemu_patches/patch_vmhost_diag.py" ]; then
    python3 "$TOOLS_DIR/qemu_patches/patch_vmhost_diag.py" "$SRC_DIR" || \
        echo "!! VMHOST_DIAG 插桩脚本执行异常（仅告警，继续构建）" >&2
else
    echo "==> VMHOST_DIAG=0：跳过宿主侧诊断插桩（干净基线）"
fi

# 5b) VMHOST_BINDCTX：定位"谁把上下文绑成没有 surface 的"（D15 结论）。
#     宿主 Adreno 830 驱动在"上下文有效但 draw/read surface = NULL"时会于固定指令
#     `LDR x5,[x21,#0x38]`（x21=0）上 SIGSEGV，从而 QEMU 整个进程死掉 —— 这正是
#     "合不出帧 / 所有被 post 的 ColorBuffer 全 0 / 访客从不 post"的上游原因。
#     FrameBuffer::bindContext() 是唯一允许 draw/read 传 EGL_NO_SURFACE 的入口，
#     所以在那里打点：draw/read 为 0 且 ctx 非 0 即肇事调用，并带出调用方偏移。
#     这个探针**不碰 GL 状态**，与 VMHOST_DIAG 的开关系独立。
f="$SRC_DIR/host/FrameBuffer.cpp"
if grep -q "VMHOST_BINDCTX" "$f"; then
    echo "==> patch: bindContext 无 surface 打点（已打过，跳过）"
else
    python3 - "$f" <<'VMHOST_PY2'
import io, sys
p = sys.argv[1]
src = io.open(p, encoding='utf-8').read()

anchor_inc = "#include <stdio.h>\n#include <string.h>\n#include <time.h>\n"
new_inc = anchor_inc + (
    "#include <stdlib.h>      /* VMHOST_BINDCTX: sscanf */\n"
    "#include <sys/syscall.h> /* VMHOST_BINDCTX: SYS_gettid */\n"
    "#include <unistd.h>      /* VMHOST_BINDCTX: syscall */\n")
if anchor_inc not in src:
    sys.stderr.write("!! VMHOST_BINDCTX include 锚点未命中\n")
    sys.exit(1)
src = src.replace(anchor_inc, new_inc, 1)

anchor = """    if (!s_egl.eglMakeCurrent(getDisplay(),
                              draw ? draw->getEGLSurface() : EGL_NO_SURFACE,
                              read ? read->getEGLSurface() : EGL_NO_SURFACE,
                              ctx ? ctx->getEGLContext() : EGL_NO_CONTEXT)) {
        ERR("eglMakeCurrent failed");
        return false;
    }
"""
probe = anchor + """
    /* VMHOST_BINDCTX: 谁把上下文绑成了"没有 surface"？
       draw/read 为 0 且 ctx 非 0 = 肇事调用；caller_off 是调用方相对
       libqemu_exec.so 基址的偏移，可直接 addr2line 定位到 host/*.cpp 行。 */
    {
        static uintptr_t s_base = 0;
        static int s_baseDone = 0;
        if (!s_baseDone) {
            s_baseDone = 1;
            FILE* mf = fopen("/proc/self/maps", "r");
            if (mf != NULL) {
                char ml[512];
                while (fgets(ml, sizeof ml, mf) != NULL) {
                    if (strstr(ml, "libqemu_exec.so") != NULL) {
                        unsigned long v = 0;
                        if (sscanf(ml, "%lx", &v) == 1) {
                            s_base = (uintptr_t)v;
                        }
                        break;
                    }
                }
                fclose(mf);
            }
        }
        const uintptr_t ra = (uintptr_t)__builtin_return_address(0);
        fprintf(stderr,
                "VMHOST_BINDCTX tid=%ld draw=%p read=%p ctx=%p caller_off=0x%zx\\n",
                (long)syscall(SYS_gettid),
                (void*)(uintptr_t)(draw ? draw->getEGLSurface() : EGL_NO_SURFACE),
                (void*)(uintptr_t)(read ? read->getEGLSurface() : EGL_NO_SURFACE),
                (void*)(uintptr_t)(ctx ? ctx->getEGLContext() : EGL_NO_CONTEXT),
                (size_t)(ra - s_base));
    }
"""
if anchor not in src:
    sys.stderr.write("!! VMHOST_BINDCTX 主体锚点未命中\n")
    sys.exit(1)
src = src.replace(anchor, probe, 1)
io.open(p, 'w', encoding='utf-8').write(src)
VMHOST_PY2
    grep -q "VMHOST_BINDCTX" "$f" \
        && echo "==> patch: bindContext 无 surface 打点已注入" \
        || { echo "!! VMHOST_BINDCTX 补丁未生效" >&2; exit 1; }
fi

# 5c) VMHOST_MAKECURFIX：真正的修点 —— 翻译器到平台 EGL 的那一层。
#     EglOsEglDisplay::makeCurrent() 传给平台 EGL 的 surface 参数是 surface 对象的
#     底层 EGL handle，而该 handle 可能是 0（已销毁/从未创建）。这时它就变成
#     eglMakeCurrent(dpy, 0, 0, ctx)：**上下文在、draw/read surface 为空** ——
#     宿主 Adreno 830 驱动正是在这个状态下于固定指令 `LDR x5,[x21,#0x38]`（x21=0）
#     上 SIGSEGV（D15 实测：eglGetCurrentContext 非空、两边 surface 都是 0），
#     直接打死整个 QEMU 进程。
#     修法：用 1x1 pbuffer 顶上缺的那一边，让驱动始终有合法 surface。
f="$SRC_DIR/host/gl/glestranslator/EGL/EglOsApi_egl.cpp"
if [ "${VMHOST_MAKECURFIX:-1}" = "0" ]; then
    echo "==> VMHOST_MAKECURFIX=0：跳过 makeCurrent 修复（二分用；需先把该文件 git 还原）"
elif grep -q "VMHOST_MAKECURFIX" "$f"; then
    echo "==> patch: makeCurrent surfaceless→pbuffer 修复（已打过，跳过）"
else
    python3 - "$f" <<'VMHOST_PY3'
import io, sys
p = sys.argv[1]
src = io.open(p, encoding='utf-8').read()

anchor = """    EglOsEglSurface* readSfc = (EglOsEglSurface*)read;
    EglOsEglSurface* drawSfc = (EglOsEglSurface*)draw;
    EglOsEglContext* ctx = (EglOsEglContext*)context;
    if (ctx && !readSfc) {
        D("warning: makeCurrent a context without surface\\n");
        return false;
    }
    D("%s %p\\n", __FUNCTION__, ctx ? ctx->context() : nullptr);
    bool ret = mDispatcher.eglMakeCurrent(
            mDisplay, drawSfc ? drawSfc->getHndl() : EGL_NO_SURFACE,
            readSfc ? readSfc->getHndl() : EGL_NO_SURFACE,
            ctx ? ctx->context() : EGL_NO_CONTEXT);
"""
repl = """    EglOsEglSurface* readSfc = (EglOsEglSurface*)read;
    EglOsEglSurface* drawSfc = (EglOsEglSurface*)draw;
    EglOsEglContext* ctx = (EglOsEglContext*)context;
    if (ctx && !readSfc) {
        D("warning: makeCurrent a context without surface\\n");
        return false;
    }
    D("%s %p\\n", __FUNCTION__, ctx ? ctx->context() : nullptr);

    /* VMHOST_MAKECURFIX: surface 对象的底层 EGL handle 可能是 0，此时平台调用就
       退化成 eglMakeCurrent(dpy, 0, 0, ctx) —— 上下文在、draw/read surface 为空。
       宿主 Adreno 830 驱动在此状态下会于固定指令 LDR x5,[x21,#0x38]（x21=0）
       上 SIGSEGV 打死整个 QEMU。这里用 1x1 pbuffer 顶上缺的那一边。 */
    EGLSurface vmhostDrawHndl = drawSfc ? drawSfc->getHndl() : EGL_NO_SURFACE;
    EGLSurface vmhostReadHndl = readSfc ? readSfc->getHndl() : EGL_NO_SURFACE;
    if (ctx != nullptr && (vmhostDrawHndl == EGL_NO_SURFACE ||
                           vmhostReadHndl == EGL_NO_SURFACE)) {
        static EGLSurface s_vmhostPbuf = EGL_NO_SURFACE;
        if (s_vmhostPbuf == EGL_NO_SURFACE && mDispatcher.eglChooseConfig &&
            mDispatcher.eglCreatePbufferSurface) {
            const EGLint pbufCfgAttribs[] = {
                EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
                EGL_NONE};
            EGLConfig pbufCfg = nullptr;
            EGLint nCfg = 0;
            if (mDispatcher.eglChooseConfig(mDisplay, pbufCfgAttribs, &pbufCfg, 1,
                                            &nCfg) &&
                nCfg > 0 && pbufCfg != nullptr) {
                const EGLint pbufAttribs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1,
                                              EGL_NONE};
                s_vmhostPbuf = mDispatcher.eglCreatePbufferSurface(
                        mDisplay, pbufCfg, pbufAttribs);
            }
        }
        if (s_vmhostPbuf != EGL_NO_SURFACE) {
            if (vmhostDrawHndl == EGL_NO_SURFACE) vmhostDrawHndl = s_vmhostPbuf;
            if (vmhostReadHndl == EGL_NO_SURFACE) vmhostReadHndl = s_vmhostPbuf;
            fprintf(stderr,
                    "VMHOST_MAKECURFIX surfaceless -> 1x1 pbuffer (ctx=%p caller=0x%zx)\\n",
                    (void*)ctx->context(),
                    (size_t)(uintptr_t)__builtin_return_address(0));
        } else {
            fprintf(stderr, "VMHOST_MAKECURFIX surfaceless 且 pbuffer 不可用 (ctx=%p)\\n",
                    (void*)ctx->context());
        }
    }

    bool ret = mDispatcher.eglMakeCurrent(
            mDisplay, vmhostDrawHndl, vmhostReadHndl,
            ctx ? ctx->context() : EGL_NO_CONTEXT);
"""
if anchor not in src:
    sys.stderr.write("!! VMHOST_MAKECURFIX 锚点未命中\n")
    sys.exit(1)
src = src.replace(anchor, repl, 1)
io.open(p, 'w', encoding='utf-8').write(src)
VMHOST_PY3
    grep -q "VMHOST_MAKECURFIX" "$f" \
        && echo "==> patch: makeCurrent surfaceless→pbuffer 修复已注入" \
        || { echo "!! VMHOST_MAKECURFIX 补丁未生效" >&2; exit 1; }
fi

# 5d) VMHOST_EGLSTRING：补齐宿主对 EGL_VENDOR / EGL_EXTENSIONS 的回答。
#     访客侧 libEGL_emulation.so 的 eglDisplay::queryString 对这三个名字会走
#     HostConnection → rcEncoder → rcGetGLString(name, buf, size)（反汇编确认）：
#       0x3053 EGL_VENDOR / 0x3054 EGL_VERSION / 0x3055 EGL_EXTENSIONS
#     而宿主这份表只为 GL_* 准备内容（追加段全是 `if (name == GL_EXTENSIONS)`），
#     对 EGL_EXTENSIONS 就会去调 glGetString(0x3055) → NULL → 返回**空串**。
#     平台 libEGL 的 eglQueryStringImplementationANDROID 要求客户端扩展里含
#     EGL_EXT_client_extensions，否则直接返回 NULL；而 SurfaceFlinger 的
#     GLESRenderEngine::create 对该返回值是 LOG_ALWAYS_FATAL
#     （"eglQueryStringImplementationANDROID(EGL_VERSION) failed"）→ SF 反复 abort，
#     init 里 `restart zygote` 级联重启 → 永远 boot 不完、合不出帧。这里补齐。
f="$SRC_DIR/host/RenderControl.cpp"
if grep -q "VMHOST_EGLSTRING" "$f"; then
    echo "==> patch: rcGetGLString 补 EGL_* 名字（已打过，跳过）"
else
    python3 - "$f" <<'VMHOST_PY4'
import io, sys
p = sys.argv[1]
src = io.open(p, encoding='utf-8').read()

anchor = "static EGLint rcGetGLString(EGLenum name, void* buffer, EGLint bufferSize) {\n"
repl = anchor + """    /* VMHOST_EGLSTRING: 访客侧 EGL 会用 rcGetGLString 索取 EGL_VENDOR /
       EGL_EXTENSIONS（0x3053 / 0x3055，见 guest libEGL_emulation 的
       eglDisplay::queryString）。上游这张表只为 GL_* 名字准备内容，EGL_* 会落到
       glGetString(0x3055) → NULL → 返回空串，访客就把"实现扩展为空"缓存下来。
       注意：这**不是** SurfaceFlinger "eglQueryStringImplementationANDROID(
       EGL_VERSION) failed" 的原因 —— 平台侧那个函数只在 validate_display()
       失败时返回 NULL（已反汇编确认），换句话说真正的问题是访客 eglInitialize
       没成功。这里只是把 EGL_* 查询按访客自带静态串补齐。 */
    if (name == 0x3053 /*EGL_VENDOR*/ || name == 0x3055 /*EGL_EXTENSIONS*/) {
        const char* eglStr = (name == 0x3053) ? "Google Android emulator"
                                              : kVMHostEglExtensions;
        const int eglLen = (int)strlen(eglStr) + 1;
        if (!buffer || eglLen > (int)bufferSize) {
            return -eglLen;
        }
        memcpy(buffer, eglStr, (size_t)eglLen);
        return eglLen;
    }

"""
if anchor not in src:
    sys.stderr.write("!! VMHOST_EGLSTRING 锚点未命中\\n")
    sys.exit(1)
src = src.replace(anchor, repl, 1)

# 常量放在 include 区之后、函数定义之前（该文件没有 <stdio.h>，用 <string.h> 作锚点）。
inc_anchor = "#include <string.h>\n"
if inc_anchor not in src:
    sys.stderr.write("!! VMHOST_EGLSTRING include 锚点未命中\\n")
    sys.exit(1)
const_text = """#include <string.h>

/* VMHOST_EGLSTRING: 返回给访客的 EGL_VENDOR / EGL_EXTENSIONS。
   内容**照抄访客 libEGL_emulation.so 自带的静态串**（strings 偏移 0x4b40 /
   0x4b58 / 0x4bbb / 0x4bda），不要臆造：
     "Google Android emulator"
     "EGL_ANDROID_image_native_buffer EGL_KHR_fence_sync EGL_KHR_image_base
      EGL_KHR_gl_texture_2d_image EGL_ANDROID_native_fence_sync EGL_KHR_wait_sync"
   宿主原实现对 EGL_* 名字会落到 glGetString(0x3055) → NULL → 返回空串，访客那侧
   就会把它当"实现扩展为空"缓存下来。 */
static const char kVMHostEglExtensions[] =
    "EGL_ANDROID_image_native_buffer "
    "EGL_KHR_fence_sync "
    "EGL_KHR_image_base "
    "EGL_KHR_gl_texture_2d_image "
    "EGL_ANDROID_native_fence_sync "
    "EGL_KHR_wait_sync";
"""
src = src.replace(inc_anchor, const_text, 1)
io.open(p, 'w', encoding='utf-8').write(src)
VMHOST_PY4
    grep -q "VMHOST_EGLSTRING" "$f" \
        && echo "==> patch: rcGetGLString 补 EGL_* 名字已注入" \
        || { echo "!! VMHOST_EGLSTRING 补丁未生效" >&2; exit 1; }
fi

# 5e) VMHOST_RC 握手探针：访客 eglDisplay::initialize 依次要
#       rcGetRendererVersion()                      （前导）
#       rcGetEGLVersion(&maj, &min) == 1            （失败点 D）
#       rcQueryEGLString(...)                       （EGL 扩展/厂商串）
#     任一失败 → eglInitialize 返回 false；平台 libEGL 的 egl_display_t
#     isInitialized() 保持 false → eglQueryStringImplementationANDROID(EGL_VERSION)
#     返回 NULL → SurfaceFlinger LOG_ALWAYS_FATAL。这里只**只读打点**，不改行为，
#     用来判定访客到底走到了哪一步（是根本没连上，还是连上了但某一步失败）。
f="$SRC_DIR/host/RenderControl.cpp"
if grep -q "VMHOST_RC handshake" "$f"; then
    echo "==> patch: rc 握手探针（已打过，跳过）"
else
    python3 - "$f" <<'VMHOST_PY5'
import io, sys
p = sys.argv[1]
src = io.open(p, encoding='utf-8').read()

edits = [
    ("static GLint rcGetRendererVersion()\n{\n",
     "static GLint rcGetRendererVersion()\n{\n"
     "    fprintf(stderr, \"VMHOST_RC handshake rcGetRendererVersion\\n\");  /* VMHOST_RC */\n"),
    ("static EGLint rcGetEGLVersion(EGLint* major, EGLint* minor)\n{\n",
     "static EGLint rcGetEGLVersion(EGLint* major, EGLint* minor)\n{\n"
     "    fprintf(stderr, \"VMHOST_RC handshake rcGetEGLVersion enter\\n\");  /* VMHOST_RC */\n"),
    ("static EGLint rcQueryEGLString(EGLenum name, void* buffer, EGLint bufferSize)\n{\n",
     "static EGLint rcQueryEGLString(EGLenum name, void* buffer, EGLint bufferSize)\n{\n"
     "    fprintf(stderr, \"VMHOST_RC handshake rcQueryEGLString name=0x%x size=%d\\n\",  /* VMHOST_RC */\n"
     "            (unsigned)name, (int)bufferSize);\n"),
]
for anchor, repl in edits:
    if anchor not in src:
        sys.stderr.write("!! VMHOST_RC 锚点未命中: " + anchor.splitlines()[0] + "\n")
        sys.exit(1)
    src = src.replace(anchor, repl, 1)

# rcGetEGLVersion 的返回值也记一笔（失败点 D 是"返回值 != 1"）。
ret_anchor = ("    fb->getEmulationGl().getEglVersion(major, minor);\n"
              "\n"
              "    return EGL_TRUE;\n")
ret_repl = ("    fb->getEmulationGl().getEglVersion(major, minor);\n"
            "    fprintf(stderr, \"VMHOST_RC handshake rcGetEGLVersion maj=%d min=%d -> TRUE\\n\",  /* VMHOST_RC */\n"
            "            (int)(major ? *major : -1), (int)(minor ? *minor : -1));\n"
            "\n"
            "    return EGL_TRUE;\n")
if ret_anchor in src:
    src = src.replace(ret_anchor, ret_repl, 1)
else:
    sys.stderr.write("!! VMHOST_RC rcGetEGLVersion 返回点锚点未命中（仅告警）\n")

io.open(p, 'w', encoding='utf-8').write(src)
VMHOST_PY5
    grep -q "VMHOST_RC handshake" "$f" \
        && echo "==> patch: rc 握手探针已注入" \
        || { echo "!! VMHOST_RC 补丁未生效" >&2; exit 1; }
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
