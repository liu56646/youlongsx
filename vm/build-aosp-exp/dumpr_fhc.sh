#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
rm -f /tmp/fhc
debugfs -R "dump -p /system/bin/flags_health_check /tmp/fhc" system_bt.img 2>/dev/null || true
ls -la /tmp/fhc 2>/dev/null || { echo "no binary"; exit 0; }
echo "=== strings: updatable/crashing/device_config ==="
strings -n 5 /tmp/fhc | grep -i -e updatable -e crashing -e attempted_boot -e device_config -e "boot_count" | head -30 || true
echo "=== strings: usage/help ==="
strings -n 5 /tmp/fhc | grep -i -e usage -e "unknown" -e BOOT_FAILURE -e "server_configurable" | head -20 || true
