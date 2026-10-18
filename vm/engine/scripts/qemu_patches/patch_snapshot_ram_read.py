"""Batch synchronous uncompressed RAM reads without changing snapshot format."""
from pathlib import Path
import sys


def patch(source):
    if 'VMHOST_RAM_READV' in source:
        return source
    anchor = '    for (Page* page : sortedPages) {\n'
    if source.count(anchor) != 1:
        raise ValueError('Missing or ambiguous RAM read loop')
    source = source.replace('#include <algorithm>',
                            '#include "vmhost_snapshot_readv.h"\n\n#include <algorithm>', 1)
    return source.replace(anchor, '''    // VMHOST_RAM_READV: disk order is contiguous even when zero pages
    // leave holes in guest memory. preadv avoids a syscall per 4 KiB page.
    // Retain the existing path for compression and demand paging.
    if (!mAccessWatch && !nonzero(mIndex.flags & IndexFlags::CompressedPages)) {
        size_t batches = 0;
        for (size_t first = 0; first < sortedPages.size();) {
            iovec vectors[256];
            size_t end = first;
            uint64_t nextOffset = sortedPages[first]->filePos;
            while (end < sortedPages.size() && end - first < 256) {
                Page* page = sortedPages[end];
                if (page->filePos != nextOffset) break;
                vectors[end - first] = {pagePtr(*page), page->sizeOnDisk};
                nextOffset += page->sizeOnDisk;
                ++end;
            }
            if (!vmhostSnapshotReadv(mStreamFd, vectors, int(end - first),
                                     off_t(sortedPages[first]->filePos))) {
                mHasError = true;
                return false;
            }
            for (size_t i = first; i < end; ++i) {
                Page* page = sortedPages[i];
                page->data = pagePtr(*page);
                page->state.store(uint8_t(State::Read), std::memory_order_release);
            }
            ++batches;
            first = end;
        }
        fprintf(stderr, "VMHOSTSNAP ram_readv pages=%zu batches=%zu\\n",
                sortedPages.size(), batches);
        return true;
    }

''' + anchor, 1)


if __name__ == '__main__':
    target = Path(sys.argv[1])
    original = target.read_text()
    changed = patch(original)
    if changed != original:
        target.write_text(changed)
