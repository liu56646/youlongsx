#!/usr/bin/env bash
# 第 1 步前置：拉取 aemu 宿主侧源码。
#
# 背景（2026-10-04 实测）：
#   - android.googlesource.com 超时、github.com/google/aemu 404，均不可用；
#   - 清华 AOSP 镜像同时托管了 aemu 项目且可正常访问，是唯一可用通道。
# 上一版脚本只试了 googlesource / github，导致 aemu 一直拉不下来。
#
# 分支选择：必须与 qemu 树同分支线。当前 qemu 用的是 emu-34-release，
# 故默认也取 emu-34-release（另有 emu-34-2/3-release，属更新补丁分支）。
set -u

DEST=/root/vmbuild/aemu
BRANCH="${BRANCH:-emu-34-release}"

MIRROR=https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/platform/hardware/google/aemu
GSRC=https://android.googlesource.com/platform/hardware/google/aemu

echo "=== 探测可达性 ==="
for U in "$MIRROR" "$GSRC" https://github.com/google/aemu; do
    echo "--- $U"
    timeout 25 git ls-remote "$U" HEAD 2>&1 | head -2
done

echo "=== 浅克隆 $BRANCH -> $DEST ==="
rm -rf "$DEST"
if timeout 300 git clone --depth 1 -b "$BRANCH" "$MIRROR" "$DEST" 2>&1 | tail -5; then
    echo "clone ok (tuna mirror)"
else
    echo "清华镜像失败，回退 googlesource"
    timeout 300 git clone --depth 1 -b "$BRANCH" "$GSRC" "$DEST" 2>&1 | tail -5 \
        || echo "googlesource 也失败"
fi

echo "=== 结果 ==="
ls -la "$DEST" 2>/dev/null | head -20
echo "=== 关键文件是否存在 ==="
for f in \
    host-common/include/host-common/AndroidPipe.h \
    host-common/include/host-common/HostGoldfishPipe.h \
    host-common/include/host-common/goldfish_pipe.h \
    host-common/include/host-common/VmLock.h \
    host-common/HostGoldfishPipe.cpp \
    host-common/AndroidPipe.cpp; do
    [ -f "$DEST/$f" ] && echo "  ok   $f" || echo "  MISS $f"
done
