#!/bin/bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
BASE=https://cdn.jsdelivr.net/gh/aosp-mirror/platform_packages_modules_Permission@android-11.0.0_r48
for p in \
  framework-s/java/com/android/permission/persistence/RuntimePermissionsPersistenceImpl.java \
  framework/java/com/android/permission/persistence/RuntimePermissionsPersistenceImpl.java \
  framework-s/java/com/android/permission/persistence/RuntimePermissionsStatePersistence.java \
  framework/java/com/android/permission/persistence/RuntimePermissionsStatePersistence.java ; do
  if curl -sSL --max-time 40 "$BASE/$p" -o rpp.java && head -3 rpp.java | grep -q Copyright; then
    echo "FOUND: $p"; break
  fi
done
wc -l rpp.java 2>/dev/null
echo "--- file/name refs ---"
grep -nE 'FILE_NAME|runtime-permissions|new File|getFile|Persistence' rpp.java 2>/dev/null | head -25
