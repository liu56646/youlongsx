#!/usr/bin/env python3
# 排障补丁：给 QEMU 的 virtio-mmio.c 加寄存器访问 trace，只针对 GPU transport
# （device_id == 0x1050），打印 guest 对 MMIO 寄存器的每次读写，精确定位
# virtio_gpu 驱动 probe 卡在哪个寄存器访问。幂等标记 VMHOST_MMIO_TRACE。
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "/root/vmbuild/qemu-aosp/hw/virtio/virtio-mmio.c"
MARK = "VMHOST_MMIO_TRACE"
GPU_ID = 16  # VIRTIO_ID_GPU = 16（不是 0x1050！）

src = open(PATH, "r", encoding="utf-8", errors="surrogateescape").read()
if MARK in src:
    print("virtio-mmio.c: already patched")
    sys.exit(0)

read_anchor = '    DPRINTF("virtio_mmio_read offset 0x%x\\n", (int)offset);'
write_anchor = '    DPRINTF("virtio_mmio_write offset 0x%x value 0x%" PRIx64 "\\n",\n            (int)offset, value);'

assert src.count(read_anchor) == 1, "read anchor not unique: %d" % src.count(read_anchor)
assert src.count(write_anchor) == 1, "write anchor not unique: %d" % src.count(write_anchor)

read_trace = read_anchor + '''
    if (vdev && vdev->device_id == %d) {
        fprintf(stderr, "VMHOSTMMIO R offset=0x%%x size=%%u val=0x%%llx\\n",
                (int)offset, size, (unsigned long long)
                virtio_mmio_read_gpu_val(proxy, offset));
    }''' % GPU_ID

# 简单起见：read 里直接打印读到的值不容易（要重复逻辑），改成在函数末尾统一打印。
# 但我们仍用锚点方案：read 分支太多，改为在开头打印 offset/size，值在调用点单独处理。
# 这里退而求其次：read 打印 offset+size+返回路径的关键寄存器值，先只打 offset。
read_trace = read_anchor + '''
    if (vdev && vdev->device_id == %d) {
        fprintf(stderr, "VMHOSTMMIO R offset=0x%%x size=%%u\\n",
                (int)offset, size);
    }''' % GPU_ID

write_trace = write_anchor + '''
    if (vdev && vdev->device_id == %d) {
        fprintf(stderr, "VMHOSTMMIO W offset=0x%%x size=%%u val=0x%%llx\\n",
                (int)offset, size, (unsigned long long)value);
    }''' % GPU_ID

src = src.replace(read_anchor, read_trace, 1)
src = src.replace(write_anchor, write_trace, 1)

marker = "/* %s: virtio-mmio GPU trace */\n" % MARK
src = marker + src
open(PATH, "w", encoding="utf-8", errors="surrogateescape").write(src)
print("virtio-mmio.c: patched OK")
