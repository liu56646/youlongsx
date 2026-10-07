#!/usr/bin/env bash
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp
IMG=${1:-system_bt.img}
echo "=== /system/etc/selinux ==="
debugfs -R "ls -l /system/etc/selinux" "$IMG" 2>/dev/null | head -30 || true
echo "=== try dump plat_sepolicy.cil ==="
rm -f /tmp/plat.cil
debugfs -R "dump -p /system/etc/selinux/plat_sepolicy.cil /tmp/plat.cil" "$IMG" 2>/dev/null || true
ls -la /tmp/plat.cil 2>/dev/null || echo "no plat_sepolicy.cil"
if [ -f /tmp/plat.cil ]; then
  echo "=== domains allowed to find activity_service ==="
  grep -oE '\(allow [a-z0-9_]+ activity_service \(service_manager \(find\)\)\)' /tmp/plat.cil | head -40 || true
  echo "=== is 'su' a type? ==="
  grep -nE '^\s*\(type su\)|\(type su\)' /tmp/plat.cil | head -5 || true
  echo "=== permissive su? ==="
  grep -nE '\(permissive su\)' /tmp/plat.cil | head -5 || true
  echo "=== hal_graphics_composer_default find rules ==="
  grep -oE '\(allow hal_graphics_composer_default [a-z0-9_]+ \(service_manager \(find\)\)\)' /tmp/plat.cil | head -20 || true
fi
