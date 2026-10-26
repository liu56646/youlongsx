"""Replace only the four full/masked TLB invalidation memset calls.

Preserves every invalidation, byte, MMU bank, lock, jump-cache clear, atomic
and CPU/snapshot layout. Candidate only, VMHOST_TLB_TEMPORAL=1 opts in.
"""
MARKER = 'VMHOST_TLB_TEMPORAL_FILL'
POLICY = '''
/* VMHOST_TLB_TEMPORAL_FILL: exact full-buffer stores; never skip a bank. */
#include "tlb_fill.h"
static bool vmhost_tlb_temporal;

__attribute__((constructor)) static void vmhost_tlb_temporal_policy(void)
{
    const char *value = getenv("VMHOST_TLB_TEMPORAL");
    vmhost_tlb_temporal = value && strcmp(value, "1") == 0;
}

static inline void vmhost_tlb_invalidate_buffer(void *p, size_t size)
{
    if (vmhost_tlb_temporal) {
        vmhost_tlb_fill_ff(p, size);
    } else {
        memset(p, -1, size);
    }
}
'''
CALLS = [
    'env->tlb_table, -1, sizeof(env->tlb_table)',
    'env->tlb_v_table, -1, sizeof(env->tlb_v_table)',
    'env->tlb_table[mmu_idx], -1, sizeof(env->tlb_table[0])',
    'env->tlb_v_table[mmu_idx], -1, sizeof(env->tlb_v_table[0])',
]


def patch(source):
    if MARKER in source:
        if source.count(POLICY) != 1:
            raise ValueError('Modified candidate block')
        return source
    anchor = '#define ALL_MMUIDX_BITS ((1 << NB_MMU_MODES) - 1)'
    if source.count(anchor) != 1 or 'VMHOST_TLB_USED_MODES' in source:
        raise ValueError('Unexpected TLB source; do not combine bank-skipping experiments')
    result = source.replace(anchor, anchor+'\n'+POLICY)
    for args in CALLS:
        old = 'memset('+args+');'
        new = 'vmhost_tlb_invalidate_buffer('+args.replace(', -1,', ',')+');'
        if result.count(old) != 1:
            raise ValueError('Invalidation call drift: '+old)
        result = result.replace(old, new)
    restored = result.replace('\n'+POLICY, '')
    for args in CALLS:
        restored = restored.replace('vmhost_tlb_invalidate_buffer('+args.replace(', -1,', ',')+');',
                                    'memset('+args+');')
    if restored != source:
        raise ValueError('Unexpected semantic changes')
    return result
