#!/usr/bin/env bash
# 造一个符合访客 fstab 期望的 userdata 盘：
#   GPT 两个分区：metadata(16MiB) + userdata(其余)
#   两个分区都格式化 ext4（/data 的 fstab 带 check 而非 formattable）
set -euo pipefail

OUT="${1:-/mnt/k/youlongsx/vm/build-aosp-exp/userdata_ud.img}"
SIZE="${2:-4G}"

rm -f "$OUT"
truncate -s "$SIZE" "$OUT"

sgdisk -o "$OUT" >/dev/null
# 1: metadata 16MiB
sgdisk -n 1:2048:+32768 -c 1:metadata -t 1:0fc63daf-8483-4772-8e79-3d69d8477de4 "$OUT" >/dev/null
# 2: userdata 其余
sgdisk -n 2:0:0 -c 2:userdata -t 2:0fc63daf-8483-4772-8e79-3d69d8477de4 "$OUT" >/dev/null

echo "--- 分区表 ---"
sgdisk -p "$OUT"

# 用 loop 设备格式化（WSL2 支持）；不支持则退化为 dd 提取 -> mkfs -> dd 回写
if losetup -f >/dev/null 2>&1; then
    LOOP=$(losetup -f --show -P "$OUT")
    echo "loop=$LOOP"
    mkfs.ext4 -F -q -b 4096 -O ^has_journal,^resize_inode "${LOOP}p1"
    mkfs.ext4 -F -q -b 4096 -O ^has_journal,^resize_inode,quota "${LOOP}p2"
    losetup -d "$LOOP"
else
    echo "!! 无 losetup，改用 dd 往返"
    T=/tmp/ud_part.img
    dd if="$OUT" of="$T" bs=512 skip=2048 count=32768 status=none
    mkfs.ext4 -F -q -b 4096 -O ^has_journal,^resize_inode "$T"
    dd if="$T" of="$OUT" bs=512 seek=2048 conv=notrunc status=none
    echo "!! userdata 主分区未格式化（体积大，交由访客处理）"
fi

echo "--- 结果 ---"
ls -l "$OUT"
sgdisk -i 1 "$OUT" | head -5
sgdisk -i 2 "$OUT" | head -5
