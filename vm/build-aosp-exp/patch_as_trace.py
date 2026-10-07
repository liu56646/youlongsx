# -*- coding: utf-8 -*-
# D1a 诊断（第 3 轮）：打开 goldfish_address_space 的 verbose logging + 加
# control MMIO 访问 trace，确认 guest 是否真的使用 address_space 分配 buffer。
import io, sys

def patch(path, pairs):
    src = io.open(path, encoding="utf-8").read()
    for old, new, tag in pairs:
        if old in src:
            src = src.replace(old, new, 1)
            print("OK[%s]: %s" % (path, tag))
        else:
            print("MISS[%s]: %s" % (path, tag))
    io.open(path, "w", encoding="utf-8").write(src)

f = "/root/vmbuild/qemu-aosp/hw/pci/goldfish_address_space.c"
patch(f, [
    (
        "static int s_verbose_logging = 0;",
        "static int s_verbose_logging = 1;  /* VMHost: 默认开日志便于诊断 */",
        "verbose=1",
    ),
    (
        "static uint64_t address_space_control_read(void* opaque, hwaddr offset, unsigned size) {",
        "static uint64_t address_space_control_read(void* opaque, hwaddr offset, unsigned size) {\n"
        "    struct address_space_state* s = (struct address_space_state*)opaque;\n"
        "    if (s_verbose_logging) {\n"
        "        fprintf(stderr, \"AS_TRACE control_read offset=0x%llx size=%u\\n\",\n"
        "                (unsigned long long)offset, size);\n"
        "    }",
        "control_read trace",
    ),
    (
        "static void address_space_control_write(void* opaque, hwaddr offset, uint64_t val, unsigned size) {",
        "static void address_space_control_write(void* opaque, hwaddr offset, uint64_t val, unsigned size) {\n"
        "    struct address_space_state* s = (struct address_space_state*)opaque;\n"
        "    if (s_verbose_logging) {\n"
        "        fprintf(stderr, \"AS_TRACE control_write offset=0x%llx val=0x%llx size=%u\\n\",\n"
        "                (unsigned long long)offset, (unsigned long long)val, size);\n"
        "    }",
        "control_write trace",
    ),
])
