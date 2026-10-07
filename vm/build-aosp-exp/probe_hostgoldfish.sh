#!/usr/bin/env bash
# 第 1 步侦察：用 NDK 工具链单独语法检查 HostGoldfishPipe.cpp，收集依赖缺口
Q=/root/vmbuild/qemu-aosp
T=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64
cd "$Q" || exit 1
"$T/bin/aarch64-linux-android28-clang++" -std=c++17 -fsyntax-only \
  -Iinclude \
  -Iandroid/android-emu \
  -Iandroid/emu/host-common/include \
  -Iandroid/android-emu-base/aemu \
  -Iandroid/android-emugl/host/include \
  android/android-emu/android/emulation/hostdevices/HostGoldfishPipe.cpp 2>&1 | head -30
echo "=== 该文件的 include 列表 ==="
grep -n '^#include' android/android-emu/android/emulation/hostdevices/HostGoldfishPipe.cpp
