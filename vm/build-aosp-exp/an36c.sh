#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g36.log
echo "=== logcat 里崩溃相关（FATAL/abort/crash/DEBUG/signal）==="
grep -anE 'FATAL|Abort message|DEBUG   |crash_dump|tombstone|>>> |signal [0-9]+|backtrace:' "$L" | head -40
echo
echo "=== 回放到的 logcat tag 分布（前 30 个最常见的）==="
grep -aoE '^\[ *[0-9.]+\] [0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ [A-Z] [^:]+:' "$L" | sed 's/.*[A-Z] //' | sort | uniq -c | sort -rn | head -30
echo
echo "=== 含 zygote/iorapd tag 的 logcat 行 ==="
grep -aE 'zygote|iorapd|audioserver|artd' "$L" | grep -aE '^\[ *[0-9.]+\] 0' | tail -20
