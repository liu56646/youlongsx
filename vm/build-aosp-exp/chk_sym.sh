#!/bin/bash
echo "=== search initLibrary definition in gfxstream src ==="
grep -rn 'RenderLibPtr initLibrary\|initLibrary()' /root/vmbuild/gfxstream/host/RenderLibImpl.cpp /root/vmbuild/gfxstream/host/render_api.cpp /root/vmbuild/gfxstream/include/render-utils/render_api.h 2>/dev/null | head -10
echo "=== nm all gfxstream .a for T initLibrary ==="
for f in $(find /root/vmbuild/gfxstream-build-arm64-v8a -name '*.a'); do
    if nm "$f" 2>/dev/null | grep -q 'T initLibrary'; then echo "FOUND in $f"; fi
done
echo "=== SR_OBJ stream_renderer_set_service_ops (raw) ==="
nm /root/vmbuild/qemu-aosp-build-arm64-v8a/vmhost/vmhost_gfxstream_renderer.o 2>/dev/null | grep -i 'set_service_ops' | head
echo "=== check SR_WORK around 2502 ==="
sed -n '2498,2506p' /root/vmbuild/qemu-aosp-build-arm64-v8a/vmhost/virtio-gpu-gfxstream-renderer.work.cpp
