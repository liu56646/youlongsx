#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g41.log
echo "=== JNI FatalError 行 + 前后 12 行 ==="
N=$(grep -an 'JNI FatalError' "$L" | head -1 | cut -d: -f1)
echo "命中行号: $N"
if [ -n "$N" ]; then
    sed -n "$((N-12)),$((N+4))p" "$L"
fi
echo
echo "=== 所有 F 级 / abort / Whited 相关 ==="
grep -anE 'F zygote|F libc |F DEBUG|Not whitelisted|FatalError|Abort message' "$L" | head -20
