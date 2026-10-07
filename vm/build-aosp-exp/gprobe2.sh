#!/system/bin/sh
# 从 guest data.img 拷贝 ANR / tombstone / logpersist 出来
IMG=/data/local/tmp/data.img
M=/mnt/gdata
D=/data/local/tmp/gdump
rm -rf $D; mkdir -p $D/anr $D/tomb $D/logd
umount $M 2>/dev/null
setenforce 0
mount -t ext4 -o loop,ro,noload $IMG $M || { echo MOUNT_FAIL; exit 1; }
cp -f $M/anr/* $D/anr/ 2>/dev/null
cp -f $M/tombstones/* $D/tomb/ 2>/dev/null
cp -f $M/misc/logd/* $D/logd/ 2>/dev/null
cp -f $M/system/dropbox/* $D/ 2>/dev/null
umount $M 2>/dev/null
setenforce 1
chmod -R 777 $D
echo "== dumped =="
ls -la $D/anr $D/tomb $D/logd
echo "== ANR head =="
head -60 $D/anr/* 2>/dev/null
echo DONE
