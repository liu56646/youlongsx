#!/usr/bin/env python3
# 修正版：NT_FILE 的 foff 以【页】为单位；file_off = foff*page + (addr-map_start)，
# 再经 qemu 二进制的 PT_LOAD 换算成 vaddr，最后用 llvm-symbolizer（带符号）。
import struct
import subprocess
import sys

NDK = "/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin"
B = "/mnt/k/youlongsx/vm/engine/src/main/cpp/prebuilt/qemu-aosp/arm64-v8a/qemu-system-aarch64"
HEAD = "/mnt/k/youlongsx/vm/build-aosp-exp/core_head2.bin"
STK = "/mnt/k/youlongsx/vm/build-aosp-exp/stk.bin"
STK_BASE = 0x7ff37b9000

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
maps, regs = [], None
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
            if pid == 4033:
                r = struct.unpack_from("<34Q", d, 112)
                regs = {"x": list(r[0:31]), "sp": r[31], "pc": r[32]}
        pos += (descsz + 3) & ~3

def resolve(addr):
    for s, e, fo, path in maps:
        if s <= addr < e:
            return path, addr - s + fo
    return None, None

def show(tag, addr):
    path, fo = resolve(addr)
    if not path:
        print(f"  {tag} 0x{addr:x} <no map>")
        return
    extra = ""
    if "qemu-system" in path:
        va = fo2va(fo)
        if va is not None:
            r = subprocess.run([NDK + "/llvm-symbolizer", "--obj=" + B, f"0x{va:x}"],
                               capture_output=True, text=True)
            lines = [l for l in r.stdout.splitlines() if l.strip()]
            extra = "  | " + " | ".join(lines[:2]) if lines else ""
    print(f"  {tag} 0x{addr:x} -> {path.split('/')[-1]} +0x{fo:x}{extra}")

print(f"pc 0x{regs['pc']:x} sp 0x{regs['sp']:x} fp 0x{regs['x'][29]:x} lr 0x{regs['x'][30]:x}")
show("pc", regs["pc"])
show("lr", regs["x"][30])
blob = open(STK, "rb").read()
def rd64(a):
    o = a - STK_BASE
    if o < 0 or o + 8 > len(blob):
        return None
    return struct.unpack_from("<Q", blob, o)[0]
print("--- fp walk ---")
cur = regs["x"][29]
for i in range(60):
    if not cur:
        break
    nxt = rd64(cur)
    ret = rd64(cur + 8)
    if ret is None:
        print(f"  [fp 0x{cur:x} out of blob]"); break
    if ret:
        show(f"#{i}", ret)
    if not nxt or nxt <= cur:
        break
    cur = nxt
