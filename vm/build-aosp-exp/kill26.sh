#!/system/bin/sh
pkill -9 -f exp26.sh
pkill -9 -f qemu-system-aarch64
sleep 1
echo cleaned
pgrep -f qemu-system-aarch64 | wc -l
