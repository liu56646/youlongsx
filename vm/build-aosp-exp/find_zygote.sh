#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
for f in /etc/init/hw/init.zygote64.rc /etc/init/hw/init.zygote64_32.rc /etc/init/hw/init.zygote32.rc /etc/init/hw/init.rc; do
    echo "--- $f ---"
    debugfs -R "cat $f" system_cur.img 2>/dev/null | grep -n -A12 'service zygote' | head -25
done
echo "=== /system/etc/init/hw 下所有 init.zygote* ==="
debugfs -R 'ls /etc/init/hw' system_cur.img 2>/dev/null | tr ' ' '\n' | grep -i zygote
