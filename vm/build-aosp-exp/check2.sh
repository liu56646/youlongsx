#!/system/bin/sh
LOG="${1:-/data/local/tmp/exp6.log}"
echo "=== 行数 ==="; wc -l "$LOG"
echo "=== virtio / blk ==="; grep -nE "virtio_blk|virtio-mmio|vda|vdb|vdc|vdd" "$LOG" | tail -15
echo "=== init / fs_mgr / mount ==="; grep -nE "init:|fs_mgr|mount|super|metadata|first stage|switch_root|avb|dm-" "$LOG" | tail -30
echo "=== 最后 6 行 ==="; tail -6 "$LOG"
