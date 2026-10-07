#!/system/bin/sh
LOG=/data/local/tmp/exp5.log
echo "=== qemu procs ==="
ps -A | grep qemu
echo "=== init/partition 相关 ==="
grep -nE "init:|partition|metadata|super|first stage|mount|vda|vdb|vdc" "$LOG" | tail -40
echo "=== 行数 ==="
wc -l "$LOG"
