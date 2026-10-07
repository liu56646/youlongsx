#!/system/bin/sh
# 检查 guest metadata 分区里的 crash.log（crashlite 的输出）
M=/mnt/gmeta
mkdir -p $M
umount $M 2>/dev/null
setenforce 0
mount -t ext4 -o loop,ro,noload /data/local/tmp/meta.img $M || { echo META_MOUNT_FAIL; dmesg | tail -5; exit 1; }
echo "== metadata root =="
ls -la $M
echo "== crash.log =="
ls -la $M/crash.log 2>&1
echo "---- content (head 200) ----"
head -200 $M/crash.log 2>&1
umount $M 2>/dev/null
setenforce 1
echo DONE
