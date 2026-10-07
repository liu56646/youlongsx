#!/usr/bin/env bash
L=/mnt/k/youlongsx/vm/build-aosp-exp/g47.log
echo "=== TOP: 各 service 被 \"starting\" 的次数 ==="
grep -a -o "starting service '[^']*'" "$L" | sed "s/starting service //" | sort | uniq -c | sort -rn | head -15
echo
echo "=== TOP: SVC_EXEC 被执行的次数（按名字） ==="
grep -a -o "SVC_EXEC service 'exec [0-9]\+ (/[^)]*)" "$L" | sed "s/SVC_EXEC service 'exec [0-9]\+ (//" | sort | uniq -c | sort -rn | head -10
echo
echo "=== updatable 进程名单 ==="
grep -a -o "updatable process '[^']*'" "$L" | sort | uniq -c | sort -rn | head -10
echo
echo "=== dhcpclient 家族各自被启动次数 ==="
grep -a -c "starting service 'dhcpclient_rtr'" "$L" || true
grep -a -c "starting service 'dhcpclient_wifi'" "$L" || true
grep -a -c "starting service 'dhcpclient_def'" "$L" || true
echo
echo "=== 是否有 eth0 / 网络接口相关 ==="
grep -a -o -m5 "eth0[^ ]*" "$L" || true
