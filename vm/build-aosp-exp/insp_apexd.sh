#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
echo "=== apexd 是否操作 updatable_crashing ==="
rm -f /tmp/apexd
debugfs -R "dump -p /system/bin/apexd /tmp/apexd" system_bt.img 2>/dev/null || true
if [ -s /tmp/apexd ]; then
  strings -n 5 /tmp/apexd | grep -i -e updatable_crashing -e "Attempting a revert" -e "is crashing" | head -10
else
  echo "(no apexd binary dumped)"
fi
echo
echo "=== 找 init.ranchu-net.sh ==="
for p in /bin/init.ranchu-net.sh /init.ranchu-net.sh /vendor/bin/init.ranchu-net.sh /etc/init/hw/init.ranchu-net.sh; do
  n=$(debugfs -R "stat $p" vendor_bt2.img 2>/dev/null | grep -c "Type: regular" || true)
  echo "  $p -> $n"
done
