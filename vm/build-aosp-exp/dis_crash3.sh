#!/bin/bash
OD=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
EXE=/root/vmbuild/qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64
$OD -d "$EXE" --start-address=0xCABDC0 --stop-address=0xCABE20 2>&1 | tail -40
