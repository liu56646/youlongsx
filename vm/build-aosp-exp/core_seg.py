#!/usr/bin/env python3
# 从 core 头部（含完整 program headers + notes）里：
#  1) 找到崩溃线程 sp 所在 PT_LOAD 段，打印 dd 参数（文件偏移 + 大小）
#  2) 打印主线程的寄存器
import struct

HEAD = "/mnt/k/youlongsx/vm/build-aosp-exp/core_head.bin"
SP = 0x7fc05ad320          # 主线程 sp（来自 parse_core.py）
FP = 0x7fc05ad350

data = open(HEAD, "rb").read()
e_phoff, = struct.unpack_from("<Q", data, 0x20)
e_phentsize, = struct.unpack_from("<H", data, 0x36)
e_phnum, = struct.unpack_from("<H", data, 0x38)
phdrs = []
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    t, fl, poff, vaddr, paddr, fsz, msz = struct.unpack_from("<IIQQQQQ", data, off)
    phdrs.append((t, poff, vaddr, fsz, msz))

print("找包含 sp 的 PT_LOAD …")
for t, poff, vaddr, fsz, msz in phdrs:
    if t != 1:
        continue
    if vaddr <= SP < vaddr + msz:
        # 只取从 sp 页开始的 2MB（够走 fp 链）
        page = 4096
        start_addr = SP & ~(page - 1)
        delta = start_addr - vaddr
        want = 2 * 1024 * 1024
        avail = max(0, fsz - delta)
        size = min(want, avail)
        print(f"seg vaddr=0x{vaddr:x} filesz=0x{fsz:x} memsz=0x{msz:x}")
        print(f"-> dd if=/data/local/tmp/core.30168 of=/data/local/tmp/stk.bin "
              f"bs=4096 skip={ (poff+delta)//4096 } count={size//4096}")
        print(f"   (addr_start=0x{start_addr:x} size=0x{size:x})")
        break
else:
    print("没找到包含 sp 的段")
