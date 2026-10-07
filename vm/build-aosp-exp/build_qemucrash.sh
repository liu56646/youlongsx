#!/usr/bin/env bash
# 编宿主侧 QEMU 崩溃捕获库（设备是 Android 16/arm64，用 NDK android-30 也兼容）
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp
NDK=/root/vmbuild/android-ndk-r28
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang"
"$CC" -shared -fPIC -O1 -g -o libqemucrash.so qemucrash.c
file libqemucrash.so
ls -la libqemucrash.so
