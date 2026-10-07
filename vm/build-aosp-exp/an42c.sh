#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g42.log
echo "=== zygote 启动/退出记录 ==="
grep -anE "starting service 'zygote'|Service 'zygote'.*(exited|signal)|Exit zygote|system server.* exited|system server has exited" "$L" | tail -20
echo
echo "=== AndroidRuntime FATAL / 异常 ==="
grep -anE 'AndroidRuntime|FATAL EXCEPTION|E AndroidRuntime|Process: ' "$L" | tail -20
echo
echo "=== SystemServer / PackageManagerService 相关 ==="
grep -anE 'SystemServer|PackageManager|package_native|Watchdog' "$L" | tail -20
echo
echo "=== 最后 15 行 ==="
tail -15 "$L"
