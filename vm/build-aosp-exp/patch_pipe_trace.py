#!/usr/bin/env python3
# 给 goldfish_pipe 的 MMIO 读写加节流日志，用于确认访客是否在死循环敲 pipe。
# 幂等：已打过就跳过。
import sys

p = "/root/vmbuild/qemu-aosp/hw/misc/goldfish_pipe.c"
s = open(p, encoding="utf-8").read()

if "VMHOST_PIPE_TRACE" in s:
    print("already patched")
    sys.exit(0)

old_w = """    DR("%s: offset = 0x%" HWADDR_PRIx " value=%" PRIu64 "/0x%" PRIx64, __func__,
       offset, value, value);
    if (offset == PIPE_REG_VERSION) {"""
new_w = """    DR("%s: offset = 0x%" HWADDR_PRIx " value=%" PRIu64 "/0x%" PRIx64, __func__,
       offset, value, value);
    {   /* VMHOST_PIPE_TRACE */
        static unsigned long long vmhost_pipe_writes = 0;
        unsigned long long n = ++vmhost_pipe_writes;
        if (n <= 64 || (n % 2000) == 0) {
            fprintf(stderr,
                    "VMHOSTPIPE write #%llu off=0x%llx val=0x%llx size=%u ver=%d\\n",
                    n, (unsigned long long) offset,
                    (unsigned long long) value, size,
                    (int) dev->device_version);
        }
    }
    if (offset == PIPE_REG_VERSION) {"""

old_r = """static uint64_t pipe_dev_read(void* opaque, hwaddr offset, unsigned size) {
    GoldfishPipeState* s = (GoldfishPipeState*)opaque;
    PipeDevice* dev = s->dev;
    if (offset == PIPE_REG_VERSION) {"""
new_r = """static uint64_t pipe_dev_read(void* opaque, hwaddr offset, unsigned size) {
    GoldfishPipeState* s = (GoldfishPipeState*)opaque;
    PipeDevice* dev = s->dev;
    {   /* VMHOST_PIPE_TRACE */
        static unsigned long long vmhost_pipe_reads = 0;
        unsigned long long n = ++vmhost_pipe_reads;
        if (n <= 64 || (n % 2000) == 0) {
            fprintf(stderr,
                    "VMHOSTPIPE read #%llu off=0x%llx size=%u ver=%d\\n",
                    n, (unsigned long long) offset, size,
                    (int) dev->device_version);
        }
    }
    if (offset == PIPE_REG_VERSION) {"""

assert old_w in s, "write pattern not found"
assert old_r in s, "read pattern not found"
s = s.replace(old_w, new_w, 1).replace(old_r, new_r, 1)
open(p, "w", encoding="utf-8").write(s)
print("patched")
