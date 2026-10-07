#!/usr/bin/env bash
# 把 vendor.img 里的 goldfish RIL 换成一个空转 shell 桩（不再 abort 刷屏）。
# 基于 vendor_hwcbt.img（已含 HWC wrapper + libhwcdbg）-> vendor_bt2.img
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp

SRC=vendor_hwcbt.img
DST=vendor_bt2.img
BIN=/bin/hw/libgoldfish-rild

sed -i 's/\r$//' ril_stub.sh

cp -f "$SRC" "$DST"
e2fsck -fy "$DST" >/dev/null 2>&1 || true

echo "--- 原文件 ---"
debugfs -R "stat $BIN" "$DST" 2>/dev/null | grep -E 'Mode|Inode:|Size:'

# 备份原二进制，再写入桩
debugfs -w -R "dump $BIN /tmp/libgoldfish-rild.orig" "$DST" >/dev/null 2>&1 || true
debugfs -w -R "rm $BIN" "$DST" >/dev/null 2>&1 || true
debugfs -w -R "write ril_stub.sh $BIN" "$DST" >/dev/null 2>&1
debugfs -w -R "sif $BIN mode 0100755" "$DST" >/dev/null 2>&1

e2fsck -fy "$DST" >/dev/null 2>&1 || true

echo "--- 替换后 ---"
debugfs -R "stat $BIN" "$DST" 2>/dev/null | grep -E 'Mode|Inode:|Size:'
debugfs -R "cat $BIN" "$DST" 2>/dev/null | head -3
ls -la "$DST"
