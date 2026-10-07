#!/bin/bash
OD=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
EXE=/root/vmbuild/qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64
$OD -d "$EXE" --start-address=0xCABFE0 --stop-address=0xCAC040 2>&1 | tail -32
echo "=== 当前源码 1025-1045 行 ==="
sed -n '1025,1045p' /root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.cpp
echo "=== 当前源码 45-60 行 ==="
sed -n '45,60p' /root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.cpp
