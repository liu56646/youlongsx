#!/usr/bin/env bash
BIN=/mnt/k/youlongsx/vm/engine/src/main/cpp/prebuilt/qemu-aosp/arm64-v8a/qemu-system-aarch64
NDK=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin
echo "=== 二进制里的 goldfish_address_space 相关符号 ==="
"$NDK/llvm-nm" "$BIN" 2>/dev/null | grep -iE 'goldfish_address_space|address_space_device_init|address_space_set_hw_funcs|address_space_set_service_ops' | head -30
echo
echo "=== 设备类型注册（init 函数名）==="
"$NDK/llvm-nm" "$BIN" 2>/dev/null | grep -iE 'do_qemu_init.*(address_space|gpex)' | head -10
echo
echo "=== 字符串：设备名 ==="
strings -a "$BIN" | grep -xE 'goldfish_address_space|goldfish_address_space_control|gpex' | sort -u | head
echo
echo "=== android_address_space_device.cpp 是否编进（qemu_android_address_space_device_init）==="
"$NDK/llvm-nm" -C "$BIN" 2>/dev/null | grep -iE 'qemu_android_address_space_device_init|address_space_device_init' | head
