#!/bin/bash
# 拉取 AOSP external/virglrenderer 的 virglrenderer.h（先试 emu-34 系分支，再试 master）
BRANCHES="emu-34 emu-34-release emu-33 emu-33-release android-mainline master"
for b in $BRANCHES; do
    url="https://android.googlesource.com/platform/external/virglrenderer/+/refs/heads/$b/src/virglrenderer.h?format=TEXT"
    out=$(curl -s "$url" | base64 -d 2>/dev/null)
    n=$(printf '%s' "$out" | wc -c)
    echo "== $b -> $n bytes"
    if [ "$n" -gt 5000 ]; then
        printf '%s' "$out" > /tmp/virglrenderer.h
        echo "SAVED from $b"
        break
    fi
done
echo "---check saved---"
if [ -s /tmp/virglrenderer.h ]; then
    grep -c 'virgl_renderer_virtio_interface' /tmp/virglrenderer.h
    grep -n 'stream_renderer\|#include' /tmp/virglrenderer.h | head -20
fi
