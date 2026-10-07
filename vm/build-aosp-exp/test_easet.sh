#!/usr/bin/env bash
# 验证：能否用 debugfs ea_set 把 security.selinux 标签写到重写后的文件上
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp
cp -f vendor_bt3.img /tmp/t.img

# 目标标签（含结尾 NUL，共 34 字节，与原文件一致）
printf 'u:object_r:goldfish_setup_exec:s0\0' > /tmp/lbl.bin
echo "label file bytes: $(stat -c %s /tmp/lbl.bin)"
xxd /tmp/lbl.bin | head -3

echo "=== ea_set ==="
debugfs -w -R "ea_set -f /tmp/lbl.bin /bin/init.ranchu-net.sh security.selinux" /tmp/t.img 2>&1 | head -5

echo "=== 校验 ==="
debugfs -R "ea_list /bin/init.ranchu-net.sh" /tmp/t.img 2>&1 | tail -4
echo "=== 与原始文件对比 ==="
debugfs -R "ea_list /bin/init.ranchu-net.sh" vendor_bt2.img 2>&1 | tail -3
