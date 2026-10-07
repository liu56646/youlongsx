#!/usr/bin/env python3
# 列出 core 里所有线程，正确换算偏移后符号化，找真正崩溃的那个线程。
import struct
import subprocess

NDK = "/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin"
B = "/mnt/k/youlongsx/vm/engine/src/main/cpp/prebuilt/qemu-aosp/arm64-v8a/qemu-system-aarch64"
QCACHE = {}

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

data = open("/mnt/k/youlongsx/vm/build-aosp-exp/core_head2.bin", "rb").read()
e_phoff, = struct.unpack_from("<Q", data, 0x20)
e_phentsize, = struct.unpack_from("<H", data, 0x36)
e_phnum, = struct.unpack_from("<H", data, 0x38)
maps, threads = [], []
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
            pid, = struct.unpack_from("<i", d, 32)
            r = struct.unpack_from("<34Q", d, 112)
            threads.append((pid, list(r[0:31]), r[31], r[32]))
        pos += (descsz + 3) & ~3

def resolve(addr):
    for s, e, fo, path in maps:
        if s <= addr < e:
            return path, addr - s + fo
    return None, None

def sym(path, fo):
    if "qemu-system" not in path:
        return ""
    va = fo2va(fo)
    if va is None:
        return ""
    r = subprocess.run([NDK + "/llvm-symbolizer", "--obj=" + B, f"0x{va:x}"],
                       capture_output=True, text=True)
    lines = [l for l in r.stdout.splitlines() if l.strip()]
    return "  | " + " | ".join(lines[:2]) if lines else ""

for pid, x, sp, pc in threads:
    lr = x[30]
    p1, f1 = resolve(pc)
    p2, f2 = resolve(lr)
    name1 = p1.split("/")[-1] if p1 else "?"
    name2 = p2.split("/")[-1] if p2 else "?"
    s1 = sym(p1, f1) if p1 else ""
    s2 = sym(p2, f2) if p2 else ""
    o1 = f1 if f1 else 0
    o2 = f2 if f2 else 0
    print(f"pid={pid} pc -> {name1}+0x{o1:x}{s1}")
    print(f"        lr -> {name2}+0x{o2:x}{s2}")
