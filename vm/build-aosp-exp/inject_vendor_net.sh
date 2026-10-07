#!/usr/bin/env bash
# 方案 b：修掉 dhcpclient_def 无限重启 / flags_health_check 风暴的根因。
# 把 vendor 里的 /vendor/bin/init.ranchu-net.sh 打补丁：只有在 eth0 存在时才启动
# dhcpclient_def（本 guest 无网卡，eth0 不存在）。
# 基于 vendor_bt2.img -> vendor_bt3.img
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp

SRC=vendor_bt2.img
DST=vendor_bt3.img
BIN=/bin/init.ranchu-net.sh

sed -i 's/\r$//' ranchu_net.sh

cp -f "$SRC" "$DST"
e2fsck -fy "$DST" >/dev/null 2>&1 || true

echo "--- 原文件 ---"
debugfs -R "stat $BIN" "$DST" 2>/dev/null | grep -E 'Inode:|Mode:|Size:'

# 备份，再写入补丁版
debugfs -w -R "dump $BIN /tmp/init.ranchu-net.sh.orig" "$DST" >/dev/null 2>&1 || true
debugfs -w -R "rm $BIN" "$DST" >/dev/null 2>&1 || true
debugfs -w -R "write ranchu_net.sh $BIN" "$DST" >/dev/null 2>&1
debugfs -w -R "sif $BIN mode 0100755" "$DST" >/dev/null 2>&1

# 关键：debugfs 的 rm+write 会新建 inode，丢掉 security.selinux 标签；init 见到
# "unlabeled / no domain transition" 会直接拒绝启动 service ranchu-net。
# 这里把【原 inode】的标签读出来，再写到【新 inode】上（通用，不写死标签值）。
LBL=/tmp/net_lbl.bin
rm -f "$LBL"
debugfs -R "ea_get -f $LBL $BIN security.selinux" "$SRC" >/dev/null 2>&1 || true
if [ -s "$LBL" ]; then
    debugfs -w -R "ea_set -f $LBL $BIN security.selinux" "$DST" >/dev/null 2>&1 || true
    echo "label restored from $SRC ($(stat -c %s "$LBL") bytes)"
else
    echo "WARN: 未能读取原标签，新文件可能仍是 unlabeled"
fi

e2fsck -fy "$DST" >/dev/null 2>&1 || true

echo "--- 替换后 ---"
debugfs -R "stat $BIN" "$DST" 2>/dev/null | grep -E 'Inode:|Mode:|Size:'
echo "--- 标签（新 vs 原） ---"
debugfs -R "ea_list $BIN" "$DST" 2>/dev/null | tail -2
debugfs -R "ea_list $BIN" "$SRC" 2>/dev/null | tail -2
echo "--- 关键片段 ---"
debugfs -R "cat $BIN" "$DST" 2>/dev/null | sed -n '11,30p'
ls -la "$DST"
