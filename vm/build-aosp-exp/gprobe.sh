#!/system/bin/sh
# 只读挂载 guest 的 data.img，翻 dropbox / anr / logpersist，找 system_server 静默退出(exit 1)的线索
IMG=/data/local/tmp/data.img
M=/mnt/gdata
mkdir -p $M
umount $M 2>/dev/null
getenforce > /data/local/tmp/gprobe_enforce.txt
setenforce 0
mount -t ext4 -o loop,ro,noload $IMG $M
echo "MOUNT_RC=$?"
if [ ! -d $M/system ]; then
  echo "== mount failed, try offset probe =="
  dmesg | tail -8
  exit 1
fi
echo "== root =="
ls -la $M | head -40
echo "== dropbox =="
ls -la $M/system/dropbox 2>&1 | tail -60
echo "== anr =="
ls -la $M/anr 2>&1 | tail -40
echo "== logpersist (logd) =="
ls -la $M/misc/logd 2>&1 | tail -40
echo "== tombstone =="
ls -la $M/tombstones 2>&1 | tail -20
umount $M 2>/dev/null
setenforce 1
echo "DONE"
