#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
echo "=== init.ranchu-net.sh (vendor_bt2.img) 里与 dhcpclient 相关的行 ==="
debugfs -R "cat /etc/init/hw/init.ranchu-net.sh" vendor_bt2.img 2>/dev/null > /tmp/rnet.sh \
  || debugfs -R "cat /vendor/bin/init.ranchu-net.sh" vendor_bt2.img 2>/dev/null > /tmp/rnet.sh || true
wc -l /tmp/rnet.sh 2>/dev/null || echo "(no script)"
grep -n -e dhcpclient -e eth0 -e networknamespace /tmp/rnet.sh 2>/dev/null || true
echo
echo "=== service.cpp: Stop()/SVC_DISABLED（验证 ctl.stop 能否停掉自动重启） ==="
grep -n -A12 "^void Service::Stop" src11/service.cpp 2>/dev/null | head -20 || true
grep -n "SVC_DISABLED" src11/service.cpp 2>/dev/null | head -20 || true
