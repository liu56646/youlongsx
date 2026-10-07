#!/usr/bin/env bash
#
# 装一份自包含的 Python 2.7，供 AOSP QEMU（底子 QEMU 2.12）构建使用。
#
# 为什么需要它：AOSP QEMU 的 configure 明确拒绝 Python 3
#   ERROR: Cannot use '...', Python 2.6 or later is required.
#          Note that Python 3 or later is not yet supported.
# 而 Ubuntu 24.04 的官方源里 Python 2 已被彻底移除，只能自己编一份。
#
# 装在 /opt/py2，不动系统 python3。
#
set -euo pipefail

PREFIX=/opt/py2
WORK=/root/vmbuild
TGZ="$WORK/Python-2.7.18.tgz"
DIR="$WORK/Python-2.7.18"

if [ -x "$PREFIX/bin/python2.7" ]; then
    echo "已存在：$("$PREFIX/bin/python2.7" -V 2>&1)"
    exit 0
fi

mkdir -p "$WORK"
cd "$WORK"

if [ ! -s "$TGZ" ]; then
    echo "==> 下载 Python 2.7.18"
    for u in \
        https://mirrors.huaweicloud.com/python/2.7.18/Python-2.7.18.tgz \
        https://registry.npmmirror.com/-/binary/python/2.7.18/Python-2.7.18.tgz \
        https://www.python.org/ftp/python/2.7.18/Python-2.7.18.tgz
    do
        echo "    $u"
        if curl -fL --connect-timeout 20 --max-time 300 -o "$TGZ" "$u"; then
            break
        fi
    done
fi
[ -s "$TGZ" ] || { echo "!! 下载失败" >&2; exit 1; }

echo "==> 解压"
rm -rf "$DIR"
tar xzf "$TGZ" -C "$WORK"
cd "$DIR"

echo "==> configure"
# -fcommon：GCC 10 起默认 -fno-common，这年代的代码会报重复定义
CFLAGS="-O2 -fcommon -Wno-error -Wno-implicit-function-declaration" \
    ./configure --prefix="$PREFIX" --enable-unicode=ucs4 --with-ensurepip=no

echo "==> make -j$(nproc)"
make -j"$(nproc)" 2>&1 | tail -5
make install

echo "==> 结果"
"$PREFIX/bin/python2.7" -V
echo "Python 2.7 就绪：$PREFIX/bin/python2.7"
