#!/usr/bin/env bash
# 编 guest 侧轻量崩溃捕获库（Android 11 / arm64）
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp
NDK=/root/vmbuild/android-ndk-r28
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang"
"$CC" -shared -fPIC -O1 -g -o libcrashlite.so crashlite.c
file libcrashlite.so
ls -la libcrashlite.so
