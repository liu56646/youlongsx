#!/bin/bash
cd /root/vmbuild
EXE=qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64
RO=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf
echo "=== NEEDED ==="
$RO -d $EXE | grep NEEDED
echo "=== libqemucrash 相关 ==="
grep -rn 'libqemucrash\|qemucrash\|crash.c' /mnt/k/youlongsx/vm/engine/scripts/build_qemu_aosp.sh 2>/dev/null | head
echo "=== 是否有 LD_PRELOAD 设置 ==="
grep -rn 'LD_PRELOAD' /mnt/k/youlongsx/vm/engine/scripts/build_qemu_aosp.sh /mnt/k/youlongsx/vm/build-aosp-exp/d1a.sh /mnt/k/youlongsx/vm/build-aosp-exp/d1c.sh 2>/dev/null | head
