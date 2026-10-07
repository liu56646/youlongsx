#!/usr/bin/env bash
# 编译静态探针（不依赖 bionic，内核可直接当 rdinit 执行）
set -e
cd "$(dirname "$0")"
CC=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android28-clang
"$CC" -static -O2 -fno-pie -no-pie dumper.c -o dumper
file dumper
ls -la dumper
