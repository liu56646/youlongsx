#!/usr/bin/env bash
#
# 把已构建好的 QEMU 静态产物打包并拷入 Android 工程，供 libvmengine.so 链接。
#
# 背景：QEMU 的 meson 把 libcommon / libqemu-aarch64-softmmu 直接以对象文件形式
# 喂给最终可执行体，并不产出 .a。这里依据 build.ninja 里
# `qemu-system-aarch64` 的真实链接输入，精确还原出等价静态库。
#
#   使用：QEMU_BUILD=<构建目录> WORKDIR=~/vmbuild ./package_qemu_static.sh
#
set -euo pipefail

WORKDIR="${WORKDIR:-$HOME/vmbuild}"
QEMU_BUILD="${QEMU_BUILD:-$WORKDIR/qemu-build-arm64-v8a}"
NDK_VER="${NDK_VER:-r28}"
SYSROOT="${SYSROOT:-$WORKDIR/sysroot-arm64}"
DST="$(cd "$(dirname "$0")/.." && pwd)/src/main/cpp/prebuilt/qemu/arm64-v8a"
AR="$WORKDIR/android-ndk-$NDK_VER/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"

[ -d "$QEMU_BUILD" ] || { echo "找不到构建目录：$QEMU_BUILD" >&2; exit 1; }
[ -x "$AR" ] || { echo "找不到 llvm-ar：$AR" >&2; exit 1; }

cd "$QEMU_BUILD"
mkdir -p "$DST"

echo "==> 从 build.ninja 提取 qemu-system-aarch64 的链接输入"
# ninja 里对象文件写在 build 行的输入侧（LINK_ARGS 只放 flags 与库）
awk '/^build qemu-system-aarch64: /{
        line = $0
        sub(/^build qemu-system-aarch64: c_LINKER /, "", line)
        sub(/ *\|.*$/, "", line)
        print line
        exit
     }' build.ninja > /tmp/qemu_link_inputs.txt

if [ ! -s /tmp/qemu_link_inputs.txt ]; then
    echo "!! 未能提取链接输入" >&2
    exit 2
fi

tr ' ' '\n' < /tmp/qemu_link_inputs.txt | grep -E '\.o$' > /tmp/qemu_link_objs.txt || true

# 静态库写在 LINK_ARGS 里（build 行只列对象文件）
awk '/^build qemu-system-aarch64: /{f=1}
     f && /LINK_ARGS = /{sub(/^ *LINK_ARGS = /, ""); print; exit}' build.ninja \
    | tr ' ' '\n' | grep -E '\.a$' | sort -u > /tmp/qemu_link_libs.txt

echo "    对象文件 $(wc -l < /tmp/qemu_link_objs.txt) 个"
echo "    静态库   $(wc -l < /tmp/qemu_link_libs.txt) 个"
echo "    静态库清单："
sed 's/^/      /' /tmp/qemu_link_libs.txt

# ---------------------------------------------------------------- 打包对象
echo "==> 打包对象文件 → libqemu_objs.a"
rm -f "$DST/libqemu_objs.a"
# 分批喂给 ar，避免命令行超长
xargs -a /tmp/qemu_link_objs.txt -n 200 "$AR" rcs "$DST/libqemu_objs.a"
"$AR" s "$DST/libqemu_objs.a"

# ---------------------------------------------------------------- 拷贝静态库
# QEMU 的 meson 产出的是**瘦归档**（thin archive），以 `!<thin>` 开头，
# 成员只是相对路径；只拷 .a 会导致链接器在别的机器上找不到成员对象。
# 这里只对瘦归档做重打包，普通归档原样拷贝。
is_thin() {
    [ "$(head -c 7 "$1")" = "!<thin>" ]
}

repack_fat() {
    local archive="$1" out="$2"
    local dir base members
    dir="$(dirname "$archive")"
    base="$(basename "$archive")"
    members="$(cd "$dir" && "$AR" t "$base")" || return 1
    [ -z "$members" ] && return 1
    rm -f "$out"
    # shellcheck disable=SC2086
    (cd "$dir" && "$AR" rcs "$out" $members) || return 1
    "$AR" s "$out"
    return 0
}

echo "==> 拷贝静态库"
while read -r lib; do
    [ -f "$lib" ] || { echo "    缺失：$lib" >&2; continue; }
    dest="$DST/$(basename "$lib")"
    if is_thin "$lib"; then
        if repack_fat "$lib" "$dest"; then
            echo "    + $(basename "$lib")  （瘦归档→普通归档，$("$AR" t "$dest" | wc -l) 个成员）"
        else
            echo "    !! 重打包失败：$lib" >&2
        fi
    else
        cp -f "$lib" "$dest"
        echo "    + $(basename "$lib")  （普通归档，原样拷贝）"
    fi
done < /tmp/qemu_link_libs.txt

# ---------------------------------------------------------------- 汇总
echo
echo "==> $DST 内容"
ls -lh "$DST" | tail -n +2

echo
echo "完成。下一步在 CMakeLists.txt 里把这些库按 --start-group 顺序链接。"
