#!/bin/bash
echo "=== vulkan.h ==="
find /root/vmbuild/gfxstream /root/vmbuild/aemu -name 'vulkan.h' -path '*vulkan*' 2>/dev/null | head -3
echo "=== virtgpu_gfxstream_protocol.h ==="
find /root/vmbuild/gfxstream -name 'virtgpu_gfxstream_protocol.h' 2>/dev/null | head -3
echo "=== drm_fourcc.h ==="
find /root/vmbuild/gfxstream -name 'drm_fourcc.h' 2>/dev/null | head -3
echo "=== GfxStreamAgents.h ==="
find /root/vmbuild/gfxstream -name 'GfxStreamAgents.h' 2>/dev/null | head -3
echo "=== host/include listing ==="
ls /root/vmbuild/gfxstream/host/include 2>/dev/null | head
echo "=== third-party ==="
ls /root/vmbuild/gfxstream/third-party 2>/dev/null | head -30
