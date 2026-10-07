#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g37.log
echo "=== 所有 crash 块头部（pid/name）与 Abort message ==="
grep -anE 'F DEBUG   : pid:|F DEBUG   : Abort message|F DEBUG   : signal' "$L" | sed 's/^\([0-9]*\):/\1 /' | head -60
echo
echo "=== 专门找 zygote 相关（app_process / name: main）==="
grep -anE 'app_process64|name: main ' "$L" | head -10
echo
echo "=== 专门找 iorapd ==="
grep -anE 'iorapd' "$L" | grep -aE 'DEBUG|Fatal signal|Abort|name:' | head -10
