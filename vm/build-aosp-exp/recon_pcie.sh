#!/usr/bin/env bash
Q=/root/vmbuild/qemu-aosp
echo "=== virt.c: VIRT_PCIE_* memmap/irqmap 定义 ==="
grep -n 'VIRT_PCIE' "$Q/hw/arm/virt.c" | head -30
echo
echo "=== virt.h 里的 memmap 顺序（含 PCIE） ==="
grep -n -B2 -A4 'VIRT_PCIE_MMIO\|VIRT_PCIE_PIO\|VIRT_PCIE_ECAM' "$Q/include/hw/arm/virt.h" 2>/dev/null | head -40
echo
echo "=== VirtMachineState 结构 ==="
grep -n -A40 'struct VirtMachineState' "$Q/include/hw/arm/virt.h" 2>/dev/null | head -50
echo
echo "=== ranchu.c: gic_phandle / intc / highmem / machine_init ==="
grep -n -iE 'gic_phandle|phandle|/intc|highmem|msi|machine_init|arm_load_kernel|create_fdt|vbi->fdt' "$Q/hw/arm/ranchu.c" | head -50
echo
echo "=== goldfish_address_space.c: 设备 ID / MSI ==="
grep -n -iE 'PCI_VENDOR|PCI_DEVICE|msi|msix|class_init|class_id|realize|BAR|0x607d|0xf153|0x607D|0xF153' "$Q/hw/pci/goldfish_address_space.c" | head -40
echo
echo "=== 构建配置 ==="
grep -nE 'CONFIG_(PCI|GOLDFISH|PCI_HOST_GPEX|PCI_TEST|VIRTIO_PCI)' "$Q/default-configs/arm-softmmu.mak" "$Q/config-host.mak" 2>/dev/null | head -30
