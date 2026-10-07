#!/bin/bash
OD=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
EXE=/root/vmbuild/qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64
$OD -d "$EXE" > /tmp/exe.dis 2>/tmp/exe.err
echo "lines: $(wc -l < /tmp/exe.dis)"
echo "err: $(head -3 /tmp/exe.err)"
grep -n 'cdb82' /tmp/exe.dis | head -5
