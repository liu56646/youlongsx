#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g36.log
echo "=== 所有 signal 6 / 6 / 退出 ==="
grep -anE 'received signal 6|received signal 9|exited with status|Fatal signal' "$L" | tail -30
echo
echo "=== zygote 相关全部行 ==="
grep -anE 'zygote' "$L" | tail -25
echo
echo "=== iorapd 相关全部行 ==="
grep -anE 'iorapd' "$L" | tail -15
echo
echo "=== 启动里程碑 ==="
grep -anE "starting service 'zygote'|starting service 'system_server'|system_server|boot_completed|Boot completed|bootanim|starting service 'surfaceflinger'" "$L" | tail -20
echo
echo "=== 最后 25 行 ==="
tail -25 "$L"
