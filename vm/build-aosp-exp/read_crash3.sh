#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
e2fsck -fy meta_bt.img >/dev/null 2>&1 || true
debugfs -R 'cat /hwc_crash.log' meta_bt.img 2>/dev/null > /tmp/crash.log
echo "crash.log lines=$(wc -l < /tmp/crash.log)"
echo "=== [ABORT] / CRASH 头 / LOG 统计 ==="
grep -n -E '\[ABORT\]|########## HWC CRASH|^\[LOG' /tmp/crash.log | head -40
echo "=== 非 maps 行（头 220）==="
grep -vE '^[0-9a-f]{6,}-[0-9a-f]{6,} ' /tmp/crash.log | head -220
echo "=== 崩溃块前后（LOG 尾部 60 行）==="
grep -vE '^[0-9a-f]{6,}-[0-9a-f]{6,} ' /tmp/crash.log | tail -60
