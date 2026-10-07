#!/bin/bash
OD=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
EXE=/root/vmbuild/qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64
# 反汇编 exe 偏移 0xCDB7c0-0xCDB860
$OD -d $EXE --start-address=$((0x5b806a4000 + 0xCDB7c0)) --stop-address=$((0x5b806a4000 + 0xCDB860)) 2>/dev/null | tail -40
