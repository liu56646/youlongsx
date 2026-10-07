#!/usr/bin/env bash
Q=/root/vmbuild/qemu-aosp
echo "=== arm-softmmu 关键 config ==="
grep -nE 'CONFIG_(PCI|GOLDFISH|PCI_HOST_GPEX|MSI|PCIE)' "$Q/default-configs/arm-softmmu.mak" | head -30
echo
echo "=== 实际构建的 config（config-host.mak / config-target）==="
grep -rnE 'CONFIG_GOLDFISH=|CONFIG_PCI_HOST_GPEX=|CONFIG_PCI=' "$Q"/config-host.mak "$Q"/config-target.mak "$Q"/config-all-devices.mak 2>/dev/null | head
echo "--- 已生成的 configs（可能别处）---"
ls "$Q"/*.mak 2>/dev/null; ls "$Q"/configs 2>/dev/null | head
echo
echo "=== goldfish_address_space.c 是否用 MSI / 中断 ==="
grep -n -iE 'msi|interrupt|irq|pci_intx' "$Q/hw/pci/goldfish_address_space.c" | head -20
echo
echo "=== qemu_android_address_space_device_init 谁调用 ==="
grep -rn 'qemu_android_address_space_device_init\|qemu_android_sync_init\|qemu_android_pipe_init' "$Q" --include='*.c' --include='*.cpp' --include='*.h' 2>/dev/null | grep -v '^.*\.o:' | head -20
echo
echo "=== ranchu.c 的 include 与 create_gic 片段 ==="
sed -n '1,40p' "$Q/hw/arm/ranchu.c"
echo "..."
sed -n '276,300p' "$Q/hw/arm/ranchu.c"
echo
echo "=== ranchu.c machine_init / main 尾部 ==="
sed -n '500,600p' "$Q/hw/arm/ranchu.c"
