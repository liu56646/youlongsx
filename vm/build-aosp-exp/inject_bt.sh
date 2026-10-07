#!/usr/bin/env bash
# 把 hwcbt.sh / hwcbt.rc 注入 system_cur.img，产出 system_bt.img
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp

SRC=system_cur.img
DST=system_bt.img

# 去掉可能存在的 CRLF（Windows 侧写出来的文件）
sed -i 's/\r$//' hwcbt.sh hwcbt.rc

cp -f "$SRC" "$DST"
# 回放 ext4 日志，避免 debugfs 报 "Inode bitmap checksum does not match"
e2fsck -fy "$DST" >/dev/null 2>&1 || true

debugfs -w -R "write hwcbt.sh /system/bin/hwcbt.sh" "$DST"
debugfs -w -R "sif /system/bin/hwcbt.sh mode 0100755" "$DST"
debugfs -w -R "write hwcbt.rc /etc/init/hwcbt.rc" "$DST"
# init 要求 rc 文件不能被 group/others 写，否则 "Skipping insecure file"
debugfs -w -R "sif /etc/init/hwcbt.rc mode 0100644" "$DST"

e2fsck -fy "$DST" >/dev/null 2>&1 || true

echo "--- verify /etc/init/hwcbt.rc ---"
debugfs -R "cat /etc/init/hwcbt.rc" "$DST"
echo "--- verify /system/bin/hwcbt.sh (head) ---"
debugfs -R "cat /system/bin/hwcbt.sh" "$DST" | head -5
echo "--- verify inode mode ---"
debugfs -R "stat /system/bin/hwcbt.sh" "$DST" | grep -E "Mode|Inode:"
ls -la "$DST"
