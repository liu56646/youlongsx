#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
e2fsck -fy meta_bt.img >/dev/null 2>&1 || true
echo "=== g38 最后时间 ==="
grep -aoE '^\[ *[0-9]+\.[0-9]+\]' g38.log | tail -1
echo "=== 里程碑 ==="
grep -anE "starting service '(zygote|iorapd|vendor.ril-daemon|surfaceflinger|bootanim)'|received signal 6|boot_completed" g38.log | tail -20
echo
echo "=== /metadata 文件 ==="
debugfs -R 'ls -l /' meta_bt.img 2>/dev/null | grep -E 'crash|hwcbt|hwc.pid'
echo
echo "=== crash.log：ASSERT 消息 ==="
debugfs -R 'cat /crash.log' meta_bt.img 2>/dev/null | grep -aE 'ANDROID_LOG_ASSERT|tag=|cond=' | head -30
echo
echo "=== crash.log：各崩溃块头部 ==="
debugfs -R 'cat /crash.log' meta_bt.img 2>/dev/null | grep -aE '^comm=|^signal=|^pc=' | head -40
echo
echo "=== hwcbt.log 尾部（状态）==="
debugfs -R 'cat /hwcbt.log' meta_bt.img 2>/dev/null | tail -6
