#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
e2fsck -fy meta_bt.img >/dev/null 2>&1 || true
echo "=== /metadata ==="
debugfs -R 'ls -l /' meta_bt.img 2>/dev/null
echo "=== hwc.pid ==="
debugfs -R 'cat /hwc.pid' meta_bt.img 2>/dev/null
echo "=== hwc_crash.log ==="
debugfs -R 'cat /hwc_crash.log' meta_bt.img 2>/dev/null
echo "=== hwcbt.log ==="
debugfs -R 'cat /hwcbt.log' meta_bt.img 2>/dev/null
