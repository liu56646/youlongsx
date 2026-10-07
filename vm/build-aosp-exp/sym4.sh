#!/bin/bash
A2L=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-addr2line
EXE=/root/vmbuild/qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64
for off in 0xCAC090 0xCAC080 0xCAC0a0 0xCAC070; do
  echo "--- $off ---"
  $A2L -e $EXE -f -C $off
done
