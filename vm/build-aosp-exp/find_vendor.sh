#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
for v in vendor*.img system_ext.img product.img; do
  [ -f "$v" ] || continue
  n=$(debugfs -R "cat /vendor/etc/init/hw/init.ranchu.rc" "$v" 2>/dev/null | grep -c dhcpclient_def || true)
  m=$(debugfs -R "cat /etc/init/hw/init.ranchu.rc" "$v" 2>/dev/null | grep -c dhcpclient_def || true)
  echo "$v  vendor_path=$n  etc_path=$m"
done
