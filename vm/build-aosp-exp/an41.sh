#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g41.log
echo "JNI_FatalError_count=$(grep -ac 'JNI FatalError' "$L")"
echo "zygote_starts=$(grep -ac "starting service 'zygote'" "$L")"
echo "signal6_count=$(grep -ac 'received signal 6' "$L")"
echo "not_whitelisted_count=$(grep -ac 'Not whitelisted' "$L")"
echo
echo "=== zygote / system_server / ZygoteInit / boot ==="
grep -anE "starting service 'zygote'|ZygoteInit took|SystemServer|boot_completed|ActivityManager: |Process: |>>> START" "$L" | tail -20
echo
echo "=== 最后时间 ==="
grep -aoE '^\[ *[0-9]+\.[0-9]+\]' "$L" | tail -1
echo "=== 最后 8 行 ==="
tail -8 "$L"
