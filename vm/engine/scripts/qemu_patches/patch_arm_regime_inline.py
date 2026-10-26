"""Expose pure local ARM regime decoding to the optimizer, preserving its body.

No cached translation state, invalidation changes, permission edits, or CPU
layout changes. All callers still perform the original validations.
"""
import argparse
from pathlib import Path

OLD = 'static inline uint32_t regime_el(CPUARMState *env, ARMMMUIdx mmu_idx)'
NEW = 'static inline __attribute__((always_inline)) uint32_t regime_el(CPUARMState *env, ARMMMUIdx mmu_idx)'


def patch(source):
    if NEW in source:
        if source.count(NEW) != 1:
            raise ValueError('Duplicate regime decoder')
        return source
    if source.count(OLD) != 1:
        raise ValueError('Regime decoder signature drift')
    result = source.replace(OLD, NEW)
    assert result.replace(NEW, OLD) == source
    return result


def configure(source, enabled):
    changed = patch(source)
    return changed if enabled else changed.replace(NEW, OLD)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('qemu_root', type=Path)
    p.add_argument('--enable', choices=['0', '1'], default='0')
    args = p.parse_args()
    file = args.qemu_root/'target/arm/helper.c'
    old = file.read_text(encoding='utf-8')
    new = configure(old, args.enable == '1')
    if new != old:
        file.write_bytes(new.encode('utf-8'))
    print('ARM regime inline experiment: '+('enabled' if args.enable == '1' else 'disabled'))


if __name__ == '__main__':
    main()
