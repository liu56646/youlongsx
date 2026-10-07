#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g42.log
echo "=== FATAL / Watchdog / System process / F 级 ==="
grep -anE 'FATAL|Watchdog|SYSTEM PROCESS|F AndroidRuntime|F SystemServer|E SystemServer|BOOT FAILURE|E Zygote' "$L" | tail -25
echo
echo "=== system_server 的 pid 与终止时刻（看间隔）==="
grep -anE 'Exit zygote because system server' "$L" | tail -12
echo
echo "=== 有没有 PackageManager 之后的进展（Scanning/Finished/Ready）==="
grep -anE 'PackageManager: .*(Scanning|Finished|Time to scan|Ready)|ActivityManager: (System ready|Start proc)|Displayed|PowerManagerService' "$L" | tail -15
echo
echo "=== 最后 10 行 ==="
tail -10 "$L"
