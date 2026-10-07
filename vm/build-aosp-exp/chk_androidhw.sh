#!/bin/bash
echo "=== renderer cpp android_hw refs ==="
grep -n 'android_hw\|AndroidHwConfig\|aemu_get_android_hw' /root/vmbuild/gfxstream/host/virtio-gpu-gfxstream-renderer.cpp | head
echo "=== search libs ==="
for f in /root/vmbuild/aemu-build-arm64-v8a/host-common/libaemu-host-common.a \
         /root/vmbuild/gfxstream-build-arm64-v8a/host/gl/gl-host-common/libgfxstream-gl-host-common.a \
         /root/vmbuild/aemu-build-arm64-v8a/base/libaemu-base.a; do
  echo "== $f"
  nm "$f" 2>/dev/null | grep -E 'aemu_get_android_hw|AndroidHwConfig' | head -5
done
echo "=== header location ==="
find /root/vmbuild/aemu /root/vmbuild/gfxstream -name 'android_hw.h' 2>/dev/null | head
