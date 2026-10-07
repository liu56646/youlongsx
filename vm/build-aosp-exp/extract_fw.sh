#!/usr/bin/env bash
# 从 guest system 镜像提取 framework.jar，看里面有什么 dex
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp
IMG=${1:-system_bt.img}
rm -rf /tmp/fw && mkdir -p /tmp/fw
debugfs -R "dump -p /system/framework/framework.jar /tmp/fw/framework.jar" "$IMG" 2>/dev/null || true
ls -la /tmp/fw/
echo "=== jar 内容 ==="
unzip -l /tmp/fw/framework.jar 2>/dev/null | head -30 || echo "unzip 不可用或非 zip"
echo "=== 是否有 IActivityController ==="
unzip -l /tmp/fw/framework.jar 2>/dev/null | grep -i activitycontroller || echo "not in framework.jar"
