#!/bin/bash
# 反汇编 exe 崩溃点 lr=0xCDB828 附近
OD=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
EXE=/root/vmbuild/qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64
echo "=== disassemble 0xCDB7c0-0xCDB870 ==="
$OD -d "$EXE" --start-address=0xCDB7c0 --stop-address=0xCDB870 2>&1 | tail -50
