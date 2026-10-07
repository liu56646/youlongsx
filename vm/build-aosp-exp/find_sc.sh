#!/bin/bash
OD=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
EXE=/root/vmbuild/qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64
# 找 initDispatchByName 符号地址
$OD -d "$EXE" 2>/dev/null | grep -n 'gles1_server_context_t13initDispatchByName' | head -2
