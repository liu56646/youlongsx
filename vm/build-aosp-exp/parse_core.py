#!/usr/bin/env python3
# 解析 ELF core 的 notes：NT_PRSTATUS（各线程寄存器）/ NT_SIGINFO / NT_FILE（映射表）
# 目标：找出收到 SIGSEGV 的线程，把 pc/lr/sp 归到「模块 + 偏移」。
import struct
import sys

PATH = "/mnt/k/youlongsx/vm/build-aosp-exp/core_head.bin"
NT_PRSTATUS = 1
NT_SIGINFO = 0x53494749
NT_FILE = 0x46494c45
NT_PRPSINFO = 3


def main():
    data = open(PATH, "rb").read()
    if data[:4] != b"\x7fELF":
        print("not ELF"); return
    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, = struct.unpack_from("<H", data, 0x36)
    e_phnum, = struct.unpack_from("<H", data, 0x38)
    print(f"phoff={e_phoff} phnum={e_phnum} size={len(data)}")

    notes = []
    phdrs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz = \
            struct.unpack_from("<IIQQQQQ", data, off)
        phdrs.append((p_type, p_offset, p_vaddr, p_filesz, p_memsz))
        if p_type == 4:  # PT_NOTE
            notes.append((p_offset, p_filesz))
    print(f"PT_NOTE segs: {notes}")
    print(f"PT_LOAD segs: {[(hex(v), hex(f)) for t,o,v,f,m in phdrs if t==1][:20]}")

    parsed = []
    for (noff, nsz) in notes:
        pos = noff
        end = noff + nsz
        while pos + 12 <= min(end, len(data)):
            namesz, descsz, ntype = struct.unpack_from("<III", data, pos)
            pos += 12
            name = data[pos:pos + namesz]
            pos += (namesz + 3) & ~3
            desc_off = pos
            desc = data[pos:pos + descsz]
            pos += (descsz + 3) & ~3
            parsed.append((ntype, name, desc_off, descsz))
    print("notes:")
    for ntype, name, doff, dsz in parsed:
        print(f"  type=0x{ntype:x} name={name!r} off=0x{doff:x} size={dsz}")

    # NT_FILE -> 映射表
    maps = []
    for ntype, name, doff, dsz in parsed:
        if ntype != NT_FILE:
            continue
        d = data[doff:doff + dsz]
        count, page_size = struct.unpack_from("<QQ", d, 0)
        p = 16
        entries = []
        for _ in range(count):
            s, e, foff = struct.unpack_from("<QQQ", d, p)
            p += 24
            entries.append((s, e, foff))
        paths = d[p:].split(b"\0")
        for i, (s, e, foff) in enumerate(entries):
            path = paths[i].decode("utf-8", "replace") if i < len(paths) else "?"
            maps.append((s, e, foff, path))
    print(f"NT_FILE entries: {len(maps)}")

    def resolve(addr):
        for s, e, foff, path in maps:
            if s <= addr < e:
                return path, addr - s + foff
        return None, None

    # 线程寄存器
    for ntype, name, doff, dsz in parsed:
        if ntype != NT_PRSTATUS:
            continue
        d = data[doff:doff + dsz]
        si_signo, si_code, si_errno = struct.unpack_from("<iii", d, 0)
        pr_cursig, = struct.unpack_from("<h", d, 12)
        pr_pid, = struct.unpack_from("<i", d, 32 + 0)
        # pr_reg 起始 112
        regs = struct.unpack_from("<34Q", d, 112)
        x = regs[0:31]
        sp = regs[31]
        pc = regs[32]
        pstate = regs[33]
        if pr_cursig == 11 or si_signo == 11:
            print(f"\n*** SIGSEGV thread pid={pr_pid} cursig={pr_cursig} si_signo={si_signo} si_code={si_code} si_errno={si_errno}")
        else:
            print(f"\nthread pid={pr_pid} cursig={pr_cursig} si_signo={si_signo}")
        for nm, v in (("pc", pc), ("sp", sp), ("lr", x[30]), ("fp", x[29])):
            path, off = resolve(v)
            if path:
                print(f"  {nm}=0x{v:x} -> {path} +0x{off:x}")
            else:
                print(f"  {nm}=0x{v:x} -> <no map>")
        # 其他像代码地址的寄存器
        for i, v in enumerate(x):
            if i in (29, 30):
                continue
            path, off = resolve(v)
            if path and ("lib" in path or "qemu" in path or ".so" in path):
                print(f"  x{i}=0x{v:x} -> {path} +0x{off:x}")

    # NT_SIGINFO
    for ntype, name, doff, dsz in parsed:
        if ntype == NT_SIGINFO:
            d = data[doff:doff + dsz]
            if len(d) >= 24:
                si_signo, si_errno, si_code = struct.unpack_from("<iii", d, 0)
                si_addr, = struct.unpack_from("<Q", d, 16)
                print(f"\nNT_SIGINFO si_signo={si_signo} si_code={si_code} si_addr=0x{si_addr:x}")


main()
