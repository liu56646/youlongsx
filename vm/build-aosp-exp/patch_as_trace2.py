# -*- coding: utf-8 -*-
# 给 goldfish_address_space control MMIO 加访问 trace（正确签名版）
import io

f = "/root/vmbuild/qemu-aosp/hw/pci/goldfish_address_space.c"
src = io.open(f, encoding="utf-8").read()

pairs = [
    (
        "static uint64_t address_space_control_read(void *opaque,\n"
        "                                           hwaddr offset,\n"
        "                                           unsigned size) {\n"
        "    struct address_space_state *state = opaque;\n"
        "    uint64_t res;\n",
        "static uint64_t address_space_control_read(void *opaque,\n"
        "                                           hwaddr offset,\n"
        "                                           unsigned size) {\n"
        "    struct address_space_state *state = opaque;\n"
        "    uint64_t res;\n"
        "    fprintf(stderr, \"AS_TRACE control_read offset=0x%llx size=%u\\n\",\n"
        "            (unsigned long long)offset, size);\n",
    ),
    (
        "static void address_space_control_write(void *opaque,\n"
        "                                         hwaddr offset,\n"
        "                                         uint64_t val,\n"
        "                                         unsigned size) {\n"
        "    struct address_space_state *state = opaque;\n"
        "\n"
        "    if (size != 4) {\n",
        "static void address_space_control_write(void *opaque,\n"
        "                                         hwaddr offset,\n"
        "                                         uint64_t val,\n"
        "                                         unsigned size) {\n"
        "    struct address_space_state *state = opaque;\n"
        "    fprintf(stderr, \"AS_TRACE control_write offset=0x%llx val=0x%llx size=%u\\n\",\n"
        "            (unsigned long long)offset, (unsigned long long)val, size);\n"
        "\n"
        "    if (size != 4) {\n",
    ),
]
for old, new in pairs:
    if old in src:
        src = src.replace(old, new, 1)
        print("OK")
    else:
        print("MISS")
io.open(f, "w", encoding="utf-8").write(src)
print("done")
