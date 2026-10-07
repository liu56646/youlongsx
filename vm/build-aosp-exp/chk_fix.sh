#!/bin/bash
cd /root/vmbuild
NM=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm
OD=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
echo "=== .o symbols ==="
$NM qemu-aosp-build-arm64-v8a/util/qemu-thread-posix.o | grep -iE 'setup_callback|trampoline|thread_setup' | head
echo "=== .o disasm register_setup_callback ==="
$OD -d qemu-aosp-build-arm64-v8a/util/qemu-thread-posix.o | grep -A30 'qemu_thread_register_setup_callback' | head -35
echo "=== .o disasm trampoline (setup calls) ==="
$OD -d qemu-aosp-build-arm64-v8a/util/qemu-thread-posix.o | grep -B2 -A40 'qemu_thread_trampoline' | head -60
