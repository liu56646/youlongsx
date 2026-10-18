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
    echo "==> 从 git 恢复待打补丁的源文件"
    git -C "$SRC_DIR" checkout -- \
        host/CMakeLists.txt \
        host/gl/glestranslator/EGL/CMakeLists.txt \
        host/apigen-codec-common/CMakeLists.txt \
        host/gl/OpenGLESDispatch/GLESv2Dispatch.cpp \
        host/gl/GLESVersionDetector.cpp 2>/dev/null || true
fi

# 0a) GLESv2Dispatch.cpp 必须保持**上游**的符号查找顺序
#     （`::translator::gles2::fn` 优先）。曾经手工改成"优先 dlsym 宿主
#     libGLESv2.so"，那会绕过 gfxstream 自己的上下文校验，把访客 GL 直接打到
#     宿主驱动上：一旦该线程没有 current context，Adreno 830 就 SIGSEGV 打死
#     整个 QEMU（实测 guest≈550s，SF 一开始真正渲染就崩）。
#     所以这里每次强制还原；若确实需要那条捷径，请用脚本显式打补丁，不要手改。

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

# 4b) RenderThread 快照保存：两条补丁（一起打，逐条幂等靠 marker 判断）。
#
#   VMHOST_SNAP_NO_PAUSE —— save() 入口先看 mState：如果渲染线程**根本没被
#     pausePreSnapshot() 碰过**（还是 Empty），waitForSnapshotCompletion()
#     永远等不到 Finished。实测 opengles 管道就是这种情况：9 条线程全部
#     state=0，各白等 5s，整次 save 多花 45s。直接按"没有渲染线程状态"降级
#     （写 0），官方 load 侧把 0 当"无状态、渲染线程直接退出"。
#
#   VMHOST_SNAP_TIMEOUT —— 真被暂停过、但卡在某次 GL 调用里回不到主循环的
#     兜底：waitForSnapshotCompletion() 给 5s 上限，超时同样降级写 0，
#     而不是让整次 `vmhostsnapshot save` 挂死（实测早期版本顶到 HMP 180s
#     超时、快照作废、ram.bin 只写一半）。
f="$SRC_DIR/host/RenderThread.cpp"
if grep -q "VMHOST_SNAP_TIMEOUT" "$f" && grep -q "VMHOST_SNAP_NO_PAUSE" "$f"; then
    echo "==> patch: RenderThread 快照保存降级（已打过，跳过）"
else
    # 半套补丁会撞锚点：先还原成上游，再两条一起打。
    git -C "$SRC_DIR" checkout -- host/RenderThread.cpp
    python3 - "$f" <<'VMHOST_PY'
import io, sys
p = sys.argv[1]
src = io.open(p, encoding='utf-8').read()

old0 = """void RenderThread::save(android::base::Stream* stream) {
    bool success;
    {
        AutoLock lock(mLock);
        assert(mState == SnapshotState::StartSaving ||
               mState == SnapshotState::InProgress ||
               mState == SnapshotState::Finished);
        waitForSnapshotCompletion(&lock);
        success = mState == SnapshotState::Finished;
    }
"""
new0 = """void RenderThread::save(android::base::Stream* stream) {
    bool success;
    {
        AutoLock lock(mLock);
        /* VMHOST_SNAP_NO_PAUSE: 没被 pausePreSnapshot() 碰过的线程（Empty）
           等不到 Finished，直接降级成"没有状态"。 */
        if (mState == SnapshotState::Empty) {
            fprintf(stderr,
                    "VMHOSTSNAP RenderThread::save: not paused (Empty), "
                    "skip renderer state\\n");
            success = false;
        } else {
            waitForSnapshotCompletion(&lock);
            success = mState == SnapshotState::Finished;
        }
    }
"""
if old0 not in src:
    sys.stderr.write("!! RenderThread::save 锚点未命中\n")
    sys.exit(1)
src = src.replace(old0, new0, 1)

old = """void RenderThread::waitForSnapshotCompletion(AutoLock* lock) {
    while (mState != SnapshotState::Finished &&
           !mFinished.load(std::memory_order_relaxed)) {
        mCondVar.wait(lock);
    }
}"""
new = """void RenderThread::waitForSnapshotCompletion(AutoLock* lock) {
    /* VMHOST_SNAP_TIMEOUT: 原版死等，渲染线程卡在 GL 调用里时整次 save 会挂死。
       给 5s 上限；超时后按"没有渲染线程状态"降级（save() 会写 0），
       后续 resume() 走的也是同一条超时路径，不会把渲染器永久留在暂停态。 */
    const uint64_t deadlineUs = android::base::getUnixTimeUs() + 5ULL * 1000 * 1000;
    while (mState != SnapshotState::Finished &&
           !mFinished.load(std::memory_order_relaxed)) {
        if (android::base::getUnixTimeUs() >= deadlineUs) {
            fprintf(stderr,
                    "VMHOSTSNAP RenderThread::waitForSnapshotCompletion timeout "
                    "(state=%d), continue without renderer state\\n",
                    (int) mState);
            break;
        }
        /* AutoLock::mLock 是私有的（只对 ConditionVariable 开放），这里用
           放锁 + 短睡轮询代替 timedWait：save 路径上 5ms 粒度足够，
           而且不会把渲染器永久留在暂停态。 */
        lock->unlock();
#ifndef _WIN32
        usleep(5 * 1000);
#else
        Sleep(5);
#endif
        lock->lock();
    }
}"""
if old not in src:
    sys.stderr.write("!! RenderThread 超时补丁锚点未命中\n")
    sys.exit(1)
io.open(p, 'w', encoding='utf-8').write(src.replace(old, new, 1))
VMHOST_PY
    grep -q "VMHOST_SNAP_TIMEOUT" "$f" && grep -q "VMHOST_SNAP_NO_PAUSE" "$f" \
        && echo "==> patch: RenderThread 快照保存降级（未暂停直接跳过 + 5s 超时）" \
        || { echo "!! RenderThread 快照补丁未生效" >&2; exit 1; }
fi

# ASG globalPreSave 与 opengles preSave 都会暂停同一线程。
# 第二次暂停不能把 Finished/InProgress 重置为 StartSaving 并清空 mStream；
# 渲染线程此时已经在等 resume，会造成逐线程 5s 超时和恢复后线程丢失。
python3 - "$SRC_DIR/host/RenderThread.cpp" <<'VMHOST_PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if 'VMHOST_SNAP_PAUSE_ONCE' not in s:
    old = '''void RenderThread::pausePreSnapshot() {
    AutoLock lock(mLock);
    assert(mState == SnapshotState::Empty);'''
    new = '''void RenderThread::pausePreSnapshot() {
    AutoLock lock(mLock);
    // VMHOST_SNAP_PAUSE_ONCE: two services can pause the same render thread.
    // Preserve both the completed stream and an in-flight snapshot operation.
    if (mState != SnapshotState::Empty) return;
    assert(mState == SnapshotState::Empty);'''
    if old not in s:
        sys.exit('RenderThread pausePreSnapshot anchor missing')
    p.write_text(s.replace(old, new, 1))
# ProcessResources only feeds VkDecoder. GLES-only threads have no Vulkan
# resource table after load when VulkanSnapshots is disabled.
s = p.read_text()
if 'VMHOST_SNAP_VK_RESOURCES_ONLY' not in s:
    old = '            if (!processResources && tInfo.m_puid) {'
    new = '''            // VMHOST_SNAP_VK_RESOURCES_ONLY: GL decoding does not use this table.
            if (tInfo.m_vkInfo && !processResources && tInfo.m_puid) {'''
    if old not in s:
        sys.exit('RenderThread processResources anchor missing')
    p.write_text(s.replace(old, new, 1))
VMHOST_PY

# 4b) Android GLES 不能把 Alpha/Luminance 纹理直接挂 FBO 读回。
#       字体 atlas 因此在恢复后变空；先着色到 RGBA，再提取原格式分量。
cp "$TOOLS_DIR/qemu_patches/vmhost_snapshot_texture.h" \
   "$SRC_DIR/host/gl/glestranslator/GLcommon/vmhost_snapshot_texture.h"
python3 - "$SRC_DIR/host/gl/glestranslator/GLcommon/SaveableTexture.cpp" <<'VMHOST_PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if 'VMHOST_SNAP_LEGACY_READ' not in s:
    s = s.replace('#include <algorithm>', '#include <algorithm>\n#include "vmhost_snapshot_texture.h"')
    old = '''        if (!shouldUseReadPixels(target, level, format, type)) {'''
    new = '''        // VMHOST_SNAP_LEGACY_READ: legacy formats are not color-renderable.
        if (isGles2Gles() && target == GL_TEXTURE_2D && level == 0 &&
            type == GL_UNSIGNED_BYTE &&
            (format == GL_ALPHA || format == GL_LUMINANCE || format == GL_LUMINANCE_ALPHA)) {
            if (!vmhostReadLegacyTexture(gl, globalName, format, width, height, data)) {
                fprintf(stderr, "VMHOSTSNAP legacy texture read failed\\n");
                abort(); // Never publish a silently corrupted snapshot.
            }
            return;
        }

        if (!shouldUseReadPixels(target, level, format, type)) {'''
    if old not in s: sys.exit('SaveableTexture legacy read anchor missing')
    p.write_text(s.replace(old, new, 1))
VMHOST_PY

python3 "$TOOLS_DIR/qemu_patches/patch_snapshot_window.py" "$SRC_DIR"

# 4c) 逐包打印的两处宿主诊断默认关掉（`VMHOST_GLES_LOG=1` 才打）。
#     VMHOST_GLES1_OP（gles1 解码器，**每个包一行**）与 VMHOST_GLES2_LOWFREQ
#     （gles2 解码器，名字叫"低频"但真实负载下每秒上千条）实测 2.5 分钟就能刷出
#     21 万行、十几分钟 35MB 的 qemu-stderr.log —— 磁盘和 IO 全被日志吃掉。
#     引擎侧 `setprop debug.vmhost.gles_log 1` 会把 VMHOST_GLES_LOG 传进来。
patch_vmhost_gles_log_gate() {
    local g1="$SRC_DIR/host/gl/gles1_dec/gles1_dec.cpp"
    local g2="$SRC_DIR/host/gl/gles2_dec/gles2_dec.cpp"
    [ -f "$g1" ] && [ -f "$g2" ] || { echo "找不到 gles1_dec/gles2_dec" >&2; return 1; }
    if grep -q "VMHOST_GLES_LOG_GATE" "$g2"; then
        echo "==> patch: 逐包 GLES 日志开关（已打过，跳过）"
        return 0
    fi
    python3 - "$g1" "$g2" <<'VMHOST_PY'
import io, sys
g1p, g2p = sys.argv[1], sys.argv[2]

src = io.open(g2p, encoding='utf-8').read()
anchor = "static void vmhost_gles2_note(uint32_t opcode, uint32_t len, const unsigned char* p) {"
gate = """/* VMHOST_GLES_LOG_GATE: 逐条打印默认关闭（见 build_gfxstream.sh 4c）。 */
static bool vmhost_gles_log_on() {
    static int enabled = -1;
    if (enabled < 0) {
        enabled = getenv("VMHOST_GLES_LOG") ? 1 : 0;
    }
    return enabled == 1;
}

"""
if anchor not in src:
    sys.stderr.write("!! gles2 note 锚点未命中\n"); sys.exit(1)
src = src.replace(anchor, gate + anchor, 1)
old = "    if (vmhost_gles2_lowfreq(opcode)) {"
new = "    if (vmhost_gles_log_on() && vmhost_gles2_lowfreq(opcode)) {"
if old not in src:
    sys.stderr.write("!! gles2 lowfreq 锚点未命中\n"); sys.exit(1)
src = src.replace(old, new, 1)
if '#include <stdlib.h>' not in src:
    src = src.replace('#include <string.h>',
                      '#include <string.h>\n#include <stdlib.h>', 1)
io.open(g2p, 'w', encoding='utf-8').write(src)

src = io.open(g1p, encoding='utf-8').read()
old1 = '\t\tfprintf(stderr, "VMHOST_GLES1_OP %u len=%u\\n", opcode, packetLen);\n'
new1 = ('\t\t/* VMHOST_GLES_LOG_GATE: 逐包打印默认关闭（见 build_gfxstream.sh 4c） */\n'
        '\t\t{ static int vmhostGlesLog = -1;\n'
        '\t\t  if (vmhostGlesLog < 0) vmhostGlesLog = getenv("VMHOST_GLES_LOG") ? 1 : 0;\n'
        '\t\t  if (vmhostGlesLog) fprintf(stderr, "VMHOST_GLES1_OP %u len=%u\\n", opcode, packetLen); }\n')
if old1 not in src:
    sys.stderr.write("!! gles1 逐包打印锚点未命中\n"); sys.exit(1)
src = src.replace(old1, new1, 1)
if '#include <stdlib.h>' not in src:
    src = src.replace('#include <string.h>',
                      '#include <string.h>\n#include <stdlib.h>', 1)
io.open(g1p, 'w', encoding='utf-8').write(src)
VMHOST_PY
    grep -q "VMHOST_GLES_LOG_GATE" "$g2" && grep -q "VMHOST_GLES_LOG_GATE" "$g1" \
        && echo "==> patch: 逐包 GLES 日志开关（VMHOST_GLES_LOG）" \
        || { echo "!! GLES 日志开关补丁未生效" >&2; exit 1; }
}

# 注意：这个 gate 必须**在 5) 的 VMHOST_DIAG 插桩之后**调用 ——
# gles2 的 vmhost_gles2_note()/LOWFREQ 打印是那一步插进去的，先跑会找不到锚点。

# 4d) 渲染器**全局状态**的快照存取：把官方 android-emu 版 OpenglEsPipe 的做法
#     接回 gfxstream 版。本版 gfxstream 把这段注释掉了 —— 新架构改由 virtio-gpu
#     的 stream_renderer_snapshot_* 钩子触发，但那些钩子在本移植里没有任何调用方
#     （`grep -rn stream_renderer_snapshot_save` 只有 end2end 测试命中）。后果：快照
#     里只有 guest RAM + 设备状态，**没有渲染器状态**（EGL 上下文 / window surface /
#     color buffer），恢复后 guest 的每条 GL 命令都打在空上下文上：
#       GLESv2Imp.cpp:glDrawArrays:1601 error null ctx
#       FB::flushEmulatedEglWindowSurfaceColorBuffer: window handle 0x9 not found
#       FrameBuffer.cpp:3371: Failed to find process owned resources for puid 4294967295
#     实测恢复后 5 分钟刷出 18 万行 / 30MB，guest 的界面等于废的。
#     官方 emu 树同一文件（android/android-emu/android/opengl/OpenglEsPipe.cpp）
#     里这段是活的：opengles service 的 preSave 里
#       renderer->pauseAllPreSave(); putByte(1); putBe32(OPENGL_SAVE_VERSION);
#       renderer->save(stream, Snapshotter::get().saver().textureSaver());
#     preLoad 里 renderer->load(stream, Snapshotter::get().loader().textureLoader())。
#     这里照它恢复（不搬 writeScreenshot：截图对恢复不是必需）。
patch_opengles_renderer_snapshot() {
    local f="$SRC_DIR/host/gl/gl-host-common/opengl/OpenglEsPipe.cpp"
    [ -f "$f" ] || { echo "找不到 $f" >&2; return 1; }
    if grep -q "VMHOST_RENDERER_SNAPSHOT" "$f"; then
        echo "==> patch: opengles 渲染器状态快照（已打过，跳过）"
        return 0
    fi
    python3 - "$f" <<'VMHOST_PY'
import io, sys
p = sys.argv[1]
src = io.open(p, encoding='utf-8').read()

if '#include "android/snapshot/Snapshotter.h"' not in src:
    src = src.replace(
        '#include "host-common/opengles.h"',
        '#include "host-common/opengles.h"\n'
        '#include "android/snapshot/Loader.h"\n'
        '#include "android/snapshot/Saver.h"\n'
        '#include "android/snapshot/Snapshotter.h"', 1)
if 'using android::snapshot::Snapshotter;' not in src:
    src = src.replace(
        'using gfxstream::RenderChannelPtr;',
        'using gfxstream::RenderChannelPtr;\nusing android::snapshot::Snapshotter;',
        1)

anchor_load = "        virtual void preLoad(android::base::Stream* stream) override {\n"
insert_load = """            /* VMHOST_RENDERER_SNAPSHOT: 恢复渲染器全局状态（上下文/窗口/颜色缓冲）。
               本版 gfxstream 把这段注释掉了，而 virtio-gpu 的 stream_renderer_snapshot_*
               钩子在本移植里没有调用方 —— 不接回来，恢复后宿主渲染器就是"没有上下文"，
               guest 的 GL 命令全部报 error null ctx。 */
            const bool hasRenderer = stream->getByte();
            const auto& renderer = android_getOpenglesRenderer();
            if (hasRenderer != (bool)renderer || !hasRenderer) {
                return;
            }
            const int vmhostVersion = stream->getBe32();
            (void)vmhostVersion;
            renderer->load(
                stream,
                android::snapshot::Snapshotter::get().loader().textureLoader());
"""
if anchor_load not in src:
    sys.stderr.write("!! opengles preLoad 锚点未命中\n"); sys.exit(1)
src = src.replace(anchor_load, anchor_load + insert_load, 1)

anchor_save = "        void preSave(android::base::Stream* stream) override {\n"
insert_save = """            /* VMHOST_RENDERER_SNAPSHOT: 保存渲染器全局状态。顺序与官方一致：
               先 pauseAllPreSave()（把各渲染线程停在一致点），再写版本号 + 状态。
               ASG 也会调用暂停，依靠 VMHOST_SNAP_PAUSE_ONCE 保留已保存的状态；
               resume 由 postSave -> resumeAll() 负责。 */
            if (const auto& renderer = android_getOpenglesRenderer()) {
                renderer->pauseAllPreSave();
                stream->putByte(1);
                stream->putBe32(OPENGL_SAVE_VERSION);
                renderer->save(
                    stream,
                    android::snapshot::Snapshotter::get().saver().textureSaver());
            } else {
                stream->putByte(0);
            }
"""
if anchor_save not in src:
    sys.stderr.write("!! opengles preSave 锚点未命中\n"); sys.exit(1)
src = src.replace(anchor_save, anchor_save + insert_save, 1)

io.open(p, 'w', encoding='utf-8').write(src)
VMHOST_PY
    grep -q "VMHOST_RENDERER_SNAPSHOT" "$f" \
        && echo "==> patch: opengles 渲染器状态快照（preSave/preLoad）" \
        || { echo "!! opengles 渲染器快照补丁未生效" >&2; exit 1; }
}

patch_opengles_renderer_snapshot

# 4e) 渲染器快照的**耗时探针**。接回渲染器状态后保存从 2s 变成 92s —— 先量清楚
#     时间花在 pauseAllPreSave / renderer->save / resumeAll 哪一段，再决定怎么优化。
patch_opengles_renderer_snapshot_timing() {
    local f="$SRC_DIR/host/gl/gl-host-common/opengl/OpenglEsPipe.cpp"
    [ -f "$f" ] || { echo "找不到 $f" >&2; return 1; }
    if grep -q "VMHOST_RENDERER_SNAPSHOT_TIMING" "$f"; then
        echo "==> patch: 渲染器快照计时（已打过，跳过）"
        return 0
    fi
    python3 - "$f" <<'VMHOST_PY'
import io, sys
p = sys.argv[1]
src = io.open(p, encoding='utf-8').read()

if '#include <chrono>' not in src:
    src = src.replace('#include <atomic>',
                      '#include <atomic>\n#include <chrono>', 1)

old = """            if (const auto& renderer = android_getOpenglesRenderer()) {
                renderer->pauseAllPreSave();
                stream->putByte(1);
                stream->putBe32(OPENGL_SAVE_VERSION);
                renderer->save(
                    stream,
                    android::snapshot::Snapshotter::get().saver().textureSaver());
            } else {
                stream->putByte(0);
            }
"""
new = """            if (const auto& renderer = android_getOpenglesRenderer()) {
                /* VMHOST_RENDERER_SNAPSHOT_TIMING */
                auto vmhostT0 = std::chrono::steady_clock::now();
                renderer->pauseAllPreSave();
                auto vmhostT1 = std::chrono::steady_clock::now();
                stream->putByte(1);
                stream->putBe32(OPENGL_SAVE_VERSION);
                renderer->save(
                    stream,
                    android::snapshot::Snapshotter::get().saver().textureSaver());
                auto vmhostT2 = std::chrono::steady_clock::now();
                fprintf(stderr,
                        "VMHOSTSNAP renderer preSave: pause=%.0fms save=%.0fms\\n",
                        std::chrono::duration<double, std::milli>(vmhostT1 - vmhostT0).count(),
                        std::chrono::duration<double, std::milli>(vmhostT2 - vmhostT1).count());
            } else {
                stream->putByte(0);
            }
"""
if old not in src:
    sys.stderr.write("!! preSave 计时锚点未命中\n"); sys.exit(1)
src = src.replace(old, new, 1)

old2 = """        void postSave(android::base::Stream* stream) override {
            if (const auto& renderer = android_getOpenglesRenderer()) {
                renderer->resumeAll();
            }
"""
new2 = """        void postSave(android::base::Stream* stream) override {
            if (const auto& renderer = android_getOpenglesRenderer()) {
                /* VMHOST_RENDERER_SNAPSHOT_TIMING */
                auto vmhostT0 = std::chrono::steady_clock::now();
                renderer->resumeAll();
                fprintf(stderr, "VMHOSTSNAP renderer postSave: resume=%.0fms\\n",
                        std::chrono::duration<double, std::milli>(
                            std::chrono::steady_clock::now() - vmhostT0).count());
            }
"""
if old2 not in src:
    sys.stderr.write("!! postSave 计时锚点未命中\n"); sys.exit(1)
src = src.replace(old2, new2, 1)

io.open(p, 'w', encoding='utf-8').write(src)
VMHOST_PY
    grep -q "VMHOST_RENDERER_SNAPSHOT_TIMING" "$f" \
        && echo "==> patch: 渲染器快照计时探针" \
        || { echo "!! 渲染器快照计时补丁未生效" >&2; exit 1; }
}

patch_opengles_renderer_snapshot_timing

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

# 4c) 逐包 GLES 日志开关（必须在 5) 之后调用，见上面的说明）
patch_vmhost_gles_log_gate

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
# 【已废弃】旧版内联补丁按 eglChooseConfig 自选一个 config 造 pbuffer，与 context 的
# config 不匹配 → eglMakeCurrent 返回 EGL_BAD_MATCH → android_startOpenglesRenderer
# 被打成 -1。代码保留备查但不再执行；实际生效的加固见下方 5c-bis 调用的脚本。
if true; then
    echo "==> VMHOST_MAKECURFIX：旧版内联补丁已停用（见 5c-bis）"
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

# 5c-bis) VMHOST_MAKECURFIX / VMHOST_PBUFSURF（现行版）：
#         ① 加固 makeCurrent —— 缺 surface 时用"试绑成功才采用"的 1x1 pbuffer 顶上，
#            绝不把渲染线程留在"没有 current context"上；
#         ② 恢复 createPbufferSurface 的真实实现（上游整段注释掉、恒返回 handle=0），
#            访客的 pbuffer 不再是假句柄，从源头消除 eglMakeCurrent(dpy,0,0,ctx)。
#         两者合起来修掉"Adreno 830 SIGSEGV @ addr=0x38"（见 §15）。
#         幂等：脚本内部按 marker 逐条判断。
if [ "${VMHOST_MAKECURFIX:-1}" = "0" ]; then
    echo "==> VMHOST_MAKECURFIX=0：跳过 surface 加固（二分用）"
else
    python3 "$TOOLS_DIR/qemu_patches/patch_vmhost_surface.py" "$SRC_DIR" || {
        echo "!! VMHOST_MAKECURFIX/VMHOST_PBUFSURF 补丁失败" >&2; exit 1; }
fi

# 5c-ter) 【已删除】VMHOST_NOMONITOR（不创建 emugl::HealthMonitor）。
#         曾经以为 §17.5「跑约 17 分钟必崩」是 HealthMonitor 的 use-after-free，
#         后来实测证伪：本工程 ENABLE_HEALTH_MONITOR 从未定义（=0），
#         `CreateHealthMonitor()` 在编出来的 libqemu_exec.so 里就是
#         `OutputLog("HealthMonitor disabled."); *out = nullptr;`（一行直接返回），
#         所以根本不存在 HealthMonitor 实例、监控线程也从不启动。
#         真正的根因见 patch_vmhost_diag.py 的 GLES2 调用点注释与
#         docs/方案B排障交接.md §19：是诊断插桩在解码循环里按访客自报的 packetLen
#         读参数，越过了命令缓冲区末尾（页边界 guard page）。
#         对应的 patch_vmhost_healthmon.py 已删除。

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

# 5d-bis) VMHOST_FORCE_GLES2：host 模式把 maxVersion 压到 GLES_DISPATCH_MAX_VERSION_2。
#     原因：宿主 EGL context 取 ES3 时，TextureDraw 的 GLSL 1.0 shader 在 Adreno 上
#     编译失败（`glAttachShader` 0x501 → `TextureDraw: Could not create/link program`），
#     压到 ES2 后正常。之前这条是**手工改在源码树里**的（外面那份 patch_gfxstream33.py
#     顺带还改了 GLESv2Dispatch.cpp —— 那条捷径已证明有害，见上面 0a），这里固化成
#     脚本步骤，配合 step 0 的 git 还原，保证每次构建状态可复现。
f="$SRC_DIR/host/gl/GLESVersionDetector.cpp"
if [ "${VMHOST_FORCE_GLES2:-1}" = "0" ]; then
    echo "==> VMHOST_FORCE_GLES2=0：跳过（二分用）"
elif grep -q "VMHOST_FORCE_GLES2" "$f"; then
    echo "==> patch: force GLES2（已打过，跳过）"
else
    python3 - "$f" <<'VMHOST_PY5'
import io, sys
p = sys.argv[1]
src = io.open(p, encoding='utf-8').read()
old = """        if (s_egl.eglGetMaxGLESVersion) {
            maxVersion =
                (GLESDispatchMaxVersion)s_egl.eglGetMaxGLESVersion(dpy);
        }"""
new = """        /* VMHOST_FORCE_GLES2: 把宿主 EGL context 压到 ES2。
           取 ES3 时 TextureDraw 的 GLSL 1.0 shader 在 Adreno 上编译失败
           （glAttachShader 0x501 → TextureDraw: Could not create/link program）。 */
        maxVersion = GLES_DISPATCH_MAX_VERSION_2;"""
if old not in src:
    sys.stderr.write("!! VMHOST_FORCE_GLES2 锚点未命中\n")
    sys.exit(1)
io.open(p, 'w', encoding='utf-8').write(src.replace(old, new, 1))
VMHOST_PY5
    grep -q "VMHOST_FORCE_GLES2" "$f" \
        && echo "==> patch: force GLES2 已注入" \
        || { echo "!! VMHOST_FORCE_GLES2 补丁未生效" >&2; exit 1; }
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

# 5f) VMHOST_LEAKREG：修掉 gfxstream **退出时**的静态析构竞态（SIGABRT）。
#     RenderThreadInfo 的全局注册表 `sRegistry` 在进程退出时会被析构（Lock 里的
#     mutex 被销毁），而仍在收尾的 RenderThread 会在 `~RenderThreadInfo()` 里
#     `AutoLock lock(sRegistry.lock)` → FORTIFY abort：
#       F libc: FORTIFY: pthread_mutex_lock called on a destroyed mutex
#     → QEMU 以 SIGABRT 退出（不是干净退出，cache=unsafe 下有脏盘风险）。
#     改成**堆上分配、永不释放**，析构顺序问题从根上消失。见 §22.5。
if [ "${VMHOST_LEAKREG:-1}" = "0" ]; then
    echo "==> VMHOST_LEAKREG=0：跳过（二分用）"
else
    python3 "$TOOLS_DIR/qemu_patches/patch_gfxstream_threadinfo.py" "$SRC_DIR" || {
        echo "!! VMHOST_LEAKREG 补丁失败" >&2; exit 1; }
fi

# ---------------------------------------------------------------- 1. configure
# 宿主侧需要 <cutils/native_handle.h>（AOSP 头，NDK 没有；仓内自带一份）。
# 只把这一个头拷进 shim 目录，避免把 android_stub 整目录挂上来遮蔽 NDK 头。
SHIM_DIR="$BUILD_DIR/vmhost-shim"
mkdir -p "$SHIM_DIR/cutils"
cp -f "$SRC_DIR/guest/mesa/include/android_stub/cutils/native_handle.h" \
      "$SHIM_DIR/cutils/native_handle.h"

# OpenglEsPipe 的渲染器状态快照要 `#include "android/snapshot/{Snapshotter,Saver,Loader}.h"`。
# 完整版在这几个头只在 QEMU 树的 android/android-emu 下（aemu/snapshot/include 里
# 只有 TextureSaver/TextureLoader 那几个接口头）。只把 android/snapshot 这一个子目录
# 链进 shim，避免把整个 android-emu 头根挂上来遮蔽别的 android/* 头。
QEMU_ANDROID_EMU_DIR="${QEMU_ANDROID_EMU_DIR:-$WORKDIR/qemu-aosp/android/android-emu}"
if [ -d "$QEMU_ANDROID_EMU_DIR/android/snapshot" ]; then
    mkdir -p "$SHIM_DIR/android"
    ln -sfn "$QEMU_ANDROID_EMU_DIR/android/snapshot" "$SHIM_DIR/android/snapshot"
    echo "==> shim: android/snapshot -> $QEMU_ANDROID_EMU_DIR/android/snapshot"
else
    echo "!! 找不到 $QEMU_ANDROID_EMU_DIR/android/snapshot（渲染器状态快照会编不过）" >&2
    exit 1
fi
# 那些 snapshot 头还会 `#include "android/base/system/System.h"` 这类老路径
# （aemu 侧对应 aemu/base/...）。兼容头在 qemu-aosp/android/emu/base/include/android/base 下。
QEMU_EMU_BASE_INCLUDE="${QEMU_EMU_BASE_INCLUDE:-$WORKDIR/qemu-aosp/android/emu/base/include}"
if [ -d "$QEMU_EMU_BASE_INCLUDE/android/base" ]; then
    mkdir -p "$SHIM_DIR/android"
    ln -sfn "$QEMU_EMU_BASE_INCLUDE/android/base" "$SHIM_DIR/android/base"
    echo "==> shim: android/base -> $QEMU_EMU_BASE_INCLUDE/android/base"
else
    echo "!! 找不到 $QEMU_EMU_BASE_INCLUDE/android/base" >&2
    exit 1
fi
# snapshot 头还会拉 avd/utils/agents/... 这些 emu 侧的兼容头，逐个链进来
# （不整根挂 android-emu，避免遮蔽 gfxstream 自己的 android/* 头）。
for _m in avd agents cmdline crashreport files feature metrics protobuf \
          studio-config utils; do
    # 优先用 android-emu-base 那份兼容头（android/utils/debug.h 等只在那里），
    # 没有再退回 emu/<m>/include 的版本。
    _src="$WORKDIR/qemu-aosp/android/android-emu-base/android/$_m"
    [ -d "$_src" ] || _src="$WORKDIR/qemu-aosp/android/emu/$_m/include/android/$_m"
    [ -d "$_src" ] && ln -sfn "$_src" "$SHIM_DIR/android/$_m"
done
echo "==> shim: android/{avd,agents,cmdline,crashreport,files,feature,metrics,protobuf,studio-config,utils}"
# 上面这些头会经 aemu 的 Log.h 拉 absl（str_format 等），把 absl 也链进 shim。
ABSEIL_DIR="${ABSEIL_DIR:-$WORKDIR/abseil}"
if [ -d "$ABSEIL_DIR/absl" ]; then
    ln -sfn "$ABSEIL_DIR/absl" "$SHIM_DIR/absl"
    echo "==> shim: absl -> $ABSEIL_DIR/absl"
else
    echo "!! 找不到 $ABSEIL_DIR/absl" >&2
    exit 1
fi
# snapshot 头还会拉生成的 protobuf 头（snapshot.pb.h 等）与 protobuf 运行库头。
PROTO_GEN_DIR="${PROTO_GEN_DIR:-$WORKDIR/proto-gen}"
PROTOBUF_INCLUDE_DIR="${PROTOBUF_INCLUDE_DIR:-$WORKDIR/protobuf-build-arm64-v8a/include}"
for _h in snapshot.pb.h snapshot_deps.pb.h emulator_compatible.pb.h; do
    [ -f "$PROTO_GEN_DIR/$_h" ] && ln -sfn "$PROTO_GEN_DIR/$_h" "$SHIM_DIR/$_h"
done
[ -d "$PROTOBUF_INCLUDE_DIR/google" ] && \
    ln -sfn "$PROTOBUF_INCLUDE_DIR/google" "$SHIM_DIR/google"
# Compressor.h 用 lz4（快照压缩）。
for _lz4 in "$WORKDIR/lz4-build-arm64-v8a/include" "$WORKDIR/lz4/lib" \
            "$WORKDIR/lz4/include"; do
    if [ -f "$_lz4/lz4.h" ]; then
        ln -sfn "$_lz4/lz4.h" "$SHIM_DIR/lz4.h"
        break
    fi
done
[ -f "$SHIM_DIR/lz4.h" ] || { echo "!! 找不到 lz4.h" >&2; exit 1; }
echo "==> shim: protobuf 生成头 + google/ + lz4 已挂载"

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
    -DCMAKE_CXX_FLAGS="-DANDROID ${VMHOST_CRASH_FP:+-fno-omit-frame-pointer}" \
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
