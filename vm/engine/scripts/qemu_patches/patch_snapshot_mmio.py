"""Exclude hostless MMIO RAMBlocks consistently from snapshot save and load."""
from pathlib import Path
import sys


def patch(source):
    save_anchor = """static int ram_save_setup(QEMUFile *f, void *opaque)
{
    RAMState **rsp = opaque;
    RAMBlock *block;
"""
    save = """
    /* VMHOST_MIG_ZERO
     * These are device address spaces, not host-backed guest RAM. Their
     * contents are saved by the graphics/address-space snapshot hooks.
     */
    RAMBLOCK_FOREACH(block) {
        if (block->host == NULL && block->used_length != 0) {
            fprintf(stderr, "VMHOST_MIG_ZERO %s used=%llu -> 0\\n",
                    block->idstr, (unsigned long long)block->used_length);
            block->used_length = 0;
        }
    }
"""
    load_anchor = """static int ram_load_setup(QEMUFile *f, void *opaque)
{
"""
    load = """    /* VMHOST_MIG_ZERO_LOAD
     * Match the zero lengths recorded by ram_save_setup before validating
     * the incoming RAMBlock list.
     */
    {
        RAMBlock *rb;
        RAMBLOCK_FOREACH(rb) {
            if (rb->host == NULL && rb->used_length != 0) {
                fprintf(stderr, "VMHOST_MIG_ZERO_LOAD %s used=%llu -> 0\\n",
                        rb->idstr, (unsigned long long)rb->used_length);
                rb->used_length = 0;
            }
        }
    }
"""
    for marker, anchor, addition in [
        ("/* VMHOST_MIG_ZERO\n", save_anchor, save),
        ("/* VMHOST_MIG_ZERO_LOAD\n", load_anchor, load),
    ]:
        if marker in source:
            continue
        if source.count(anchor) != 1:
            raise ValueError("Missing or ambiguous snapshot anchor: " + marker)
        source = source.replace(anchor, anchor + addition, 1)
    return source


if __name__ == "__main__":
    target = Path(sys.argv[1])
    original = target.read_text()
    changed = patch(original)
    if changed != original:
        target.write_text(changed)
