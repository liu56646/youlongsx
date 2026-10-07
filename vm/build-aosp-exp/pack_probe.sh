#!/usr/bin/env bash
# 在「物理分区版」ramdisk 上再加探针，打成 ramdisk_probe.img
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp
rm -rf /tmp/rdp
python3 extract_cpio.py ramdisk_phys.img /tmp/rdp >/dev/null
cp -f dumper /tmp/rdp/dumper
chmod 755 /tmp/rdp/dumper
# 去掉两个纯测试用、启动极慢的模块（kmem_cache/stackinit 压力测试，启动不需要）
rm -f /tmp/rdp/lib/modules/test_meminit.ko /tmp/rdp/lib/modules/test_stackinit.ko
for f in modules.load modules.dep; do
  [ -f "/tmp/rdp/lib/modules/$f" ] && \
    grep -vE 'test_meminit|test_stackinit' "/tmp/rdp/lib/modules/$f" > "/tmp/rdp/lib/modules/$f.new" && \
    mv "/tmp/rdp/lib/modules/$f.new" "/tmp/rdp/lib/modules/$f"
done
echo "--- 裁剪后 modules.load ---"
grep -c . /tmp/rdp/lib/modules/modules.load
# 预置最基础的设备节点（否则内核会在 rootfs 里现造 /dev/console，过程中旧 inode 被
# unlink，init 及其子进程拿到的是 "(deleted)" 的 console fd —— 实测会让 ART 报
# "JNI FatalError called: (system_server) Not whitelisted (3): /dev/console (deleted)"
# 并 abort，导致 zygote/system_server 无限重启）
mkdir -p /tmp/rdp/dev
[ -e /tmp/rdp/dev/console ] || mknod /tmp/rdp/dev/console c 5 1
[ -e /tmp/rdp/dev/null ]    || mknod /tmp/rdp/dev/null    c 1 3
chmod 600 /tmp/rdp/dev/console
chmod 666 /tmp/rdp/dev/null
ls -la /tmp/rdp/dev
( cd /tmp/rdp && find . | cpio -o -H newc 2>/dev/null | gzip -9 > /mnt/k/youlongsx/vm/build-aosp-exp/ramdisk_probe.img )
ls -la ramdisk_probe.img
