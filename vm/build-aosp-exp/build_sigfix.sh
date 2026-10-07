#!/bin/bash
# 用 NDK 编 libsigfix.so（LD_PRELOAD 用）
cd /tmp
CLANG=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android28-clang
cp /mnt/k/youlongsx/vm/build-aosp-exp/libsigfix.c /tmp/libsigfix.c
$CLANG -O2 -shared -fPIC -o /tmp/libsigfix.so /tmp/libsigfix.c -ldl
ls -la /tmp/libsigfix.so
