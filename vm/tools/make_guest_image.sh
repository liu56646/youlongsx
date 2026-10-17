#!/usr/bin/env bash
#
# 从 Google 官方仓库直接拉取 Android arm64 系统镜像，打成 App 需要的 zip。
#
# 为什么不用 sdkmanager：
#   它会把镜像装进 SDK 目录（C 盘），而每个版本约 3 GB 的占用在本机不现实。
#   这里全程用 K 盘 + /tmp 做临时目录，SDK 目录一点不占。
#
# 用法：
#   ./make_guest_image.sh 25              # Android 7.1 → dist/p71_arm64.zip
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

# Android 9 的 SDK userdata.img 只是一个 1MB 的全零占位文件，不是可挂载
# 的 ext4。p9 的 first-stage fstab 会直接 mount /dev/block/vdc，如果不补
# 文件系统，会在 "VFS: Can't find ext4 filesystem" 处直接 reboot。
if [ "$API" -eq 28 ]; then
    P9_DATA="$STAGE/userdata.img"
    if ! dumpe2fs -h "$P9_DATA" >/dev/null 2>&1; then
        rm -f "$P9_DATA"
        # 与 VmDiskStore.DEFAULT_USERDATA_SIZE 保持一致，避免 p9 的
        # FDE（vdc enablecrypto）在“4GB 盘 + 2GB ext4”上做 footer 时踩坑。
        truncate -s 4G "$P9_DATA"
        # Android 9 的 4.4 内核支持 quota（0x100），但不支持 project
        # （0x2000）；带上 project 会让 /data 挂载报
        # "unsupported optional features (2000)"。
        mkfs.ext4 -F -q -L userdata -O quota "$P9_DATA"
        echo "    已生成 p9 userdata.img（4GB ext4）"
    fi
    # Android 9 的 vendor fstab 是 FDE：
    #   /dev/block/vdc /data ... forceencrypt=/dev/block/vdd
    # vdd 必须是一块独立的加密 footer/key 盘。SDK 原包通常带
    # encryptionkey.img；没有时补一块 16MB 的零盘（fs_mgr 首次启动会写入）。
    if [ ! -f "$STAGE/encryptionkey.img" ]; then
        truncate -s 16M "$STAGE/encryptionkey.img"
        echo "    已生成 p9 encryptionkey.img（16MB FDE key/footer 盘）"
    fi
    # 镜像被改名后，vm_qemu.c 仍能识别 p9 SAR 布局。
    : > "$STAGE/vmhost_guest_p9"
fi

# The API 28 SDK vendor init.ranchu.rc relies on qemu-props for the display
# properties.  The VMHost pipe does not provide them, so SurfaceFlinger falls
# back to HWC overlay and fails EGLImage creation.  Fill the properties early
# and force GLES composition / skip bootanim.
if [ "$API" -eq 28 ] && [ -f "$STAGE/vendor.img" ]; then
    P9_VDIR="$WORK/p9-vendor"
    P9_VENDOR="$P9_VDIR/vendor.img"
    P9_RC="$P9_VDIR/init.ranchu.rc"
    rm -rf "$P9_VDIR"
    mkdir -p "$P9_VDIR"
    dd if="$STAGE/vendor.img" of="$P9_VENDOR" bs=512 skip=2048 count=200703 status=none
    debugfs -R "cat /etc/init/hw/init.ranchu.rc" "$P9_VENDOR" > "$P9_RC" 2>/dev/null || true
    if [ -s "$P9_RC" ] && ! grep -q "debug.sf.nobootanimation" "$P9_RC"; then
        python3 - "$P9_RC" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
block = """on post-fs
    setprop debug.sf.hw 0
    setprop ro.sf.hw 0
    setprop debug.sf.nobootanimation 1
    setprop ro.sf.lcd_density 320
    setprop ro.kernel.qemu.uirenderer opengl
    setprop ro.kernel.qemu.opengles.version 131072
    setprop ro.kernel.qemu.dalvik.vm.heapsize 512m
    setprop ro.kernel.qemu.gles 1
    setprop ro.kernel.qemu.lcd_density 320

"""
needle = "\non post-fs-data\n"
if needle not in text:
    raise SystemExit("p9 vendor init.ranchu.rc post-fs-data anchor missing")
path.write_text(
    text.replace(needle, "\n" + block + "on post-fs-data\n", 1),
    encoding="utf-8",
)
PY
        debugfs -w -R "rm /etc/init/hw/init.ranchu.rc" "$P9_VENDOR" >/dev/null 2>&1 || true
        debugfs -w -R "write $P9_RC /etc/init/hw/init.ranchu.rc" "$P9_VENDOR" >/dev/null
        debugfs -w -R "sif /etc/init/hw/init.ranchu.rc mode 0100644" "$P9_VENDOR" >/dev/null
        e2fsck -fy "$P9_VENDOR" >/dev/null 2>&1 || true
        dd if="$P9_VENDOR" of="$STAGE/vendor.img" bs=512 seek=2048 conv=notrunc status=none
        echo "    已补 p9 vendor 显示属性（GLES 合成 + qemu props）"
    fi

    # The p9 SDK image has no usable NIC in this engine.  ranchu-net starts
    # dhcpclient_def, which exits immediately and is restarted forever.
    if [ -s "$P9_RC" ] && ! grep -q "VMHOST_P9_NET_DISABLED" "$P9_RC"; then
        python3 - "$P9_RC" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
for service in ("ranchu-net", "dhcpclient_rtr", "dhcpclient_def"):
    text, _ = re.subn(
        r"\nservice " + re.escape(service) + r" .*?\n(?:    .*\n)+",
        "\n",
        text,
        count=1,
    )
text += "\n# VMHOST_P9_NET_DISABLED\n"
path.write_text(text, encoding="utf-8")
PY
        debugfs -w -R "rm /etc/init/hw/init.ranchu.rc" "$P9_VENDOR" >/dev/null 2>&1 || true
        debugfs -w -R "write $P9_RC /etc/init/hw/init.ranchu.rc" "$P9_VENDOR" >/dev/null
        debugfs -w -R "sif /etc/init/hw/init.ranchu.rc mode 0100644" "$P9_VENDOR" >/dev/null
        e2fsck -fy "$P9_VENDOR" >/dev/null 2>&1 || true
        dd if="$P9_VENDOR" of="$STAGE/vendor.img" bs=512 seek=2048 conv=notrunc status=none
        echo "    已移除 p9 ranchu-net/dhcpclient 服务"
    fi
fi

# ---------------------------------------------------------------- 4b. p71 ramdisk
# Android 7.1 的 SDK ramdisk 与 8+ 不同：
#   - system.img / userdata.img 都是**整盘 ext4**，不是 GPT 分区；
#   - 没有 vendor 分区，也没有 metadata/cache 盘；
#   - init.ranchu.rc 通过 `import init.${ro.qemu.initrc}.rc` 选择加密策略，
#     这个属性通常由官方 emulator 的 qemu-props 注入。我们的引擎不注入它，
#     所以固定导入 noencrypt 版本。
#
# 本引擎在 ranchu 上按“data 先加、system 后加”挂盘，virtio-mmio 的盘符
# 与添加顺序相反，因此 p71 实际是 vda=system、vdb=data。原厂 fstab 期望
# vdb=cache、vdc=data，直接照搬会挂错；这里去掉 cache 条目（p71 正常启动
# 不依赖它），并把 /data 指到 vdb。
repack_p71_ramdisk() {
    local ramdisk="$STAGE/ramdisk.img"
    local rd="$WORK/ramdisk-p71"
    local fstab="$rd/fstab.ranchu-noencrypt"

    echo "    适配 p71 ramdisk（固定 noencrypt fstab + legacy goldfish 输入）"
    rm -rf "$rd"
    mkdir -p "$rd"
    gzip -dc "$ramdisk" | ( cd "$rd" && cpio -idm --quiet --no-absolute-filenames )

    python3 - "$rd/init.ranchu.rc" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
old = "import init.${ro.qemu.initrc}.rc"
new = "import init.ranchu-noencrypt.rc"
if old not in src:
    raise SystemExit("p71 init.ranchu.rc 里找不到 ro.qemu.initrc import")
src = src.replace(old, new, 1)

# The engine deliberately runs p71 without a NIC (the child QEMU path has no
# netdev). ranchu-net would start dhcpclient_def, which exits immediately and
# is restarted by init forever, blocking boot_completed. Network is optional
# for this image; remove the service entries rather than leaving a restart
# loop. The other emulator network services are already disabled by default.
for service in ("ranchu-net", "dhcpclient_rtr", "dhcpclient_def"):
    pattern = (
        r"\nservice " + re.escape(service) +
        r" .*?\n(?:    .*\n)+"
    )
    src, count = re.subn(pattern, "\n", src, count=1)
    if count != 1:
        raise SystemExit("p71 init.ranchu.rc 找不到 service " + service)

path.write_text(src, encoding="utf-8")
PY

    cat > "$fstab" <<'EOF'
# p71 SDK image: system/userdata are whole ext4 images (no GPT, no vendor).
# Engine order on ranchu: userdata first, system last -> vda=system, vdb=data.
/dev/block/vda                                          /system             ext4      ro                                                   wait
/dev/block/vdb                                          /data               ext4      noatime,nosuid,nodev,nomblk_io_submit,errors=panic   wait,check
EOF
    cp "$fstab" "$rd/fstab.ranchu"

    # init.rc 会在 post-fs 阶段 chown/mkdir /cache；给它一个 ramdisk 内的空目录，
    # 避免没有 cache 分区时反复报错。它不持久化，也不影响正常启动。
    mkdir -p "$rd/cache"

    ( cd "$rd" && find . -print0 | cpio --null -o -H newc --owner 0:0 --quiet | gzip -9n > "$ramdisk" )
}

if [ "$API" -eq 25 ]; then
    repack_p71_ramdisk
    # Layout marker used by vm_qemu.c, so the guest keeps the p71 path even
    # when its image directory is renamed after import.
    : > "$STAGE/vmhost_guest_p71"
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

# SDK 的 p71 system/userdata 镜像带有“inode bitmap 尾部填充位未设置”的
# ext4 小问题。p71 的 /data 在 fstab 里是 wait,check，首次启动会执行 e2fsck；
# 先在打包阶段修干净，避免 Android 7.1 的 fsck 因版本差异拒绝挂载。
if [ "$API" -eq 25 ]; then
    # p71 的 Android 7.1 fs_mgr 没有 resize flag，直接在打包阶段
    # 把 userdata 模板扩到 4GiB，guest 挂载时就是最终大小。
    if dumpe2fs -h "$STAGE/userdata.img" >/dev/null 2>&1; then
        truncate -s 4G "$STAGE/userdata.img"
        e2fsck -fy "$STAGE/userdata.img" >/dev/null 2>&1 || true
        resize2fs "$STAGE/userdata.img" >/dev/null 2>&1 || true
        e2fsck -fy "$STAGE/userdata.img" >/dev/null 2>&1 || true
        echo "    已把 p71 userdata 扩到 4GiB"
    fi
    e2fsck -fy "$STAGE/system.img" >/dev/null 2>&1 || true
    e2fsck -fy "$STAGE/userdata.img" >/dev/null 2>&1 || true
    echo "    已清理 p71 system/userdata 的 ext4 bitmap 填充位"
fi

OUT="$DIST/$TAG.zip"
rm -f "$OUT"
( cd "$STAGE" && zip -6 -r "$OUT" . >/dev/null )

echo "==> 产出 $OUT  $(du -h "$OUT" | cut -f1)"
unzip -l "$OUT"

[ "$KEEP" = "--keep" ] || rm -rf "$WORK"
echo "完成。把 $OUT 上传到你的镜像服务器，App 会按 <base>/$TAG.zip 取。"
