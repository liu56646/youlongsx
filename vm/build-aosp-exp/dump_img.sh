#!/system/bin/sh
# 导出 p11 的 ramdisk.img 与 vendor.img，供离线解析 fstab
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cp -f "$IMG/ramdisk.img" /data/local/tmp/ramdisk.img
cp -f "$IMG/vendor.img" /data/local/tmp/vendor.img
chmod 644 /data/local/tmp/ramdisk.img /data/local/tmp/vendor.img
ls -l /data/local/tmp/ramdisk.img /data/local/tmp/vendor.img
