"""Use compiler-independent atomic builtins in the old QEMU configure probes."""
from pathlib import Path
import sys


def patch(source):
    # Clang supports the generic builtins, but not GCC's size-suffixed spellings.
    # A false negative makes every 64/128-bit guest atomic stop all TCG CPUs.
    replacements = {
        '__atomic_load_16(&x, 0)': '__atomic_load_n(&x, 0)',
        '__atomic_store_16(&x, y, 0)': '__atomic_store_n(&x, y, 0)',
        '__atomic_compare_exchange_16(&x, &y, x, 0, 0, 0)':
            '__atomic_compare_exchange_n(&x, &y, x, 0, 0, 0)',
        '__atomic_load_8(&x, 0)': '__atomic_load_n(&x, 0)',
        '__atomic_store_8(&x, y, 0)': '__atomic_store_n(&x, y, 0)',
        '__atomic_compare_exchange_8(&x, &y, x, 0, 0, 0)':
            '__atomic_compare_exchange_n(&x, &y, x, 0, 0, 0)',
        '__atomic_exchange_8(&x, y, 0)': '__atomic_exchange_n(&x, y, 0)',
        '__atomic_fetch_add_8(&x, y, 0)': '__atomic_fetch_add(&x, y, 0)',
    }
    for old, new in replacements.items():
        if old not in source and new not in source:
            raise ValueError('Missing atomic probe: ' + old)
        source = source.replace(old, new)
    return source


if __name__ == '__main__':
    path = Path(sys.argv[1])
    original = path.read_text()
    changed = patch(original)
    if changed != original:
        path.write_text(changed)
