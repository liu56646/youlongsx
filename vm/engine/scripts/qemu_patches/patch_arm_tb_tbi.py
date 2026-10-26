#!/usr/bin/env python3
"""Share live TCR/regime decoding for the two AArch64 TB TBI flag bits.

No CPU state, TB format, register write, permission check or TLB invalidation
changes. VMHOST_TBI_COMBINE=0 retains the original pair of computations.
"""
import argparse
from pathlib import Path

MARKER = 'VMHOST_TB_TBI_COMBINE'
HELPER = r'''/* VMHOST_TB_TBI_COMBINE: compute both TB-key TBI bits from the same
 * live register state. No memoization or invalidation contract is added.
 * The legacy functions remain available for other callers and an opt-out.
 */
static bool vmhost_tb_tbi_combine = true;
__attribute__((constructor)) static void vmhost_tb_tbi_policy(void)
{
    const char *v = getenv("VMHOST_TBI_COMBINE");
    vmhost_tb_tbi_combine = !v || strcmp(v, "0") != 0;
}

static inline __attribute__((always_inline)) uint32_t
vmhost_arm_tb_tbi_flags(CPUARMState *env, ARMMMUIdx mmu_idx)
{
#if defined(TARGET_AARCH64) && !defined(CONFIG_USER_ONLY)
    if (vmhost_tb_tbi_combine) {
        mmu_idx = stage_1_mmu_idx(mmu_idx);
        const uint32_t el = regime_el(env, mmu_idx);
        const uint64_t raw = mmu_idx == ARMMMUIdx_S2NS
            ? env->cp15.vtcr_el2.raw_tcr : env->cp15.tcr_el[el].raw_tcr;
        const uint32_t tbi0 = extract64(raw, el > 1 ? 20 : 37, 1);
        const uint32_t tbi1 = el > 1 ? 0 : extract64(raw, 38, 1);
        return (tbi0 << ARM_TBFLAG_TBI0_SHIFT) | (tbi1 << ARM_TBFLAG_TBI1_SHIFT);
    }
#endif
    return (arm_regime_tbi0(env, mmu_idx) << ARM_TBFLAG_TBI0_SHIFT) |
           (arm_regime_tbi1(env, mmu_idx) << ARM_TBFLAG_TBI1_SHIFT);
}

'''
ORIGINAL = '''        flags |= (arm_regime_tbi0(env, mmu_idx) << ARM_TBFLAG_TBI0_SHIFT);
        flags |= (arm_regime_tbi1(env, mmu_idx) << ARM_TBFLAG_TBI1_SHIFT);'''
REPLACEMENT = '        flags |= vmhost_arm_tb_tbi_flags(env, mmu_idx);'
ENTRY = 'void cpu_get_tb_cpu_state('


def patch(src):
    if MARKER in src:
        return src
    if src.count(ENTRY) != 1 or src.count(ORIGINAL) != 1:
        raise ValueError('Unexpected ARM TB-state implementation')
    # These bodies provide the reference contract for the fused computation.
    for anchor in ['mmu_idx = stage_1_mmu_idx(mmu_idx);',
                   'return &env->cp15.vtcr_el2;',
                   'return &env->cp15.tcr_el[regime_el(env, mmu_idx)];',
                   'return extract64(tcr->raw_tcr, 20, 1);',
                   'return extract64(tcr->raw_tcr, 37, 1);',
                   'return extract64(tcr->raw_tcr, 38, 1);']:
        if anchor not in src:
            raise ValueError('TCR/TBI contract changed: ' + anchor)
    return src.replace(ENTRY, HELPER + ENTRY, 1).replace(ORIGINAL, REPLACEMENT, 1)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('qemu_root', type=Path)
    a = p.parse_args()
    path = a.qemu_root/'target/arm/helper.c'
    old = path.read_text(encoding='utf-8')
    new = patch(old)
    if new != old:
        path.write_text(new, encoding='utf-8')
    print('ARM TB TBI: ' + ('updated' if new != old else 'unchanged'))


if __name__ == '__main__':
    main()
