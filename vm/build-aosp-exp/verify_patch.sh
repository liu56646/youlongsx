#!/usr/bin/env bash
E=/mnt/k/youlongsx/vm/engine/scripts/qemu_patches/patch_ranchu_pcie.py
Q=/root/vmbuild/qemu-aosp

echo "=== 1) 幂等性（对已打过补丁的文件再跑一次）==="
python3 "$E" "$Q"
echo
echo "=== 2) 从原始版本重打，与当前正在用的文件对比 ==="
rm -rf /tmp/ranchutest
mkdir -p /tmp/ranchutest/hw/arm
cp "$Q/hw/arm/ranchu.c.orig_pcie" /tmp/ranchutest/hw/arm/ranchu.c
python3 "$E" /tmp/ranchutest
if diff -u "$Q/hw/arm/ranchu.c" /tmp/ranchutest/hw/arm/ranchu.c > /tmp/ranchudiff.txt 2>&1; then
    echo "OK: 重打结果与当前可用文件完全一致（补丁可重现）"
else
    echo "!! 存在差异："
    head -40 /tmp/ranchudiff.txt
fi
echo
echo "=== 3) 构建脚本里已挂上该步骤 ==="
grep -n -B2 -A6 'patch_ranchu_pcie()' /mnt/k/youlongsx/vm/engine/scripts/build_qemu_aosp.sh | head -20
