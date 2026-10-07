#!/usr/bin/env bash
# 把静态探针塞进已解开的 ramdisk，重新打包成 initramfs
set -e
cd /tmp/rd3
cp -f /mnt/k/youlongsx/vm/build-aosp-exp/dumper ./dumper
chmod 755 ./dumper
find . | cpio -o -H newc 2>/dev/null | gzip -9 > /mnt/k/youlongsx/vm/build-aosp-exp/ramdisk_dump.img
ls -la /mnt/k/youlongsx/vm/build-aosp-exp/ramdisk_dump.img
