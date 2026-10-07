#!/bin/bash
# 从 GitHub aosp-mirror 拉 virglrenderer.h，检查是否含 stream_renderer / virtio_interface
BRANCHES="android13-release android12-release android-mainline main"
for b in $BRANCHES; do
    url="https://raw.githubusercontent.com/aosp-mirror/platform_external_virglrenderer/$b/src/virglrenderer.h"
    out=$(curl -s --max-time 30 "$url")
    n=$(printf '%s' "$out" | wc -c)
    echo "== $b -> $n bytes"
    if [ "$n" -gt 3000 ]; then
        printf '%s' "$out" > /tmp/virglrenderer.h
        echo "SAVED from $b"
        echo "--- contains: ---"
        grep -c 'virgl_renderer_virtio_interface' /tmp/virglrenderer.h
        grep -c 'stream_renderer_resource_create_args' /tmp/virglrenderer.h
        grep -c 'virgl_renderer_gl_ctx_param' /tmp/virglrenderer.h
        grep -n '#include' /tmp/virglrenderer.h | head
        break
    fi
done
