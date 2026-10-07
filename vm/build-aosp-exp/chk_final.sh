#!/bin/bash
echo "=== goldfish_pipe_service_ops static block (1978-2015) ==="
sed -n '1978,2015p' /root/vmbuild/gfxstream/host/virtio-gpu-gfxstream-renderer.cpp
echo "=== set_service_ops def ==="
grep -n 'stream_renderer_set_service_ops' /root/vmbuild/gfxstream/host/virtio-gpu-gfxstream-renderer.cpp | head
echo "=== gralloc prop value in vendor.img ==="
debugfs -R 'cat /vendor/etc/build.prop' /root/vmbuild/vendor30_ext4.img 2>/dev/null | grep -i 'gralloc' | head
echo "--- alt: search all prop files ---"
debugfs -R 'ls -p /vendor/etc' /root/vmbuild/vendor30_ext4.img 2>/dev/null | head -40
