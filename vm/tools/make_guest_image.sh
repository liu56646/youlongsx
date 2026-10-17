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
# 目标结构（VmImageProvider 依赖），根目录直放、不套一层：
#   kernel  system.img  vendor.img  ramdisk.img  userdata.img
#   （Android 11+ 还要 metadata.img，见下）
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

# metadata 盘（Android 11+ 的 FBE 元数据分区）—— **必须随包分发**：
# 引擎只在文件存在时才挂这块盘（vm_qemu.c 的 add_blk_dev），缺了之后它后面的
# 盘整体前移一位 —— /metadata 与 /data 全部挂错，guest 起来后 zygote 建不了
# /data/dalvik-cache 直接 SIGABRT（实测 `app_process64 ... signal=6`）。
# guest 是整盘挂载（`/dev/block/vde -> /metadata`），所以是"纯 ext4 整盘"，不需要 GPT。
if [ "$API" -ge 30 ]; then
    META="$STAGE/metadata.img"
    truncate -s 16M "$META"
    mkfs.ext4 -F -q -L metadata "$META"
    echo "    已生成 metadata.img（16MB ext4）"
fi

# ---------------------------------------------------------------- 5. 启动负载精简
# 依据真机实测（TCG，无 KVM 硬件加速）：
#   a) 缺 regulatory.db 时 ueventd 会空等 51.98s（等一个永远不来的固件，见
#      console.log 的 "could not find firmware for regulatory.db"）；补上后降到 ~60ms。
#      regulatory.db 是 WiFi 监管库，沙箱不用 WiFi 也无妨，只要能满足 ueventd 查找。
#   b) installd.rc 里 98 条 `mkdir /config/sdcardfs/extensions/...` 在 TCG 下每条约
#      380ms（合计 ~21s），而 Android 11 沙箱并不使用 sdcardfs 扩展名策略，可直接移除。
# 两项合计把 system_server 启动提前约 71s（真机实测 386.8s → 315.4s）。
debugfs -R "cat /system/etc/init/installd.rc" "$STAGE/system.img" > "$WORK/installd.rc" 2>/dev/null || true
if [ -s "$WORK/installd.rc" ] && grep -q 'mkdir /config/sdcardfs' "$WORK/installd.rc"; then
    grep -v 'mkdir /config/sdcardfs' "$WORK/installd.rc" > "$WORK/installd.new.rc" || true
    debugfs -w -R "rm /system/etc/init/installd.rc" "$STAGE/system.img" >/dev/null 2>&1 || true
    debugfs -w -R "write $WORK/installd.new.rc /system/etc/init/installd.rc" "$STAGE/system.img" >/dev/null 2>&1 || true
    debugfs -w -R "sif /system/etc/init/installd.rc mode 0100644" "$STAGE/system.img" >/dev/null 2>&1 || true
    echo "    已移除 installd.rc 的 sdcardfs mkdir（约省 21s）"
fi

#   c) bootstat 的 `--set_system_boot_reason` 实测要 20.4s（纯启动统计，沙箱不需要）。
#   d) bootanim 实测后台跑 49.8s（本镜像里 debug.sf.nobootanimation 未生效），
#      沙箱不需要开机动画，直接移除服务定义即可。
debugfs -R "cat /system/etc/init/bootstat.rc" "$STAGE/system.img" > "$WORK/bootstat.rc" 2>/dev/null || true
if [ -s "$WORK/bootstat.rc" ] && grep -q -- '--set_system_boot_reason' "$WORK/bootstat.rc"; then
    sed 's|^\( *exec_background .*--set_system_boot_reason\)|#\1|' "$WORK/bootstat.rc" > "$WORK/bootstat.new.rc"
    debugfs -w -R "rm /system/etc/init/bootstat.rc" "$STAGE/system.img" >/dev/null 2>&1 || true
    debugfs -w -R "write $WORK/bootstat.new.rc /system/etc/init/bootstat.rc" "$STAGE/system.img" >/dev/null 2>&1 || true
    debugfs -w -R "sif /system/etc/init/bootstat.rc mode 0100644" "$STAGE/system.img" >/dev/null 2>&1 || true
    echo "    已禁用 bootstat --set_system_boot_reason（约省 20s）"
fi
if debugfs -R "ls /system/etc/init" "$STAGE/system.img" 2>/dev/null | grep -q 'bootanim\.rc'; then
    debugfs -w -R "rm /system/etc/init/bootanim.rc" "$STAGE/system.img" >/dev/null 2>&1 || true
    echo "    已移除 bootanim 服务（省去后台动画约 50s 的 CPU 占用）"
fi

REGDB=/lib/firmware/regulatory.db
if [ ! -f "$REGDB" ] && command -v apt-get >/dev/null 2>&1; then
    apt-get install -y wireless-regdb >/dev/null 2>&1 || true
fi
if [ -f "$REGDB" ]; then
    debugfs -w -R "mkdir /system/etc/firmware" "$STAGE/system.img" >/dev/null 2>&1 || true
    debugfs -w -R "write $REGDB /system/etc/firmware/regulatory.db" "$STAGE/system.img" >/dev/null 2>&1 || true
    if [ -f "$REGDB.p7s" ]; then
        debugfs -w -R "write $REGDB.p7s /system/etc/firmware/regulatory.db.p7s" "$STAGE/system.img" >/dev/null 2>&1 || true
    fi
    echo "    已补 regulatory.db（避免 ueventd 空等约 52s）"
else
    echo "    ！未找到 regulatory.db：guest 首启时 ueventd 会空等约 52s" >&2
fi

OUT="$DIST/$TAG.zip"
rm -f "$OUT"
( cd "$STAGE" && zip -6 -r "$OUT" . >/dev/null )

echo "==> 产出 $OUT  $(du -h "$OUT" | cut -f1)"
unzip -l "$OUT"

[ "$KEEP" = "--keep" ] || rm -rf "$WORK"
echo "完成。把 $OUT 上传到你的镜像服务器，App 会按 <base>/$TAG.zip 取。"
