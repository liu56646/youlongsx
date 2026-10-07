#!/usr/bin/env bash
#
# 交叉编译 qemu-system-aarch64 到 Android（aarch64）
# 必须在 WSL2 / Linux 中运行；依赖 sysroot 由 wsl_bootstrap.sh 预先准备好。
#
#   使用：WORKDIR=~/vmbuild ./build_qemu.sh
#
# 产物：engine/src/main/jniLibs/arm64-v8a/libqemu-system-aarch64.so
#   Android 10+ 禁止执行应用私有目录里的文件（W^X / noexec），
#   所以可执行体必须以 lib*.so 形式经 jniLibs 分发，
#   安装后由系统解压到 nativeLibraryDir 才可执行。
#
set -euo pipefail

# ---------------------------------------------------------------- 配置
QEMU_VERSION="${QEMU_VERSION:-v9.2.0}"
WORKDIR="${WORKDIR:-$HOME/vmbuild}"
NDK_VER="${NDK_VER:-r28}"
API_LEVEL="${API_LEVEL:-28}"
ABI="${ABI:-arm64-v8a}"
JOBS="${JOBS:-8}"

NDK_DIR="$WORKDIR/android-ndk-$NDK_VER"
TOOLCHAIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
SYSROOT="$WORKDIR/sysroot-arm64"
SRC_DIR="$WORKDIR/qemu"
BUILD_DIR="$WORKDIR/qemu-build-$ABI"
ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# 依赖库（glib 等）要随 APK 分发，放 jniLibs
LIB_OUT_DIR="$ENGINE_DIR/src/main/jniLibs/$ABI"
# 独立可执行体只作参考/回退，不随 APK 分发（QEMU 已静态链入 libvmengine.so）
BIN_OUT_DIR="$ENGINE_DIR/src/main/cpp/prebuilt/qemu/$ABI"

case "$ABI" in
    arm64-v8a) TRIPLE="aarch64-linux-android" ;;
    x86_64)    TRIPLE="x86_64-linux-android"  ;;
    *) echo "unsupported ABI: $ABI" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- 前置检查
[ -d "$TOOLCHAIN" ] || { echo "找不到 NDK 工具链：$TOOLCHAIN" >&2; exit 1; }
[ -d "$SYSROOT/lib/pkgconfig" ] || {
    echo "找不到 sysroot：$SYSROOT" >&2
    echo "请先运行 wsl_bootstrap.sh 交叉编译 glib / pixman。" >&2
    exit 2
}

export CC="$TOOLCHAIN/bin/${TRIPLE}${API_LEVEL}-clang"
export CXX="$TOOLCHAIN/bin/${TRIPLE}${API_LEVEL}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export LD="$TOOLCHAIN/bin/ld.lld"
# 关键：限定 pkg-config 只在 sysroot 内查找，避免误用宿主机的 glib
export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig"

echo "==> QEMU $QEMU_VERSION | ABI $ABI | API $API_LEVEL"
echo "==> SYSROOT = $SYSROOT"
echo "==> CC      = $CC"

echo "==> pkg-config 自检"
pkg-config --exists glib-2.0   || { echo "glib-2.0 不可见"   >&2; exit 2; }
pkg-config --exists pixman-1   || { echo "pixman-1 不可见"   >&2; exit 2; }
echo "    glib-2.0 $(pkg-config --modversion glib-2.0) / pixman-1 $(pkg-config --modversion pixman-1)"

# QEMU 的 meson 交叉配置会去找「带 cross-prefix 的 pkg-config」（即 llvm-pkg-config），
# 系统里不存在就会报 "Pkg-config for machine host machine not found"。
# 这里造一个包装脚本，强制它只在 sysroot 内查找。
PKGCONFIG_WRAPPER="$TOOLCHAIN/bin/llvm-pkg-config"
if [ ! -x "$PKGCONFIG_WRAPPER" ]; then
    echo "==> 生成 pkg-config 包装脚本：$PKGCONFIG_WRAPPER"
    cat > "$PKGCONFIG_WRAPPER" <<EOF
#!/bin/sh
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig"
export PKG_CONFIG_PATH="\$PKG_CONFIG_LIBDIR"
exec /usr/bin/pkg-config "\$@"
EOF
    chmod +x "$PKGCONFIG_WRAPPER"
fi

# ---------------------------------------------------------------- 1. 取源码
mkdir -p "$WORKDIR"
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "==> 克隆 QEMU 源码"
    git clone --depth 1 --branch "$QEMU_VERSION" \
        https://gitlab.com/qemu-project/qemu.git "$SRC_DIR"
else
    echo "==> QEMU 源码已存在"
fi

# ---------------------------------------------------------------- 1.5 Android 适配补丁
# bionic 的 <sys/stat.h> 把 st_atime_nsec / st_mtime_nsec / st_ctime_nsec 定义成了宏，
# 而 QEMU 的 fsdev/9p-marshal.h 里用这些名字做结构体成员，展开后语法就被破坏。
# 在包含该头文件前取消这几个宏定义即可。幂等：重复执行不会重复插入。
MARSHAL_H="$SRC_DIR/fsdev/9p-marshal.h"
PATCH_MARK="__ANDROID_STAT_NSEC_UNDEF__"
if [ -f "$MARSHAL_H" ] && ! grep -q "$PATCH_MARK" "$MARSHAL_H"; then
    echo "==> 打 Android 适配补丁：fsdev/9p-marshal.h"
    python3 - "$MARSHAL_H" "$PATCH_MARK" <<'PY'
import sys

path, mark = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
anchor = "typedef struct V9fsString"
if anchor not in src:
    sys.exit("补丁锚点未找到：" + anchor)

inject = (
    "/* " + mark + " */\n"
    "#if defined(__ANDROID__)\n"
    "/* bionic 的 <sys/stat.h> 把 st_*time_nsec 定义成了宏，\n"
    "   会破坏下面结构体中同名的成员，这里先取消定义。 */\n"
    "#undef st_atime_nsec\n"
    "#undef st_mtime_nsec\n"
    "#undef st_ctime_nsec\n"
    "#endif\n\n"
)
open(path, "w", encoding="utf-8").write(src.replace(anchor, inject + anchor, 1))
print("    已插入 __ANDROID__ 分支")
PY
else
    echo "==> 9p-marshal.h 补丁已存在，跳过"
fi

# bionic 没有 POSIX 共享内存实现（_POSIX_SHARED_MEMORY_OBJECTS 缺失），
# 导致 shm_open / shm_unlink 连声明都没有。相关代码只在
# memory-backend-shm / ivshmem 场景使用，本项目用不到，故在 Android 下
# 提供返回 ENOSYS 的本地实现，避免编译中断。幂等。
patch_shm_shim() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -q "QEMU_ANDROID_SHM_SHIM" "$file" && return 0
    echo "==> 打补丁（shm 兼容）：${file#"$SRC_DIR"/}"
    python3 - "$file" <<'PY'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
anchor = '#include "qemu/osdep.h"'
if anchor not in src:
    sys.exit("补丁锚点未找到：" + path)

shim = anchor + """

#if defined(__ANDROID__)
/* QEMU_ANDROID_SHM_SHIM
 * bionic 未实现 POSIX 共享内存（_POSIX_SHARED_MEMORY_OBJECTS 缺失）。
 * 相关代码仅用于 memory-backend-shm / ivshmem，本项目用不到，
 * 因此在 Android 上直接返回 ENOSYS，避免编译期缺符号。
 */
#include <errno.h>
static inline int shm_open(const char *name, int oflag, mode_t mode)
{
    (void)name; (void)oflag; (void)mode;
    errno = ENOSYS;
    return -1;
}
static inline int shm_unlink(const char *name)
{
    (void)name;
    errno = ENOSYS;
    return -1;
}
#endif
"""
open(path, "w", encoding="utf-8").write(src.replace(anchor, shim, 1))
print("    已插入 shm shim")
PY
}

patch_shm_shim "$SRC_DIR/backends/hostmem-shm.c"
patch_shm_shim "$SRC_DIR/contrib/ivshmem-server/ivshmem-server.c"
patch_shm_shim "$SRC_DIR/tests/qtest/ivshmem-test.c"

# ---------------------------------------------------------------- 1.6 vmhost 显示后端
# 把自定义显示后端装进 QEMU 源码树：
#   a) 新增 ui/vmhost.c，并拷入共享头 include/ui/vmhost_display.h
#   b) 在 ui/meson.build 里注册该源文件
#   c) 在 graphic_console_init() 末尾挂载 DCL
# 幂等：靠源码里的标记字符串判断是否已打过。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VMHOST_IMPL="$SCRIPT_DIR/qemu_patches/ui_vmhost.c"
VMHOST_HDR="$(cd "$SCRIPT_DIR/.." && pwd)/src/main/cpp/src/vmhost_display.h"
VMHOST_INPUT_HDR="$(cd "$SCRIPT_DIR/.." && pwd)/src/main/cpp/src/vmhost_input.h"
VMHOST_CTRL_HDR="$(cd "$SCRIPT_DIR/.." && pwd)/src/main/cpp/src/vmhost_control.h"

if [ -f "$VMHOST_IMPL" ] && [ -f "$VMHOST_HDR" ]; then
    echo "==> 安装 vmhost 显示/输入后端"
    cp -f "$VMHOST_IMPL" "$SRC_DIR/ui/vmhost.c"
    mkdir -p "$SRC_DIR/include/ui"
    cp -f "$VMHOST_HDR" "$SRC_DIR/include/ui/vmhost_display.h"
    if [ -f "$VMHOST_INPUT_HDR" ]; then
        cp -f "$VMHOST_INPUT_HDR" "$SRC_DIR/include/ui/vmhost_input.h"
    else
        echo "!! 缺少 vmhost_input.h，输入注入将不可用" >&2
    fi
    if [ -f "$VMHOST_CTRL_HDR" ]; then
        cp -f "$VMHOST_CTRL_HDR" "$SRC_DIR/include/ui/vmhost_control.h"
    else
        echo "!! 缺少 vmhost_control.h，停机将不可用" >&2
    fi

    python3 - "$SRC_DIR" <<'PY'
import os
import sys

root = sys.argv[1]


def patch(rel, old, new, marker):
    path = os.path.join(root, rel)
    src = open(path, encoding="utf-8").read()
    if marker in src:
        print("    已打过补丁：" + rel)
        return
    if old not in src:
        sys.exit("补丁锚点未找到：" + rel)
    open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
    print("    已打补丁：" + rel)


# a) 注册源文件
patch(
    "ui/meson.build",
    "  'util.c',\n))",
    "  'util.c',\n  'vmhost.c',\n))",
    "'vmhost.c'",
)

# b) 在 graphic_console_init() 返回前挂载 DCL。
#    在这里声明 prototype 即可，不必动文件头的 include（QemuConsole 此时已可见）。
patch(
    "ui/console.c",
    "    s->gl_unblock_timer = timer_new_ms(QEMU_CLOCK_REALTIME,\n"
    "                                       graphic_hw_gl_unblock_timer, s);\n"
    "    return s;",
    "    s->gl_unblock_timer = timer_new_ms(QEMU_CLOCK_REALTIME,\n"
    "                                       graphic_hw_gl_unblock_timer, s);\n"
    "    /* vmhost: 挂载自定义显示后端（实现见 ui/vmhost.c） */\n"
    "    {\n"
    "        extern void vmhost_display_attach(QemuConsole *con);\n"
    "        vmhost_display_attach(s);\n"
    "    }\n"
    "    return s;",
    "vmhost_display_attach",
)
# c) 关闭 -Werror。
#    从 git checkout 构建时 QEMU 默认开 werror；而 meson 一旦因 meson.build 变更
#    自动重跑，configure 的 -Dwerror=false 会被丢掉，导致新启用的代码路径直接编译失败。
#    写进 default_options 才能在重跑后依然生效。
patch(
    "meson.build",
    "'optimization=2', 'b_pie=true'],",
    "'optimization=2', 'b_pie=true', 'werror=false'],",
    "'werror=false'",
)

# d) bionic 给 getrandom 加了 nonnull 注解，QEMU 用它探测可用性时传 NULL，
#    在 -Werror 下会失败。改成传一个长度为 0 的哑地址，语义不变。
patch(
    "crypto/random-platform.c",
    "/* This is -1 for getrandom(), or a file handle for /dev/{u,}random.  */\nstatic int fd;",
    "/* This is -1 for getrandom(), or a file handle for /dev/{u,}random.  */\nstatic int fd;\n"
    "/* bionic 的 getrandom 带 nonnull 注解，探测可用性时给个哑地址 */\nstatic char getrandom_probe;",
    "static char getrandom_probe;",
)
patch(
    "crypto/random-platform.c",
    "if (getrandom(NULL, 0, 0) == 0) {",
    "if (getrandom(&getrandom_probe, 0, 0) == 0) {",
    "getrandom(&getrandom_probe, 0, 0)",
)
PY
else
    echo "!! 缺少 vmhost 显示后端源文件，跳过（画面只会是占位渐变）"
fi

# ---------------------------------------------------------------- 2. configure
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ ! -f build.ninja ]; then
    echo "==> configure"
    rm -rf "$BUILD_DIR"/* "$BUILD_DIR"/.[!.]* 2>/dev/null || true
    "$SRC_DIR/configure" \
        --cross-prefix="$TOOLCHAIN/bin/llvm-" \
        --cc="$CC" \
        --cxx="$CXX" \
        --target-list="aarch64-softmmu" \
        --disable-werror \
        --disable-docs \
        --disable-guest-agent \
        --disable-tools \
        --disable-gtk \
        --disable-sdl \
        --disable-spice \
        --disable-vnc \
        --disable-opengl \
        --disable-vhost-user \
        --disable-vhost-user-blk-server \
        --disable-pie \
        --extra-cflags="-fPIC -I$SYSROOT/include" \
        --extra-ldflags="-L$SYSROOT/lib"
else
    echo "==> 已 configure 过，跳过"
fi

# ---------------------------------------------------------------- 3. build
echo "==> ninja -j$JOBS"
ninja -j"$JOBS"

# ---------------------------------------------------------------- 4. 产出
mkdir -p "$BIN_OUT_DIR" "$LIB_OUT_DIR"
CANDIDATE_BIN="$(find "$BUILD_DIR" -maxdepth 2 -name 'qemu-system-aarch64' -type f -print -quit)"

if [ -n "$CANDIDATE_BIN" ]; then
    cp "$CANDIDATE_BIN" "$BIN_OUT_DIR/libqemu-system-aarch64.so"
    "$STRIP" --strip-unneeded "$BIN_OUT_DIR/libqemu-system-aarch64.so" || true
    echo "==> 独立可执行体（仅作参考/回退，不进 APK）："
    echo "    $BIN_OUT_DIR/libqemu-system-aarch64.so"
    ls -lh "$BIN_OUT_DIR/libqemu-system-aarch64.so"
    file "$BIN_OUT_DIR/libqemu-system-aarch64.so" || true
else
    echo "!! 未找到 QEMU 产物，请检查构建日志。" >&2
    exit 3
fi

echo
echo "==> 收集运行期依赖库 → $LIB_OUT_DIR"

READELF="$TOOLCHAIN/bin/llvm-readelf"

# 递归收集 NEEDED，只从 sysroot 取，跳过 Android 系统自带的库
collect_deps() {
    local lib="$1"
    local name candidate
    for name in $("$READELF" -d "$lib" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
        case "$name" in
            libc.so|libm.so|libdl.so|liblog.so|libz.so|libatomic.so|\
            libandroid.so|libEGL.so|libGLESv2.so|libvulkan.so)
                continue ;;
        esac
        [ -f "$LIB_OUT_DIR/$name" ] && continue
        candidate="$(ls -1 "$SYSROOT/lib/$name" 2>/dev/null | head -1)"
        [ -z "$candidate" ] && continue
        cp -L "$candidate" "$LIB_OUT_DIR/$name"
        echo "    + $name"
        collect_deps "$LIB_OUT_DIR/$name"
    done
}

collect_deps "$BIN_OUT_DIR/libqemu-system-aarch64.so"

echo
echo "jniLibs/$ABI 内容（随 APK 分发）："
ls -lh "$LIB_OUT_DIR" | tail -n +2

echo
echo "完成。接着执行 scripts/package_qemu_static.sh 打包静态产物，"
echo "engine 模块会把 QEMU 静态链入 libvmengine.so。"
