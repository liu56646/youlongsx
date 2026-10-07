#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g36.log
echo "=== FATAL / Abort / CHECK / 崩溃块 ==="
grep -anE 'FATAL|Abort message|CHECK failed|Fatal signal|beginning of crash|*** *** ***|SIGABRT|signal 6' "$L" | head -40
echo
echo "=== audioserver / audio-hal 相关 ==="
grep -anE 'audioserver|audio-hal|AudioFlinger' "$L" | tail -20
echo
echo "=== 是否出现 logcat 回放（switch to main/events 等）==="
grep -acE '^\[ *[0-9.]+\] --------- switch to' "$L"
echo "=== logcat 行的最早/最晚时间戳 ==="
grep -aoE '0[0-9]-[0-9]{2} [0-9:.]+' "$L" | head -2
grep -aoE '0[0-9]-[0-9]{2} [0-9:.]+' "$L" | tail -2
echo
echo "=== system_server / system_server 相关（logcat）==="
grep -anE 'system_server|SystemServer|boot_progress|Boot is finished|ActivityManager' "$L" | tail -20
