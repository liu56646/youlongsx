#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
debugfs -R 'cat /hwcbt.log' meta_bt.img 2>/dev/null > /tmp/hwcbt.log
echo "lines=$(wc -l < /tmp/hwcbt.log)"
echo "--- SAMPLE headers ---"
grep -n 'SAMPLE n=' /tmp/hwcbt.log
echo "--- PID / SCAN / GONE ---"
grep -n -E 'PID it=|SCAN it=|GONE' /tmp/hwcbt.log | head -80
echo "--- debuggerd ---"
grep -n -A30 'debuggerd -b' /tmp/hwcbt.log | head -80
echo "--- non-maps non-tid lines ---"
grep -v -E '^[0-9a-f]{6,}-[0-9a-f]{6,} ' /tmp/hwcbt.log | grep -v -E '^tid=' | head -100
