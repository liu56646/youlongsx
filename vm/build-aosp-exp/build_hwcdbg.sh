#!/usr/bin/env bash
# 编译 LD_PRELOAD 崩溃捕获库（guest 为 Android 11 / arm64，用 NDK android-30）
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp

NDK=/root/vmbuild/android-ndk-r28
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang"

[ -x "$CC" ] || { echo "找不到 clang: $CC" >&2; exit 1; }

"$CC" -shared -fPIC -O1 -g -o libhwcdbg.so hwcdbg.c
echo "--- built ---"
file libhwcdbg.so
ls -la libhwcdbg.so
echo "--- symbols ---"
"$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm" -D libhwcdbg.so 2>/dev/null | head -20
