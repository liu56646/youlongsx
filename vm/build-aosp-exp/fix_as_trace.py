# -*- coding: utf-8 -*-
# 修复 control_write 的 trace 插入位置（移到函数体开始）
import io

f = "/root/vmbuild/qemu-aosp/hw/pci/goldfish_address_space.c"
src = io.open(f, encoding="utf-8").read()

# 先把坏插入删掉
bad = (
    "static void address_space_control_write(void *opaque,\n"
    "    fprintf(stderr, \"AS_TRACE control_write offset=0x%llx val=0x%llx size=%u\\n\",\n"
    "            (unsigned long long)offset, (unsigned long long)val, size);\n"
    "                                        hwaddr offset,\n"
    "                                        uint64_t val,\n"
    "                                        unsigned size) {\n"
    "    struct address_space_state *state = opaque;\n"
)
good = (
    "static void address_space_control_write(void *opaque,\n"
    "                                        hwaddr offset,\n"
    "                                        uint64_t val,\n"
    "                                        unsigned size) {\n"
    "    struct address_space_state *state = opaque;\n"
    "    fprintf(stderr, \"AS_TRACE control_write offset=0x%llx val=0x%llx size=%u\\n\",\n"
    "            (unsigned long long)offset, (unsigned long long)val, size);\n"
)
if bad in src:
    src = src.replace(bad, good, 1)
    io.open(f, "w", encoding="utf-8").write(src)
    print("FIXED")
else:
    print("BAD NOT FOUND")
