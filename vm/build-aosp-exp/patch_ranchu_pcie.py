#!/usr/bin/env python3
# 给 ranchu 机器补一个 PCIe host（gpex）+ goldfish_address_space 设备。
# 背景：guest 的 gralloc(GoldfishMapper) 必需 /dev/goldfish_address_space，
#       而 goldfish_address_space 是 PCI 设备（vendor 0x607D, device 0xF153），
#       ranchu 原来没有任何 PCI 总线 -> gralloc 打开失败 -> HWC abort。
import os
import shutil
import sys

SRC = "/root/vmbuild/qemu-aosp/hw/arm/ranchu.c"
MARK = "RANCHU_PCIE_MMIO"

src = open(SRC, "r", encoding="utf-8", errors="surrogateescape").read()
if MARK in src:
    print("already patched, nothing to do")
    sys.exit(0)

def rep(old, new, cnt=1):
    global src
    n = src.count(old)
    if n != cnt:
        print("!! anchor 命中 %d 次（期望 %d）:\n%s" % (n, cnt, old[:200]))
        sys.exit(2)
    src = src.replace(old, new, cnt)

# A. includes
rep('#include "qapi/error.h"\n\n#define NUM_VIRTIO_TRANSPORTS 32\n',
    '#include "qapi/error.h"\n'
    '#include "hw/pci-host/gpex.h"\n'
    '#include "hw/pci/pci.h"\n'
    '#include "hw/pci/pci_host.h"\n'
    '#include "hw/pci/pci_bus.h"\n'
    '#include "hw/pci/pcie_host.h"\n'
    '\n#define NUM_VIRTIO_TRANSPORTS 32\n')

# B. enum
rep('    RANCHU_MMIO,\n};\n',
    '    RANCHU_MMIO,\n'
    '    RANCHU_PCIE,\n'
    '    RANCHU_PCIE_MMIO,\n'
    '    RANCHU_PCIE_MMIO_HIGH,\n'
    '    RANCHU_PCIE_PIO,\n'
    '    RANCHU_PCIE_ECAM,\n'
    '};\n')

# C. memmap（用预留的 0x10000000..0x40000000 窗口）
rep('    /* 0x10000000 .. 0x40000000 reserved for PCI */\n'
    '    [RANCHU_MEM] = { 0x40000000, 30ULL * 1024 * 1024 * 1024 },\n',
    '    /* 0x10000000 .. 0x40000000 reserved for PCI */\n'
    '    [RANCHU_PCIE_MMIO] = { 0x10000000, 0x2eff0000 },\n'
    '    [RANCHU_PCIE_MMIO_HIGH] = { 0x800000000ULL, 0x800000000ULL },\n'
    '    [RANCHU_PCIE_PIO]  = { 0x3eff0000, 0x00010000 },\n'
    '    [RANCHU_PCIE_ECAM] = { 0x3f000000, 0x01000000 },\n'
    '    [RANCHU_MEM] = { 0x40000000, 30ULL * 1024 * 1024 * 1024 },\n')

# D. irqmap（virtio-mmio 用 16..47，PCIE 取 48..）
rep('    [RANCHU_MMIO] = 16, /* ...to 16 + NUM_VIRTIO_TRANSPORTS - 1 */\n};\n',
    '    [RANCHU_MMIO] = 16, /* ...to 16 + NUM_VIRTIO_TRANSPORTS - 1 */\n'
    '    [RANCHU_PCIE] = 48, /* ...to 51 (GPEX_NUM_IRQS) */\n'
    '};\n')

# E. VirtBoardInfo 增加 gic_phandle
rep('    uint32_t clock_phandle;\n} VirtBoardInfo;\n',
    '    uint32_t clock_phandle;\n'
    '    uint32_t gic_phandle;\n'
    '} VirtBoardInfo;\n')

# F. fdt_add_gic_node 记录 phandle
rep('static void fdt_add_gic_node(const VirtBoardInfo *vbi)\n'
    '{\n'
    '    uint32_t gic_phandle;\n'
    '\n'
    '    gic_phandle = qemu_fdt_alloc_phandle(vbi->fdt);\n',
    'static void fdt_add_gic_node(VirtBoardInfo *vbi)\n'
    '{\n'
    '    uint32_t gic_phandle;\n'
    '\n'
    '    gic_phandle = qemu_fdt_alloc_phandle(vbi->fdt);\n'
    '    vbi->gic_phandle = gic_phandle;\n')

# G. 插入 create_pcie_irq_map / create_pcie
PCIE_CODE = r'''
/* ===== VMHOST PCIE BEGIN ===== */
static void create_pcie_irq_map(const VirtBoardInfo *vbi,
                                uint32_t gic_phandle,
                                int first_irq, const char *nodename)
{
    int devfn, pin;
    uint32_t full_irq_map[16 * 4 * 10] = { 0 };
    uint32_t *irq_map = full_irq_map;

    for (devfn = 0; devfn <= 0x78; devfn += 0x8) {
        for (pin = 0; pin < 4; pin++) {
            int irq_type = GIC_FDT_IRQ_TYPE_SPI;
            int irq_nr = first_irq + ((pin + PCI_SLOT(devfn)) % PCI_NUM_PINS);
            int irq_level = GIC_FDT_IRQ_FLAGS_LEVEL_HI;
            int i;

            uint32_t map[] = {
                devfn << 8, 0, 0,
                pin + 1,
                gic_phandle, 0, 0, irq_type, irq_nr, irq_level };

            for (i = 0; i < 10; i++) {
                irq_map[i] = cpu_to_be32(map[i]);
            }
            irq_map += 10;
        }
    }

    qemu_fdt_setprop(vbi->fdt, nodename, "interrupt-map",
                     full_irq_map, sizeof(full_irq_map));

    qemu_fdt_setprop_cells(vbi->fdt, nodename, "interrupt-map-mask",
                           0x7800, 0, 0, /* devfn: 覆盖 slot 0..15 */
                           0x7);
}

static void create_pcie(VirtBoardInfo *vbi, qemu_irq *pic)
{
    hwaddr base_mmio = memmap[RANCHU_PCIE_MMIO].base;
    hwaddr size_mmio = memmap[RANCHU_PCIE_MMIO].size;
    hwaddr base_mmio_high = memmap[RANCHU_PCIE_MMIO_HIGH].base;
    hwaddr size_mmio_high = memmap[RANCHU_PCIE_MMIO_HIGH].size;
    hwaddr base_pio = memmap[RANCHU_PCIE_PIO].base;
    hwaddr size_pio = memmap[RANCHU_PCIE_PIO].size;
    hwaddr base_ecam = memmap[RANCHU_PCIE_ECAM].base;
    hwaddr size_ecam = memmap[RANCHU_PCIE_ECAM].size;
    int nr_pcie_buses = size_ecam / PCIE_MMCFG_SIZE_MIN;
    int irq = irqmap[RANCHU_PCIE];
    MemoryRegion *mmio_alias;
    MemoryRegion *mmio_reg;
    MemoryRegion *ecam_alias;
    MemoryRegion *ecam_reg;
    DeviceState *dev;
    char *nodename;
    int i;
    PCIHostState *pci;

    dev = qdev_create(NULL, TYPE_GPEX_HOST);
    qdev_init_nofail(dev);

    /* ECAM */
    ecam_alias = g_new0(MemoryRegion, 1);
    ecam_reg = sysbus_mmio_get_region(SYS_BUS_DEVICE(dev), 0);
    memory_region_init_alias(ecam_alias, OBJECT(dev), "pcie-ecam",
                             ecam_reg, 0, size_ecam);
    memory_region_add_subregion(get_system_memory(), base_ecam, ecam_alias);

    /* MMIO（1:1） */
    mmio_alias = g_new0(MemoryRegion, 1);
    mmio_reg = sysbus_mmio_get_region(SYS_BUS_DEVICE(dev), 1);
    memory_region_init_alias(mmio_alias, OBJECT(dev), "pcie-mmio",
                             mmio_reg, base_mmio, size_mmio);
    memory_region_add_subregion(get_system_memory(), base_mmio, mmio_alias);

    /* 64-bit（high MMIO）窗口：goldfish AREA BAR 是 16GB，必须给它 */
    {
        MemoryRegion *high_alias = g_new0(MemoryRegion, 1);
        memory_region_init_alias(high_alias, OBJECT(dev), "pcie-mmio-high",
                                 mmio_reg, base_mmio_high, size_mmio_high);
        memory_region_add_subregion(get_system_memory(), base_mmio_high,
                                    high_alias);
    }

    /* IO 口 */
    sysbus_mmio_map(SYS_BUS_DEVICE(dev), 2, base_pio);

    for (i = 0; i < GPEX_NUM_IRQS; i++) {
        sysbus_connect_irq(SYS_BUS_DEVICE(dev), i, pic[irq + i]);
        gpex_set_irq_num(GPEX_HOST(dev), i, irq + i);
    }

    pci = PCI_HOST_BRIDGE(dev);

    /* goldfish_address_space：guest 的 gralloc(GoldfishMapper) 必需 */
    if (pci->bus) {
        pci_create_simple(pci->bus, PCI_DEVFN(11, 0), "goldfish_address_space");
    } else {
        error_report("ranchu: no PCI bus for goldfish_address_space");
    }

    nodename = g_strdup_printf("/pcie@%" PRIx64, base_mmio);
    qemu_fdt_add_subnode(vbi->fdt, nodename);
    qemu_fdt_setprop_string(vbi->fdt, nodename, "compatible",
                            "pci-host-ecam-generic");
    qemu_fdt_setprop_string(vbi->fdt, nodename, "device_type", "pci");
    qemu_fdt_setprop_cell(vbi->fdt, nodename, "#address-cells", 3);
    qemu_fdt_setprop_cell(vbi->fdt, nodename, "#size-cells", 2);
    qemu_fdt_setprop_cells(vbi->fdt, nodename, "bus-range", 0,
                           nr_pcie_buses - 1);
    qemu_fdt_setprop(vbi->fdt, nodename, "dma-coherent", NULL, 0);
    qemu_fdt_setprop_sized_cells(vbi->fdt, nodename, "reg",
                                 2, base_ecam, 2, size_ecam);
    qemu_fdt_setprop_sized_cells(vbi->fdt, nodename, "ranges",
                                 1, FDT_PCI_RANGE_IOPORT, 2, 0,
                                 2, base_pio, 2, size_pio,
                                 1, FDT_PCI_RANGE_MMIO, 2, base_mmio,
                                 2, base_mmio, 2, size_mmio,
                                 1, FDT_PCI_RANGE_MMIO_64BIT,
                                 2, base_mmio_high,
                                 2, base_mmio_high, 2, size_mmio_high);
    qemu_fdt_setprop_cell(vbi->fdt, nodename, "#interrupt-cells", 1);
    create_pcie_irq_map(vbi, vbi->gic_phandle, irq, nodename);

    g_free(nodename);
}
/* ===== VMHOST PCIE END ===== */

'''
rep('static void *ranchu_dtb(const struct arm_boot_info *binfo, int *fdt_size)\n',
    PCIE_CODE + 'static void *ranchu_dtb(const struct arm_boot_info *binfo, int *fdt_size)\n')

# H. 在 ranchu_init 里调用
rep('    create_gic(vbi, pic);\n',
    '    create_gic(vbi, pic);\n'
    '    create_pcie(vbi, pic);\n')

shutil.copyfile(SRC, SRC + ".orig_pcie")
open(SRC, "w", encoding="utf-8", errors="surrogateescape").write(src)
print("patched OK, backup -> ranchu.c.orig_pcie")
