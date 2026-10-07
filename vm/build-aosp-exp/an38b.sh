#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g38.log
echo "=== F libc / F DEBUG pid / Abort message（全部）==="
grep -anE 'F libc  |F DEBUG   : pid:|F DEBUG   : Abort message|F fatal  |F DEBUG   : name:' "$L" | head -40
echo
echo "=== ril-daemon 是否还崩（应消失）==="
grep -acE 'libgoldfish-ril' "$L"
echo
echo "=== zygote 相关 F 级 / 异常 ==="
grep -anE 'zygote|Zygote' "$L" | grep -aE 'F |E |Abort|Fatal|Watchdog|gc ' | head -20
echo
echo "=== 含 'Abort message' 的行（完整）==="
grep -anE 'Abort message' "$L" | head -10
