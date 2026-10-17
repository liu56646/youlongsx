#!/usr/bin/env bash
#
# 交叉编译 AOSP QEMU（emu-34，底子 QEMU 2.12 + ranchu/goldfish）为 Android/arm64。
#
# 与 build_qemu.sh（上游 QEMU 9.2）的区别：
#   1) 构建期需要 Python 2（AOSP 版 configure 明确拒绝 py3），走 /opt/py2
#   2) 用的是 Make 而不是 meson/ninja
#   3) 目标产物是 ranchu 机器 + goldfish 设备，供 Google 的模拟器镜像直接使用
#
# 用法：
#   ./build_qemu_aosp.sh                 # configure + make
#   CONFIGURE_ONLY=1 ./build_qemu_aosp.sh # 只 configure，便于快速看报错
#
set -euo pipefail

WORKDIR="${WORKDIR:-/root/vmbuild}"
SRC_DIR="${SRC_DIR:-$WORKDIR/qemu-aosp}"
BUILD_DIR="${BUILD_DIR:-$WORKDIR/qemu-aosp-build-arm64-v8a}"

# 期望的 AOSP QEMU 源码线 / 大版本。emu-34-release 底子是 QEMU 2.12。
# 本脚本全套补丁按该版本的源码锚点写；换大版本需先移植（见
# engine/scripts/QEMU基座升级-移植指南.md），否则版本闸门会拦下。
QEMU_AOSP_BRANCH="${QEMU_AOSP_BRANCH:-emu-34-release}"
QEMU_AOSP_EXPECT="${QEMU_AOSP_EXPECT:-2.12}"

# aemu 宿主侧子集（host-common/base/snapshot），由 build_aemu.sh 产出。
# 用来替换 goldfish_pipe 的 null 空桩：把 QEMU 的 pipe 设备接到真正的
# AndroidPipe 服务上。源码：fetch_aemu.sh（清华镜像）。
AEMU_DIR="${AEMU_DIR:-$WORKDIR/aemu}"
AEMU_LIB_DIR="${AEMU_LIB_DIR:-$WORKDIR/aemu-build-arm64-v8a}"

# gfxstream 宿主渲染器（GL 路径），由 build_gfxstream.sh 产出。
# 用来让 pipe:opengles 真正可用 —— guest 的 hwcomposer(EmuHWC2) 没有它就会
# 致命 abort，进而 onrestart 把 surfaceflinger 一起拖重启。
GFX_DIR="${GFX_DIR:-$WORKDIR/gfxstream}"
GFX_BUILD_DIR="${GFX_BUILD_DIR:-$WORKDIR/gfxstream-build-arm64-v8a}"

# aemu 快照库及其依赖。Snapshotter 的 protobuf / RAM 分段钩子都在这条链上。
SNAPSHOT_LIB="${SNAPSHOT_LIB:-$WORKDIR/aemu-snapshot-build-arm64-v8a/libaemu-snapshot.a}"
ABSEIL_DIR="${ABSEIL_DIR:-$WORKDIR/abseil}"
ABSEIL_BUILD_DIR="${ABSEIL_BUILD_DIR:-$WORKDIR/abseil-build-arm64-v8a}"
LZ4_LIB="${LZ4_LIB:-$WORKDIR/lz4-build-arm64-v8a/lib/liblz4.a}"
PROTO_GEN_DIR="${PROTO_GEN_DIR:-$WORKDIR/proto-gen}"
PROTOBUF_BUILD_DIR="${PROTOBUF_BUILD_DIR:-$WORKDIR/protobuf-build-arm64-v8a}"
PROTOBUF_INCLUDE_DIR="$PROTOBUF_BUILD_DIR/include"
PROTOBUF_LIB="$PROTOBUF_BUILD_DIR/lib/libprotobuf.a"

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
ABI="${ABI:-arm64-v8a}"
OUT_DIR="${OUT_DIR:-$TOOLS_DIR/../src/main/cpp/prebuilt/qemu-aosp/arm64-v8a}"
# 子进程 QEMU 必须随 APK 分发，见本文件末尾「安装到 jniLibs」一节。
JNI_DIR="$ENGINE_DIR/src/main/jniLibs/$ABI"

NDK_VER="${NDK_VER:-r28}"
NDK_DIR="$WORKDIR/android-ndk-$NDK_VER"
TOOLCHAIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
SYSROOT="$WORKDIR/sysroot-arm64"
TRIPLE="aarch64-linux-android"
API_LEVEL="${API_LEVEL:-28}"
PY2="${PY2:-/opt/py2/bin/python2.7}"
JOBS="${JOBS:-$(nproc)}"

[ -x "$PY2" ] || { echo "找不到 Python 2：$PY2（先跑 tools/wsl_setup_py2.sh）" >&2; exit 1; }
[ -d "$TOOLCHAIN" ] || { echo "找不到 NDK 工具链：$TOOLCHAIN" >&2; exit 1; }
[ -d "$SYSROOT/lib/pkgconfig" ] || { echo "找不到 sysroot：$SYSROOT" >&2; exit 1; }
[ -f "$SRC_DIR/configure" ] || { echo "找不到 AOSP QEMU 源码：$SRC_DIR" >&2; exit 1; }
[ -d "$AEMU_DIR/host-common" ] || {
    echo "找不到 aemu 源码：$AEMU_DIR（先跑 vm/build-aosp-exp/fetch_aemu.sh）" >&2; exit 1; }
for _lib in host-common/libaemu-host-common.a snapshot/libgfxstream-snapshot.a; do
    [ -f "$AEMU_LIB_DIR/$_lib" ] || {
        echo "找不到 aemu 静态库：$AEMU_LIB_DIR/$_lib（先跑 build_aemu.sh）" >&2; exit 1; }
done

# vendored android-emu-base：快照链和 host-common 需要的 android::base::* 由它提供。
# **不再链外部 aemu 的 libaemu-base.a / liblogging-base.a** —— 两者同处
# android::base 命名空间，混链必然重复定义 + 连锁缺符号（实测，见
# vm/engine/scripts/aemu快照移植指南.md §8）。
ANDROID_EMU_BASE_LIB_DIR="${ANDROID_EMU_BASE_LIB_DIR:-$WORKDIR/android-emu-base-build-arm64-v8a/lib}"
for _lib in libandroid-emu-base.a libandroid-emu-base-memory.a \
            libandroid-emu-base-logging.a; do
    [ -f "$ANDROID_EMU_BASE_LIB_DIR/$_lib" ] || {
        echo "找不到 vendored base：$ANDROID_EMU_BASE_LIB_DIR/$_lib（先跑 build_android_emu_base.sh）" >&2
        exit 1; }
done

[ -f "$SNAPSHOT_LIB" ] || {
    echo "找不到 aemu 快照静态库：$SNAPSHOT_LIB（先跑 build_aemu_snapshot.sh）" >&2; exit 1; }
[ -d "$ABSEIL_BUILD_DIR" ] || {
    echo "找不到 abseil 构建目录：$ABSEIL_BUILD_DIR（先跑 build_abseil.sh）" >&2; exit 1; }
[ -d "$ABSEIL_DIR" ] || {
    echo "找不到 abseil 源码 include 根：$ABSEIL_DIR" >&2; exit 1; }
[ -f "$LZ4_LIB" ] || {
    echo "找不到 lz4 静态库：$LZ4_LIB（先跑 build_lz4.sh）" >&2; exit 1; }
[ -f "$PROTOBUF_LIB" ] || {
    echo "找不到 protobuf 静态库：$PROTOBUF_LIB（先跑 build_protobuf.sh）" >&2; exit 1; }
[ -f "$PROTO_GEN_DIR/snapshot.pb.h" ] || {
    echo "找不到生成的 snapshot protobuf：$PROTO_GEN_DIR/snapshot.pb.h" >&2; exit 1; }

# gfxstream 宿主渲染器（pipe:opengles 的必要条件）
[ -d "$GFX_DIR/host" ] || {
    echo "找不到 gfxstream 源码：$GFX_DIR（见 docs/opengles宿主渲染器实施方案.md）" >&2; exit 1; }
for _lib in host/libgfxstream_backend_static.a \
            host/gl/gl-host-common/libgfxstream-gl-host-common.a; do
    [ -f "$GFX_BUILD_DIR/$_lib" ] || {
        echo "找不到 gfxstream 静态库：$GFX_BUILD_DIR/$_lib（先跑 build_gfxstream.sh）" >&2; exit 1; }
done

# ---------------------------------------------------------------- 前置：QEMU 版本闸门
# 本脚本的全套补丁都是按 AOSP QEMU **emu-34（底子 QEMU 2.12）** 的源码锚点写的。
# 换成更新的大版本（emu-35+ / QEMU 7/8）后，锚点文法与若干内部 API 都变了，
# 直接跑只会在某个 “补丁锚点未找到” 处半途而废，甚至编出能过编译但行为不对的
# 二进制。所以先探版本：与预期主线一致就继续；不一致则中止（除非显式放行）。
qemu_ver=""
if [ -f "$SRC_DIR/VERSION" ]; then
    qemu_ver="$(head -n1 "$SRC_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
fi
if [ -z "$qemu_ver" ] && [ -f "$SRC_DIR/configure" ]; then
    qemu_ver="$(grep -aom1 -E 'QEMU_VERSION=[0-9][0-9.]*' "$SRC_DIR/configure" 2>/dev/null | cut -d= -f2 || true)"
fi
echo "==> AOSP QEMU 源码线：$QEMU_AOSP_BRANCH"
echo "==> 检测到 QEMU 版本：${qemu_ver:-未知}（本套补丁预期：$QEMU_AOSP_EXPECT）"
if [ -n "$qemu_ver" ]; then
    case "$qemu_ver" in
        "$QEMU_AOSP_EXPECT"*) : ;;   # 命中预期主线（如 2.12.x），继续
        *)
            if [ "${ALLOW_UNVERIFIED_QEMU:-0}" != "1" ]; then
                cat >&2 <<EOF
!! QEMU 版本与预期不符：检测到 $qemu_ver，本套补丁针对 $QEMU_AOSP_EXPECT。

   换大版本（例如升到现代 Android Emulator 的 QEMU 7/8）需要先移植这批补丁：
     engine/scripts/QEMU基座升级-移植指南.md
   移植完成后再把 QEMU_AOSP_EXPECT 改成新版本；确实只想强行试跑，
   设 ALLOW_UNVERIFIED_QEMU=1 再执行（补丁很可能不命中）。
EOF
                exit 4
            fi
            echo "!! ALLOW_UNVERIFIED_QEMU=1：跳过版本闸门继续（补丁锚点大概率不命中）" >&2
        ;;
    esac
fi

export CC="$TOOLCHAIN/bin/${TRIPLE}${API_LEVEL}-clang"
export CXX="$TOOLCHAIN/bin/${TRIPLE}${API_LEVEL}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export NM="$TOOLCHAIN/bin/llvm-nm"
export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig"

echo "==> 源码   $SRC_DIR"
echo "==> 构建   $BUILD_DIR"
echo "==> Python $PY2 ($($PY2 -V 2>&1))"
echo "==> CC     $CC"

# ---------------------------------------------------------------- 1. 源码补丁
# 先把要打补丁的源文件恢复成 git 上游版本，保证每次都是"干净起点"。
# 否则早期版本留下的补丁块（如 VMHOST_NULL_OPS）会和现在的补丁串味，
# 幂等判断也救不回来（例如 goldfish_pipe.c 现在改用 aemu 真头文件，
# 必须去掉当年为"桩头文件"写的空回调补丁）。
reset_scratch_sources() {
    if git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        echo "==> 从 git 恢复 vl.c / hw/misc/goldfish_pipe.c 到上游版本"
        git -C "$SRC_DIR" checkout -- vl.c hw/misc/goldfish_pipe.c 2>/dev/null || true
    else
        echo "!! $SRC_DIR 不是 git 仓库，跳过源码重置（补丁可能重复）" >&2
    fi
}
reset_scratch_sources

# 让 goldfish_pipe 退出来宾迁移（savevm / migrate）。
#
# 必须放在 reset_scratch_sources 之后 —— 上面那步会把 goldfish_pipe.c
# 还原成上游版本，早先手工打的补丁会被它静默撤销（本次踩过：改了源码、
# 编出来却仍带 register_savevm，恢复时照旧
# "error while loading state for instance 0x0 of device 'goldfish_pipe'"）。
#
# 原因：goldfish_pipe_load_v2() 恢复时要用 map_guest_buffer() 把快照里记录的
# guest 物理地址映射成宿主指针，而新起的 QEMU 进程里这些映射尚未建立，
# 必然返回 -EIO。管道承载的是宿主侧 gfxstream 运行时资源（host pipe / EGL /
# FBO），本就不该也无法跨进程序列化。不参与迁移后，保存/恢复两侧流一致，
# guest 运行中会按需重新打开管道（等价于一次 GPU 复位）。
patch_goldfish_pipe_savevm() {
    local f="$SRC_DIR/hw/misc/goldfish_pipe.c"
    [ -f "$f" ] || return 0
    grep -q "VMHOST_NO_PIPE_SAVEVM" "$f" && return 0
    echo "==> 打补丁（goldfish_pipe 退出迁移）：hw/misc/goldfish_pipe.c"
    python3 - "$f" <<'PY'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
mark = "VMHOST_NO_PIPE_SAVEVM"
if mark in src:
    sys.exit(0)

old = """    register_savevm_with_post_load(
            dev, "goldfish_pipe", 0, GOLDFISH_PIPE_SAVE_VERSION,
            goldfish_pipe_save, goldfish_pipe_load, goldfish_pipe_post_load, s);"""

new = """    /* VMHOST_NO_PIPE_SAVEVM
     * 管道承载的是宿主侧 gfxstream 运行时资源（host pipe / EGL / FBO），
     * 无法跨进程序列化；恢复时 goldfish_pipe_load_v2 的 map_guest_buffer
     * 必然拿不到映射而返回 -EIO（"error while loading state for instance
     * 0x0 of device 'goldfish_pipe'"）。直接不参与迁移：两侧流一致，
     * guest 运行中自行重建管道。
     */
    (void) goldfish_pipe_save;
    (void) goldfish_pipe_load;
    (void) goldfish_pipe_post_load;"""

if old not in src:
    sys.exit("goldfish_pipe.c 补丁锚点未找到")
open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
print("    已移除 register_savevm_with_post_load")
PY
}
# patch_goldfish_pipe_savevm   # 撤销：移除注册会导致恢复后 guest 访问 MMIO 踩空

# 给 vl.c 加一个嵌入式入口：main_impl 是 static 的，AOSP 原生的
# run_qemu_main() 又被 CONFIG_ANDROID 挡住（会把整个 emulator 前端拖进来）。
# 这里只加一个 3 行的包装函数，让引擎能在进程内直接驱动 QEMU。
patch_embed_entry() {
    local vl="$SRC_DIR/vl.c"
    if grep -q "VMHOST_NOEXITCTOR" "$vl"; then
        echo "==> vl.c 已有嵌入式入口（含 _exit 跳过静态析构），跳过"
        return
    fi
    # 清掉旧版本注入的入口块（无 _exit 那段），避免重复定义。
    # 注意 /* 与横线之间有空格，别把 \s* 漏掉。
    perl -0pi -e 's{\n/\*[^\n]*\n \* VMHost: 进程内嵌入式入口.*\z}{}s' "$vl"
    echo "==> 注入嵌入式入口 vmhost_qemu_main()（含崩溃捕获 + _exit 跳过静态析构）"
    cat >> "$vl" <<'EOF'

/* ------------------------------------------------------------------
 * VMHost: 进程内嵌入式入口。
 *
 * AOSP 自带的 run_qemu_main() 被 #if defined(CONFIG_ANDROID) 包住，
 * 打开它会连带编译整个 emulator 前端（android/、android-qemu2-glue），
 * 而我们只需要 QEMU 本身。main_impl 是 static 的，所以在文件末尾
 * 加一层薄包装把它暴露出来；on_main_loop_done 原样传 NULL
 * （main_impl 里对它有 if 判空）。
 * ------------------------------------------------------------------ */

/* ------------------------------------------------------------------
 * VMHOST_CRASH_CAPTURE: 实验用崩溃捕获。
 *
 * Android 上以 root/ksu 身份运行的 QEMU 崩溃时不会生成 tombstone，
 * 这里注册进程级信号处理器，并借助 QEMU 自己的每线程 setup 钩子
 * qemu_thread_register_setup_callback() 给每个线程装上备用信号栈
 * （栈溢出也必须能进处理器）。崩溃时把 信号/故障地址/PC/LR/调用栈
 * 落到固定文件，供离线 llvm-symbolizer 还原。
 * ------------------------------------------------------------------ */
#include <signal.h>
#include <ucontext.h>
#include <unwind.h>
#include <pthread.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void qemu_thread_register_setup_callback(void (*)(void));

static uintptr_t vmhost_crash_exe_base = 0;

static void vmhost_crash_find_base(void)
{
    int fd = open("/proc/self/maps", O_RDONLY);
    if (fd < 0) return;
    char buf[8192];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return;
    buf[n] = '\0';
    char *line = buf;
    while (line && *line) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = '\0';
        if (strstr(line, "qemu-system-aarch64")) {
            unsigned long long base = 0;
            if (sscanf(line, "%llx", &base) == 1) {
                vmhost_crash_exe_base = (uintptr_t) base;
                return;
            }
        }
        if (!nl) break;
        line = nl + 1;
    }
}

struct vmhost_bt_state { void **p; int n; int max; };

static _Unwind_Reason_Code vmhost_unwind_cb(struct _Unwind_Context *ctx, void *arg)
{
    struct vmhost_bt_state *s = (struct vmhost_bt_state *) arg;
    uintptr_t ip = _Unwind_GetIP(ctx);
    if (ip && s->n < s->max) s->p[s->n++] = (void *) ip;
    return _URC_NO_REASON;
}

static void vmhost_crash_handler(int sig, siginfo_t *info, void *uctx)
{
    int fd = open("/data/local/tmp/qemu_crash.txt",
                  O_CREAT | O_WRONLY | O_APPEND, 0644);
    uintptr_t pc = 0, lr = 0, sp = 0, fault = 0;
    if (uctx) {
        ucontext_t *uc = (ucontext_t *) uctx;
        pc = (uintptr_t) uc->uc_mcontext.pc;
        sp = (uintptr_t) uc->uc_mcontext.sp;
        lr = (uintptr_t) uc->uc_mcontext.regs[30];
        fault = (uintptr_t) uc->uc_mcontext.fault_address;
    }
    if (fd >= 0) {
        char b[640];
        int len = snprintf(b, sizeof(b),
            "SIGNAL=%d si_code=%d si_addr=0x%llx exe_base=0x%llx\n"
            "PC=0x%llx PC_off=0x%llx\nLR=0x%llx LR_off=0x%llx\nSP=0x%llx FAULT=0x%llx\n",
            sig, info ? info->si_code : -999,
            (unsigned long long) (uintptr_t) (info ? info->si_addr : 0),
            (unsigned long long) vmhost_crash_exe_base,
            (unsigned long long) pc, (unsigned long long) (pc - vmhost_crash_exe_base),
            (unsigned long long) lr, (unsigned long long) (lr - vmhost_crash_exe_base),
            (unsigned long long) sp, (unsigned long long) fault);
        (void) write(fd, b, len);
    }
    /* 把整份 /proc/self/maps 落盘，离线判定故障 PC 落在哪个映射
       （.so / TCG 代码缓冲 / 匿名区）。maps 可能上百 KB，一次读满。 */
    if (fd >= 0) {
        int mf = open("/proc/self/maps", O_RDONLY);
        if (mf >= 0) {
            static char vmhost_maps_buf[512 * 1024];
            ssize_t total = 0;
            ssize_t n;
            while (total < (ssize_t) sizeof(vmhost_maps_buf) - 1 &&
                   (n = read(mf, vmhost_maps_buf + total,
                             sizeof(vmhost_maps_buf) - 1 - total)) > 0) {
                total += n;
            }
            close(mf);
            (void) write(fd, "\n=== MAPS ===\n", 13);
            if (total > 0) {
                (void) write(fd, vmhost_maps_buf, (size_t) total);
            }
            (void) write(fd, "\n=== END MAPS ===\n", 17);
        }
    }
    /* 栈内存原始 dump：libunwind 展不开时，离线在栈里搜落在 exe 代码段的
       返回地址，用来还原调用链。 */
    if (fd >= 0 && sp) {
        char b[64];
        int len = snprintf(b, sizeof(b), "=== STACK (256 words from SP) ===\n");
        (void) write(fd, b, len);
        for (int i = 0; i < 256; i++) {
            unsigned long long v = 0;
            memcpy(&v, (const char *) sp + (size_t) i * 8, 8);
            len = snprintf(b, sizeof(b), "%03d 0x%016llx\n", i, v);
            (void) write(fd, b, len);
        }
        (void) write(fd, "=== END STACK ===\n", 18);
    }
    /* 调用栈展开默认关闭：libunwind 的 _Unwind_Backtrace 在本工程的
       信号帧上会无限循环（实测 100% CPU 自旋），把真正的信号上下文吞掉。
       需要栈时显式设 VMHOST_CRASH_UNWIND=1。 */
    void *bt[96];
    struct vmhost_bt_state st = { bt, 0, 96 };
    if (getenv("VMHOST_CRASH_UNWIND")) {
        _Unwind_Backtrace(vmhost_unwind_cb, &st);
    }
    if (fd >= 0) {
        char b[128];
        int len = snprintf(b, sizeof(b), "unwind_frames=%d\n", st.n);
        (void) write(fd, b, len);
        for (int i = 0; i < st.n; i++) {
            uintptr_t a = (uintptr_t) bt[i];
            len = snprintf(b, sizeof(b), "#%02d abs=0x%llx off=0x%llx\n",
                           i, (unsigned long long) a,
                           (unsigned long long) (a - vmhost_crash_exe_base));
            (void) write(fd, b, len);
        }
        close(fd);
    }
    _exit(128 + sig);
}

static void vmhost_crash_thread_setup(void)
{
    char *alt = (char *) malloc(65536);
    if (alt) {
        stack_t ss;
        ss.ss_sp = alt;
        ss.ss_size = 65536;
        ss.ss_flags = 0;
        sigaltstack(&ss, NULL);
    }
    /* qemu_thread_create() 用 sigfillset() 屏蔽了所有信号后再 pthread_create，
       新线程会继承这个「全屏蔽」掩码；同步 SIGSEGV 在被屏蔽时不会进处理器，
       而是直接走默认动作把进程杀掉。AOSP 前端正是靠这个 setup 回调解屏蔽。 */
    sigset_t un;
    sigemptyset(&un);
    sigaddset(&un, SIGSEGV);
    sigaddset(&un, SIGBUS);
    sigaddset(&un, SIGABRT);
    sigaddset(&un, SIGILL);
    sigaddset(&un, SIGFPE);
    pthread_sigmask(SIG_UNBLOCK, &un, NULL);
}

static void vmhost_crash_install(void)
{
    /* 默认不安装！本项目 CONFIG_COROUTINE_BACKEND=sigaltstack，QEMU 块层
       异步 I/O 依赖 SIGUSR2 + sigaltstack 切协程栈；一旦我们给线程装了
       信号处理器/备用信号栈，协程切换就会跳飞（表现为 SIGILL in libc +
       100% CPU 假死）。仅在显式设 VMHOST_CRASH_CAPTURE=1 时开启，用于排障。 */
    if (!getenv("VMHOST_CRASH_CAPTURE")) {
        return;
    }
    vmhost_crash_find_base();
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = vmhost_crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
    vmhost_crash_thread_setup();
    qemu_thread_register_setup_callback(vmhost_crash_thread_setup);

    {   /* 安装确认 + 自检开关：VMHOST_CRASH_TEST=1 时主动触发一次 SIGSEGV */
        int fd = open("/data/local/tmp/crash_installed.txt",
                      O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (fd >= 0) {
            char m[160];
            int len = snprintf(m, sizeof(m), "installed exe_base=0x%llx\n",
                               (unsigned long long) vmhost_crash_exe_base);
            (void) write(fd, m, len);
            close(fd);
        }
        if (getenv("VMHOST_CRASH_TEST")) {
            raise(SIGSEGV);
        }
    }
}

int vmhost_qemu_main(int argc, char **argv);
extern int vmhost_pipe_init(void); /* VMHOST_PIPE_PROTO */
extern int vmhost_gfx_init(void); /* VMHOST_GFX_PROTO */
int vmhost_qemu_main(int argc, char **argv)
{
    vmhost_crash_install();
    vmhost_pipe_init(); /* VMHOST_PIPE_INIT */
    vmhost_gfx_init(); /* VMHOST_GFX_INIT */
    const int vmhost_rc = main_impl(argc, argv, NULL);
    /* VMHOST_NOEXITCTOR: main_impl 里 QEMU 自己的收尾（block flush、设备 unrealize）
       已经做完；接下来就是 C++ **静态析构**。而此刻仍有多条 gfxstream RenderThread
       在跑并去 lock 已被析构的 mutex（实测：android::base::Lock / ProcessPipeIdRegistry
       / std::__ndk1::mutex 的析构先跑），必然触发
         libc: FORTIFY: pthread_mutex_lock called on a destroyed mutex
       → abort() → SIGABRT（非干净退出，cache=unsafe 下有脏盘风险）。
       静态析构在进程退出时没有任何价值，直接 _exit 跳过整段析构，竞态从根上消失。
       详见 docs/方案B排障交接.md §22.5。 */
    fprintf(stderr, "VMHOST_NOEXITCTOR main_impl=%d -> _exit（跳过静态析构）\n",
            vmhost_rc);
    fflush(stderr);
    _exit(vmhost_rc);
}
EOF
}

patch_embed_entry

# ---------------------------------------------------------------- 1b. bionic 兼容
# AOSP QEMU 的底子是 2018 年的 QEMU 2.12，当年没考虑过 bionic；
# 每一处都用幂等判断，重复执行安全。
patch_bionic() {
    # openpty：QEMU 只在 __GLIBC__ / CONFIG_BSD 下 include <pty.h>，
    # bionic 确实有 <pty.h>（API 23+）但不匹配这些条件，
    # 于是变成隐式函数声明 —— clang 18 起这是 error 而不是 warning。
    local f="$SRC_DIR/util/qemu-openpty.c"
    if [ -f "$f" ] && ! grep -q "__ANDROID__" "$f"; then
        perl -0pi -e \
            's/#if defined\(__GLIBC__\)\n# include <pty\.h>/#if defined(__GLIBC__) || defined(__ANDROID__)\n# include <pty.h>/' \
            "$f"
        echo "==> patch: qemu-openpty.c 支持 __ANDROID__"
    fi
}

patch_bionic

# vl.c 的 #include "host-common/feature_control.h"（第 170 行）落在
# #ifdef CONFIG_ANDROID 区间（148-221）里，但第 5605 行的调用在外面，
# 不定义 CONFIG_ANDROID 时就变成隐式函数声明 → clang 18 直接报错。
# 把这个 include 提到 qemu/osdep.h 之后，无条件生效。
patch_feature_include() {
    local f="$SRC_DIR/vl.c"
    if grep -q "VMHOST_FEATURE_INCLUDE" "$f"; then
        return
    fi
    perl -0pi -e \
        's{#include "qemu/osdep\.h"\n}{#include "qemu/osdep.h"\n#include "host-common/feature_control.h" /* VMHOST_FEATURE_INCLUDE */\n}' \
        "$f"
    echo "==> patch: vl.c 把 feature_control.h 提到 CONFIG_ANDROID 之外"
}

patch_feature_include

# 崩溃捕获的入口挂钩：
#   - 在文件顶部（osdep 之后）放一个 static 原型，让 main() 可见
#   - 在真正 main()/run_qemu_main() 的主体开头调用安装函数
patch_crash_hooks() {
    local vl="$SRC_DIR/vl.c"
    if grep -q "VMHOST_NOEXITCTOR_MAIN" "$vl"; then
        return
    fi
    # 原型：放在文件顶部（osdep / feature_control 之后），main() 可见
    if ! grep -q "VMHOST_CRASH_PROTO" "$vl"; then
        perl -0pi -e \
            's/(#include "host-common\/feature_control\.h" \/\* VMHOST_FEATURE_INCLUDE \*\/\n)/$1static void vmhost_crash_install(void); \/* VMHOST_CRASH_PROTO *\/\nextern int vmhost_pipe_init(void); \/* VMHOST_PIPE_PROTO *\/\nextern int vmhost_gfx_init(void); \/* VMHOST_GFX_PROTO *\/\n/' \
            "$vl"
    fi
    # 主体挂钩：用 / 作分隔符，避免 {} 配对问题
    if ! grep -q "VMHOST_MAIN_CRASH" "$vl"; then
        perl -0pi -e \
            's/\{\n    const int res = main_impl\(argc, argv, on_main_loop_done\);/{\n    vmhost_crash_install(); \/* VMHOST_MAIN_CRASH *\/\n    vmhost_pipe_init(); \/* VMHOST_PIPE_INIT_MAIN *\/\n    vmhost_gfx_init(); \/* VMHOST_GFX_INIT_MAIN *\/\n    const int res = main_impl(argc, argv, on_main_loop_done);/' \
            "$vl"
    fi
    # VMHOST_NOEXITCTOR_MAIN：**B1 子进程走的是这个 main()**（vmhost_qemu_main 只用于
    # 进程内嵌）。main_impl 返回后、静态析构开始前，此刻仍有多条线程在 lock
    # libc++/aemu/gfxstream 已被析构的静态 mutex → FORTIFY abort（SIGABRT，非干净
    # 退出，cache=unsafe 有脏盘风险）。静态析构在进程退出时没有价值，直接 _exit 跳过。
    # 实测根因见 docs/方案B排障交接.md §22.5（MUTEXDBG 定位到
    # /system/lib64/libc++.so+0x27470 的静态 mutex 析构点）。
    perl -0pi -e \
        's/    qemu_exit_notifiers_notify\(\);\n\n    return res;\n/    qemu_exit_notifiers_notify();\n\n    \/* VMHOST_NOEXITCTOR_MAIN: 跳过静态析构，避免退出竞态 SIGABRT *\/\n    fprintf(stderr, "VMHOST_NOEXITCTOR main res=%d -> _exit（跳过静态析构）\\n", res);\n    fflush(stderr);\n    _exit(res);\n/' \
        "$vl"
    echo "==> patch: vl.c 在 main() 挂崩溃捕获 + pipe/gfxstream 初始化 + _exit 跳过静态析构"
}

patch_crash_hooks

# virtio-gpu.c 在 --disable-virgl 时，update_cursor_data_virgl 的 #else 分支
# 仍然硬编码调用 virgl_renderer_get_cursor_data()，这是 AOSP 在非 virgl 构建下的
# 遗留 bug。该分支只在 3D（virgl）模式下才会被执行，我们走 2D，直接让它返回 NULL。
patch_virtio_gpu() {
    local f="$SRC_DIR/hw/display/virtio-gpu.c"
    if grep -q "VMHOST_NO_VIRGL" "$f"; then
        return
    fi
    perl -0pi -e \
        's/#else\n(\s*)data = virgl_renderer_get_cursor_data\(resource_id, &width, &height\);\n#endif/#else\n$1\/* VMHOST_NO_VIRGL *\/\n$1(void)resource_id;\n$1data = NULL;\n#endif/' \
        "$f"
    grep -q "VMHOST_NO_VIRGL" "$f" \
        && echo "==> patch: virtio-gpu.c 非 virgl 分支改为返回 NULL" \
        || echo "!! virtio-gpu.c 补丁未命中" >&2
}

patch_virtio_gpu

# goldfish_pipe.c 里 interleaved buffer mapping 的 RAM_SPLIT_BOUNDARY
# 用 #if defined(TARGET_MIPS)/TARGET_I386/TARGET_ARM 判断架构，但 QEMU 的
# include/exec/poison.h 会把这些 TARGET_* 宏毒化（防串台），aarch64 构建下
# 连引用都会报 "attempt to use a poisoned identifier"，最终落到
# #error Unsupported architecture!。aarch64 与 arm 的 RAM 布局一致
# （单个连续 RAM 区，无 4G 拆分），直接把整段判断换成固定边界。
patch_goldfish_pipe_arch() {
    local f="$SRC_DIR/hw/misc/goldfish_pipe.c"
    if grep -q "VMHOST_ARCH_SPLIT" "$f"; then
        return
    fi
    perl -0pi -e \
        's{#if defined\(TARGET_MIPS\).*?#error Unsupported architecture!\n#endif\n}{/* VMHOST_ARCH_SPLIT: aarch64 同 arm，单段 RAM */\n#define RAM_SPLIT_BOUNDARY 0x40000000\n}gs' \
        "$f"
    grep -q "VMHOST_ARCH_SPLIT" "$f" \
        && echo "==> patch: goldfish_pipe.c 固定 RAM_SPLIT_BOUNDARY（aarch64）" \
        || echo "!! goldfish_pipe.c 架构补丁未命中" >&2
}

patch_goldfish_pipe_arch

# 给 ranchu 机器补 PCIe(gpex) + goldfish_address_space 设备。
# guest 的 gralloc(GoldfishMapper) 必须打开 /dev/goldfish_address_space，
# 而它是 **PCI 设备**（607d:f153，内核模块 alias=pci:v0000607Dd0000F153...）；
# ranchu 原来没有任何 PCI 总线 ⇒ 驱动不绑定 ⇒ 设备节点不存在 ⇒ gralloc 打开失败
# ⇒ EmuHWC2 初始化主屏时 abort（HWC 启动 ~60s 后必崩）。
# 注意该设备 AREA BAR 是 16GB，必须另开 64 位 high MMIO 窗口，否则会
# "BAR 1: no space for [mem size 0x400000000 64bit]" 分配失败。
patch_ranchu_pcie() {
    python3 "$TOOLS_DIR/qemu_patches/patch_ranchu_pcie.py" "$SRC_DIR" \
        && echo "==> patch: ranchu 增加 PCIe + goldfish_address_space" \
        || echo "!! ranchu PCIe 补丁失败" >&2
}

patch_ranchu_pcie

# 方案 B（virtio-gpu + gfxstream stream_renderer）：
# 让 virtio-gpu 设备走 gfxstream 的 stream_renderer 路径（CONFIG_STREAM_RENDERER）。
# 只改 virtio-gpu.c / virtio-gpu-3d.c，不整树开 CONFIG_ANDROID。
patch_virtio_gpu_stream() {
    python3 "$TOOLS_DIR/qemu_patches/patch_virtio_gpu_stream.py" "$SRC_DIR" \
        && echo "==> patch: virtio-gpu stream_renderer 模式（方案 B）" \
        || echo "!! virtio-gpu stream_renderer 补丁失败" >&2
}

patch_virtio_gpu_stream

# capset 通告修复：gfxstream renderer 只支持 gfxstream 系 capset（3/7/8/9），
# 把设备通告从 VIRGL 换成 gfxstream，否则 guest 内核驱动 probe 找不到可用
# capset → 不开 3D → 无 render node → guest EGL 失败。
patch_virtio_gpu_capset() {
    python3 "$TOOLS_DIR/qemu_patches/patch_virtio_gpu_capset.py" "$SRC_DIR" \
        && echo "==> patch: virtio-gpu capset 通告（gfxstream 系）" \
        || echo "!! virtio-gpu capset 补丁失败" >&2
}

patch_virtio_gpu_capset

# 可选调试：给 goldfish_pipe 的 MMIO 读写加节流日志（VMHOSTPIPE）。
# 用 PIPE_TRACE=1 打开，用于对比访客敲 pipe 寄存器的行为。默认不打。
# 注意必须在 reset_scratch_sources 之后执行，否则会被 git checkout 冲掉。
if [ "${PIPE_TRACE:-0}" = "1" ]; then
    python3 "$TOOLS_DIR/../../build-aosp-exp/patch_pipe_trace.py" \
        && echo "==> patch: 已注入 VMHOST_PIPE_TRACE 打点（PIPE_TRACE=1）" \
        || echo "!! VMHOST_PIPE_TRACE 打点注入失败" >&2
fi

# 注意：早期版本这里有一段 patch_goldfish_pipe_null_ops，给 s_null_service_ops
# 补了一堆空回调（当时用的是自写桩头文件，DMA 字段全 NULL 会跳到地址 0）。
# 现在已改为：① goldfish_pipe.c 直接用 aemu 的真 goldfish_pipe.h；
# ② 启动时由 vmhost_pipe_init() 注册真正的 GoldfishPipeServiceOps。
# 上游那份只填 6 个字段的 s_null_service_ops 在真头文件下编译完全正常，
# 且不再是实际生效的 ops，故该补丁已废弃、不再应用。

# util/mmap-alloc.c 为大块映射（>=1G）安装 tcmalloc 的 mmap/munmap 替换钩子，
# 用来规避前端 gl 线程误 munmap 打洞导致的 KVM Bad Address。
# MallocHook_* 由 aemu 前端的 gperftools 提供，我们没有也不跑 KVM，
# 直接去掉这两个调用（否则链接期 undefined symbol）。
patch_mmap_alloc() {
    local f="$SRC_DIR/util/mmap-alloc.c"
    if grep -q "VMHOST_NO_MALLOC_HOOK" "$f"; then
        return
    fi
    perl -0pi -e \
        's/\n\s*MallocHook_SetMmapReplacement\(&MmapReplacement\);\n\s*MallocHook_SetMunmapReplacement\(&MunmapReplacement\);/\n        \/* VMHOST_NO_MALLOC_HOOK *\//' \
        "$f"
    grep -q "VMHOST_NO_MALLOC_HOOK" "$f" \
        && echo "==> patch: mmap-alloc.c 去掉 MallocHook 调用" \
        || echo "!! mmap-alloc.c 补丁未命中" >&2
}

patch_mmap_alloc

# VMHost 快照 HMP 入口：引擎通过 QMP human-monitor-command 执行
#   vmhostsnapshot save|load <name>
# savevm.c 是 C，Snapshotter 是 C++；这里注册 HMP 命令，由
# vmhost_snapshot_glue.cpp 导出的 C ABI 转入 android::snapshot::Snapshotter。
patch_vmhostsnapshot() {
    local hmp_commands="$SRC_DIR/hmp-commands.hx"
    local hmp_header="$SRC_DIR/hmp.h"
    local savevm="$SRC_DIR/migration/savevm.c"

    for f in "$hmp_commands" "$hmp_header" "$savevm"; do
        [ -f "$f" ] || { echo "找不到 vmhostsnapshot 补丁目标：$f" >&2; return 1; }
    done
    if grep -q "VMHOSTSNAPSHOT" "$hmp_commands" \
        && grep -q "VMHOSTSNAPSHOT" "$hmp_header" \
        && grep -q "VMHOSTSNAPSHOT_V2" "$savevm"; then
        echo "==> vmhostsnapshot 补丁已存在且为 Snapshotter 版本，跳过"
        return 0
    fi

    echo "==> 打补丁（vmhostsnapshot HMP 命令 → Snapshotter C ABI）"
    python3 - "$SRC_DIR" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
marker = "VMHOSTSNAPSHOT"
savevm_marker = "VMHOSTSNAPSHOT_V2"


def read_source(path):
    if not path.is_file():
        raise SystemExit("vmhostsnapshot 补丁文件不存在: %s" % path)
    return path.read_text(encoding="utf-8")


def insert_after_anchor(path, anchor, addition):
    src = read_source(path)
    if marker in src:
        return False
    if anchor not in src:
        raise SystemExit("vmhostsnapshot 补丁锚点未找到: %s" % path)
    if src.count(anchor) != 1:
        raise SystemExit("vmhostsnapshot 补丁锚点不唯一: %s" % path)
    path.write_text(src.replace(anchor, anchor + addition, 1), encoding="utf-8")
    return True


hmp_commands_anchor = """    {
        .name       = "savevm",
        .args_type  = "name:s?",
        .params     = "[tag|id]",
        .help       = "save a VM snapshot. If no tag or id are provided, a new snapshot is created",
        .cmd        = hmp_savevm,
    },

STEXI
@item savevm [@var{tag}|@var{id}]
@findex savevm
Create a snapshot of the whole virtual machine. If @var{tag} is
provided, it is used as human readable identifier. If there is already
a snapshot with the same tag or ID, it is replaced. More info at
@ref{vm_snapshots}.
ETEXI
"""

hmp_commands_addition = """
/* VMHOSTSNAPSHOT */
    {
        .name       = "vmhostsnapshot",
        .args_type  = "op:s,name:s",
        .params     = "save|load name",
        .help       = "save or load a VMHost snapshot",
        .cmd        = hmp_vmhostsnapshot,
    },

STEXI
@item vmhostsnapshot @var{save|load} @var{name}
@findex vmhostsnapshot
Save or load a VMHost snapshot with the given name.
ETEXI
"""

hmp_header_anchor = "void hmp_savevm(Monitor *mon, const QDict *qdict);\n"
hmp_header_addition = (
    "/* VMHOSTSNAPSHOT */\n"
    "void hmp_vmhostsnapshot(Monitor *mon, const QDict *qdict);\n"
)

savevm_anchor = """bool vmstate_check_only_migratable(const VMStateDescription *vmsd)
{
    /* check needed if --only-migratable is specified */
    if (!migrate_get_current()->only_migratable) {
        return true;
    }

    return !(vmsd && vmsd->unmigratable);
}
"""

savevm_addition = """
/* VMHOSTSNAPSHOT_V2
 *
 * savevm.c is C while android::snapshot::Snapshotter is C++. The C++ wrapper
 * in qemu_patches/vmhost_snapshot_glue.cpp owns the Snapshotter call and all
 * protobuf / aemu RAM callback setup happens behind that interface.
 */
extern int vmhost_snapshot_save(const char *name, char errbuf[512]);
extern int vmhost_snapshot_load(const char *name, char errbuf[512]);

void hmp_vmhostsnapshot(Monitor *mon, const QDict *qdict)
{
    const char *op = qdict_get_str(qdict, "op");
    const char *name = qdict_get_str(qdict, "name");
    char errbuf[512] = { 0 };
    int ret;

    if (strcmp(op, "save") == 0) {
        ret = vmhost_snapshot_save(name, errbuf);
    } else if (strcmp(op, "load") == 0) {
        ret = vmhost_snapshot_load(name, errbuf);
    } else {
        monitor_printf(mon, "vmhostsnapshot: operation must be save or load\\n");
        return;
    }

    if (ret != 0) {
        monitor_printf(mon, "vmhostsnapshot: %s '%s' failed: %s\\n",
                       op, name,
                       errbuf[0] ? errbuf : "unknown error");
    }
}
"""

changed = []
if insert_after_anchor(root / "hmp-commands.hx",
                       hmp_commands_anchor, hmp_commands_addition):
    changed.append("hmp-commands.hx")
if insert_after_anchor(root / "hmp.h",
                       hmp_header_anchor, hmp_header_addition):
    changed.append("hmp.h")

savevm_path = root / "migration/savevm.c"
savevm = read_source(savevm_path)
if savevm_marker not in savevm:
    old_marker = savevm.find(marker)
    if old_marker >= 0:
        # Upgrade the previous save_snapshot()/load_snapshot() version. The
        # marker block is appended at EOF, so truncate there and replace it.
        savevm = savevm[:old_marker].rstrip() + "\n\n" + savevm_addition.lstrip()
    else:
        if not savevm.endswith(savevm_anchor):
            raise SystemExit("vmhostsnapshot 补丁锚点未找到: %s" % savevm_path)
        savevm = savevm + savevm_addition
    savevm_path.write_text(savevm, encoding="utf-8")
    changed.append("migration/savevm.c")

print("    已修改: %s" % ", ".join(changed))
PY
}

# VMHost 快照：让 raw 盘"不参与快照"，而不是整体拒绝
#   上游 bdrv_all_can_snapshot()（block/snapshot.c:409）只要发现**任一**可写设备
#   不支持快照就返回 false → qemu_savevm() 一开头就退出，aemu 的 Saver 根本没被
#   创建（实测：save 只花 100ms、盘上什么都没有）。我们的 userdata/metadata
#   刻意保持 raw（它们是实例的持久状态，不该进快照），只给快照挂一块 qcow2
#   vmstate 盘，所以这里把"不支持快照"的设备改成跳过。
patch_snapshot_skip_raw() {
    local f="$SRC_DIR/block/snapshot.c"
    [ -f "$f" ] || { echo "找不到 $f" >&2; return 1; }
    if grep -q "VMHOST_SKIP_NON_SNAPSHOT_DEVICES" "$f"; then
        echo "==> bdrv_all_can_snapshot 补丁已存在，跳过"
        return 0
    fi
    echo "==> 打补丁（bdrv_all_can_snapshot 跳过不支持快照的盘）"
    python3 - "$f" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
old = """        aio_context_acquire(ctx);
        if (bdrv_is_inserted(bs) && !bdrv_is_read_only(bs)) {
            ok = bdrv_can_snapshot(bs);
        }
        aio_context_release(ctx);
        if (!ok) {
            bdrv_next_cleanup(&it);
            goto fail;
        }
"""
new = """        aio_context_acquire(ctx);
        if (bdrv_is_inserted(bs) && !bdrv_is_read_only(bs)) {
            /* VMHOST_SKIP_NON_SNAPSHOT_DEVICES
             *
             * 上游语义：只要有任一可写设备不支持快照就整体拒绝。
             * VMHost 的实例盘（system/vendor/userdata/metadata）刻意保持 raw ——
             * 它们是实例的持久状态，不该进快照；快照只存 RAM + 设备状态
             * （RAM 走 aemu 的 QEMUFileHooks 落到 ram.img，VM state 落在
             * vmstate.qcow2）。所以这里把不支持快照的设备跳过，
             * 交给 bdrv_all_find_vmstate_bs() 去找那块 qcow2。
             */
            if (!bdrv_can_snapshot(bs)) {
                aio_context_release(ctx);
                continue;
            }
        }
        aio_context_release(ctx);
"""
if old not in src:
    raise SystemExit("bdrv_all_can_snapshot 锚点未找到")
path.write_text(src.replace(old, new, 1), encoding="utf-8")
print("    已修改: block/snapshot.c")
PY
}

patch_snapshot_skip_raw

# 诊断插桩：savevm 收尾路径（RAM 迭代结束 → 设备状态落盘 → 内部快照 → on_end）
# 到底停在哪一步。实机踩到：ram.bin 写到 1.3GB 之后整次 save 卡死、HMP 180s 超时，
# 而 textures.bin / snapshot.pb 都没生成 —— 说明卡在 qemu_savevm() 的尾部，
# 不是 aemu 的 Saver 构造阶段。先量清楚再改。
patch_savevm_diag() {
    local sv="$SRC_DIR/migration/savevm.c"
    local rc="$SRC_DIR/migration/ram.c"
    [ -f "$sv" ] && [ -f "$rc" ] || { echo "找不到 savevm.c / ram.c" >&2; return 1; }
    if grep -q "VMHOSTSNAP_SAVEVM_DIAG" "$sv"; then
        echo "==> savevm 收尾诊断已存在，跳过"
        return 0
    fi
    echo "==> 打补丁（savevm 收尾诊断）"
    python3 - "$sv" "$rc" <<'PY'
import pathlib
import sys

sv = pathlib.Path(sys.argv[1])
rc = pathlib.Path(sys.argv[2])

s = sv.read_text(encoding="utf-8")
old = """    ret = qemu_savevm_state(f, &local_err);
    vm_state_size = qemu_ftell(f);
    qemu_fclose(f);
"""
new = """    /* VMHOSTSNAP_SAVEVM_DIAG */
    fprintf(stderr, "VMHOSTSNAP qemu_savevm_state enter\\n");
    ret = qemu_savevm_state(f, &local_err);
    fprintf(stderr, "VMHOSTSNAP qemu_savevm_state done ret=%d\\n", ret);
    vm_state_size = qemu_ftell(f);
    qemu_fclose(f);
    fprintf(stderr, "VMHOSTSNAP qemu_fclose done size=%llu\\n",
            (unsigned long long)vm_state_size);
"""
if old not in s:
    raise SystemExit("savevm.c qemu_savevm_state 锚点未找到")
s = s.replace(old, new, 1)

old2 = """    ret = bdrv_all_create_snapshot(sn, bs, vm_state_size, &bs);
"""
new2 = """    ret = bdrv_all_create_snapshot(sn, bs, vm_state_size, &bs);
    fprintf(stderr, "VMHOSTSNAP bdrv_all_create_snapshot ret=%d\\n", ret);
"""
if old2 not in s:
    raise SystemExit("savevm.c bdrv_all_create_snapshot 锚点未找到")
s = s.replace(old2, new2, 1)

old3 = """    if (s_snapshot_callbacks.savevm.on_end) {
        s_snapshot_callbacks.savevm.on_end(name, ret);
    }
"""
new3 = """    if (s_snapshot_callbacks.savevm.on_end) {
        fprintf(stderr, "VMHOSTSNAP on_end enter ret=%d\\n", ret);
        s_snapshot_callbacks.savevm.on_end(name, ret);
        fprintf(stderr, "VMHOSTSNAP on_end done\\n");
    }
"""
if old3 not in s:
    raise SystemExit("savevm.c on_end 锚点未找到")
s = s.replace(old3, new3, 1)
sv.write_text(s, encoding="utf-8")

r = rc.read_text(encoding="utf-8")
old4 = """    ram_control_after_iterate(f, RAM_CONTROL_FINISH);
"""
new4 = """    fprintf(stderr, "VMHOSTSNAP ram_save_complete: before FINISH\\n");
    ram_control_after_iterate(f, RAM_CONTROL_FINISH);
    fprintf(stderr, "VMHOSTSNAP ram_save_complete: after FINISH\\n");
"""
if old4 not in r:
    raise SystemExit("ram.c RAM_CONTROL_FINISH 锚点未找到")
r = r.replace(old4, new4, 1)
rc.write_text(r, encoding="utf-8")
print("    已修改: migration/savevm.c, migration/ram.c")
PY
}

patch_savevm_diag

# 第二层探针：savevm 收尾的**逐语句**进度。第一层已经确认卡点落在
# ram_save_complete() 里 FINISH 回调之后（ram_control_after_iterate 已返回、
# 再往后就没有输出了），剩下只有 rcu_read_unlock() 和写 EOS 两种可能；
# 同时给 qemu_savevm_state_cleanup()/ram_save_cleanup() 各加一对进出门，
# 万一卡点在更后面也能一次定位。
patch_savevm_tail_diag() {
    local sv="$SRC_DIR/migration/savevm.c"
    local rc="$SRC_DIR/migration/ram.c"
    [ -f "$sv" ] && [ -f "$rc" ] || { echo "找不到 savevm.c / ram.c" >&2; return 1; }
    # marker 落在 ram.c（rcu/EOS 那段），守卫必须查同一个文件，否则每次都会
    # 重打一遍、撞上已经替换掉的锚点 → set -e 直接终止整个构建。
    if grep -q "VMHOSTSNAP_TAIL_DIAG" "$rc"; then
        echo "==> savevm 收尾二级诊断已存在，跳过"
        return 0
    fi
    echo "==> 打补丁（savevm 收尾二级诊断）"
    python3 - "$sv" "$rc" <<'PY'
import pathlib
import sys

sv = pathlib.Path(sys.argv[1])
rc = pathlib.Path(sys.argv[2])

r = rc.read_text(encoding="utf-8")
old = """    rcu_read_unlock();

    qemu_put_be64(f, RAM_SAVE_FLAG_EOS);
"""
new = """    /* VMHOSTSNAP_TAIL_DIAG */
    fprintf(stderr, "VMHOSTSNAP ram_save_complete: rcu unlocking\\n");
    rcu_read_unlock();
    fprintf(stderr, "VMHOSTSNAP ram_save_complete: rcu unlocked, pos=%lld\\n",
            (long long)qemu_ftell(f));
    qemu_put_be64(f, RAM_SAVE_FLAG_EOS);
    fprintf(stderr, "VMHOSTSNAP ram_save_complete: EOS written\\n");
"""
if old not in r:
    raise SystemExit("ram.c rcu/EOS 锚点未找到")
r = r.replace(old, new, 1)

old2 = """static void ram_save_cleanup(void *opaque)
{
    RAMState **rsp = opaque;
    RAMBlock *block;
"""
new2 = """static void ram_save_cleanup(void *opaque)
{
    RAMState **rsp = opaque;
    RAMBlock *block;
    fprintf(stderr, "VMHOSTSNAP ram_save_cleanup enter\\n");
"""
if old2 not in r:
    raise SystemExit("ram.c ram_save_cleanup 锚点未找到")
r = r.replace(old2, new2, 1)

old3 = """    xbzrle_cleanup();
    compress_threads_save_cleanup();
    ram_state_cleanup(rsp);
}
"""
new3 = """    xbzrle_cleanup();
    fprintf(stderr, "VMHOSTSNAP compress_threads_save_cleanup enter\\n");
    compress_threads_save_cleanup();
    fprintf(stderr, "VMHOSTSNAP compress_threads_save_cleanup done\\n");
    ram_state_cleanup(rsp);
    fprintf(stderr, "VMHOSTSNAP ram_save_cleanup done\\n");
}
"""
if old3 not in r:
    raise SystemExit("ram.c ram_save_cleanup 尾部锚点未找到")
r = r.replace(old3, new3, 1)
rc.write_text(r, encoding="utf-8")

s = sv.read_text(encoding="utf-8")
old4 = """    ret = qemu_file_get_error(f);
    if (ret == 0) {
        qemu_savevm_state_complete_precopy(f, false, false);
        ret = qemu_file_get_error(f);
    }
    qemu_savevm_state_cleanup();
"""
new4 = """    ret = qemu_file_get_error(f);
    if (ret == 0) {
        fprintf(stderr, "VMHOSTSNAP complete_precopy enter\\n");
        qemu_savevm_state_complete_precopy(f, false, false);
        fprintf(stderr, "VMHOSTSNAP complete_precopy done\\n");
        ret = qemu_file_get_error(f);
    }
    fprintf(stderr, "VMHOSTSNAP savevm_state_cleanup enter\\n");
    qemu_savevm_state_cleanup();
    fprintf(stderr, "VMHOSTSNAP savevm_state_cleanup done\\n");
"""
if old4 not in s:
    raise SystemExit("savevm.c qemu_savevm_state 尾部锚点未找到")
s = s.replace(old4, new4, 1)
sv.write_text(s, encoding="utf-8")
print("    已修改: migration/savevm.c, migration/ram.c")
PY
}

patch_savevm_tail_diag

# 第三层探针：设备状态序列化。二级探针证明 RAM 收尾（rcu/EOS）已经走完，
# 卡点在之后写设备状态那段；而 RAM 之后第一个被写的设备就是 goldfish_pipe
# （`pos=373` 说明设备状态一个字节都还没落）。这里把每个设备的
# `vmstate_save()` 进出都打出来，顺带把 pipe glue 的
# pre_save / 每条 pipe 的 save / post_save 也打上，谁卡住一目了然。
patch_savevm_dev_diag() {
    local sv="$SRC_DIR/migration/savevm.c"
    [ -f "$sv" ] || { echo "找不到 $sv" >&2; return 1; }
    if grep -q "VMHOSTSNAP_DEV_DIAG" "$sv"; then
        echo "==> 设备状态诊断已存在，跳过"
        return 0
    fi
    echo "==> 打补丁（设备状态诊断）"
    python3 - "$sv" <<'PY'
import pathlib
import sys

sv = pathlib.Path(sys.argv[1])
s = sv.read_text(encoding="utf-8")

old = """static int vmstate_save(QEMUFile *f, SaveStateEntry *se, QJSON *vmdesc)
{
    trace_vmstate_save(se->idstr, se->vmsd ? se->vmsd->name : "(old)");
    if (!se->vmsd) {
        vmstate_save_old_style(f, se, vmdesc);
        return 0;
    }
    return vmstate_save_state(f, se->vmsd, se->opaque, vmdesc);
}
"""
new = """static int vmstate_save(QEMUFile *f, SaveStateEntry *se, QJSON *vmdesc)
{
    /* VMHOSTSNAP_DEV_DIAG */
    int vmhostRet;
    fprintf(stderr, "VMHOSTSNAP vmstate_save enter id=%s\\n", se->idstr);
    trace_vmstate_save(se->idstr, se->vmsd ? se->vmsd->name : "(old)");
    if (!se->vmsd) {
        vmstate_save_old_style(f, se, vmdesc);
        fprintf(stderr, "VMHOSTSNAP vmstate_save done id=%s\\n", se->idstr);
        return 0;
    }
    vmhostRet = vmstate_save_state(f, se->vmsd, se->opaque, vmdesc);
    fprintf(stderr, "VMHOSTSNAP vmstate_save done id=%s ret=%d\\n",
            se->idstr, vmhostRet);
    return vmhostRet;
}
"""
if old not in s:
    raise SystemExit("savevm.c vmstate_save 锚点未找到")
s = s.replace(old, new, 1)
sv.write_text(s, encoding="utf-8")
print("    已修改: migration/savevm.c")
PY
}

patch_savevm_dev_diag

# 恢复侧：RAMBlock 名单里查不到的块**跳过**而不是整次失败。
#   完全开机的 guest 里，gfxstream/gralloc 会创建一批**空名字**的
#   user-backed RAM block（`VMHOST_RAMBLOCK id= host=0x... used=3690496`）。
#   它们在保存时被写进 RAMBlock 名单，恢复时 `qemu_ram_block_by_name("")`
#   必然查不到，于是整次 load 直接
#     Unknown ramblock "", cannot accept migration
#     error while loading state for instance 0x0 of device 'ram'
#   这批块是宿主侧重建的临时区，本来就不该进快照；保存侧（vmhost_pipe_glue
#   之外，见 vmhost_vm_operations.cpp 的 ramOps.registerBlock 过滤）也不再把它们
#   交给 aemu，两边保持一致。
patch_ram_load_skip_unknown() {
    local f="$SRC_DIR/migration/ram.c"
    [ -f "$f" ] || { echo "找不到 $f" >&2; return 1; }
    if grep -q "VMHOST_SKIP_UNKNOWN_RAMBLOCK" "$f"; then
        echo "==> ram_load 跳过未知 RAMBlock 补丁已存在，跳过"
        return 0
    fi
    echo "==> 打补丁（ram_load 跳过未知 RAMBlock）"
    python3 - "$f" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
old = """                } else {
                    error_report("Unknown ramblock \\"%s\\", cannot "
                                 "accept migration", id);
                    ret = -EINVAL;
                }
"""
new = """                } else {
                    /* VMHOST_SKIP_UNKNOWN_RAMBLOCK
                     *
                     * 空名字的匿名 user-backed RAMBlock（gfxstream / gralloc 的
                     * 临时共享区）按名字永远查不到；它们是宿主侧重建的，
                     * 不该进快照，跳过即可。整次 load 因为一个临时区失败不值得。
                     */
                    fprintf(stderr,
                            "VMHOST_SKIP_UNKNOWN_RAMBLOCK id=\\"%s\\" len=%llu\\n",
                            id, (unsigned long long)length);
                }
"""
if old not in src:
    raise SystemExit("ram.c Unknown ramblock 锚点未找到")
path.write_text(src.replace(old, new, 1), encoding="utf-8")
print("    已修改: migration/ram.c")
PY
}

patch_ram_load_skip_unknown

# virtio-tablet 缺少 INPUT_PROP_DIRECT → Android 把它当鼠标（只画光标、拖动不滚动）。
# 补上 PROP_BITS=INPUT_PROP_DIRECT 后 InputReader 按"直连触摸屏"处理，
# BTN_TOUCH + ABS_X/Y 就是一根手指，tap/滑动都正常。
patch_virtio_tablet_direct() {
    local f="$SRC_DIR/hw/input/virtio-input-hid.c"
    [ -f "$f" ] || { echo "找不到 $f" >&2; return 1; }
    if grep -q "VMHOST_TABLET_DIRECT" "$f"; then
        echo "==> virtio-tablet DIRECT 补丁已存在，跳过"
        return 0
    fi
    echo "==> 打补丁（virtio-tablet 标记为直连触摸屏）"
    python3 - "$f" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
anchor = """    },{
        .select    = VIRTIO_INPUT_CFG_ABS_INFO,
        .subsel    = ABS_Y,
        .size      = sizeof(virtio_input_absinfo),
        .u.abs.min = const_le32(INPUT_EVENT_ABS_MIN),
        .u.abs.max = const_le32(INPUT_EVENT_ABS_MAX),
    },
"""
add = """    {
        /* VMHOST_TABLET_DIRECT：没有这一项时 Android 把 virtio-tablet 当鼠标，
           只画一个光标，滑动手势不会滚动列表。标成 DIRECT 后按触摸屏处理。 */
        .select    = VIRTIO_INPUT_CFG_PROP_BITS,
        .size      = 1,
        .u.bitmap  = {
            (1 << INPUT_PROP_DIRECT),
        },
    },
"""
count = src.count(anchor)
if count < 1:
    raise SystemExit("virtio-tablet ABS_Y 锚点未找到")
src = src.replace(anchor, anchor + add)
path.write_text(src, encoding="utf-8")
print("    已修改: hw/input/virtio-input-hid.c（%d 处）" % count)
PY
}

patch_virtio_tablet_direct

# p71 的显示走 ranchu goldfish_fb，而不是 virtio-gpu。AOSP QEMU 没有
# 编 ui_vmhost.c，所以 gfxstream 的 post callback 永远拿不到 goldfish_fb
# 的像素。这里增加一个轻量 DisplayChangeListener，把 goldfish_fb surface
# 转成 RGBA 后写进同一个 frame.shm；只在 VMHOST_GOLDFISH_FB=1 时启用。
patch_vmhost_goldfish_fb() {
    local impl="$TOOLS_DIR/qemu_patches/vmhost_goldfish_fb.c"
    local shm_hdr="$ENGINE_DIR/src/main/cpp/src/vm_frame_shm.h"
    local dst="$SRC_DIR/ui/vmhost_goldfish_fb.c"
    local console="$SRC_DIR/ui/console.c"
    local mk="$SRC_DIR/ui/Makefile.objs"

    [ -f "$impl" ] || { echo "找不到 $impl" >&2; return 1; }
    [ -f "$shm_hdr" ] || { echo "找不到 $shm_hdr" >&2; return 1; }
    cp -f "$impl" "$dst"
    cp -f "$shm_hdr" "$SRC_DIR/ui/vm_frame_shm.h"

    if ! grep -q "vmhost_goldfish_fb.o" "$mk"; then
        printf '\n# VMHOST_GOLDFISH_FB\ncommon-obj-y += vmhost_goldfish_fb.o\n' >> "$mk"
    fi

    python3 - "$console" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")

proto_marker = "/* VMHOST_GOLDFISH_FB_PROTO */"
call_marker = "/* VMHOST_GOLDFISH_FB_CALL */"
if call_marker in src:
    print("    ui/console.c goldfish_fb hook already present")
    raise SystemExit(0)

if proto_marker not in src:
    anchor = "QemuConsole *graphic_console_init(DeviceState *dev, uint32_t head,"
    if anchor not in src:
        raise SystemExit("ui/console.c graphic_console_init 锚点未找到")
    proto = (
        "extern void vmhost_goldfish_fb_attach(QemuConsole *con); "
        "/* VMHOST_GOLDFISH_FB_PROTO */\n\n"
    )
    src = src.replace(anchor, proto + anchor, 1)

anchor = "    dpy_gfx_replace_surface(s, surface);\n    return s;\n"
replacement = (
    "    dpy_gfx_replace_surface(s, surface);\n"
    "    /* VMHOST_GOLDFISH_FB_CALL */\n"
    "    vmhost_goldfish_fb_attach(s);\n"
    "    return s;\n"
)
if anchor not in src:
    raise SystemExit("ui/console.c graphic_console_init return 锚点未找到")
src = src.replace(anchor, replacement, 1)
path.write_text(src, encoding="utf-8")
print("    已修改: ui/console.c + ui/Makefile.objs（goldfish_fb 帧回传）")
PY
}

patch_vmhost_goldfish_fb

# min_config_qemu_mode() is true in our AVD shim, so vl.c normally forces
# goldfish_fb into host-GPU mode. In that mode goldfish_fb_write() returns
# before calling graphic_hw_update(), which is exactly why p71 stayed at
# frame.seq=0. Keep the guest-GPU framebuffer path for p71 only.
patch_goldfish_fb_software_fallback() {
    local f="$SRC_DIR/hw/display/goldfish_fb.c"
    [ -f "$f" ] || { echo "找不到 $f" >&2; return 1; }
    if grep -q "VMHOST_GOLDFISH_FB_SOFTWARE" "$f"; then
        echo "==> goldfish_fb software fallback 补丁已存在，跳过"
        return 0
    fi
    echo "==> 打补丁（goldfish_fb p71 software framebuffer）"
    python3 - "$f" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
old = """void goldfish_fb_set_use_host_gpu(int enabled) {
    s_use_host_gpu = enabled;
}
"""
new = """void goldfish_fb_set_use_host_gpu(int enabled) {
    /* VMHOST_GOLDFISH_FB_SOFTWARE: p71 has no virtio-gpu driver; force the
       CPU framebuffer update path so the DCL can publish frames. */
    if (getenv("VMHOST_GOLDFISH_FB") != NULL &&
        strcmp(getenv("VMHOST_GOLDFISH_FB"), "1") == 0) {
        enabled = 0;
    }
    s_use_host_gpu = enabled;
}
"""
if old not in src:
    raise SystemExit("goldfish_fb_set_use_host_gpu 锚点未找到")
path.write_text(src.replace(old, new, 1), encoding="utf-8")
print("    已修改: hw/display/goldfish_fb.c")
PY
}

patch_goldfish_fb_software_fallback

# goldfish-events 的 key handler 直接把 QKeyCode 枚举值塞进 evdev 队列，
# 但 Android 7.1 的 GoldfishEvDev 读的是 Linux input code。p71 没有
# virtio-input 驱动，按键必须走 goldfish-events；这里把 QKeyCode 显式
# 转成 Linux code（例如 Q_KEY_CODE_VOLUMEUP -> KEY_VOLUMEUP=115）。
# p11 不使用 goldfish-events 输入，因此该转换不会影响 p11。
patch_goldfish_events_keymap() {
    local f="$SRC_DIR/hw/input/goldfish_events.c"
    [ -f "$f" ] || { echo "找不到 $f" >&2; return 1; }
    if grep -q "VMHOST_GOLDFISH_KEY_TRANSLATE" "$f"; then
        echo "==> goldfish-events keycode 转换补丁已存在，跳过"
        return 0
    fi
    echo "==> 打补丁（goldfish-events QKeyCode -> Linux keycode）"
    python3 - "$f" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
old = """    int qcode = kv->u.qcode.data;

    goldfish_enqueue_event(s, EV_KEY, qcode, evt->u.key.data->down);
"""
new = """    int qcode = kv->u.qcode.data;

    /* VMHOST_GOLDFISH_KEY_TRANSLATE: Android p71 reads Linux evdev codes,
       while QMP gives us QKeyCode enum values. Translate before enqueueing. */
    int linux_code = qcode;
    if (qcode >= 0 && qcode < (int) qemu_input_map_qcode_to_linux_len) {
        int mapped = qemu_input_map_qcode_to_linux[qcode];
        if (mapped != 0) {
            linux_code = mapped;
        }
    }
    goldfish_enqueue_event(s, EV_KEY, linux_code, evt->u.key.data->down);
"""
if old not in src:
    raise SystemExit("goldfish_events.c key handler 锚点未找到")
path.write_text(src.replace(old, new, 1), encoding="utf-8")
print("    已修改: hw/input/goldfish_events.c")
PY
}

patch_goldfish_events_keymap

# p9/p71 的 first-stage init 只读设备树里的 fstab（ramdisk 里的 fstab.ranchu 不生效）。
# ranchu.c 只建了 /firmware/android，没有 fstab 子节点，于是 Android 9/7.1 会报
# "First stage mount skipped (missing/incompatible fstab in device tree)"，
# 接着 /system 挂不上、SELinux 策略读不到，直接 reboot。
# 这里补一个标准 DT fstab：p9 的 SDK 镜像是 GPT 单分区盘，
# system/vendor 实际是 vda1/vdb1（userdata 是整盘 ext4，vdc）。
# p71 不使用这个节点：它走 ramdisk 的 fstab.ranchu-noencrypt，
# 并在 make_guest_image.sh 里改成 vda=system、vdb=data。
patch_ranchu_dt_fstab() {
    local f="$SRC_DIR/hw/arm/ranchu.c"
    [ -f "$f" ] || { echo "找不到 $f" >&2; return 1; }
    if grep -q "VMHOST_DT_FSTAB_V6" "$f"; then
        echo "==> ranchu DT fstab 补丁已存在，跳过"
        return 0
    fi
    echo "==> 打补丁（ranchu 设备树 fstab）"
    python3 - "$f" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
marker = "VMHOST_DT_FSTAB_V6"
if marker in src:
    print("    ranchu DT fstab V5 already present")
    raise SystemExit(0)

block = '''    /* VMHOST_DT_FSTAB_V6: p9 needs the legacy GPT entries.  The GPT
       partition labels are "system"/"vendor", so first-stage init must use
       /dev/block/by-name/* and ranchu must advertise the virtio-mmio platform
       device names in boot_devices.  p9 is system-as-root: with VMHOST_SAR
       set, the kernel mounts vda1 at / and init must not mount it again. */
    {
        static const char boot_devices[] =
            "a000000.virtio_mmio,a000200.virtio_mmio,a000400.virtio_mmio,"
            "a000600.virtio_mmio,a000800.virtio_mmio,a000a00.virtio_mmio,"
            "a000c00.virtio_mmio,a000e00.virtio_mmio,a001000.virtio_mmio,"
            "a001200.virtio_mmio,a001400.virtio_mmio,a001600.virtio_mmio,"
            "a001800.virtio_mmio,a001a00.virtio_mmio,a001c00.virtio_mmio,"
            "a001e00.virtio_mmio,a002000.virtio_mmio,a002200.virtio_mmio,"
            "a002400.virtio_mmio,a002600.virtio_mmio,a002800.virtio_mmio,"
            "a002a00.virtio_mmio,a002c00.virtio_mmio,a002e00.virtio_mmio,"
            "a003000.virtio_mmio,a003200.virtio_mmio,a003400.virtio_mmio,"
            "a003600.virtio_mmio,a003800.virtio_mmio,a003a00.virtio_mmio,"
            "a003c00.virtio_mmio,a003e00.virtio_mmio";
        qemu_fdt_setprop_string(fdt, "/firmware/android", "boot_devices",
                                boot_devices);
    }

    if (g_strcmp0(getenv("VMHOST_DT_FSTAB"), "none") != 0) {
        qemu_fdt_add_subnode(fdt, "/firmware/android/fstab");
        qemu_fdt_setprop_string(fdt, "/firmware/android/fstab",
                                "compatible", "android,fstab");

        if (g_strcmp0(getenv("VMHOST_SAR"), "1") != 0) {
            qemu_fdt_add_subnode(fdt, "/firmware/android/fstab/system");
            qemu_fdt_setprop_string(fdt, "/firmware/android/fstab/system",
                                    "dev", "/dev/block/by-name/system");
            qemu_fdt_setprop_string(fdt, "/firmware/android/fstab/system",
                                    "type", "ext4");
            qemu_fdt_setprop_string(fdt, "/firmware/android/fstab/system",
                                    "mnt_flags", "ro");
            qemu_fdt_setprop_string(fdt, "/firmware/android/fstab/system",
                                    "fsmgr_flags", "wait");
        }

        qemu_fdt_add_subnode(fdt, "/firmware/android/fstab/vendor");
        qemu_fdt_setprop_string(fdt, "/firmware/android/fstab/vendor",
                                "dev", "/dev/block/by-name/vendor");
        qemu_fdt_setprop_string(fdt, "/firmware/android/fstab/vendor",
                                "type", "ext4");
        qemu_fdt_setprop_string(fdt, "/firmware/android/fstab/vendor",
                                "mnt_flags", "ro");
        qemu_fdt_setprop_string(fdt, "/firmware/android/fstab/vendor",
                                "fsmgr_flags", "wait");

        /* SAR 的 /data 由 vendor fstab 在第二段 init 挂载。若第一段先挂，
           mount_all 会再次尝试同一个 mount point，实测 EBUSY 并中断 fs 动作。 */
        if (g_strcmp0(getenv("VMHOST_SAR"), "1") != 0) {
            qemu_fdt_add_subnode(fdt, "/firmware/android/fstab/data");
            qemu_fdt_setprop_string(fdt, "/firmware/android/fstab/data",
                                    "dev", "/dev/block/vdc");
            qemu_fdt_setprop_string(fdt, "/firmware/android/fstab/data",
                                    "type", "ext4");
            qemu_fdt_setprop_string(fdt, "/firmware/android/fstab/data",
                                    "mnt_flags", "noatime,nosuid,nodev,barrier=1");
            qemu_fdt_setprop_string(fdt, "/firmware/android/fstab/data",
                                    "fsmgr_flags", "wait,check,formattable");
        }
    }
'''

legacy_marker = "/* VMHOST_DT_FSTAB"
tail_anchor = "    if (device_tree_setup_func) {"

legacy_marker_pos = src.find(legacy_marker)
if legacy_marker_pos >= 0:
    legacy_start = src.rfind("\n", 0, legacy_marker_pos) + 1
    legacy_end = src.find(tail_anchor, legacy_start)
    if legacy_end < 0:
        raise SystemExit("ranchu.c DT fstab 结束锚点未找到")
    src = src[:legacy_start] + block + "\n" + src[legacy_end:]
else:
    anchor = '    qemu_fdt_setprop_string(fdt, "/firmware/android", "hardware", "ranchu");\n'
    if anchor not in src:
        raise SystemExit("ranchu.c hardware 锚点未找到")
    src = src.replace(anchor, anchor + "\n" + block, 1)

path.write_text(src, encoding="utf-8")
print("    已修改: hw/arm/ranchu.c")
PY
}

patch_ranchu_dt_fstab

# 诊断插桩：goldfish_pipe 恢复时到底读到什么、哪一步映射失败
# （跨进程快照恢复时 pipe 的 signalled buffer / open command 要重新映射回宿主
#  地址空间，失败就 -EIO 终止整次恢复。先量清楚再改语义。）
patch_pipe_load_diag() {
    local f="$SRC_DIR/hw/misc/goldfish_pipe.c"
    [ -f "$f" ] || { echo "找不到 $f" >&2; return 1; }
    if grep -q "VMHOSTPIPE_LOAD_DIAG" "$f"; then
        echo "==> goldfish_pipe 恢复诊断已存在，跳过"
        return 0
    fi
    echo "==> 打补丁（goldfish_pipe 恢复诊断）"
    python3 - "$f" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")

anchor1 = """    dev->signalled_pipe_buffer_size = qemu_get_be32(file);
    dev->signalled_pipe_buffer_addr = qemu_get_be64(file);
"""
diag1 = anchor1 + """    /* VMHOSTPIPE_LOAD_DIAG */
    fprintf(stderr,
            "VMHOSTPIPE_LOAD dev_v=%u drv_v=%u sig_size=%u sig_addr=0x%llx\\n",
            dev->device_version, dev->driver_version,
            dev->signalled_pipe_buffer_size,
            (unsigned long long)dev->signalled_pipe_buffer_addr);
"""
if anchor1 not in src:
    raise SystemExit("pipe 诊断锚点 1 未找到")
src = src.replace(anchor1, diag1, 1)

anchor2 = """    if (!dev->signalled_pipe_buffer) {
        goto done;
    }
"""
diag2 = """    if (!dev->signalled_pipe_buffer) {
        /* VMHOSTPIPE_LOAD_DIAG */
        fprintf(stderr, "VMHOSTPIPE_LOAD signalled buffer map FAILED (addr=0x%llx size=%u)\\n",
                (unsigned long long)dev->signalled_pipe_buffer_addr,
                dev->signalled_pipe_buffer_size);
        goto done;
    }
"""
if anchor2 not in src:
    raise SystemExit("pipe 诊断锚点 2 未找到")
src = src.replace(anchor2, diag2, 1)

anchor3 = """    dev->open_command_addr = qemu_get_be64(file);
"""
diag3 = anchor3 + """    /* VMHOSTPIPE_LOAD_DIAG */
    fprintf(stderr, "VMHOSTPIPE_LOAD open_cmd_addr=0x%llx\\n",
            (unsigned long long)dev->open_command_addr);
"""
if anchor3 not in src:
    raise SystemExit("pipe 诊断锚点 3 未找到")
src = src.replace(anchor3, diag3, 1)

anchor4 = """    if (!dev->open_command) {
        goto done;
    }
"""
diag4 = """    if (!dev->open_command) {
        /* VMHOSTPIPE_LOAD_DIAG */
        fprintf(stderr, "VMHOSTPIPE_LOAD open_command map FAILED (addr=0x%llx)\\n",
                (unsigned long long)dev->open_command_addr);
        goto done;
    }
"""
if anchor4 not in src:
    raise SystemExit("pipe 诊断锚点 4 未找到")
src = src.replace(anchor4, diag4, 1)

path.write_text(src, encoding="utf-8")
print("    已修改: hw/misc/goldfish_pipe.c（诊断）")
PY
}

patch_pipe_load_diag

# 诊断插桩 2：宿主侧 pipe 重建（service_ops->guest_load）到底返回了什么
patch_pipe_load_diag2() {
    local f="$SRC_DIR/hw/misc/goldfish_pipe.c"
    [ -f "$f" ] || { echo "找不到 $f" >&2; return 1; }
    if grep -q "VMHOSTPIPE_LOAD_DIAG2" "$f"; then
        echo "==> goldfish_pipe 宿主 pipe 诊断已存在，跳过"
        return 0
    fi
    echo "==> 打补丁（goldfish_pipe 宿主 pipe 重建诊断）"
    python3 - "$f" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
old = """        char force_close = 0;
        char has_host_pipe = qemu_get_byte(file);
        if (has_host_pipe) {
            pipe->host_pipe = service_ops->guest_load(file, pipe, &force_close);
        } else {
            force_close = 1;
        }
"""
new = """        char force_close = 0;
        char has_host_pipe = qemu_get_byte(file);
        if (has_host_pipe) {
            pipe->host_pipe = service_ops->guest_load(file, pipe, &force_close);
            /* VMHOSTPIPE_LOAD_DIAG2 */
            fprintf(stderr,
                    "VMHOSTPIPE_LOAD2 pipe id=%u has_host=1 host_pipe=%p force_close=%d\\n",
                    pipe->id, pipe->host_pipe, (int)force_close);
        } else {
            force_close = 1;
            /* VMHOSTPIPE_LOAD_DIAG2 */
            fprintf(stderr, "VMHOSTPIPE_LOAD2 pipe id=%u has_host=0 (force close)\\n",
                    pipe->id);
        }
"""
if old not in src:
    raise SystemExit("宿主 pipe 诊断锚点未找到")
path.write_text(src.replace(old, new, 1), encoding="utf-8")
print("    已修改: hw/misc/goldfish_pipe.c（宿主 pipe 诊断）")
PY
}

patch_pipe_load_diag2
patch_vmhostsnapshot

# ---------------------------------------------------------------- 1c. feature-control 桩
# AOSP QEMU 的 QEMU 部分会引用 emulator 前端的特性开关
# （vl.c 里 include "host-common/feature_control.h"），
# 但那个头文件来自前端的另一个仓库，本仓没有。
# 绝大部分调用都在 #ifdef CONFIG_ANDROID 里，只有 vl.c:5605 一处露在外面，
# 所以给一个自包含的最小实现即可（inline，无需额外 .c 参与链接）。
STUB_DIR="$BUILD_DIR/vmhost-stub"
mkdir -p "$STUB_DIR/host-common"
cat > "$STUB_DIR/host-common/feature_control.h" <<'EOF'
/* VMHost 桩：替代 emulator 前端的 host-common/feature_control.h */
#ifndef VMHOST_FEATURE_CONTROL_H
#define VMHOST_FEATURE_CONTROL_H

typedef enum {
    kFeature_Invalid = 0,
    kFeature_GLDMA,
    kFeature_GLDirectMem,
    kFeature_GLESDynamicVersion,
    kFeature_SystemAsRoot,
    kFeature_DynamicPartition,
    kFeature_FastSnapshotV1,
    kFeature_MigratableSnapshotSave,
    kFeature_DownloadableSnapshot,
    kFeature_PlayStoreImage,
    kFeature_IpDisconnectOnLoad,
    kFeature_WiFiPacketStream,
    kFeature_VirtioInput,
    kFeature_VirtioMouse,
    kFeature_VirtioTablet,
    kFeature_KeycodeForwarding,
    kFeature_Mac80211hwsimUserspaceManaged,
    kFeature_Minigbm,
    kFeature_VideoPlayback,
    kFeature_VirtualScene,
    kFeature_Vulkan,
    kFeature_Wifi,
    kFeature_HVF,
    kFeature_Max
} Feature;

/* 我们不带 emulator 前端，所有可选项一律按关闭处理 */
static inline int feature_is_enabled(Feature feature) { (void) feature; return 0; }
static inline void feature_set_enabled_override(Feature feature, int enabled)
{
    (void) feature;
    (void) enabled;
}

#endif /* VMHOST_FEATURE_CONTROL_H */
EOF

# hw/misc/goldfish_pipe.c 需要的 host-common/goldfish_pipe.h 与
# host-common/android_pipe_base.h 现在**直接用 aemu 源码里的真头文件**
# （下面会把 $AEMU_DIR/host-common/include 加进 QEMU_CFLAGS）。
# 真头文件与 aemu 的 AndroidPipe 服务、以及 goldfish_pipe.c 的枚举取值
# 都是一致的（尤其是 GOLDFISH_PIPE_ERROR_*，早期桩里 IO/AGAIN 值写反了）。
# 这里清掉早期版本生成的同名桩文件，避免它们抢在真头文件前面被找到。
rm -f "$STUB_DIR/host-common/android_pipe_base.h" \
      "$STUB_DIR/host-common/goldfish_pipe.h"
echo "==> 清理旧的 android_pipe_base / goldfish_pipe 桩（改用 aemu 真头文件）"

# 1d. 最小 virglrenderer.h 桩（方案 B）。
# AOSP 原版在 external/virglrenderer，本工程拉不到；CONFIG_STREAM_RENDERER
# 模式下 virtio-gpu*.c 只用到少数 virgl 类型，用最小桩 + gfxstream 头即可。
VIRGL_STUB_DIR="$BUILD_DIR/vmhost-stub/virgl"
mkdir -p "$VIRGL_STUB_DIR"
cp -f "$TOOLS_DIR/qemu_patches/vmhost_virglrenderer.h" "$VIRGL_STUB_DIR/virglrenderer.h"
echo "==> 准备最小 virglrenderer.h 桩：$VIRGL_STUB_DIR/virglrenderer.h"

# ---------------------------------------------------------------- 2. configure
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ ! -f config-host.mak ]; then
    echo "==> configure"
    # 用 bash 执行：AOSP 这版 configure 里有 bash 专有语法，dash 会报
    # "test: no: unexpected operator"
    bash "$SRC_DIR/configure" \
        --python="$PY2" \
        --cross-prefix="$TOOLCHAIN/bin/llvm-" \
        --cc="$CC" \
        --cxx="$CXX" \
        --target-list="aarch64-softmmu" \
        --disable-werror \
        --disable-docs \
        --disable-tools \
        --disable-guest-agent \
        --disable-gtk \
        --disable-sdl \
        --disable-spice \
        --disable-vnc \
        --disable-curl \
        --disable-capstone \
        --disable-pie \
        --audio-drv-list= \
        --disable-slirp \
        --extra-cflags="-fPIC -fcommon -Wno-error -I$SYSROOT/include" \
        --extra-ldflags="-L$SYSROOT/lib" \
        2>&1 | tail -40
else
    echo "==> 已 configure 过，跳过"
fi

# 桩头文件也要进编译搜索路径，改 configure 产物即可，避免重跑 configure
if ! grep -q "vmhost-stub" "$BUILD_DIR/config-host.mak" 2>/dev/null; then
    sed -i "s|^QEMU_CFLAGS=|QEMU_CFLAGS=-I$STUB_DIR |" "$BUILD_DIR/config-host.mak"
    echo "==> patch: config-host.mak 增加 stub 头文件路径"
fi
if ! grep -q "vmhost-stub" "$BUILD_DIR/config-target.mak" 2>/dev/null; then
    sed -i "s|^QEMU_CFLAGS=|QEMU_CFLAGS=-I$STUB_DIR |" "$BUILD_DIR/config-target.mak" 2>/dev/null || true
    echo "==> patch: config-target.mak 增加 stub 头文件路径"
fi

# aemu 头文件路径：goldfish_pipe.c 现在 include aemu 的真 host-common/*.h。
# 追加到 QEMU_CFLAGS 末尾（不是开头），这样 $STUB_DIR 里的 feature_control.h
# 仍然优先于 aemu 的同名头（vl.c 依赖我们那份精简桩）。
AEMU_INCLUDES="-I$AEMU_DIR/host-common/include -I$AEMU_DIR/base/include -I$AEMU_DIR/third-party/cuda/include -I$AEMU_DIR/snapshot/include"
for _mk in config-host.mak config-target.mak; do
    if [ -f "$BUILD_DIR/$_mk" ] && ! grep -qF "$AEMU_DIR/host-common/include" "$BUILD_DIR/$_mk"; then
        sed -i "s|^QEMU_CFLAGS=\(.*\)$|QEMU_CFLAGS=\1 $AEMU_INCLUDES|" "$BUILD_DIR/$_mk"
        echo "==> patch: $_mk 增加 aemu 头文件路径"
    fi
done

# bionic 把 openpty/forkpty 放在 libc 里，没有独立的 libutil，
# 而 QEMU 的 configure 会无条件往 libs_softmmu 里加 -lutil，
# 链接期报 "unable to find library -lutil"。直接在 config-host.mak 里去掉。
if grep -q -- "-lutil" "$BUILD_DIR/config-host.mak" 2>/dev/null; then
    sed -i 's/-lutil//g' "$BUILD_DIR/config-host.mak"
    echo "==> patch: 从 config-host.mak 去掉 -lutil"
fi

# 方案 B：开 virtio-gpu 3D 编译。QEMU 2.12 的 per-object cflags
# （virtio-gpu{,-3d}.o-cflags := $(VIRGL_CFLAGS)）在我们这个改过的构建里
# 没有生效（$@-cflags 与 basename 变量对不上），直接全局加 QEMU_CFLAGS。
# CONFIG_VIRGL / CONFIG_STREAM_RENDERER 只在 virtio-gpu{,-3d}.c 与
# virtio-gpu.h 里被引用，全局定义安全；VIRGL_LIBS 置空（stream_renderer 不链
# virgl 库）。
if ! grep -q "CONFIG_STREAM_RENDERER" "$BUILD_DIR/config-host.mak" 2>/dev/null; then
    # 清掉旧方案的 VIRGL_CFLAGS 行（per-object 不生效的产物），避免残留
    sed -i '/^VIRGL_CFLAGS=/d; /^VIRGL_LIBS=/d' "$BUILD_DIR/config-host.mak"
    {
        echo "QEMU_CFLAGS += -DCONFIG_VIRGL -DCONFIG_STREAM_RENDERER -DCONFIG_VM_VIRTIO_GPU -I$VIRGL_STUB_DIR -I$GFX_DIR/host/include"
        echo "VIRGL_LIBS="
    } >> "$BUILD_DIR/config-host.mak"
    echo "==> patch: config-host.mak QEMU_CFLAGS += stream_renderer 模式"
else
    echo "==> 已存在 stream_renderer 标记，检查 QEMU_CFLAGS += 是否已加"
    if ! grep -q "QEMU_CFLAGS += .*CONFIG_STREAM_RENDERER" "$BUILD_DIR/config-host.mak" 2>/dev/null; then
        sed -i '/^VIRGL_CFLAGS=/d; /^VIRGL_LIBS=/d' "$BUILD_DIR/config-host.mak"
        {
            echo "QEMU_CFLAGS += -DCONFIG_VIRGL -DCONFIG_STREAM_RENDERER -DCONFIG_VM_VIRTIO_GPU -I$VIRGL_STUB_DIR -I$GFX_DIR/host/include"
            echo "VIRGL_LIBS="
        } >> "$BUILD_DIR/config-host.mak"
        echo "==> patch: 补加 QEMU_CFLAGS += stream_renderer 模式"
    fi
fi

# ---------------------------------------------------------------- 2b. 协程后端
# QEMU 自带的 sigaltstack / ucontext 后端都靠**跨栈** sigsetjmp/siglongjmp 切协程。
# bionic 的 longjmp 用 PAC 保护返回地址（paciasp/autiasp，以 SP 作 modifier），
# 跨栈时鉴权失败；在支持 FEAT_FPAC 的设备上内核把这次失败投递成 SIGILL。
# 真机实测：访客内核探测到 virtio-blk 后第一次读盘（挂载 system.img）时，
# 崩在 libc siglongjmp 的 autiasp 指令上。
# 换成本仓自带的纯 asm 后端（不使用 setjmp/longjmp，也不碰信号）即可绕开。
cp -f "$TOOLS_DIR/qemu_patches/coroutine-android.c" "$SRC_DIR/util/coroutine-android.c"
if grep -q '^CONFIG_COROUTINE_BACKEND=' "$BUILD_DIR/config-host.mak" 2>/dev/null; then
    sed -i 's/^CONFIG_COROUTINE_BACKEND=.*/CONFIG_COROUTINE_BACKEND=android/' \
        "$BUILD_DIR/config-host.mak"
else
    echo "CONFIG_COROUTINE_BACKEND=android" >> "$BUILD_DIR/config-host.mak"
fi
echo "==> patch: 协程后端 = android（纯 asm 切栈，绕开 bionic PAC longjmp）"

if [ "${CONFIGURE_ONLY:-0}" = "1" ]; then
    echo "==> 仅 configure，按要求退出"
    exit 0
fi

# ---------------------------------------------------------------- 2c. aemu pipe 服务接线
# 把 vmhost_pipe_glue.cpp（AndroidPipe 服务 + qemu2::VmLock）编成 .o，
# 再把这 4 个 aemu 静态库接到最终链接上。这一步取代了早期的 null 空桩：
# 启动时 vmhost_pipe_init() 会调 goldfish_pipe_set_service_ops() 注册真服务。
GLUE_SRC="$TOOLS_DIR/qemu_patches/vmhost_pipe_glue.cpp"
# aemu 的 host-common/VmLock.cpp 不在 BUILD_STANDALONE 源清单里（上游由
# emulator 前端提供），但它定义了 android::VmLock 的默认实现
# （get/set/析构/vtable），我们的 glue 要用，必须一起编。
AEMU_VMLOCK_SRC="$AEMU_DIR/host-common/VmLock.cpp"
GLUE_OBJ_DIR="$BUILD_DIR/vmhost"
GLUE_OBJ="$GLUE_OBJ_DIR/vmhost_pipe_glue.o"
VMLOCK_OBJ="$GLUE_OBJ_DIR/vmhost_aemu_vmlock.o"
mkdir -p "$GLUE_OBJ_DIR"

# 复用 configure 生成的那套 QEMU_CFLAGS：glue 要 include qemu/osdep.h、
# qemu/main-loop.h，依赖 sysroot 的 glib/pixman 与 config-host.h。
# 把里面 $(SRC_PATH)/$(BUILD_DIR) 字面量展开成真实路径。
QCFLAGS="$(grep -m1 '^QEMU_CFLAGS=' "$BUILD_DIR/config-host.mak" | sed 's/^QEMU_CFLAGS=//')"
QCFLAGS="${QCFLAGS//\$(SRC_PATH)/$SRC_DIR}"
QCFLAGS="${QCFLAGS//\$(BUILD_DIR)/$BUILD_DIR}"

GLUE_CXXFLAGS="-std=c++17 -fPIC -fcommon -Wno-error $QCFLAGS \
-I$SRC_DIR -I$SRC_DIR/include -I$BUILD_DIR \
-I$SRC_DIR/android-qemu2-glue \
-I$PROTO_GEN_DIR -I$PROTOBUF_INCLUDE_DIR -I$ABSEIL_DIR \
-I$AEMU_DIR/host-common/include -I$AEMU_DIR/base/include \
-I$AEMU_DIR/third-party/cuda/include -I$AEMU_DIR/snapshot/include"

echo "==> 编译 pipe 接线 glue"
rm -f "$GLUE_OBJ" "$VMLOCK_OBJ"
if ! $CXX -c "$GLUE_SRC" -o "$GLUE_OBJ" $GLUE_CXXFLAGS \
        >"$GLUE_OBJ_DIR/glue.log" 2>&1; then
    echo "!! pipe glue 编译失败：" >&2
    tail -40 "$GLUE_OBJ_DIR/glue.log" >&2
    exit 1
fi
if ! $CXX -c "$AEMU_VMLOCK_SRC" -o "$VMLOCK_OBJ" $GLUE_CXXFLAGS \
        -I"$AEMU_DIR/host-common/include/host-common" \
        >"$GLUE_OBJ_DIR/vmlock.log" 2>&1; then
    echo "!! aemu VmLock 编译失败：" >&2
    tail -40 "$GLUE_OBJ_DIR/vmlock.log" >&2
    exit 1
fi

# QemuFileStream：QEMUFile → android::base::Stream 的桥，pipe 状态序列化要用
# （官方 android-qemu2-glue/emulation/android_pipe_device.cpp 就是靠它把宿主 pipe
#  的状态存进快照 / 从快照恢复）。
QEMU_FILE_STREAM_SRC="$SRC_DIR/android-qemu2-glue/base/files/QemuFileStream.cpp"
QEMU_FILE_STREAM_OBJ="$GLUE_OBJ_DIR/vmhost_qemu_file_stream.o"
rm -f "$QEMU_FILE_STREAM_OBJ"
if ! $CXX -c "$QEMU_FILE_STREAM_SRC" -o "$QEMU_FILE_STREAM_OBJ" $GLUE_CXXFLAGS \
        -I"$PROTO_GEN_DIR" -I"$PROTOBUF_INCLUDE_DIR" \
        >"$GLUE_OBJ_DIR/qemu_file_stream.log" 2>&1; then
    echo "!! QemuFileStream 编译失败：" >&2
    tail -40 "$GLUE_OBJ_DIR/qemu_file_stream.log" >&2
    exit 1
fi
echo "==> glue ok: $(ls -lh "$GLUE_OBJ" "$VMLOCK_OBJ" | awk '{print $5, $9}' | tr '\n' ' ')"

# aemu 快照 C ABI 包装层。只 include aemu 侧头文件，不拉 QEMU 的 glib。
SNAPSHOT_GLUE_SRC="$TOOLS_DIR/qemu_patches/vmhost_snapshot_glue.cpp"
SNAPSHOT_GLUE_OBJ="$GLUE_OBJ_DIR/vmhost_snapshot_glue.o"

# emu-34 树里有两份"由 ini 生成、但没跟着树走"的头：
#   - android/avd/hw-config-defs.h（AndroidHwConfig 的字段表）
#   - android/hw-lcd.h（LCD 密度表）
# 它们在 aemu 仓库里有配套副本（host-common/*），这里造两个一行映射把它们指过去，
# 供后面的 C / C++ 补件共用（不改上游源码）。
mkdir -p "$BUILD_DIR/vmhost-stub/android/avd"
cat > "$BUILD_DIR/vmhost-stub/android/avd/hw-config-defs.h" <<'EOF'
/* VMHost: emu-34 树缺这份生成头，指向 aemu 里与 host-common/hw-config.h 配套的那份。 */
#include "host-common/hw-config-defs.h"
EOF
cat > "$BUILD_DIR/vmhost-stub/android/hw-lcd.h" <<'EOF'
/* VMHost: emu-34 树缺 android/hw-lcd.h，指向 aemu 的 host-common/hw-lcd.h。 */
#include "host-common/hw-lcd.h"
EOF

SNAPSHOT_CXXFLAGS="-std=c++17 -fPIC -fcommon -Wno-error \
-I$BUILD_DIR/vmhost-stub \
-I$AEMU_DIR/base/include \
-I$AEMU_DIR/host-common/include \
-I$AEMU_DIR/snapshot/include \
-I$SRC_DIR/android/emu/base/include \
-I$SRC_DIR/android/emu/avd/include \
-I$SRC_DIR/android/android-emugl/shared \
-I$SRC_DIR/android/emu/feature/src \
-I$SRC_DIR/android/emu/protobuf/src \
-I$SRC_DIR/android/emu/metrics/src \
-I$SRC_DIR/android/emu/crashreport/src \
-I$SRC_DIR/android/emu/tracing \
-I$SRC_DIR/android/emu/studio-config/src \
-I$SRC_DIR/android/emu/avd/src \
-I$SRC_DIR/android/emu/adb/interface/src \
-I$SRC_DIR/android/emu/agents/include \
-I$SRC_DIR/android/emu/cmdline/include \
-I$SRC_DIR/android/emu/crashreport/include \
-I$SRC_DIR/android/emu/files/include \
-I$SRC_DIR/android/emu/feature/include \
-I$SRC_DIR/android/emu/metrics/include \
-I$SRC_DIR/android/emu/protobuf/include \
-I$SRC_DIR/android/emu/studio-config/include \
-I$SRC_DIR/android/emu/utils/include \
-I$SRC_DIR/android/emu/protos \
-I$SRC_DIR/android/android-emu \
-I$SRC_DIR/android/android-emu-base \
-I$BUILD_DIR \
-I$ABSEIL_DIR \
-I$PROTO_GEN_DIR \
-I$GFX_DIR/include \
-I$PROTOBUF_INCLUDE_DIR"

echo "==> 编译 snapshot C ABI glue"
rm -f "$SNAPSHOT_GLUE_OBJ"
if ! $CXX -c "$SNAPSHOT_GLUE_SRC" -o "$SNAPSHOT_GLUE_OBJ" \
        $SNAPSHOT_CXXFLAGS >"$GLUE_OBJ_DIR/snapshot_glue.log" 2>&1; then
    echo "!! snapshot glue 编译失败：" >&2
    tail -60 "$GLUE_OBJ_DIR/snapshot_glue.log" >&2
    exit 1
fi
echo "==> snapshot glue ok: $(ls -lh "$SNAPSHOT_GLUE_OBJ" | awk '{print $5}')"

# Snapshotter 的 QEMU 侧"操作表"（官方由 qemu-vm-operations-impl.cpp 提供，
# 我们没编那个文件——它拖 gRPC/前端）。没有它 Snapshotter::save() 会直接
# 调空函数指针崩掉。见 qemu_patches/vmhost_vm_operations.cpp 头部说明。
#
# 这个 TU 现在还要引 QEMU 的**真头文件**（QEMUFileHooks / RAM_CONTROL_* /
# qemu_ram_* / smp_* …，见该文件头部），所以单独给它 QEMU 的 include 根和
# sysroot 里 glib 的 cflags。**只加给这一个 TU**：-I$SRC_DIR 会改变同名头的
# 解析顺序，别的 TU 不掺和。
SNAPSHOT_VMOPS_SRC="$TOOLS_DIR/qemu_patches/vmhost_vm_operations.cpp"
SNAPSHOT_VMOPS_OBJ="$GLUE_OBJ_DIR/vmhost_vm_operations.o"
SNAPSHOT_VMOPS_GLIB_CFLAGS="$(pkg-config --cflags glib-2.0)"
[ -n "$SNAPSHOT_VMOPS_GLIB_CFLAGS" ] || {
    echo "!! 取不到 glib 的 cflags（PKG_CONFIG_PATH=$PKG_CONFIG_PATH）" >&2; exit 1; }
SNAPSHOT_VMOPS_CXXFLAGS="$SNAPSHOT_CXXFLAGS \
-I$SRC_DIR -I$SRC_DIR/include $SNAPSHOT_VMOPS_GLIB_CFLAGS"
echo "==> 编译 snapshot VM operations glue"
rm -f "$SNAPSHOT_VMOPS_OBJ"
if ! $CXX -c "$SNAPSHOT_VMOPS_SRC" -o "$SNAPSHOT_VMOPS_OBJ" \
        $SNAPSHOT_VMOPS_CXXFLAGS >"$GLUE_OBJ_DIR/snapshot_vmops.log" 2>&1; then
    echo "!! snapshot VM operations glue 编译失败：" >&2
    tail -60 "$GLUE_OBJ_DIR/snapshot_vmops.log" >&2
    exit 1
fi
echo "==> snapshot vmops ok"

# 以前这里逐个补编 emu-base 的支撑 TU（ContiguousRangeMapper / LazyInstance /
# path_system / Log* / avd-info …）。那条路是错的：它们是 vendored base 的一部分，
# 手补会与另一份 base 重复定义、且永远补不完。现在整份 vendored base 由
# build_android_emu_base.sh 统一编成 libandroid-emu-base{,-memory,-logging}.a，
# 在下面的链接行里整包接入（见 aemu快照移植指南.md §8）。

# 外部 aemu 里有两个 TU **不在** 我们 BUILD_STANDALONE 的产物里（build_aemu.sh
# 是最小子集），但 vendored base / gfxstream 会引用它们的符号：
#   - base/Metrics.cpp                    → android::base::MetricsLogger::set_crash_annotation_callback
#   - host-common/GfxstreamFatalError.cpp → emugl::setDieFunction
# 只补编这两个文件，不整包重编 aemu。
EXTRA_AEMU_SUPPORT_SRCS=(
    "$AEMU_DIR/base/Metrics.cpp"
    "$AEMU_DIR/host-common/GfxstreamFatalError.cpp"
    # 下面这些是"模拟器前端"里真正参与快照语义的部分（官方 android-emu 目标的子集）：
    #   - snapshot/interface.cpp          → androidSnapshot_save/load/invalidate…（快照 C API 本体）
    #   - emugl shared_library.cpp        → android::base::SharedLibrary（动态库加载，gfxstream 会调）
    #   - featurecontrol/FeatureControl   → android::featurecontrol::isEnabled（feature flag 语义相关，不能用 stub）
    #   - protobuf/LoadSave.cpp           → android::protobuf::load/saveProtobufFileImpl（快照依赖文件用）
    "$SRC_DIR/android/android-emu/android/snapshot/interface.cpp"
    "$SRC_DIR/android/android-emugl/shared/emugl/common/shared_library.cpp"
    "$SRC_DIR/android/emu/feature/src/android/featurecontrol/FeatureControl.cpp"
    # 与 FeatureControl.cpp 配套的实现/override（模拟器树的真实现）。
    # 外部 aemu 的 host-common 里还带着**旧的** feature_control.cpp.o 和
    # FeatureControlOverride.cpp.o，两者都定义 setFeatureEnabledCallback，
    # 会与这里重复定义 —— 链接时用下面的"摘掉旧成员"的副本解决。
    "$SRC_DIR/android/emu/feature/src/android/featurecontrol/FeatureControlImpl.cpp"
    "$SRC_DIR/android/emu/feature/src/android/featurecontrol/FeatureControlOverride.cpp"
    "$SRC_DIR/android/emu/protobuf/src/android/protobuf/LoadSave.cpp"
)
EXTRA_AEMU_SUPPORT_OBJS=""
for _src in "${EXTRA_AEMU_SUPPORT_SRCS[@]}"; do
    _name="$(basename "$_src")"
    _name="${_name%.cpp}"
    _obj="$GLUE_OBJ_DIR/vmhost_aemu_support_${_name}.o"
    _log="$GLUE_OBJ_DIR/vmhost_aemu_support_${_name}.log"
    echo "==> 编译 aemu 补件: $_name"
    rm -f "$_obj"
    if ! $CXX -c "$_src" -o "$_obj" $SNAPSHOT_CXXFLAGS >"$_log" 2>&1; then
        echo "!! aemu 补件编译失败：$_src" >&2
        tail -40 "$_log" >&2
        exit 1
    fi
    EXTRA_AEMU_SUPPORT_OBJS="$EXTRA_AEMU_SUPPORT_OBJS $_obj"
done

# ---------------------------------------------------------------- 2c-2. 剩余符号
# 按 aemu快照移植指南.md §8.3 的簇处理剩下这批：能用真实现的就用真的。
# 这里全部是模拟器树里、真正参与快照语义的 TU（不是替身）：
#   - android-emugl/combined/impl/base/{System,SharedLibrary,HealthMonitor}.cpp
#       android::base::* 时间/环境/sleep/cpu 那批、android::base::SharedLibrary、
#       emugl::CreateHealthMonitor / HealthMonitor<>
#   - android-emugl/shared/emugl/common/logging.cpp       emugl_logger
#   （注意：**不要**编 emu/feature/.../feature_control.cpp —— 它 include 的是外部
#    aemu 的旧 feature 表，与模拟器树 Features.h 的枚举对不上；真实现用上面的
#    FeatureControl.cpp / FeatureControlImpl.cpp / FeatureControlOverride.cpp）
#   - emu/files/src/android/emulation/ConfigDirs.cpp      android::ConfigDirs::*
#   - emu/files/src/android/utils/ini.cpp                 C 版 iniFile_*（ConfigDirs/util 用）
#   - emu/cmdline/.../bufprint_config_dirs.cpp            bufprint_avd_home_path 等
# combined/impl/base 下那几个 TU 的 include 根要按它自己的布局给
# （HealthMonitor.cpp include "testing/TestClock.h"，相对 combined/impl/base）。
SNAPSHOT_CXXFLAGS="$SNAPSHOT_CXXFLAGS -I$SRC_DIR/android/android-emugl/combined/impl/base"
EXTRA_REAL_IMPL_SRCS=(
    "$SRC_DIR/android/android-emugl/combined/impl/base/System.cpp"
    "$SRC_DIR/android/android-emugl/combined/impl/base/SharedLibrary.cpp"
    "$SRC_DIR/android/android-emugl/combined/impl/base/HealthMonitor.cpp"
    "$SRC_DIR/android/android-emugl/shared/emugl/common/logging.cpp"
    "$SRC_DIR/android/emu/files/src/android/emulation/ConfigDirs.cpp"
    "$SRC_DIR/android/emu/files/src/android/utils/ini.cpp"
    "$SRC_DIR/android/emu/cmdline/src/android/emulation/bufprint_config_dirs.cpp"
    "$SRC_DIR/android/emu/avd/src/android/avd/util_wrapper.cpp"
)
for _src in "${EXTRA_REAL_IMPL_SRCS[@]}"; do
    _name="$(basename "$_src")"
    _name="${_name%.cpp}"
    _obj="$GLUE_OBJ_DIR/vmhost_aemu_support_${_name}.o"
    _log="$GLUE_OBJ_DIR/vmhost_aemu_support_${_name}.log"
    echo "==> 编译 aemu 补件（真实现）: $_name"
    rm -f "$_obj"
    if ! $CXX -c "$_src" -o "$_obj" $SNAPSHOT_CXXFLAGS >"$_log" 2>&1; then
        echo "!! aemu 补件编译失败：$_src" >&2
        tail -40 "$_log" >&2
        exit 1
    fi
    EXTRA_AEMU_SUPPORT_OBJS="$EXTRA_AEMU_SUPPORT_OBJS $_obj"
done

# avd/util.c、avd/hw-config.c、utils/property_file.c 是 C 源码，必须用 $CC 编，
# 否则 clang++ 会把它们当 C++ 而卡在 C 才有的写法上。info.c 刻意不编（它会定义
# avdInfo_getContentPath，和 qemu_patches/vmhost_avd_shim.cpp 冲突）。
#
# hw-config.c include 的 "android/avd/hw-config-defs.h"（由 hardware-properties.ini
# 生成）在这份 emu-34 树里已经不存在，只剩 aemu 里那份规范副本；而 hw-config.c
# 用的 AndroidHwConfig 结构体正是由 aemu 的 host-common/hw-config.h 按同一份 defs
# 展开的，所以这里把该名字指回那份规范副本（不改上游源码）。
mkdir -p "$BUILD_DIR/vmhost-stub/android/avd"
cat > "$BUILD_DIR/vmhost-stub/android/avd/hw-config-defs.h" <<'EOF'
/* VMHost: 见 build_qemu_aosp.sh —— emu-34 树里缺这份生成头，
 * 指向 aemu 里与 host-common/hw-config.h 配套的那份。 */
#include "host-common/hw-config-defs.h"
EOF
EXTRA_SUPPORT_C_SRCS=(
    "$SRC_DIR/android/emu/avd/src/android/avd/util.c"
    "$SRC_DIR/android/emu/avd/src/android/avd/hw-config.c"
    "$SRC_DIR/android/emu/avd/src/android/hw-lcd.c"
    "$SRC_DIR/android/emu/files/src/android/utils/property_file.c"
    "$SRC_DIR/android/emu/files/src/android/utils/file_data.c"
)
SNAPSHOT_CFLAGS="${SNAPSHOT_CXXFLAGS/-std=c++17/-std=gnu11} -I$BUILD_DIR/vmhost-stub"
EXTRA_SUPPORT_C_OBJS=""
for _src in "${EXTRA_SUPPORT_C_SRCS[@]}"; do
    _name="$(basename "$_src")"
    _name="${_name%.c}"
    _obj="$GLUE_OBJ_DIR/vmhost_aemu_c_${_name}.o"
    _log="$GLUE_OBJ_DIR/vmhost_aemu_c_${_name}.log"
    echo "==> 编译 aemu 补件（C）: $_name"
    rm -f "$_obj"
    if ! $CC -c "$_src" -o "$_obj" $SNAPSHOT_CFLAGS >"$_log" 2>&1; then
        echo "!! aemu 补件（C）编译失败：$_src" >&2
        tail -40 "$_log" >&2
        exit 1
    fi
    EXTRA_SUPPORT_C_OBJS="$EXTRA_SUPPORT_C_OBJS $_obj"
done

# 遥测/崩溃上报/显示 UI 那批走 no-op 替身（vmhost_frontend_stubs.cpp），AVD 那批
# 走 vmhost_avd_shim.cpp（我们不是 AVD，contentPath 读 VMHOST_SNAP_DIR）。
# 这两个文件在 qemu_patches/ 下，不碰 vm/engine/src。它们的 include 需要
# perfetto 头（Tracing.cpp）与 crashpad/mini_chromium 头（base/logging.h）。
EXTRA_FRONTEND_SRCS=(
    "$SRC_DIR/android/emu/tracing/android/base/Tracing.cpp"
    "$SRC_DIR/android/third_party/perfetto-tracing-only-stub/stub.cpp"
    "$TOOLS_DIR/qemu_patches/vmhost_avd_shim.cpp"
    "$TOOLS_DIR/qemu_patches/vmhost_frontend_stubs.cpp"
)
FRONTEND_CXXFLAGS="$SNAPSHOT_CXXFLAGS \
-I$SRC_DIR/android/third_party/perfetto-tracing-only \
-I$SRC_DIR/android/third_party/crashpad \
-I$SRC_DIR/android/third_party/crashpad/third_party/mini_chromium/mini_chromium"
EXTRA_FRONTEND_OBJS=""
for _src in "${EXTRA_FRONTEND_SRCS[@]}"; do
    _name="$(basename "$_src")"
    _name="${_name%.cpp}"
    _obj="$GLUE_OBJ_DIR/vmhost_frontend_${_name}.o"
    _log="$GLUE_OBJ_DIR/vmhost_frontend_${_name}.log"
    echo "==> 编译前端补件: $_name"
    rm -f "$_obj"
    if ! $CXX -c "$_src" -o "$_obj" $FRONTEND_CXXFLAGS >"$_log" 2>&1; then
        echo "!! 前端补件编译失败：$_src" >&2
        tail -60 "$_log" >&2
        exit 1
    fi
    EXTRA_FRONTEND_OBJS="$EXTRA_FRONTEND_OBJS $_obj"
done

# 链接：glue .o + aemu/snapshot/abseil/lz4/protobuf 追加进 LIBS。
# abseil 是多库，且子库之间有反向依赖，统一放进 --start-group 让链接器按需
# 反复扫描即可。这里不用 --whole-archive：它会把未引用的 TU 全拉进来，增大
# 体积并更容易触发重复定义。
# -static-libstdc++：NDK clang++ 默认链 libc++_shared.so，静态链才能单文件跑。
# 先删掉本脚本上次追加的行（config-host.mak 是 configure 产物，不会被重置），
# 再重新追加，保证重复运行时不重复累加。
sed -i \
    -e '/vmhost_pipe_glue\.o/d' \
    -e '/vmhost_qemu_file_stream\.o/d' \
    -e '/vmhost_snapshot_glue\.o/d' \
    -e '/vmhost_vm_operations\.o/d' \
    -e '/vmhost_snapshot_support_.*\.o/d' \
    -e '/vmhost_aemu_support_.*\.o/d' \
    -e '/vmhost_aemu_c_.*\.o/d' \
    -e '/vmhost_frontend_.*\.o/d' \
    -e '/vmhost_gfx_glue\.o/d' \
    -e '/vmhost_gfxstream_renderer\.o/d' \
    -e '/vmhost_gfxstream_render_api\.o/d' \
    -e '/libaemu-host-common\.a/d' \
    -e '/libaemu-host-common-nofc\.a/d' \
    -e '/libaemu-snapshot\.a/d' \
    -e '/libaemu-base\.a/d' \
    -e '/liblogging-base\.a/d' \
    -e '/libandroid-emu-base.*\.a/d' \
    -e '/libabsl_.*\.a/d' \
    -e '/liblz4\.a/d' \
    -e '/libprotobuf\.a/d' \
    -e '/libgfxstream_backend_static\.a/d' \
    -e '/libgfxstream-gl-host-common\.a/d' \
    -e '/^LIBS+=-llog$/d' \
    -e '/^LIBS+=-landroid -llog$/d' \
    -e '/^LDFLAGS+=-static-libstdc++$/d' \
    "$BUILD_DIR/config-host.mak"
ABSEIL_LIBS="$(find "$ABSEIL_BUILD_DIR" -name '*.a' | sort | tr '\n' ' ')"
[ -n "$ABSEIL_LIBS" ] || {
    echo "!! abseil 构建目录里没有静态库：$ABSEIL_BUILD_DIR" >&2; exit 1; }

# 外部 aemu 的 host-common 里带着两份**旧版** feature-control 实现
# （feature_control.cpp.o / FeatureControlOverride.cpp.o），它们和模拟器树的
# 真实现（FeatureControl.cpp / FeatureControlOverride.cpp）都定义
# setFeatureEnabledCallback → 重复定义。这里拷一份归档、摘掉这两个旧成员再链接，
# 不去改动 build_aemu.sh 的产物本身。
AEMU_HC_LINK="$GLUE_OBJ_DIR/libaemu-host-common-nofc.a"
cp -f "$AEMU_LIB_DIR/host-common/libaemu-host-common.a" "$AEMU_HC_LINK"
"$TOOLCHAIN/bin/llvm-ar" d "$AEMU_HC_LINK" \
    feature_control.cpp.o FeatureControlOverride.cpp.o >/dev/null 2>&1 || true
echo "==> host-common 链接副本（已摘掉旧 feature-control 成员）：$AEMU_HC_LINK"
{
    echo "LIBS+=$GLUE_OBJ $VMLOCK_OBJ $QEMU_FILE_STREAM_OBJ $SNAPSHOT_GLUE_OBJ $SNAPSHOT_VMOPS_OBJ"
    echo "LIBS+=$EXTRA_AEMU_SUPPORT_OBJS"
    echo "LIBS+=$EXTRA_SUPPORT_C_OBJS"
    echo "LIBS+=$EXTRA_FRONTEND_OBJS"
    # base 用 **vendored** 那份：host-common 需要的 28 个 android::base::* 符号
    # （MemStream/SubAllocator/MessageChannel/Stream…）与快照链要的 System/PathUtils/
    # StdioStream/memoryHint/MurmurHash 都由它提供，已用 llvm-nm 逐个核对。
    echo "LIBS+=-Wl,--start-group $AEMU_HC_LINK $AEMU_LIB_DIR/snapshot/libgfxstream-snapshot.a $SNAPSHOT_LIB $ANDROID_EMU_BASE_LIB_DIR/libandroid-emu-base.a $ANDROID_EMU_BASE_LIB_DIR/libandroid-emu-base-memory.a $ANDROID_EMU_BASE_LIB_DIR/libandroid-emu-base-logging.a $ABSEIL_LIBS $LZ4_LIB $PROTOBUF_LIB -Wl,--end-group"
    echo "LDFLAGS+=-static-libstdc++"
} >> "$BUILD_DIR/config-host.mak"
echo "==> patch: config-host.mak 追加 snapshot glue + aemu/abseil/lz4/protobuf + -static-libstdc++"

# ------------------------------------------------- 2d. gfxstream 宿主渲染器接线
# gfxstream 把功能拆成一堆静态库（gfxstream_backend_static / gl-host-common /
# gl-server / gles1_dec / gles2_dec / OpenGLESDispatch / renderControl_dec /
# vulkan-server / magma-server / snapshot / apigen ...），CMake 里的 PUBLIC 依赖
# 只是"链接关系"，静态库不会互相合并，所以最终链接时要把它们**全部**塞进
# 同一个 --start-group 里。直接 find 收集最稳，避免漏项。
GFX_GLUE_SRC="$TOOLS_DIR/qemu_patches/vmhost_gfx_glue.cpp"
GFX_GLUE_OBJ="$GLUE_OBJ_DIR/vmhost_gfx_glue.o"

# include 顺序要跟 gfxstream 自己的构建一致：gfxstream 的 include 在前、
# aemu 的在后（gfxstream 只在自己没有时才用 aemu 的同名头）。
# shim 目录提供 <cutils/native_handle.h>（AOSP 头，NDK 没有）。
GFX_CXXFLAGS="-std=c++17 -fPIC -fcommon -Wno-error \
-I$GFX_DIR/host -I$GFX_DIR/host/include -I$GFX_DIR/include \
-I$GFX_DIR/host/gl/gl-host-common/include \
-I$GFX_DIR/gl-host-common/include \
-I$GFX_DIR/common/opengl/include \
-I$GFX_BUILD_DIR/vmhost-shim \
-I$ENGINE_DIR/src/main/cpp/src \
-I$AEMU_DIR/host-common/include -I$AEMU_DIR/base/include \
-I$AEMU_DIR/third-party/cuda/include -I$AEMU_DIR/snapshot/include"

echo "==> 编译 gfxstream 渲染器 glue"
rm -f "$GFX_GLUE_OBJ"
if ! $CXX -c "$GFX_GLUE_SRC" -o "$GFX_GLUE_OBJ" $GFX_CXXFLAGS \
        >"$GLUE_OBJ_DIR/gfx_glue.log" 2>&1; then
    echo "!! gfxstream glue 编译失败：" >&2
    tail -40 "$GLUE_OBJ_DIR/gfx_glue.log" >&2
    exit 1
fi
echo "==> gfx glue ok: $(ls -lh "$GFX_GLUE_OBJ" | awk '{print $5}')"

GFX_LIBS="$(find "$GFX_BUILD_DIR" -name '*.a' | sort | tr '\n' ' ')"
echo "==> gfxstream 静态库 $(echo "$GFX_LIBS" | wc -w) 个"
{
    echo "LIBS+=$GFX_GLUE_OBJ"
    echo "LIBS+=-Wl,--start-group $GFX_LIBS -Wl,--end-group"
    # 注意：**不要**加 -landroid。真机上链 libandroid.so 会拖进
    # libharfbuzz_ng.so -> libicu.so，而 libicu.so 在 app 的 linker namespace
    # 里解析不到，运行时直接 "CANNOT LINK EXECUTABLE"。
    # ANativeWindow_* 已在 vmhost_gfx_glue.cpp 里自带最小桩。
    # -llog：gfxstream/aemu 的日志走 __android_log_*。
    echo "LIBS+=-llog"
} >> "$BUILD_DIR/config-host.mak"
echo "==> patch: config-host.mak 追加 gfxstream glue.o + 全部 gfxstream 静态库"

# ------------------------------------------------ 2e. gfxstream stream_renderer 接线
# 方案 B 核心：把 gfxstream 的 stream_renderer API 实现（host/virtio-gpu-gfxstream-
# renderer.cpp）直接编进 QEMU，给 virtio-gpu-3d.o 提供 stream_renderer_* 符号。
# 前端（android-qemu2-glue）是 dlopen libgfxstream_backend.so；我们没有前端，
# 静态链接等价替代。
#
# 该文件自带 goldfish_pipe_get_service_ops()（fallback 用的空服务 ops），
# 与 QEMU 的 hw/misc/goldfish_pipe.c 重复 —— 静态链接会 "multiple definition"。
# 拷贝一份编译，删掉该定义即可（stream_renderer_set_service_ops 会用 QEMU 侧实现）。
SR_RENDERER_SRC="$GFX_DIR/host/virtio-gpu-gfxstream-renderer.cpp"
SR_RENDERER_OBJ="$GLUE_OBJ_DIR/vmhost_gfxstream_renderer.o"
SR_WORK="$GLUE_OBJ_DIR/virtio-gpu-gfxstream-renderer.work.cpp"
mkdir -p "$GLUE_OBJ_DIR"
cp -f "$SR_RENDERER_SRC" "$SR_WORK"
perl -0pi -e \
    's/\nconst GoldfishPipeServiceOps\* goldfish_pipe_get_service_ops\(\) \{ return &goldfish_pipe_service_ops; \}//' \
    "$SR_WORK"
if grep -q 'goldfish_pipe_get_service_ops() {' "$SR_WORK"; then
    echo "!! stream_renderer 源裁剪失败（重复定义仍在）" >&2
    exit 1
fi

SR_CXXFLAGS="-std=c++17 -fPIC -fcommon -Wno-error \
-DGLM_FORCE_DEFAULT_ALIGNED_GENTYPES -DGLM_FORCE_RADIANS -DUSE_X11 \
-DVIRGL_RENDERER_UNSTABLE_APIS -DVK_GFXSTREAM_STRUCTURE_TYPE_EXT -DCONFIG_AEMU \
-I$GFX_DIR -I$GFX_DIR/include -I$GFX_DIR/host -I$GFX_DIR/host/include \
-I$GFX_DIR/host/gl \
-I$GFX_DIR/host/gl/glestranslator/include \
-I$GFX_DIR/host/gl/gl-host-common/include \
-I$GFX_DIR/gl-host-common/include \
-I$GFX_DIR/common/opengl/include \
-I$GFX_DIR/common/vulkan/include \
-I$GFX_DIR/host/apigen-codec-common \
-I$GFX_DIR/host/vulkan -I$GFX_DIR/host/vulkan/cereal/common \
-I$GFX_DIR/host/magma -I$GFX_DIR/host/magma/magma_dec \
-I$GFX_DIR/third-party/fuchsia/magma/include \
-I$GFX_DIR/third-party/glm/include \
-I$GFX_DIR/third-party/renderdoc/include \
-I$GFX_DIR/utils/include \
-I$GFX_BUILD_DIR/vmhost-shim \
-I$AEMU_DIR/host-common/include -I$AEMU_DIR/base/include \
-I$AEMU_DIR/third-party/cuda/include -I$AEMU_DIR/snapshot/include"

echo "==> 编译 gfxstream stream_renderer 实现（virtio-gpu 3D）"
rm -f "$SR_RENDERER_OBJ"
if ! $CXX -c "$SR_WORK" -o "$SR_RENDERER_OBJ" $SR_CXXFLAGS \
        >"$GLUE_OBJ_DIR/sr_renderer.log" 2>&1; then
    echo "!! stream_renderer 编译失败：" >&2
    tail -60 "$GLUE_OBJ_DIR/sr_renderer.log" >&2
    exit 1
fi
echo "==> stream_renderer ok: $(ls -lh "$SR_RENDERER_OBJ" | awk '{print $5}')"
{
    echo "LIBS+=$SR_RENDERER_OBJ"
} >> "$BUILD_DIR/config-host.mak"
echo "==> patch: config-host.mak 追加 stream_renderer.o"

# initLibrary()/gfxstream::initLibrary() 定义在 host/render_api.cpp（属于 gfxstream
# 的共享库目标 gfxstream_backend，静态库里没有），单独编进来补符号。
SR_API_SRC="$GFX_DIR/host/render_api.cpp"
SR_API_OBJ="$GLUE_OBJ_DIR/vmhost_gfxstream_render_api.o"
echo "==> 编译 gfxstream render_api（initLibrary 定义）"
rm -f "$SR_API_OBJ"
if ! $CXX -c "$SR_API_SRC" -o "$SR_API_OBJ" $SR_CXXFLAGS \
        >"$GLUE_OBJ_DIR/sr_render_api.log" 2>&1; then
    echo "!! render_api 编译失败：" >&2
    tail -40 "$GLUE_OBJ_DIR/sr_render_api.log" >&2
    exit 1
fi
{
    echo "LIBS+=$SR_API_OBJ"
} >> "$BUILD_DIR/config-host.mak"
echo "==> patch: config-host.mak 追加 render_api.o"

# ---------------------------------------------------------------- 3. build
# -k：老代码库在新 clang 下会有一批不兼容点，一次收集全部错误，
#     免得一轮只修一个、来回几十次。
# 只构建主程序：helper（qemu-bridge-helper 等）我们不需要，
# 它们会带出 tests/Makefile.include 里的 -lutil，而 bionic 没有 libutil。
echo "==> make -k -j$JOBS"
# config-host.mak 改了 LIBS/LDFLAGS，但 make 不一定把它当依赖，先删掉旧产物
# 强制重新链接（.o 都已存在，重链很快）。
find "$BUILD_DIR" -maxdepth 2 -name 'qemu-system-aarch64' -type f -delete 2>/dev/null || true
# 方案 B：VIRGL_CFLAGS 变了，旧的 virtio-gpu.o/3d.o 是空壳，删掉强制重编
# （virtio-gpu-pci.o 也删：它的 VirtIOGPU 布局随 CONFIG_VIRGL 变化，不重编
#   会导致 object_initialize 断言 size>=instance_size 崩溃）
rm -f "$BUILD_DIR/aarch64-softmmu/hw/display/virtio-gpu.o" \
      "$BUILD_DIR/aarch64-softmmu/hw/display/virtio-gpu-3d.o" \
      "$BUILD_DIR/aarch64-softmmu/hw/display/virtio-gpu-pci.o" \
      "$BUILD_DIR/aarch64-softmmu/hw/display/virtio-gpu.d" \
      "$BUILD_DIR/aarch64-softmmu/hw/display/virtio-gpu-3d.d" \
      "$BUILD_DIR/aarch64-softmmu/hw/display/virtio-gpu-pci.d"
echo "==> 删除旧 virtio-gpu 目标文件（VIRGL_CFLAGS 已变，强制重编）"
# 用 -k 继续跑：helper（qemu-bridge-helper / qemu-pr-helper）会因为 bionic
# 没有 libutil 而失败，但它们我们完全不需要；主程序不受影响。
# || true：不让 helper 的失败中断脚本，后面还要统计产物。
#
# 注意必须**显式指定主程序目标**：默认目标 all 会先撞上
# tests/qemu-iotests/socket_scm_helper 与 qemu-bridge-helper 的 -lutil 链接失败，
# -k 虽然继续，但主程序的构建链排在那些失败目标之后，实测会被整条跳过 ——
# 表现为 make "跑完了"、脚本也"完成"，可 BUILD_DIR 下根本没有 qemu-system-aarch64
# （脚本随后把 prebuilt 里的旧产物原样收集，产物时间不变，极难察觉）。
# AOSP 版的目标名是 subdir-<TARGET_DIRS>，即 subdir-aarch64-softmmu。
make -k -j"$JOBS" subdir-aarch64-softmmu 2>&1 | tail -20 || true

# 主程序必须真的存在，否则后面收集到的是上一次的旧产物（静默的错误结果）。
MAIN_BIN="$(find "$BUILD_DIR" -maxdepth 2 -name 'qemu-system-aarch64' -type f -print -quit)"
if [ -z "$MAIN_BIN" ]; then
    echo "!! 主程序未生成（BUILD_DIR=$BUILD_DIR）" >&2
    exit 4
fi
echo "==> 主程序已重链：$MAIN_BIN"
ls -l "$MAIN_BIN"

# ---------------------------------------------------------------- 4. 产出
# 把可执行体与它真正需要的运行时 .so 一起收进 app 的 prebuilt 目录。
# 注意：新二进制是 -static-libstdc++，**不再需要 libc++_shared.so**；
# 也不能带 libandroid.so（真机上会拖 libharfbuzz_ng → libicu 解析失败）。
mkdir -p "$OUT_DIR"
EXE="$BUILD_DIR/aarch64-softmmu/qemu-system-aarch64"
if [ -f "$EXE" ]; then
    echo "==> 可执行体：$(ls -lh "$EXE" | awk '{print $5}')"
    cp -f "$EXE" "$OUT_DIR/qemu-system-aarch64"
else
    echo "!! 未生成 qemu-system-aarch64（见上面 make 输出）" >&2
fi

# 运行时依赖（NEEDED）：glib 系 + pixman，全部来自 sysroot
RUNTIME_SOS="
libglib-2.0.so
libgthread-2.0.so
libintl.so
libpcre2-8.so
libpcre2-posix.so
libffi.so
libpixman-1.so
"
for _so in $RUNTIME_SOS; do
    if [ -f "$SYSROOT/lib/$_so" ]; then
        cp -f "$SYSROOT/lib/$_so" "$OUT_DIR/$_so"
    else
        echo "!! 缺少运行时库 $SYSROOT/lib/$_so" >&2
    fi
done
# 旧版本残留的 libc++_shared.so 已不需要，清掉避免误导
rm -f "$OUT_DIR/libc++_shared.so"

# ---------------------------------------------------------------- 5. 安装到 jniLibs
# 引擎（src/main/cpp/src/vm_qemu.c）在 **nativeLibraryDir** 里按
# libqemu_exec.so 查找子进程 QEMU；该目录由 APK 的 jniLibs 解压而来，
# 所以可执行体与它的运行时依赖都必须以 lib*.so 形式放进
# engine/src/main/jniLibs/<abi>/ 才会被 AGP 打包。
#
# 这一步以前完全缺失：没有任何脚本产出 jniLibs/libqemu_exec.so
# （build_qemu.sh 产出的是 prebuilt/qemu/.../libqemu-system-aarch64.so），
# 于是 vm_qemu_start() 永远找不到子进程 QEMU，静默退回进程内嵌的
# 「-M virt」路径 —— 而那条路跑不起来这套 ranchu 访客。
mkdir -p "$JNI_DIR"
if [ -f "$EXE" ]; then
    cp -f "$EXE" "$JNI_DIR/libqemu_exec.so"
    chmod 0755 "$JNI_DIR/libqemu_exec.so"
    echo "==> 已安装子进程可执行体：$JNI_DIR/libqemu_exec.so"
else
    echo "!! 未生成 $EXE，jniLibs 里不会有 libqemu_exec.so" >&2
fi

for _so in $RUNTIME_SOS; do
    if [ -f "$OUT_DIR/$_so" ]; then
        cp -f "$OUT_DIR/$_so" "$JNI_DIR/$_so"
    fi
done

echo "==> 目标文件数：$(find "$BUILD_DIR" -name '*.o' | wc -l)"
echo "==> 已收集到 $OUT_DIR："
ls -lh "$OUT_DIR" | tail -n +2
echo
echo "==> jniLibs（随 APK 分发，解压到 nativeLibraryDir）：$JNI_DIR"
ls -lh "$JNI_DIR" | tail -n +2
echo "完成。"
