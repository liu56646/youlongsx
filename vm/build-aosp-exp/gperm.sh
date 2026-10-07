#!/system/bin/sh
# 取 PermissionController 的 versionCode 和 Build.FINGERPRINT，用于预置 runtime-permissions.xml
M=/mnt/gdata
mkdir -p $M
umount $M 2>/dev/null
setenforce 0
mount -t ext4 -o loop,ro,noload /data/local/tmp/data.img $M || { echo FAIL; exit 1; }
echo "== packages.xml :: permissioncontroller =="
grep -aoE '<package name="[^"]*permissioncontroller[^"]*"[^>]*' $M/system/packages.xml 2>&1
echo "== packages.xml :: any version= sample =="
grep -aoE '<package name="com.android.permissioncontroller"[^>]*' $M/system/packages.xml 2>&1
echo "== data/system/users/0 files =="
ls -la $M/system/users/0/ 2>&1
echo "== existing runtime-permissions.xml? =="
cat $M/system/users/0/runtime-permissions.xml 2>&1 | head -20
umount $M 2>/dev/null
echo "== build.prop fingerprint (from system.img) =="
S=/mnt/gsys
mkdir -p $S
umount $S 2>/dev/null
mount -t ext4 -o loop,ro,noload /data/local/tmp/system.img $S 2>/dev/null && {
  grep -a 'ro.build.fingerprint' $S/build.prop 2>&1
  grep -a 'ro.build.version.incremental\|ro.build.id' $S/build.prop 2>&1
  umount $S 2>/dev/null
}
setenforce 1
echo DONE
