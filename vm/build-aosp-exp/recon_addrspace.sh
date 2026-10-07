#!/usr/bin/env bash
Q=/root/vmbuild/qemu-aosp
echo "=== ranchu.c: 关键字 ==="
grep -n -iE 'pci|gpex|sysbus|virtio-mmio|create_simple_device|address_space|DEFINE_MACHINE|machine_init' "$Q/hw/arm/ranchu.c" | head -80
echo
echo "=== goldfish_address_space.c: 类型/接口 ==="
grep -n -iE 'DEFINE_|TypeInfo|TYPE_|pci_|sysbus_|realize|instance_init|class_init|memory_region' "$Q/hw/misc/goldfish_address_space.c" | head -80
echo
echo "=== 相关文件 ==="
ls -la "$Q/hw/misc/goldfish_address_space.c" "$Q/include/hw/pci/goldfish_address_space.h" 2>/dev/null
echo
echo "=== virt.c 里怎么建的 ==="
grep -n -A1 -B3 'goldfish_address_space' "$Q/hw/arm/virt.c" | head -40
