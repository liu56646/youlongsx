#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
rm -rf /tmp/rdp2; mkdir -p /tmp/rdp2
python3 extract_cpio.py ramdisk_probe.img /tmp/rdp2 >/dev/null 2>&1
echo "=== ramdisk /lib/modules ==="
ls /tmp/rdp2/lib/modules 2>/dev/null | head -60
echo
KM=/tmp/rdp2/lib/modules/goldfish_address_space.ko
if [ ! -f "$KM" ]; then
    echo "(ramdisk 里没有，找 vendor/system 里的)"
    KM=""
fi
if [ -n "$KM" ]; then
    echo "=== $KM strings ==="
    strings -a "$KM" | grep -iE 'pci|platform|of:|compatible|goldfish|address_space|virtgpu' | head -40
    echo "=== modalias/description ==="
    strings -a "$KM" | grep -iE '^description=|^alias=|^license=|^name=' | head -20
fi
