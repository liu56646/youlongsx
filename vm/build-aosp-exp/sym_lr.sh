#!/bin/bash
cd /root/vmbuild
EXE=qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64
A2L=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-addr2line
echo "=== addr2line lr=0xCD3010 ==="
$A2L -e $EXE -f -C 0xCD3010
echo "=== 附近几个偏移 ==="
for off in 0xCD3000 0xCD3014 0xCD2ff0 0xCD3008; do
  echo "--- $off ---"
  $A2L -e $EXE -f -C $off
done
