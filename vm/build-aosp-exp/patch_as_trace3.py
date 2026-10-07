# -*- coding: utf-8 -*-
# 给 goldfish_address_space control_write 加访问 trace（宽松匹配）
import io

f = "/root/vmbuild/qemu-aosp/hw/pci/goldfish_address_space.c"
src = io.open(f, encoding="utf-8").read()

old = "static void address_space_control_write(void *opaque,\n"
"                                        hwaddr offset,\n"
"                                        uint64_t val,\n"
"                                        unsigned size) {\n"
"    struct address_space_state *state = opaque;\n"

new = old + (
"    fprintf(stderr, \"AS_TRACE control_write offset=0x%llx val=0x%llx size=%u\\n\",\n"
"            (unsigned long long)offset, (unsigned long long)val, size);\n"
)

if old in src:
    src = src.replace(old, new, 1)
    io.open(f, "w", encoding="utf-8").write(src)
    print("OK")
else:
    print("MISS")
