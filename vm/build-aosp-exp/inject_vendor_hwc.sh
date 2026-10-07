#!/usr/bin/env bash
# 给 vendor.img 加 HWC wrapper（写 pid 再 exec），产出 vendor_hwcbt.img
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp

SRC=vendor_dev.img
DST=vendor_hwcbt.img
RC=/etc/init/android.hardware.graphics.composer@2.3-service.rc

sed -i 's/\r$//' vmhost_hwc_wrap.sh hwc_wrap.rc

cp -f "$SRC" "$DST"
e2fsck -fy "$DST" >/dev/null 2>&1 || true

debugfs -w -R "write vmhost_hwc_wrap.sh /bin/vmhost_hwc_wrap.sh" "$DST"
debugfs -w -R "sif /bin/vmhost_hwc_wrap.sh mode 0100755" "$DST"
# 崩溃捕获库（LD_PRELOAD 进 composer）
debugfs -w -R "write libhwcdbg.so /lib64/libhwcdbg.so" "$DST"
debugfs -w -R "sif /lib64/libhwcdbg.so mode 0100644" "$DST"
debugfs -w -R "rm $RC" "$DST"
debugfs -w -R "write hwc_wrap.rc $RC" "$DST"
debugfs -w -R "sif $RC mode 0100644" "$DST"

e2fsck -fy "$DST" >/dev/null 2>&1 || true

echo "--- verify rc ---"
debugfs -R "cat $RC" "$DST" 2>/dev/null
echo "--- verify wrapper ---"
debugfs -R "cat /bin/vmhost_hwc_wrap.sh" "$DST" 2>/dev/null
echo "--- modes ---"
debugfs -R "stat /bin/vmhost_hwc_wrap.sh" "$DST" 2>/dev/null | grep -E 'Mode|Inode:'
debugfs -R "stat $RC" "$DST" 2>/dev/null | grep -E 'Mode|Inode:'
ls -la "$DST"
