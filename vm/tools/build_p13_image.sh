#!/usr/bin/env bash
#
# Build a VMHost-compatible Android 13 (API 33, arm64) image from the
# official SDK emulator package.
#
# Usage:
#   ./build_p13_image.sh [source.zip] [kernel/Image] [output.zip]
#
# Defaults:
#   source: vm/dist/p13_arm64.zip
#   kernel: /root/kernel_common/arch/arm64/boot/Image
#   output: vm/dist/p13_arm64_bootable.zip
#
# The SDK package stores system_ext/product/vendor inside system.img's super
# partition. VMHost uses standalone read-only ext4 images, so this script
# unpacks super and writes a complete first-stage fstab into the GKI ramdisk.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC_ZIP="${1:-}"
if [ -z "$SRC_ZIP" ]; then
    if [ -f "$REPO_DIR/dist/p13_arm64_sdk.zip" ]; then
        SRC_ZIP="$REPO_DIR/dist/p13_arm64_sdk.zip"
    else
        SRC_ZIP="$REPO_DIR/dist/p13_arm64.zip"
    fi
fi
KERNEL_IMAGE="${2:-/root/kernel_common/arch/arm64/boot/Image}"
OUTPUT="${3:-$REPO_DIR/dist/p13_arm64_bootable.zip}"
LUNPACK="$REPO_DIR/build-aosp-exp/lpunpack.py"
EXTRACT_CPIO="$REPO_DIR/build-aosp-exp/extract_cpio.py"

for tool in unzip zip python3 debugfs mkfs.ext4 gzip cpio lz4; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing build tool: $tool" >&2
        exit 1
    }
done
[ -f "$SRC_ZIP" ] || { echo "source zip not found: $SRC_ZIP" >&2; exit 1; }
[ -f "$KERNEL_IMAGE" ] || { echo "kernel Image not found: $KERNEL_IMAGE" >&2; exit 1; }
[ -f "$LUNPACK" ] || { echo "lpunpack helper not found: $LUNPACK" >&2; exit 1; }
[ -f "$EXTRACT_CPIO" ] || { echo "cpio helper not found: $EXTRACT_CPIO" >&2; exit 1; }

WORK="$(mktemp -d /tmp/vmhost-p13.XXXXXX)"
KEEP_WORK="${P13_KEEP_WORK:-0}"
cleanup() {
    if [ "$KEEP_WORK" = "1" ]; then
        echo "work directory kept: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

mkdir -p "$WORK/raw" "$WORK/super" "$WORK/ramdisk" "$WORK/stage" "$WORK/out"
echo "==> source: $SRC_ZIP"
echo "==> kernel: $KERNEL_IMAGE"
echo "==> work:   $WORK"

echo "==> extracting SDK images"
unzip -p "$SRC_ZIP" system.img > "$WORK/raw/system.img"
unzip -p "$SRC_ZIP" ramdisk.img > "$WORK/raw/ramdisk.img"
if unzip -p "$SRC_ZIP" userdata.img > "$WORK/raw/userdata.img" 2>/dev/null; then
    :
else
    truncate -s 1M "$WORK/raw/userdata.img"
fi

echo "==> unpacking super logical partitions"
python3 "$LUNPACK" "$WORK/raw/system.img" "$WORK/super"
for part in system system_ext product vendor; do
    [ -s "$WORK/super/$part.img" ] || {
        echo "super partition missing: $part" >&2
        exit 1
    }
done

replace_ext4_file() {
    local image="$1"
    local guest_path="$2"
    local source_file="$3"
    local mode="${4:-0100644}"

    debugfs -w -R "rm $guest_path" "$image" >/dev/null 2>&1 || true
    debugfs -w -R "write $source_file $guest_path" "$image" >/dev/null
    debugfs -w -R "sif $guest_path mode $mode" "$image" >/dev/null
    debugfs -R "stat $guest_path" "$image" 2>&1 | grep -q "Type: regular" || {
        echo "failed to replace $guest_path in $image" >&2
        exit 1
    }
}

echo "==> patching system zygote service"
for rc_name in init.zygote64.rc init.zygote64_32.rc; do
    rc_path="/etc/init/hw/$rc_name"
    rc_file="$WORK/$rc_name"
    debugfs -R "cat $rc_path" "$WORK/super/system.img" > "$rc_file"
    python3 - "$rc_file" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if "-Xverify:none" not in text:
    text = text.replace(
        "/system/bin/app_process64 -Xzygote",
        "/system/bin/app_process64 -Xverify:none -Xzygote",
        1,
    )
path.write_text(text, encoding="utf-8")
PY
    replace_ext4_file "$WORK/super/system.img" "$rc_path" "$rc_file"
done

# The SDK image does not contain the conscrypt APEX self-test binary, but
# init still exec_starts it when apexd becomes ready.  The service has
# reboot_on_failure, so the missing binary reboots the guest.  The regular
# system BoringSSL self-tests already passed; disable only the APEX triggers.
echo "==> patching system BoringSSL APEX self-test"
boringssl_rc="/system/etc/init/hw/init.rc"
boringssl_file="$WORK/init.rc"
debugfs -R "cat $boringssl_rc" "$WORK/super/system.img" > "$boringssl_file" 2>/dev/null || true
if [ -s "$boringssl_file" ]; then
    python3 - "$boringssl_file" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(True)
out = []
changed = False
for line in lines:
    stripped = line.lstrip()
    if not stripped.startswith("#") and (
        "apexd.status=ready" in line
        or "exec_start boringssl_self_test_apex" in line
    ):
        line = "# " + line
        changed = True
    out.append(line)
if changed:
    path.write_text("".join(out), encoding="utf-8")
PY
    if grep -q '^# on property:apexd.status=ready' "$boringssl_file"; then
        replace_ext4_file "$WORK/super/system.img" "$boringssl_rc" "$boringssl_file"
        e2fsck -fy "$WORK/super/system.img" >/dev/null 2>&1 || true
    fi
fi

# llkd misreads TCG slowness as a livelock and SIGKILLs system_server
# (observed on p11: "Killing 'system_server' to check forward scheduling
# progress"), restarting the whole boot.  It also enables khungtask.
if debugfs -R "ls /system/etc/init" "$WORK/super/system.img" 2>/dev/null | grep -q 'llkd\.rc'; then
    echo "==> removing llkd watchdog"
    debugfs -w -R "rm /system/etc/init/llkd.rc" "$WORK/super/system.img" >/dev/null 2>&1 || true
    e2fsck -fy "$WORK/super/system.img" >/dev/null 2>&1 || true
fi

echo "==> patching vendor properties and boot rules"
cat > "$WORK/fstab.ranchu" <<'EOF'
# VMHost p13: standalone ext4 partitions, explicit virtio-blk device paths.
/dev/block/vda   /system      ext4  ro,barrier=1  wait,first_stage_mount
/dev/block/vdb   /vendor      ext4  ro,barrier=1  wait,first_stage_mount
/dev/block/vdc   /product     ext4  ro,barrier=1  wait,first_stage_mount
/dev/block/vdd   /system_ext  ext4  ro,barrier=1  wait,first_stage_mount
/dev/block/vde   /metadata    ext4  noatime,nosuid,nodev  wait,formattable,first_stage_mount
/dev/block/vdf   /data        ext4  noatime,nosuid,nodev  wait,check,formattable
EOF
replace_ext4_file "$WORK/super/vendor.img" "/etc/fstab.ranchu" "$WORK/fstab.ranchu"

debugfs -R "cat /build.prop" "$WORK/super/vendor.img" > "$WORK/vendor-build.prop"
python3 - "$WORK/vendor-build.prop" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
out = []
found = False
for line in lines:
    if line.startswith("ro.zygote="):
        out.append("ro.zygote=zygote64")
        found = True
    else:
        out.append(line)
if not found:
    out.append("ro.zygote=zygote64")
path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
replace_ext4_file "$WORK/super/vendor.img" "/build.prop" "$WORK/vendor-build.prop"

debugfs -R "cat /etc/init/hw/init.ranchu.rc" "$WORK/super/vendor.img" > "$WORK/init.ranchu.rc"
python3 - "$WORK/init.ranchu.rc" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

props = """    setprop ro.hw_timeout_multiplier 10
    setprop dalvik.vm.usejit false
    setprop dalvik.vm.extra-opts -Xverify:none
    setprop pm.dexopt.first-boot skip
"""
if "ro.hw_timeout_multiplier" not in text:
    text = text.replace("on early-init\n", "on early-init\n" + props, 1)

if "mkdir /metadata/hwc" not in text:
    text = text.replace(
        "on post-fs-data\n",
        "on post-fs-data\n    mkdir /metadata/hwc 0777 system system\n",
        1,
    )

text = text.replace(
    "service goldfish-logcat /system/bin/logcat -f /dev/hvc1 ${ro.boot.logcat}",
    "service goldfish-logcat /system/bin/logcat -f /metadata/hwc/logcat",
)
path.write_text(text, encoding="utf-8")
PY
replace_ext4_file "$WORK/super/vendor.img" "/etc/init/hw/init.ranchu.rc" "$WORK/init.ranchu.rc"

cat > "$WORK/vmhost_hwc_wrap.sh" <<'EOF'
#!/system/bin/sh
exec /vendor/bin/hw/android.hardware.graphics.composer@2.4-service > /metadata/hwc/hwc.out 2>&1
EOF
replace_ext4_file "$WORK/super/vendor.img" "/bin/vmhost_hwc_wrap.sh" \
    "$WORK/vmhost_hwc_wrap.sh" 0100755

debugfs -R "cat /etc/init/android.hardware.graphics.composer@2.4-service.rc" \
    "$WORK/super/vendor.img" > "$WORK/composer.rc"
python3 - "$WORK/composer.rc" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace(
    "service vendor.hwcomposer-2-4 /vendor/bin/hw/android.hardware.graphics.composer@2.4-service",
    "service vendor.hwcomposer-2-4 /system/bin/sh /vendor/bin/vmhost_hwc_wrap.sh",
)
if "seclabel u:r:hal_graphics_composer_default:s0" not in text:
    text = text.replace(
        "    capabilities SYS_NICE\n",
        "    capabilities SYS_NICE\n    seclabel u:r:hal_graphics_composer_default:s0\n",
        1,
    )
path.write_text(text, encoding="utf-8")
PY
replace_ext4_file "$WORK/super/vendor.img" \
    "/etc/init/android.hardware.graphics.composer@2.4-service.rc" "$WORK/composer.rc"

echo "==> rebuilding GKI ramdisk with first-stage fstab"
if file "$WORK/raw/ramdisk.img" | grep -q "LZ4 compressed"; then
    lz4 -d -c "$WORK/raw/ramdisk.img" > "$WORK/ramdisk.cpio"
else
    if gzip -t "$WORK/raw/ramdisk.img" 2>/dev/null; then
        gzip -dc "$WORK/raw/ramdisk.img" > "$WORK/ramdisk.cpio"
    else
        cp "$WORK/raw/ramdisk.img" "$WORK/ramdisk.cpio"
    fi
fi
python3 "$EXTRACT_CPIO" "$WORK/ramdisk.cpio" "$WORK/ramdisk"
mkdir -p "$WORK/ramdisk/first_stage_ramdisk"
cp "$WORK/fstab.ranchu" "$WORK/ramdisk/fstab.ranchu"
cp "$WORK/fstab.ranchu" "$WORK/ramdisk/first_stage_ramdisk/fstab.ranchu"
(
    cd "$WORK/ramdisk"
    find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 -n > "$WORK/ramdisk.img"
)

echo "==> staging flat VMHost image"
cp "$WORK/super/system.img" "$WORK/stage/system.img"
cp "$WORK/super/system_ext.img" "$WORK/stage/system_ext.img"
cp "$WORK/super/product.img" "$WORK/stage/product.img"
cp "$WORK/super/vendor.img" "$WORK/stage/vendor.img"
cp "$WORK/ramdisk.img" "$WORK/stage/ramdisk.img"
cp "$WORK/raw/userdata.img" "$WORK/stage/userdata.img"

if file "$KERNEL_IMAGE" | grep -q "gzip compressed"; then
    gzip -dc "$KERNEL_IMAGE" > "$WORK/Image"
else
    cp "$KERNEL_IMAGE" "$WORK/Image"
fi
gzip -9 -n -c "$WORK/Image" > "$WORK/stage/kernel"

truncate -s 16M "$WORK/stage/metadata.img"
mkfs.ext4 -F -q -L metadata "$WORK/stage/metadata.img"

echo "==> verifying staged image"
python3 - "$WORK/stage" <<'PY'
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])
for name in ("system", "system_ext", "product", "vendor", "metadata"):
    path = root / (name + ".img")
    with path.open("rb") as f:
        f.seek(0x438)
        magic = f.read(2)
    if magic != b"\x53\xef":
        raise SystemExit("not an ext4 image: %s" % path)
    print("    ext4 %-12s %d MiB" % (name, path.stat().st_size // 1048576))
PY

ZIP_TMP="$WORK/out/p13_arm64_bootable.zip"
(
    cd "$WORK/stage"
    zip -6 -q -r "$ZIP_TMP" .
)

echo "==> fstab"
cat "$WORK/fstab.ranchu"
echo "==> ramdisk entries"
gzip -dc "$WORK/stage/ramdisk.img" | cpio -it 2>/dev/null | grep -E "^(init|fstab.ranchu|first_stage_ramdisk/fstab.ranchu)$"
echo "==> output"
ls -lh "$ZIP_TMP"
unzip -l "$ZIP_TMP"

mkdir -p "$(dirname "$OUTPUT")"
cp "$ZIP_TMP" "$OUTPUT.new"
mv "$OUTPUT.new" "$OUTPUT"
echo "==> wrote $OUTPUT"
