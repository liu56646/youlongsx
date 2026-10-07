#!/bin/bash
RO=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf
EXE=/root/vmbuild/qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64
echo "=== 段头 .text ==="
$RO -S $EXE 2>/dev/null | grep -E '\.text|\.text\s' | head -3
echo "=== 程序头 LOAD ==="
$RO -l $EXE 2>/dev/null | grep -A1 'LOAD' | head -12
