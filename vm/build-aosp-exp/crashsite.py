#!/usr/bin/env python3
# 输入 core 头部（含 phdrs+notes），直接输出：崩溃信号 + 各线程 pc/lr 的符号化
# 用法: python3 crashsite.py core_headX.bin
import struct
import subprocess
import sys

HEAD = sys.argv[1]
NDK = "/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin"
B = "/mnt/k/youlongsx/vm/engine/src/main/cpp/prebuilt/qemu-aosp/arm64-v8a/qemu-system-aarch64"

bh = open(B, "rb").read(1024 * 1024)
e_phoff, = struct.unpack_from("<Q", bh, 0x20)
e_phentsize, = struct.unpack_from("<H", bh, 0x36)
e_phnum, = struct.unpack_from("<H", bh, 0x38)
bloads = []
for i in range(e_phnum):
    o = e_phoff + i * e_phentsize
    t, fl, poff, va, pa, fsz, msz = struct.unpack_from("<IIQQQQQ", bh, o)
    if t == 1:
        bloads.append((poff, va, fsz))

def fo2va(fo):
    for poff, va, fsz in bloads:
        if poff <= fo < poff + fsz:
            return va + (fo - poff)
    return None

data = open(HEAD, "rb").read()
e_phoff, = struct.unpack_from("<Q", data, 0x20)
e_phentsize, = struct.unpack_from("<H", data, 0x36)
e_phnum, = struct.unpack_from("<H", data, 0x38)
maps, threads, siginfo = [], [], None
for i in range(e_phnum):
    o = e_phoff + i * e_phentsize
    t, fl, poff, va, pa, fsz, msz = struct.unpack_from("<IIQQQQQ", data, o)
    if t != 4:
        continue
    pos, end = poff, poff + fsz
    while pos + 12 <= min(end, len(data)):
        namesz, descsz, ntype = struct.unpack_from("<III", data, pos)
        pos += 12
        pos += (namesz + 3) & ~3
        if ntype == 0x46494c45:
            d = data[pos:pos + descsz]
            cnt, pg = struct.unpack_from("<QQ", d, 0)
            p = 16
            ents = []
            for _ in range(cnt):
                s, e, fo = struct.unpack_from("<QQQ", d, p)
                p += 24
                ents.append((s, e, fo))
            paths = d[p:].split(b"\0")
            for k, (s, e, fo) in enumerate(ents):
                maps.append((s, e, fo * pg, paths[k].decode("utf-8", "replace")))
        elif ntype == 1:
            d = data[pos:pos + descsz]
            sig, = struct.unpack_from("<i", d, 0)
            pid, = struct.unpack_from("<i", d, 32)
            r = struct.unpack_from("<34Q", d, 112)
            threads.append((pid, sig, list(r[0:31]), r[31], r[32]))
        elif ntype == 0x53494749:
            d = data[pos:pos + descsz]
            if len(d) >= 24:
                s1, s2, s3 = struct.unpack_from("<iii", d, 0)
                addr, = struct.unpack_from("<Q", d, 16)
                siginfo = (s1, s2, s3, addr)
        pos += (descsz + 3) & ~3

print("NT_SIGINFO:", siginfo)

def resolve(addr):
    for s, e, fo, path in maps:
        if s <= addr < e:
            return path, addr - s + fo
    return None, None

def line(tag, addr):
    path, fo = resolve(addr)
    if not path:
        return f"  {tag} 0x{addr:x} <no map>"
    extra = ""
    if "qemu-system" in path:
        va = fo2va(fo)
        if va is not None:
            r = subprocess.run([NDK + "/llvm-symbolizer", "--obj=" + B, f"0x{va:x}"],
                               capture_output=True, text=True)
            l = [x for x in r.stdout.splitlines() if x.strip()]
            extra = "  | " + " | ".join(l[:2]) if l else ""
    return f"  {tag} 0x{addr:x} -> {path.split('/')[-1]} +0x{fo:x}{extra}"

for pid, sig, x, sp, pc in threads:
    p1, _ = resolve(pc)
    # 只打印 qemu 代码里的（崩溃的那个），其余线程只报 pid
    if p1 and "qemu-system" in p1:
        print(f"\n*** 崩溃线程 pid={pid} sig={sig} sp=0x{sp:x}")
        print(line("pc", pc))
        print(line("lr", x[30]))
