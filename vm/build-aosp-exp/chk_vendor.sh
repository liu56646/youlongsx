#!/bin/bash
echo "=== QEMU goldfish_pipe.c android_pipe_guest_open ==="
grep -n 'android_pipe_guest_open\|android_pipe_guest_close' /root/vmbuild/qemu-aosp/hw/misc/goldfish_pipe.c | head -5
echo "=== vendor build.prop via debugfs (try several paths) ==="
for p in /build.prop /etc/build.prop /vendor/build.prop /vendor/etc/build.prop; do
  echo "-- $p"
  debugfs -R "cat $p" /root/vmbuild/vendor30_ext4.img 2>/dev/null | grep -i 'gralloc' | head -3
done
echo "=== vendor root listing ==="
debugfs -R 'ls -p /' /root/vmbuild/vendor30_ext4.img 2>/dev/null | head -30
echo "=== ramdisk build script ==="
grep -rln 'ramdisk_probe' /mnt/k/youlongsx/vm 2>/dev/null | head
