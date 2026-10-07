#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
NM=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm

echo "--- /lib64/hw ---"
debugfs -R 'ls /lib64/hw' vendor_dev.img 2>/dev/null | tr ' ' '\n' | grep -iE 'ranchu|mapper|composer' | head

mkdir -p /tmp/hwclibs
debugfs -R 'dump /lib64/hw/hwcomposer.ranchu.so /tmp/hwclibs/hwcomposer.ranchu.so' vendor_dev.img >/dev/null 2>&1
debugfs -R 'dump /lib64/hw/android.hardware.graphics.mapper@3.0-impl-ranchu.so /tmp/hwclibs/mapper30-impl-ranchu.so' vendor_dev.img >/dev/null 2>&1
ls -la /tmp/hwclibs

echo "--- dynsym counts ---"
for f in /tmp/hwclibs/*; do
    echo "$f: dynsym=$($NM -D "$f" 2>/dev/null | wc -l)"
done
