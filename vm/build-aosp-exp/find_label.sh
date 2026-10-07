#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
V=vendor_bt2.img
echo "=== vendor_file_contexts 里 init.ranchu-net.sh 的标签 ==="
debugfs -R "cat /etc/selinux/vendor_file_contexts" "$V" 2>/dev/null | grep -n "ranchu" || echo "(none)"
echo
echo "=== debugfs 是否支持 ea_*（可在新 inode 上写回安全标签） ==="
debugfs -R "help" "$V" 2>&1 | grep -i "ea_" || echo "(no ea_ commands)"
echo
echo "=== 原文件现有 xattr ==="
debugfs -R "ea_list /bin/init.ranchu-net.sh" "$V" 2>&1 | head -12 || true
