#!/usr/bin/env bash
# 抓 flags_health_check / updatable_crashing / goldfish ranchu 网络相关源码
set -e
D=/mnt/k/youlongsx/vm/build-aosp-exp/src11
mkdir -p "$D"; cd "$D"
SC='https://cdn.jsdelivr.net/gh/aosp-mirror/platform_system_core@android-11.0.0_r48'
GH='https://cdn.jsdelivr.net/gh/aosp-mirror/device_generic_goldfish@android-11.0.0_r48'
fetch() { # fetch <url> <out>
  if curl -fsSL "$1" -o "$2"; then echo "OK $2 $(stat -c %s "$2")"; else echo "FAIL $2"; fi
}
fetch "$SC/init/service.cpp"             service.cpp
fetch "$SC/init/flags_health_check.cpp"  flags_health_check.cpp
fetch "$SC/init/flags_health_check.rc"   flags_health_check.rc
fetch "$GH/init.ranchu.rc"               init.ranchu.rc
fetch "$GH/init.ranchu-net.sh"           init.ranchu-net.sh
echo "=== updatable_crashing 触发点 ==="
grep -n "updatable_crashing" service.cpp flags_health_check.cpp flags_health_check.rc 2>/dev/null || true
echo "=== dhcpclient / ranchu-net 定义 ==="
grep -n -A14 "service dhcpclient_def\|service ranchu-net" init.ranchu.rc 2>/dev/null || true
