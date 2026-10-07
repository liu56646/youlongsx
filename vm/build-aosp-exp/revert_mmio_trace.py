#!/usr/bin/env python3
# 还原 patch_virtio_mmio_trace.py 的错误插入（0x1050 过滤），
# 便于用正确 device_id(16) 重打。
import re
import sys

p = sys.argv[1] if len(sys.argv) > 1 else "/root/vmbuild/qemu-aosp/hw/virtio/virtio-mmio.c"
s = open(p, encoding="utf-8", errors="surrogateescape").read()

s = re.sub(r"/\* VMHOST_MMIO_TRACE: virtio-mmio GPU trace \*/\n", "", s)

s = s.replace(
    """    DPRINTF("virtio_mmio_read offset 0x%x\\n", (int)offset);
    if (vdev && vdev->device_id == 0x1050) {
        fprintf(stderr, "VMHOSTMMIO R offset=0x%x size=%u\\n",
                (int)offset, size);
    }""",
    """    DPRINTF("virtio_mmio_read offset 0x%x\\n", (int)offset);""",
)

s = s.replace(
    """    DPRINTF("virtio_mmio_write offset 0x%x value 0x%" PRIx64 "\\n",
            (int)offset, value);
    if (vdev && vdev->device_id == 0x1050) {
        fprintf(stderr, "VMHOSTMMIO W offset=0x%x size=%u val=0x%llx\\n",
                (int)offset, size, (unsigned long long)value);
    }""",
    """    DPRINTF("virtio_mmio_write offset 0x%x value 0x%" PRIx64 "\\n",
            (int)offset, value);""",
)

assert "VMHOSTMMIO" not in s, "still has VMHOSTMMIO"
open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
print("reverted OK")
