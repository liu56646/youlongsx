#!/usr/bin/env python3
# 排障补丁 v2：给 QEMU 的 virtio_set_status / virtio_validate_features 加 trace，
# 确认处理 guest STATUS=0x83(FEATURES_OK) 时的具体行为。幂等标记 VMHOST_VSS_TRACE。
import sys

V = sys.argv[1] if len(sys.argv) > 1 else "/root/vmbuild/qemu-aosp/hw/virtio/virtio.c"
MARK = "VMHOST_VSS_TRACE"

s = open(V, "r", encoding="utf-8", errors="surrogateescape").read()
if MARK in s:
    print("virtio.c: already patched")
    sys.exit(0)

# 1) virtio_set_status 进入
a1 = """int virtio_set_status(VirtIODevice *vdev, uint8_t val)
{
    VirtioDeviceClass *k = VIRTIO_DEVICE_GET_CLASS(vdev);
    trace_virtio_set_status(vdev, val);
"""
n1 = """int virtio_set_status(VirtIODevice *vdev, uint8_t val)
{
    VirtioDeviceClass *k = VIRTIO_DEVICE_GET_CLASS(vdev);
    trace_virtio_set_status(vdev, val);
    fprintf(stderr, "VMHOSTVSS enter dev_id=%d val=0x%x old_status=0x%x has_v1=%d\\n",
            vdev->device_id, val, vdev->status,
            virtio_vdev_has_feature(vdev, VIRTIO_F_VERSION_1) ? 1 : 0);
"""
assert s.count(a1) == 1, "a1 count=%d" % s.count(a1)
s = s.replace(a1, n1, 1)

# 2) virtio_set_status 返回前
a2 = """    if (k->set_status) {
        k->set_status(vdev, val);
    }
    vdev->status = val;
    return 0;
}"""
n2 = """    if (k->set_status) {
        k->set_status(vdev, val);
    }
    fprintf(stderr, "VMHOSTVSS set done dev_id=%d val=0x%x\\n", vdev->device_id, val);
    vdev->status = val;
    return 0;
}"""
assert s.count(a2) == 1, "a2 count=%d" % s.count(a2)
s = s.replace(a2, n2, 1)

# 3) virtio_validate_features 进入/返回
a3 = """static int virtio_validate_features(VirtIODevice *vdev)
{
    VirtioDeviceClass *k = VIRTIO_DEVICE_GET_CLASS(vdev);

    if (virtio_host_has_feature(vdev, VIRTIO_F_IOMMU_PLATFORM) &&
        !virtio_vdev_has_feature(vdev, VIRTIO_F_IOMMU_PLATFORM)) {
        return -EFAULT;
    }

    if (k->validate_features) {
        return k->validate_features(vdev);
    } else {
        return 0;
    }
}"""
n3 = """static int virtio_validate_features(VirtIODevice *vdev)
{
    VirtioDeviceClass *k = VIRTIO_DEVICE_GET_CLASS(vdev);

    if (virtio_host_has_feature(vdev, VIRTIO_F_IOMMU_PLATFORM) &&
        !virtio_vdev_has_feature(vdev, VIRTIO_F_IOMMU_PLATFORM)) {
        fprintf(stderr, "VMHOSTVSS validate IOMMU fail dev_id=%d\\n", vdev->device_id);
        return -EFAULT;
    }

    if (k->validate_features) {
        int r = k->validate_features(vdev);
        fprintf(stderr, "VMHOSTVSS validate cb dev_id=%d ret=%d\\n", vdev->device_id, r);
        return r;
    } else {
        return 0;
    }
}"""
assert s.count(a3) == 1, "a3 count=%d" % s.count(a3)
s = s.replace(a3, n3, 1)

marker = "/* %s: virtio status trace */\n" % MARK
s = marker + s
open(V, "w", encoding="utf-8", errors="surrogateescape").write(s)
print("virtio.c: patched OK")
