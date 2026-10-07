#!/usr/bin/env python3
# 反汇编 guest allocator@3.0-service 的 allocateCb 成功路径（refcount 通过后）
import capstone, sys

data = open('/tmp/alloc30', 'rb').read()
md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
md.detail = False

# allocateCb 在 0x4c48；成功路径从 0x4e44 开始
for addr in range(0x4e30, 0x5000, 4):
    code = data[addr:addr+4]
    ins = next(md.disasm(code, addr))
    print(f"0x{addr:05x}: {ins.mnemonic} {ins.op_str}")
