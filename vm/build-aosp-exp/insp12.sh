#!/usr/bin/env bash
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp
IMG=${1:-system_bt.img}
echo "=== /bin/am script ==="
debugfs -R "cat /bin/am" "$IMG" 2>/dev/null || true
echo "=== /bin/app_process (symlink?) ==="
debugfs -R "stat /bin/app_process" "$IMG" 2>/dev/null | head -12 || true
echo "=== init.environ.rc ==="
debugfs -R "cat /init.environ.rc" "$IMG" 2>/dev/null || true
echo "=== where is the injected libcrashlite ==="
for p in /system/lib64/libcrashlite.so /lib64/libcrashlite.so; do
  echo "-- $p"; debugfs -R "stat $p" "$IMG" 2>/dev/null | head -4 || true
done
echo "=== /system subdirs ==="
debugfs -R "ls -l /system" "$IMG" 2>/dev/null | head -30 || true
echo "=== /bin/dalvikvm ==="
debugfs -R "cat /bin/dalvikvm" "$IMG" 2>/dev/null || true
echo "=== /etc/init/hw/init.zygote64.rc ==="
debugfs -R "cat /etc/init/hw/init.zygote64.rc" "$IMG" 2>/dev/null || true
