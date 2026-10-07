#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
V=${1:-vendor_bt2.img}
echo "=== $V : /etc/init/hw/init.ranchu.rc (network 相关) ==="
debugfs -R "cat /etc/init/hw/init.ranchu.rc" "$V" 2>/dev/null > /tmp/ranchu.rc
wc -l /tmp/ranchu.rc
echo "--- service dhcpclient_def ---"
grep -n -A14 "service dhcpclient_def" /tmp/ranchu.rc || echo none
echo "--- service ranchu-net ---"
grep -n -A14 "service ranchu-net" /tmp/ranchu.rc || echo none
echo "--- 所有提到 dhcp / networknamespace 的行 ---"
grep -n -e dhcp -e networknamespace /tmp/ranchu.rc || true
