#!/usr/bin/env bash
#
# 在 WSL2 / Linux 中为 QEMU 准备 Android aarch64 交叉编译 sysroot。
#
# 产出：$SYSROOT 下 glib-2.0 / pixman-1 及其依赖（共享库形态）
#   zlib → libffi → pcre2 → glib-2.0
#   pixman-1（独立）
#
# 为什么用共享库：QEMU 的 configure 用 `pkg-config --libs`（不带 --static），
# 静态 glib 会漏掉 libffi/pcre2 的符号。共享库形态也与参考应用的
# libglib-2.0.so / libintl.so 分发方式一致。
#
# 幂等：每步完成后打 .built 标记，可重复执行。
#
set -euo pipefail

WORKDIR="${WORKDIR:-$HOME/vmbuild}"
NDK_VER="${NDK_VER:-r28}"
API="${API:-28}"          # bionic 的 iconv 从 API 28 起提供，glib 依赖它
JOBS="${JOBS:-8}"
TRIPLE="aarch64-linux-android"

NDK_DIR="$WORKDIR/android-ndk-$NDK_VER"
SYSROOT="$WORKDIR/sysroot-arm64"
SRC="$WORKDIR/src"
TOOLCHAIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
CROSS_FILE="$WORKDIR/android-arm64.meson"

mkdir -p "$WORKDIR" "$SYSROOT" "$SRC"

echo "==> WORKDIR = $WORKDIR"
echo "==> SYSROOT = $SYSROOT"

# ------------------------------------------------------------------ 1. NDK
if [ ! -d "$NDK_DIR" ]; then
    echo "==> 下载 Android NDK $NDK_VER (linux)"
    cd "$WORKDIR"
    [ -f "android-ndk-$NDK_VER-linux.zip" ] || \
        wget -q -O "android-ndk-$NDK_VER-linux.zip" \
            "https://dl.google.com/android/repository/android-ndk-$NDK_VER-linux.zip"
    unzip -q "android-ndk-$NDK_VER-linux.zip" -d "$WORKDIR"
else
    echo "==> NDK 已存在，跳过"
fi

export CC="$TOOLCHAIN/bin/${TRIPLE}${API}-clang"
export CXX="$TOOLCHAIN/bin/${TRIPLE}${API}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig"
# 注意：.pc 里的 prefix 是真实绝对路径，因此不要设 PKG_CONFIG_SYSROOT_DIR

# ------------------------------------------------------------------ 2. meson 交叉文件
cat > "$CROSS_FILE" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
pkg_config_libdir = '$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig'
EOF
echo "==> 交叉文件：$CROSS_FILE"

fetch() {   # fetch <输出文件名> <URL...>
    local out="$1"; shift
    [ -f "$SRC/$out" ] && return 0
    local url
    for url in "$@"; do
        echo "    下载 $url"
        if wget -q -O "$SRC/$out.part" "$url"; then
            mv "$SRC/$out.part" "$SRC/$out"
            return 0
        fi
    done
    echo "!! 下载失败：$out" >&2
    return 1
}

# ------------------------------------------------------------------ 3. zlib
build_zlib() {
    cd "$SRC"
    [ -f .zlib_built ] && { echo "==> zlib 已完成"; return 0; }
    fetch zlib-1.3.1.tar.gz \
        "https://www.zlib.net/fossils/zlib-1.3.1.tar.gz" \
        "https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz"
    [ -d zlib-1.3.1 ] || tar xf zlib-1.3.1.tar.gz
    cd zlib-1.3.1
    echo "==> 编译 zlib"
    # zlib 的 Makefile 不自动加 -fPIC，aarch64 上会导致 .so 链接失败，必须显式传入
    CHOST=$TRIPLE CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="-O2 -fPIC" \
        ./configure --prefix="$SYSROOT"
    make -j"$JOBS"
    make install
    touch "$SRC/.zlib_built"
}

# ------------------------------------------------------------------ 4. libffi
build_libffi() {
    cd "$SRC"
    [ -f .libffi_built ] && { echo "==> libffi 已完成"; return 0; }
    fetch libffi-3.4.6.tar.gz \
        "https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz" \
        "https://sourceware.org/pub/libffi/libffi-3.4.6.tar.gz"
    [ -d libffi-3.4.6 ] || tar xf libffi-3.4.6.tar.gz
    cd libffi-3.4.6
    echo "==> 编译 libffi"
    ./configure --host="$TRIPLE" --prefix="$SYSROOT" \
        --enable-shared --disable-static --disable-docs
    make -j"$JOBS"
    make install
    touch "$SRC/.libffi_built"
}

# ------------------------------------------------------------------ 5. pcre2
build_pcre2() {
    cd "$SRC"
    [ -f .pcre2_built ] && { echo "==> pcre2 已完成"; return 0; }
    fetch pcre2-10.44.tar.gz \
        "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz"
    [ -d pcre2-10.44 ] || tar xf pcre2-10.44.tar.gz
    cd pcre2-10.44
    echo "==> 编译 pcre2"
    ./configure --host="$TRIPLE" --prefix="$SYSROOT" \
        --enable-shared --disable-static \
        --disable-pcre2grep-libz --disable-pcre2grep-libbz2 --disable-pcre2test-libreadline
    make -j"$JOBS"
    make install
    touch "$SRC/.pcre2_built"
}

# ------------------------------------------------------------------ 6. glib
build_glib() {
    cd "$SRC"
    [ -f .glib_built ] && { echo "==> glib 已完成"; return 0; }
    fetch glib-2.80.0.tar.xz \
        "https://download.gnome.org/sources/glib/2.80/glib-2.80.0.tar.xz" \
        "https://mirrors.tuna.tsinghua.edu.cn/gnome/sources/glib/2.80/glib-2.80.0.tar.xz"
    [ -d glib-2.80.0 ] || tar xf glib-2.80.0.tar.xz
    cd glib-2.80.0
    echo "==> 编译 glib"
    rm -rf _build
    meson setup _build \
        --cross-file "$CROSS_FILE" \
        --prefix="$SYSROOT" \
        --buildtype=release \
        --default-library=shared \
        -Dtests=false -Dnls=disabled \
        -Dselinux=disabled -Dlibmount=disabled
    ninja -C _build -j "$JOBS"
    ninja -C _build install
    touch "$SRC/.glib_built"
}

# ------------------------------------------------------------------ 7. pixman
build_pixman() {
    cd "$SRC"
    [ -f .pixman_built ] && { echo "==> pixman 已完成"; return 0; }
    fetch pixman-0.43.4.tar.gz \
        "https://cairographics.org/releases/pixman-0.43.4.tar.gz"
    [ -d pixman-0.43.4 ] || tar xf pixman-0.43.4.tar.gz
    cd pixman-0.43.4
    echo "==> 编译 pixman"
    rm -rf _build
    meson setup _build \
        --cross-file "$CROSS_FILE" \
        --prefix="$SYSROOT" \
        --buildtype=release \
        --default-library=shared \
        --wrap-mode=nodownload \
        -Dtests=disabled -Ddemos=disabled
    ninja -C _build -j "$JOBS"
    ninja -C _build install
    touch "$SRC/.pixman_built"
}

build_zlib
build_libffi
build_pcre2
build_glib
build_pixman

# ------------------------------------------------------------------ 8. libslirp
# QEMU 的 `-netdev user`（用户态 NAT）依赖 libslirp，而 QEMU 的 meson 只用
# pkg-config 找它、没有配 fallback，所以 meson 不会自动拉 subprojects/slirp.wrap。
# 这里自己按 wrap 里 pin 的 revision 编译一份装进 sysroot。
SLIRP_REV="26be815b86e8d49add8c9a8b320239b9594ff03d"

build_libslirp() {
    cd "$SRC"
    [ -f .slirp_built ] && { echo "==> libslirp 已完成"; return 0; }

    if [ ! -d libslirp/.git ]; then
        echo "==> 克隆 libslirp"
        git clone -q https://gitlab.freedesktop.org/slirp/libslirp.git libslirp
        (cd libslirp && git checkout -q "$SLIRP_REV")
    fi

    cd libslirp
    echo "==> 编译 libslirp"
    rm -rf _build
    meson setup _build \
        --cross-file "$CROSS_FILE" \
        --prefix="$SYSROOT" \
        --buildtype=release \
        --default-library=shared
    ninja -C _build -j "$JOBS"
    ninja -C _build install
    touch "$SRC/.slirp_built"
}

build_libslirp

# ------------------------------------------------------------------ 9. 自检
echo
echo "==================== 自检 ===================="
pkg-config --exists glib-2.0   && echo "glib-2.0   OK  ($(pkg-config --modversion glib-2.0))"   || { echo "glib-2.0   FAIL"; exit 1; }
pkg-config --exists pixman-1   && echo "pixman-1   OK  ($(pkg-config --modversion pixman-1))"   || { echo "pixman-1   FAIL"; exit 1; }
pkg-config --exists zlib       && echo "zlib       OK  ($(pkg-config --modversion zlib))"       || echo "zlib       WARN"
pkg-config --exists libffi     && echo "libffi     OK  ($(pkg-config --modversion libffi))"     || echo "libffi     WARN"
pkg-config --exists libpcre2-8 && echo "libpcre2-8 OK  ($(pkg-config --modversion libpcre2-8))" || echo "libpcre2-8 WARN"
pkg-config --exists slirp      && echo "slirp      OK  ($(pkg-config --modversion slirp))"      || echo "slirp      WARN（-netdev user 将不可用）"

echo
echo "sysroot 内的共享库："
ls -1 "$SYSROOT/lib"/*.so* 2>/dev/null | sed "s|$SYSROOT/||" || true

echo
echo "下一步：WORKDIR=$WORKDIR ./build_qemu.sh"
