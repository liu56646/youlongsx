#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
echo "=== guest kernel: PCIe / address space 相关 ==="
grep -ainE 'pci-host-ecam|pcie|PCI host bridge|goldfish_address_space|address_space|pci 0000' g26.log | head -40
echo
echo "=== HWC 时间线 ==="
grep -anE "hwcomposer-2-3|received signal 6|restart surfaceflinger" g26.log | head -12
echo
echo "=== guest 时间轴末端 ==="
grep -aoE '^\[ *[0-9]+\.[0-9]+\]' g26.log | tail -1
echo
echo "=== meta.img: /metadata 文件 ==="
adb=1
e2fsck -fy meta_bt.img >/dev/null 2>&1 || true
debugfs -R 'ls -l /' meta_bt.img 2>/dev/null | tail -6
echo "=== hwc_crash.log 里的 LOG/ABORT 行（最后 30）==="
debugfs -R 'cat /hwc_crash.log' meta_bt.img 2>/dev/null | grep -nE '\[LOG|\[ABORT\]|HWC CRASH|GoldfishMapper|host_memory_allocator' | tail -30
echo "=== hwcbt.log 尾部 ==="
debugfs -R 'cat /hwcbt.log' meta_bt.img 2>/dev/null | tail -30
