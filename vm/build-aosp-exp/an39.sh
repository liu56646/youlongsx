#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g39.log
echo "=== JNI FatalError / Not whitelisted 出现次数 ==="
grep -ac 'JNI FatalError' "$L"
grep -anE 'JNI FatalError|Not whitelisted' "$L" | head -6
echo
echo "=== zygote 启动次数 / 时间点 ==="
grep -acE "starting service 'zygote'" "$L"
grep -anE "starting service 'zygote'" "$L" | tail -6
echo
echo "=== 任何 signal 6 ==="
grep -acE 'received signal 6' "$L"
echo
echo "=== boot_completed / system_server 迹象 ==="
grep -anE 'boot_completed|SystemServer|boot_progress|ActivityManager: |ZygoteInit' "$L" | tail -12
echo
echo "=== 最后时间 ==="
grep -aoE '^\[ *[0-9]+\.[0-9]+\]' "$L" | tail -1
echo "=== 最后 8 行 ==="
tail -8 "$L"
