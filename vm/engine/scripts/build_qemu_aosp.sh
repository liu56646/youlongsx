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
for _lib in host-common/libaemu-host-common.a base/libaemu-base.a \
            host-common/liblogging-base.a snapshot/libgfxstream-snapshot.a; do
    [ -f "$AEMU_LIB_DIR/$_lib" ] || {
        echo "找不到 aemu 静态库：$AEMU_LIB_DIR/$_lib（先跑 build_aemu.sh）" >&2; exit 1; }
done

# gfxstream 宿主渲染器（pipe:opengles 的必要条件）
[ -d "$GFX_DIR/host" ] || {
    echo "找不到 gfxstream 源码：$GFX_DIR（见 docs/opengles宿主渲染器实施方案.md）" >&2; exit 1; }
for _lib in host/libgfxstream_backend_static.a \
            host/gl/gl-host-common/libgfxstream-gl-host-common.a; do
    [ -f "$GFX_BUILD_DIR/$_lib" ] || {
        echo "找不到 gfxstream 静态库：$GFX_BUILD_DIR/$_lib（先跑 build_gfxstream.sh）" >&2; exit 1; }
done

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

# 给 vl.c 加一个嵌入式入口：main_impl 是 static 的，AOSP 原生的
# run_qemu_main() 又被 CONFIG_ANDROID 挡住（会把整个 emulator 前端拖进来）。
# 这里只加一个 3 行的包装函数，让引擎能在进程内直接驱动 QEMU。
patch_embed_entry() {
    local vl="$SRC_DIR/vl.c"
    if grep -q "VMHOST_CRASH_CAPTURE" "$vl"; then
        echo "==> vl.c 已有嵌入式入口（含崩溃捕获），跳过"
        return
    fi
    # 先清掉早期版本追加的入口块（无崩溃捕获那段），避免重复定义。
    # 注意 /* 与横线之间有空格，别把 \s* 漏掉。
    perl -0pi -e 's{\n/\*[^\n]*\n \* VMHost: 进程内嵌入式入口.*\z}{}s' "$vl"
    echo "==> 注入嵌入式入口 vmhost_qemu_main()（含崩溃捕获）"
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
    return main_impl(argc, argv, NULL);
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
    if grep -q "VMHOST_MAIN_CRASH" "$vl"; then
        return
    fi
    # 原型：放在文件顶部（osdep / feature_control 之后），main() 可见
    if ! grep -q "VMHOST_CRASH_PROTO" "$vl"; then
        perl -0pi -e \
            's/(#include "host-common\/feature_control\.h" \/\* VMHOST_FEATURE_INCLUDE \*\/\n)/$1static void vmhost_crash_install(void); \/* VMHOST_CRASH_PROTO *\/\nextern int vmhost_pipe_init(void); \/* VMHOST_PIPE_PROTO *\/\nextern int vmhost_gfx_init(void); \/* VMHOST_GFX_PROTO *\/\n/' \
            "$vl"
    fi
    # 主体挂钩：用 / 作分隔符，避免 {} 配对问题
    perl -0pi -e \
        's/\{\n    const int res = main_impl\(argc, argv, on_main_loop_done\);/{\n    vmhost_crash_install(); \/* VMHOST_MAIN_CRASH *\/\n    vmhost_pipe_init(); \/* VMHOST_PIPE_INIT_MAIN *\/\n    vmhost_gfx_init(); \/* VMHOST_GFX_INIT_MAIN *\/\n    const int res = main_impl(argc, argv, on_main_loop_done);/' \
        "$vl"
    echo "==> patch: vl.c 在 main() 挂上崩溃捕获 + pipe 服务 + gfxstream 渲染器初始化"
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
echo "==> glue ok: $(ls -lh "$GLUE_OBJ" "$VMLOCK_OBJ" | awk '{print $5, $9}' | tr '\n' ' ')"

# 链接：glue .o + 4 个 aemu 静态库追加进 LIBS（--start-group 解决相互依赖）。
# -static-libstdc++：NDK clang++ 默认链 libc++_shared.so，静态链才能单文件跑。
# 先删掉本脚本上次追加的行（config-host.mak 是 configure 产物，不会被重置），
# 再重新追加，保证重复运行时不重复累加。
sed -i \
    -e '/vmhost_pipe_glue\.o/d' \
    -e '/vmhost_gfx_glue\.o/d' \
    -e '/vmhost_gfxstream_renderer\.o/d' \
    -e '/vmhost_gfxstream_render_api\.o/d' \
    -e '/libaemu-host-common\.a/d' \
    -e '/libgfxstream_backend_static\.a/d' \
    -e '/libgfxstream-gl-host-common\.a/d' \
    -e '/^LIBS+=-llog$/d' \
    -e '/^LIBS+=-landroid -llog$/d' \
    -e '/^LDFLAGS+=-static-libstdc++$/d' \
    "$BUILD_DIR/config-host.mak"
{
    echo "LIBS+=$GLUE_OBJ $VMLOCK_OBJ"
    echo "LIBS+=-Wl,--start-group $AEMU_LIB_DIR/host-common/libaemu-host-common.a $AEMU_LIB_DIR/base/libaemu-base.a $AEMU_LIB_DIR/snapshot/libgfxstream-snapshot.a $AEMU_LIB_DIR/host-common/liblogging-base.a -Wl,--end-group"
    echo "LDFLAGS+=-static-libstdc++"
} >> "$BUILD_DIR/config-host.mak"
echo "==> patch: config-host.mak 追加 glue.o + aemu 静态库 + -static-libstdc++"

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
make -k -j"$JOBS" 2>&1 | tail -40 || true

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
