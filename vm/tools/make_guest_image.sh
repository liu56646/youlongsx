#!/usr/bin/env bash
#
# 从 Google 官方仓库直接拉取 Android arm64 系统镜像，打成 App 需要的 zip。
#
# 为什么不用 sdkmanager：
#   它会把镜像装进 SDK 目录（C 盘），而每个版本约 3 GB 的占用在本机不现实。
#   这里全程用 K 盘 + /tmp 做临时目录，SDK 目录一点不占。
#
# 用法：
#   ./make_guest_image.sh 28              # Android 9  → dist/p9_arm64.zip
#   ./make_guest_image.sh 33 default      # Android 13 → dist/p13_arm64.zip
#   ./make_guest_image.sh 30 default --keep   # 保留临时目录便于排查
#
set -euo pipefail

API="${1:?用法: $0 <api-level> [variant] [--keep]}"
VARIANT="${2:-default}"
KEEP="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST="$REPO_DIR/dist"
WORK="/tmp/guestimg-$API"

# API → Android 版本号，用于生成 tag（p9_arm64 / p11_arm64 / p13_arm64 …）
case "$API" in
    24) VER=70 ;; 25) VER=71 ;; 26) VER=80 ;; 27) VER=81 ;;
    28) VER=9  ;; 29) VER=10 ;; 30) VER=11 ;; 31) VER=12 ;;
    32) VER=12 ;; 33) VER=13 ;; 34) VER=14 ;; 35) VER=15 ;; 36) VER=16 ;;
    *)  VER="$API" ;;
esac
TAG="p${VER}_arm64"

mkdir -p "$DIST" "$WORK"
cd "$WORK"

echo "==> API $API ($VARIANT)  →  $TAG"

# ---------------------------------------------------------------- 1. 找直链
XML="$WORK/sys-img.xml"
curl -sf -o "$XML" \
    "https://dl.google.com/android/repository/sys-img/android/sys-img2-1.xml"

ZIP_URL="$(python3 "$SCRIPT_DIR/../tools/list_sysimg.py" "$XML" "$VARIANT" \
           | awk -v a="API $API " '$0 ~ a {print $NF}')"
if [ -z "$ZIP_URL" ]; then
    echo "!! 仓库里没有 API $API 的 $VARIANT arm64 镜像" >&2
    exit 1
fi
echo "    直链：$ZIP_URL"

# ---------------------------------------------------------------- 2. 下载
ZIP="$WORK/sys.img.zip"
if [ -f "$ZIP" ]; then
    echo "    复用已下载的压缩包（$(du -h "$ZIP" | cut -f1)）"
else
    curl -# -o "$ZIP" "$ZIP_URL"
fi

# ---------------------------------------------------------------- 3. 解压
rm -rf "$WORK/raw"
mkdir -p "$WORK/raw"
unzip -q "$ZIP" -d "$WORK/raw"

SRC="$(dirname "$(find "$WORK/raw" -name 'system.img' -print -quit)")"
if [ -z "$SRC" ] || [ "$SRC" = "." ]; then
    echo "!! 解压后找不到 system.img，实际内容如下：" >&2
    find "$WORK/raw" -maxdepth 3 -type f | sed 's/^/      /' >&2
    echo "   （新版本 Android 可能改用 super.img 动态分区，本引擎暂不支持）" >&2
    exit 2
fi

echo "    镜像内容："
ls -1 "$SRC" | sed 's/^/      /'

# ---------------------------------------------------------------- 4. 打扁平 zip
# 目标结构（VmImageProvider 依赖）：
#   kernel  system.img  vendor.img  ramdisk.img  userdata.img
STAGE="$WORK/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

for f in kernel kernel-ranchu ramdisk.img system.img vendor.img userdata.img; do
    [ -f "$SRC/$f" ] || continue
    if [ "$f" = "kernel-ranchu" ]; then
        cp "$SRC/$f" "$STAGE/kernel"
    else
        cp "$SRC/$f" "$STAGE/$f"
    fi
done

[ -f "$STAGE/kernel" ] || { echo "!! 镜像里没有 kernel / kernel-ranchu" >&2; exit 3; }
[ -f "$STAGE/system.img" ] || { echo "!! 镜像里没有 system.img" >&2; exit 3; }
[ -f "$STAGE/userdata.img" ] || echo "    ！缺少 userdata.img，访客可能无法挂载 /data" >&2

OUT="$DIST/$TAG.zip"
rm -f "$OUT"
( cd "$STAGE" && zip -6 -r "$OUT" . >/dev/null )

echo "==> 产出 $OUT  $(du -h "$OUT" | cut -f1)"
unzip -l "$OUT"

[ "$KEEP" = "--keep" ] || rm -rf "$WORK"
echo "完成。把 $OUT 上传到你的镜像服务器，App 会按 <base>/$TAG.zip 取。"
