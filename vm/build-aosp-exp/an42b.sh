#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g42.log
echo "guest_last_time=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' "$L" | tail -1)"
echo "JNI_FatalError=$(grep -ac 'JNI FatalError' "$L")  zygote_starts=$(grep -ac "starting service 'zygote'" "$L")  signal6=$(grep -ac 'received signal 6' "$L")"
echo "boot_completed=$(grep -ac 'boot_completed' "$L")  bootanim_stop=$(grep -ac 'bootanim.*exited' "$L")"
echo
echo "=== 关键里程碑 ==="
grep -anE 'boot_completed|SystemServer|ActivityManager: |dex2oat64: |ZygoteInit took|package_native' "$L" | tail -10
echo
echo "=== 最近 6 行 ==="
tail -6 "$L"
