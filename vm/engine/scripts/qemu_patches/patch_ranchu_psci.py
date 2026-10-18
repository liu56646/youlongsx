"""Expose the existing TCG PSCI implementation to ranchu guests."""
from pathlib import Path
import sys


def patch(source):
    old = '    /* No PSCI for TCG yet */\n    if (kvm_enabled()) {'
    new = '''    /* VMHOST_RANCHU_TCG_PSCI: ARM TCG implements PSCI 0.2. Without
     * this node Linux leaves psci_ops.cpu_on unset and boots only CPU 0. */
    if (kvm_enabled() || tcg_enabled()) {'''
    anchor = '        /* Secondary CPUs start in PSCI powered-down state */'
    if 'VMHOST_RANCHU_TCG_PSCI' not in source:
        if source.count(old) != 1 or source.count(anchor) != 1:
            raise ValueError('Missing or ambiguous ranchu PSCI anchors')
        source = source.replace(old, new, 1)
        source = source.replace(anchor, '''        /* Match the HVC conduit advertised in /psci, as virt does. KVM
         * continues to use its existing in-kernel PSCI implementation. */
        if (tcg_enabled()) {
            object_property_set_int(cpuobj, QEMU_PSCI_CONDUIT_HVC,
                                    "psci-conduit", &error_abort);
        }

''' + anchor, 1)
    # create_fdt runs before CPU objects exist. Query psci_version only after
    # realization, otherwise qemu_get_cpu(0) is NULL on this board.
    if 'static void fdt_add_psci_node(' not in source:
        start = source.index('    /* VMHOST_RANCHU_TCG_PSCI:')
        end = source.index('\n}\n\nstatic void fdt_add_timer_nodes', start)
        block = source[start:end]
        source = (source[:start] + '}\n\n'
                  'static void fdt_add_psci_node(const VirtBoardInfo *vbi)\n{\n'
                  '    void *fdt = vbi->fdt;\n' + block + source[end:])
        call = '    fdt_add_cpu_nodes(vbi);'
        if source.count(call) != 1:
            raise ValueError('Missing or ambiguous CPU realization anchor')
        source = source.replace(call, call + '\n    fdt_add_psci_node(vbi);', 1)
    # Real SMP is useful for experiments, but cold-boot performance has not yet
    # passed a clean comparison. Preserve the established default DT meanwhile.
    source = source.replace('    if (kvm_enabled() || tcg_enabled()) {',
        '''    /* VMHOST_TCG_PSCI_OPT_IN: saved guest DT is restored with RAM. */
    const char *tcg_psci = getenv("VMHOST_TCG_PSCI");
    if (kvm_enabled() || (tcg_enabled() && tcg_psci &&
                          strcmp(tcg_psci, "1") == 0)) {''', 1)
    # arm_load_dtb also synthesizes /psci from the CPU conduit. Keep HVC on
    # the CPU for restored SMP snapshots, but gate the final cold DT as well.
    if 'static void ranchu_tcg_psci_gate(' not in source:
        anchor = 'static void *ranchu_dtb('
        if source.count(anchor) != 1:
            raise ValueError('Missing or ambiguous ranchu DT callback anchor')
        source = source.replace(anchor, '''static void ranchu_tcg_psci_gate(const struct arm_boot_info *binfo,
                                 void *fdt)
{
    const char *enabled = getenv("VMHOST_TCG_PSCI");
    (void)binfo;
    if (tcg_enabled() && (!enabled || strcmp(enabled, "1") != 0)) {
        /* Generic ARM boot code just added this node from psci-conduit. */
        qemu_fdt_nop_node(fdt, "/psci");
    }
}

''' + anchor, 1)
        anchor = '    vbi->bootinfo.get_dtb = ranchu_dtb;'
        if source.count(anchor) != 1:
            raise ValueError('Missing or ambiguous bootinfo DT anchor')
        source = source.replace(anchor, anchor +
            '\n    vbi->bootinfo.modify_dtb = ranchu_tcg_psci_gate;', 1)
    return source


if __name__ == '__main__':
    path = Path(sys.argv[1])
    original = path.read_text()
    changed = patch(original)
    if changed != original:
        path.write_text(changed)
