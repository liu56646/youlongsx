#!/usr/bin/env bash
#
# 切换访客（guest）对外的「设备身份」。
#
# 背景：
#   guest 的品牌/型号/指纹等属性**唯一**来自 product.img 的 /build.prop，
#   实测该文件里只有这一组（其余分区没有覆盖它们）：
#       ro.product.product.brand / device / manufacturer / model / name
#       ro.product.build.fingerprint / id / tags / type
#       ro.build.characteristics
#   所以「模拟成什么设备」= 改写这个文件。
#
# 用法：
#   ./set_device_profile.sh --list                      # 列出内置机型
#   ./set_device_profile.sh pixel_7                     # 应用内置机型
#   ./set_device_profile.sh show                        # 查看当前身份
#   ./set_device_profile.sh set model="Pixel 7" \
#         brand=google device=panther manufacturer=Google   # 自定义任意字段
#
# 产物：直接改写 images/<tag>/product.img 里的 /build.prop（原文件备份为 product.img.bak）
#
set -euo pipefail

# ---------------------------------------------------------------- 配置
IMG="${IMG:-}"
if [ -z "$IMG" ]; then
    # 默认取设备上的镜像路径（用 adb pull 到本地临时目录再改）
    IMG="/mnt/c/Users/liu/AppData/Local/Temp/vmdbg/product.img"
fi
PROP_PATH="/build.prop"

command -v debugfs >/dev/null || { echo "需要 debugfs（apt install e2fsprogs）" >&2; exit 1; }

# ---------------------------------------------------------------- 内置机型
# 每个机型给出 5 个核心字段；fingerprint 按 Android 惯例拼装。
profile_fields() {
    case "$1" in
        pixel_7)
            echo "brand=google|device=panther|manufacturer=Google|model=Pixel 7|name=panther|release=13|sdk=33|id=TQ3A.230805.001" ;;
        pixel_5)
            echo "brand=google|device=redfin|manufacturer=Google|model=Pixel 5|name=redfin|release=11|sdk=30|id=RQ3A.210805.001.A1" ;;
        pixel_4a)
            echo "brand=google|device=sunfish|manufacturer=Google|model=Pixel 4a|name=sunfish|release=11|sdk=30|id=RQ3A.210805.001.A1" ;;
        xiaomi_13)
            echo "brand=Xiaomi|device=fuxi|manufacturer=Xiaomi|model=2211133C|name=fuxi|release=13|sdk=33|id=TKQ1.221114.001" ;;
        samsung_s23)
            echo "brand=samsung|device=dm1q|manufacturer=samsung|model=SM-S911B|name=dm1q|release=13|sdk=33|id=TP1A.220624.014" ;;
        oneplus_11)
            echo "brand=OnePlus|device=PHB110|manufacturer=OnePlus|model=PHB110|name=PHB110|release=13|sdk=33|id=TP1A.220905.001" ;;
        *)
            return 1 ;;
    esac
}

list_profiles() {
    echo "内置机型："
    for p in pixel_7 pixel_5 pixel_4a xiaomi_13 samsung_s23 oneplus_11; do
        printf "  %-14s %s\n" "$p" "$(profile_fields "$p" | tr '|' ' ' | sed 's/=/=/g')"
    done
}

# ---------------------------------------------------------------- 读写 build.prop
dump_prop() {
    debugfs -R "cat $PROP_PATH" "$IMG" 2>/dev/null
}

show_current() {
    echo "当前身份（$IMG）："
    dump_prop | grep -E "^ro\.(product\.product|product\.build|build\.characteristics)" | sed 's/^/  /'
}

# 生成新的 build.prop（保留原有与身份无关的行）
gen_prop() {
    local brand="$1" device="$2" manufacturer="$3" model="$4" name="$5"
    local release="$6" sdk="$7" bid="$8"
    dump_prop | awk -v brand="$brand" -v device="$device" -v mfr="$manufacturer" \
        -v model="$model" -v name="$name" -v rel="$release" -v sdk="$sdk" -v bid="$bid" '
    BEGIN {
        fp = "Android/" name "/" device ":" rel "/" bid ":userdebug/test-keys"
    }
    /^ro\.product\.product\.brand=/        { print "ro.product.product.brand=" brand; next }
    /^ro\.product\.product\.device=/       { print "ro.product.product.device=" device; next }
    /^ro\.product\.product\.manufacturer=/ { print "ro.product.product.manufacturer=" mfr; next }
    /^ro\.product\.product\.model=/        { print "ro.product.product.model=" model; next }
    /^ro\.product\.product\.name=/         { print "ro.product.product.name=" name; next }
    /^ro\.product\.build\.fingerprint=/    { print "ro.product.build.fingerprint=" fp; next }
    /^ro\.product\.build\.id=/             { print "ro.product.build.id=" bid; next }
    /^ro\.product\.build\.version\.release=/        { print "ro.product.build.version.release=" rel; next }
    /^ro\.product\.build\.version\.release_or_codename=/ { print "ro.product.build.version.release_or_codename=" rel; next }
    /^ro\.product\.build\.version\.sdk=/   { print "ro.product.build.version.sdk=" sdk; next }
    /^ro\.build\.characteristics=emulator/ { print "ro.build.characteristics=phone"; next }
                                                   { print }
    '
}

apply_prop() {
    local newprop="$1"
    [ -f "$IMG" ] || { echo "镜像不存在：$IMG" >&2; exit 1; }
    [ -f "$IMG.bak" ] || cp "$IMG" "$IMG.bak"
    # debugfs 写文件需要宿主机上的临时文件；用短路径规避长度限制
    local tmp=/tmp/vmhost_build.prop
    printf '%s\n' "$newprop" > "$tmp"
    debugfs -w -R "rm $PROP_PATH" "$IMG" >/dev/null 2>&1 || true
    debugfs -w -R "write $tmp $PROP_PATH" "$IMG" >/dev/null 2>&1
    # 权限与属主对齐原文件（100600 root:root）
    debugfs -w -R "sif $PROP_PATH mode 0100600" "$IMG" >/dev/null 2>&1 || true
    debugfs -w -R "sif $PROP_PATH uid 0" "$IMG" >/dev/null 2>&1 || true
    debugfs -w -R "sif $PROP_PATH gid 0" "$IMG" >/dev/null 2>&1 || true
    echo "已写入。校验："
    dump_prop | grep -E "^ro\.(product\.product|product\.build\.fingerprint|build\.characteristics)" | sed 's/^/  /'
}

# ---------------------------------------------------------------- 主流程
case "${1:-}" in
    --list|-l) list_profiles ;;
    show)      show_current ;;
    set)
        shift
        declare -A kv
        for a in "$@"; do kv["${a%%=*}"]="${a#*=}"; done
        apply_prop "$(gen_prop \
            "${kv[brand]:-Android}" "${kv[device]:-emulator_arm64}" \
            "${kv[manufacturer]:-unknown}" "${kv[model]:-Custom Device}" \
            "${kv[name]:-${kv[device]:-emulator_arm64}}" \
            "${kv[release]:-11}" "${kv[sdk]:-30}" "${kv[id]:-RSR1.210722.013.A4}")"
        ;;
    ""|-h|--help)
        sed -n '2,28p' "$0" ;;
    *)
        fields="$(profile_fields "$1")" || { echo "未知机型：$1（用 --list 查看）" >&2; exit 2; }
        declare -A kv
        IFS='|' read -ra parts <<< "$fields"
        for a in "${parts[@]}"; do kv["${a%%=*}"]="${a#*=}"; done
        apply_prop "$(gen_prop "${kv[brand]}" "${kv[device]}" "${kv[manufacturer]}" \
            "${kv[model]}" "${kv[name]}" "${kv[release]}" "${kv[sdk]}" "${kv[id]}")"
        ;;
esac
