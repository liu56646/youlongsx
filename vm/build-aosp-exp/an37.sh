#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g37.log
echo "=== 里程碑（service 启动 / signal 6 / boot_completed）==="
grep -anE "starting service '(zygote|surfaceflinger|bootanim|iorapd|system_server|vendor\.hwcomposer-2-3)'|received signal 6|boot_completed|Boot completed" "$L" | tail -25
echo
echo "=== 最后时间 ==="
grep -aoE '^\[ *[0-9]+\.[0-9]+\]' "$L" | tail -1
echo
echo "=== 最后 10 行 ==="
tail -10 "$L"
echo
echo "=== logcat 行数（回放是否在走）==="
grep -acE '^\[ *[0-9.]+\] [0-9]{2}-[0-9]{2} ' "$L"
grep -aoE '[0-9]{2}-[0-9]{2} [0-9:.]+' "$L" | tail -1
