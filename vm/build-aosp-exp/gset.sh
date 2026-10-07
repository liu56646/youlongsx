#!/system/bin/sh
M=/mnt/gdata
mkdir -p $M
umount $M 2>/dev/null
setenforce 0
mount -t ext4 -o loop,ro,noload /data/local/tmp/data.img $M || { echo FAIL; exit 1; }
echo "===== settings_secure.xml ====="
cat $M/system/users/0/settings_secure.xml 2>&1
echo "===== settings_global.xml (grep) ====="
grep -anE 'name="(device_provisioned|user_setup_complete|runtime_permissions)' $M/system/users/0/settings_global.xml 2>&1
umount $M 2>/dev/null
setenforce 1
echo DONE
