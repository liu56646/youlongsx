#!/usr/bin/env bash
# 检查 guest system 镜像布局与 am/app_process 用法（方案 2 引导需要）
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp
IMG=${1:-system_bt.img}
echo "=== image root ==="
debugfs -R "ls -l /" "$IMG" 2>/dev/null | head -40
echo "=== exists /system ? ==="
debugfs -R "stat /system" "$IMG" 2>/dev/null | head -5 || true
echo "=== /bin am & app_process ==="
debugfs -R "ls -l /bin" "$IMG" 2>/dev/null | grep -E "am\b|app_process|dalvikvm" || true
debugfs -R "ls -l /system/bin" "$IMG" 2>/dev/null | grep -E "am\b|app_process|dalvikvm" || true
echo "=== /etc/init/hw/init.rc exports ==="
debugfs -R "cat /etc/init/hw/init.rc" "$IMG" 2>/dev/null | grep -inE "bootclasspath|ANDROID_ROOT|ANDROID_DATA|export |zygote|SYSTEMSERVER" | head -40 || true
echo "=== /framework (jar around am) ==="
debugfs -R "ls -l /framework" "$IMG" 2>/dev/null | grep -iE "am.jar|framework.jar|services.jar|vr|boot" || true
echo "=== our injected rc present? ==="
debugfs -R "cat /etc/init/vmhost_input.rc" "$IMG" 2>/dev/null || true
