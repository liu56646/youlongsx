#!/system/bin/sh
# 往 guest 的 /data/system/users/0/runtime-permissions.xml 预置权限指纹，
# 让 PackageManagerService.Settings.RuntimePermissionPersistence.isPermissionUpgradeNeeded() 返回 false，
# 从而跳过「调用 PermissionController 应用做 runtime 权限升级」这一步（它在 TCG 上要 >90s，
# 必被 Watchdog 硬编码的 60s 打死，导致 system_server 反复重启）。
# 要求 QEMU 已停止（否则 data.img 被占/不一致）。
M=/mnt/gdata
IMG=/data/local/tmp/data.img
mkdir -p $M
umount $M 2>/dev/null
setenforce 0
mount -t ext4 -o loop,rw $IMG $M || { echo MOUNT_FAIL; dmesg | tail -5; exit 1; }
D=$M/system/users/0
mkdir -p $D
cp -f /data/local/tmp/runtime_perm.xml $D/runtime-permissions.xml || { echo CP_FAIL; exit 1; }
chown 1000:1000 $D/runtime-permissions.xml
chmod 600 $D/runtime-permissions.xml
sync
echo "== installed =="
ls -l $D/runtime-permissions.xml
cat $D/runtime-permissions.xml
umount $M
setenforce 1
echo DONE
