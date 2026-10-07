#!/usr/bin/env bash
# 把 super 解出的物理分区接成 6 个独立 virtio-blk（整盘 ext4），
# 并把 ramdisk / vendor 里的 fstab 改成显式设备路径（不依赖 by-name / super）。
set -euo pipefail
cd /mnt/k/youlongsx/vm/build-aosp-exp
PHYS=/tmp/phys

cat > /tmp/fstab_first <<'EOF'
# VMHost: 物理分区，显式设备路径（不依赖 by-name / super）
/dev/block/vda   /system      ext4  ro,barrier=1  wait,first_stage_mount
/dev/block/vdb   /vendor      ext4  ro,barrier=1  wait,first_stage_mount
/dev/block/vdc   /product     ext4  ro,barrier=1  wait,first_stage_mount
/dev/block/vdd   /system_ext  ext4  ro,barrier=1  wait,first_stage_mount
/dev/block/vde   /metadata    ext4  noatime,nosuid,nodev  wait,formattable,first_stage_mount
/dev/block/vdf   /data        ext4  noatime,nosuid,nodev  wait,check,formattable
EOF

cat > /tmp/fstab_second <<'EOF'
# VMHost: 物理分区，显式设备路径
/dev/block/vda   /system      ext4  ro,barrier=1  wait
/dev/block/vdb   /vendor      ext4  ro,barrier=1  wait
/dev/block/vdc   /product     ext4  ro,barrier=1  wait
/dev/block/vdd   /system_ext  ext4  ro,barrier=1  wait
/dev/block/vde   /metadata    ext4  noatime,nosuid,nodev  wait,formattable
/dev/block/vdf   /data        ext4  noatime,nosuid,nodev  wait,check,formattable
EOF

echo "==> 改写 vendor 里的 /etc/fstab.ranchu"
debugfs -w -R "rm /etc/fstab.ranchu" "$PHYS/vendor.img" >/dev/null 2>&1 || true
debugfs -w -R "write /tmp/fstab_second /etc/fstab.ranchu" "$PHYS/vendor.img" >/dev/null
debugfs -R "cat /etc/fstab.ranchu" "$PHYS/vendor.img"

echo "==> 重打包 ramdisk（改写 first-stage fstab）"
rm -rf /tmp/rd4
python3 extract_cpio.py ramdisk.img /tmp/rd4 >/dev/null
cp /tmp/fstab_first /tmp/rd4/fstab.ranchu
cp /tmp/fstab_first /tmp/rd4/first_stage_ramdisk/fstab.ranchu
( cd /tmp/rd4 && find . | cpio -o -H newc 2>/dev/null | gzip -9 > /mnt/k/youlongsx/vm/build-aosp-exp/ramdisk_phys.img )
ls -la /mnt/k/youlongsx/vm/build-aosp-exp/ramdisk_phys.img

echo "==> 拷贝物理分区到 K:（便于推送）"
mkdir -p /mnt/k/youlongsx/vm/build-aosp-exp/phys
cp -f "$PHYS"/*.img /mnt/k/youlongsx/vm/build-aosp-exp/phys/
ls -la /mnt/k/youlongsx/vm/build-aosp-exp/phys
