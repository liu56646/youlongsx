#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g42.log
echo "JNI_FatalError_count=$(grep -ac 'JNI FatalError' "$L")"
echo "zygote_starts=$(grep -ac "starting service 'zygote'" "$L")"
echo "signal6=$(grep -ac 'received signal 6' "$L")"
echo "boot_completed=$(grep -ac 'boot_completed' "$L")"
echo
echo "=== FatalError / Not whitelisted 行 ==="
grep -anE 'JNI FatalError|Not whitelisted' "$L" | head -5
echo
echo "=== 里程碑 ==="
grep -anE "starting service 'zygote'|ZygoteInit took|>>> START|SystemServer|boot_completed|ActivityManager: " "$L" | tail -12
echo
echo "=== 最后时间 ==="
grep -aoE '^\[ *[0-9]+\.[0-9]+\]' "$L" | tail -1
echo "=== 最后 8 行 ==="
tail -8 "$L"
