#!/usr/bin/env python3
# 替换 virtio-mmio trace：打印所有设备的访问（带 dev_id），
# 并在 read DEVICE_FEATURES(0x10) 时打印返回的 features 值。
import sys

p = sys.argv[1] if len(sys.argv) > 1 else "/root/vmbuild/qemu-aosp/hw/virtio/virtio-mmio.c"
s = open(p, encoding="utf-8", errors="surrogateescape").read()

# 去掉旧 trace 块（含 MARK 注释头、read trace、write trace）
import re
s = re.sub(r"/\* VMHOST_MMIO_TRACE: virtio-mmio GPU trace \*/\n", "", s)
s = s.replace(
    """    DPRINTF("virtio_mmio_read offset 0x%x\\n", (int)offset);
    if (vdev && vdev->device_id == 16) {
        fprintf(stderr, "VMHOSTMMIO R offset=0x%x size=%u\\n",
                (int)offset, size);
    }""",
    """    DPRINTF("virtio_mmio_read offset 0x%x\\n", (int)offset);
    if (vdev) {
        fprintf(stderr, "VMHOSTMMIO R dev=%d off=0x%x sz=%u\\n",
                vdev->device_id, (int)offset, size);
    }""",
)
s = s.replace(
    """    DPRINTF("virtio_mmio_write offset 0x%x value 0x%" PRIx64 "\\n",
            (int)offset, value);
    if (vdev && vdev->device_id == 16) {
        fprintf(stderr, "VMHOSTMMIO W offset=0x%x size=%u val=0x%llx\\n",
                (int)offset, size, (unsigned long long)value);
    }""",
    """    DPRINTF("virtio_mmio_write offset 0x%x value 0x%" PRIx64 "\\n",
            (int)offset, value);
    if (vdev) {
        fprintf(stderr, "VMHOSTMMIO W dev=%d off=0x%x sz=%u val=0x%llx\\n",
                vdev->device_id, (int)offset, size, (unsigned long long)value);
    }""",
)

# 在 read 的 DEVICE_FEATURES case 打印返回值（读 host features）
a = """    case VIRTIO_MMIO_DEVICE_FEATURES:
        if (proxy->host_features_sel) {
            return 0;
        }
        return vdev->host_features;"""
n = """    case VIRTIO_MMIO_DEVICE_FEATURES:
        if (proxy->host_features_sel) {
            return 0;
        }
        fprintf(stderr, "VMHOSTMMIO R dev=%d DEVFEAT sel=%d val=0x%llx\\n",
                vdev->device_id, proxy->host_features_sel,
                (unsigned long long)vdev->host_features);
        return vdev->host_features;"""
assert s.count(a) == 1, "devfeat anchor count=%d" % s.count(a)
s = s.replace(a, n, 1)

# 在 write 的 DRIVER_FEATURES case 打印写值
a2 = """    case VIRTIO_MMIO_DRIVER_FEATURES:
        if (!proxy->guest_features_sel) {
            virtio_set_features(vdev, value);
        }
        break;"""
n2 = """    case VIRTIO_MMIO_DRIVER_FEATURES:
        fprintf(stderr, "VMHOSTMMIO W dev=%d DRVFEAT sel=%d val=0x%llx\\n",
                vdev->device_id, proxy->guest_features_sel,
                (unsigned long long)value);
        if (!proxy->guest_features_sel) {
            virtio_set_features(vdev, value);
        }
        break;"""
assert s.count(a2) == 1, "drvfeat anchor count=%d" % s.count(a2)
s = s.replace(a2, n2, 1)

marker = "/* VMHOST_MMIO_TRACE: virtio-mmio all-dev trace */\n"
s = marker + s
open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
print("virtio-mmio.c: all-dev trace patched OK")
