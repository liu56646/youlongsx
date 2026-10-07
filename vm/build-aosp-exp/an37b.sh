#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g37.log
echo "=== Abort message / Fatal signal / DEBUG 头部 ==="
grep -anE 'Abort message|Fatal signal|F DEBUG   : \*\*\*|F DEBUG   : pid:|F DEBUG   : signal|beginning of crash' "$L" | head -40
echo
echo "=== libc 相关 F 级日志 ==="
grep -anE 'F libc ' "$L" | head -30
