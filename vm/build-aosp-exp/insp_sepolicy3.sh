#!/usr/bin/env bash
set -e
CIL=/tmp/plat.cil
echo "=== init -> selinuxfs / setenforce / mac_admin ==="
grep -nE 'selinuxfs|setenforce|mac_admin' "$CIL" | head -30 || true
echo "=== 'enforce' file refs ==="
grep -nE '\(file \(write\)\)' "$CIL" | grep -iE 'init|selinux' | head -20 || true
echo "=== who can find base_typeattr_522 (shell) ==="
grep -oE '\(typeattributeset base_typeattr_522.*' "$CIL" | head -3 || true
echo "=== audioserver / mediaserver / cameraserver -> system_server binder ==="
for d in audioserver mediaserver cameraserver permissioncontroller_app isolated_app; do
  echo "-- $d"
  grep -oE "\(allow $d system_server \(binder \([a-z ]+\)\)\)" "$CIL" | head -4 || true
done
echo "=== appdomain -> system_server binder ==="
grep -oE '\(allow appdomain system_server \(binder \([a-z ]+\)\)\)' "$CIL" | head -4 || true
