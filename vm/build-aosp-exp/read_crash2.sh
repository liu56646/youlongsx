#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
e2fsck -fy meta_bt.img >/dev/null 2>&1 || true
echo "=== /metadata ==="
debugfs -R 'ls -l /' meta_bt.img 2>/dev/null | tail -5
echo "=== ANDROID_LOG_ASSERT 命中 ==="
debugfs -R 'cat /hwc_crash.log' meta_bt.img 2>/dev/null | grep -n -A8 'ANDROID_LOG_ASSERT' | head -80
echo "=== crash log 头部（到 maps 前）==="
debugfs -R 'cat /hwc_crash.log' meta_bt.img 2>/dev/null | sed -n '1,/--- maps ---/p' | head -140
echo "=== sampler 日志尾部 ==="
debugfs -R 'cat /hwcbt.log' meta_bt.img 2>/dev/null | tail -100
