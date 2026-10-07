#!/system/bin/sh
M=/mnt/gmeta
mkdir -p $M
umount $M 2>/dev/null
setenforce 0
mount -t ext4 -o loop,ro,noload /data/local/tmp/meta.img $M || { echo META_MOUNT_FAIL; exit 1; }
cp -f $M/crash.log /data/local/tmp/gcrash.log
cp -f $M/hwc_crash.log /data/local/tmp/ghwc_crash.log 2>/dev/null
cp -f $M/hwcbt.log /data/local/tmp/ghwcbt.log 2>/dev/null
umount $M 2>/dev/null
setenforce 1
chmod 777 /data/local/tmp/gcrash.log /data/local/tmp/ghwc_crash.log /data/local/tmp/ghwcbt.log 2>/dev/null
echo "== counts by comm =="
grep -a '^comm=' /data/local/tmp/gcrash.log | sed 's/ pid=.*//' | sort | uniq -c
echo DONE
