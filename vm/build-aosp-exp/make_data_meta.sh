#!/usr/bin/env bash
# 造访客 fstab 需要的两个盘：
#   data.img —— 第 3 个 virtio-blk（/dev/block/vdc），整盘 ext4，挂 /data
#   meta.img —— 带 GPT 分区名 metadata 的小盘，供 by-name/metadata 解析
set -euo pipefail
cd "$(dirname "$0")"

echo "==> data.img (ext4, quota+verity)"
rm -f data.img
truncate -s 2G data.img
mkfs.ext4 -F -q -b 4096 -O quota,verity -L data data.img
ls -l data.img

echo "==> meta.img (GPT: metadata)"
rm -f meta.img
truncate -s 64M meta.img
sgdisk -o meta.img >/dev/null
sgdisk -n 1:2048:+32768 -c 1:metadata \
       -t 1:0fc63daf-8483-4772-8e79-3d69d8477de4 meta.img >/dev/null
sgdisk -p meta.img
