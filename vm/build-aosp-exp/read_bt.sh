#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
debugfs -R 'cat /hwcbt.log' meta_bt.img 2>/dev/null > /tmp/hwcbt.log
echo "lines=$(wc -l < /tmp/hwcbt.log)"
echo "--- SAMPLE count ---"
grep -c 'SAMPLE n=' /tmp/hwcbt.log
echo "--- all debuggerd lines ---"
grep -n 'debuggerd' /tmp/hwcbt.log | head -30
echo "--- first SAMPLE block (40 lines) ---"
grep -n -A40 'SAMPLE n=0' /tmp/hwcbt.log | head -50
echo "--- tail 40 ---"
tail -40 /tmp/hwcbt.log
