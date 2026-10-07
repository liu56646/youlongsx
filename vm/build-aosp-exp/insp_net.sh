#!/usr/bin/env bash
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp
SYS=${1:-system_bt.img}
VEN=${2:-vendor.img}
echo "=== flags_health_check.rc (system) ==="
debugfs -R "cat /etc/init/flags_health_check.rc" "$SYS" 2>/dev/null || echo "(no such file)"
echo
echo "=== vendor init.ranchu.rc: dhcpclient_def / ranchu-net ==="
debugfs -R "cat /vendor/etc/init/hw/init.ranchu.rc" "$VEN" 2>/dev/null \
  | grep -n -B2 -A16 -e "service dhcpclient_def" -e "service ranchu-net" || echo "(not found)"
echo
echo "=== vendor: 谁触发 dhcpclient_def / qemu.networknamespace ==="
debugfs -R "cat /vendor/etc/init/hw/init.ranchu.rc" "$VEN" 2>/dev/null \
  | grep -n -B3 -A6 -e "dhcpclient_def" -e "networknamespace" || true
