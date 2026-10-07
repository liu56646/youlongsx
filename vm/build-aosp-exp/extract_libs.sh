#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
NM=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm

mkdir -p /tmp/hwclibs
debugfs -R 'dump /hw/hwcomposer.ranchu.so /tmp/hwclibs/hwcomposer.ranchu.so' vendor_dev.img >/dev/null 2>&1
debugfs -R 'dump /hw/android.hardware.graphics.mapper@3.0-impl-ranchu.so /tmp/hwclibs/mapper30-impl-ranchu.so' vendor_dev.img >/dev/null 2>&1
debugfs -R 'dump /bin/hw/android.hardware.graphics.composer@2.3-service /tmp/hwclibs/composer-service' vendor_dev.img >/dev/null 2>&1
ls -la /tmp/hwclibs
for f in /tmp/hwclibs/*; do
    echo "--- $f : total syms=$($NM "$f" 2>/dev/null | wc -l) funcs=$($NM "$f" 2>/dev/null | grep -c ' [tT] ') ---"
done
