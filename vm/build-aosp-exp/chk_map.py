#!/usr/bin/env python3
import struct
data = open("/mnt/k/youlongsx/vm/build-aosp-exp/core_head2.bin", "rb").read()
e_phoff, = struct.unpack_from("<Q", data, 0x20)
e_phentsize, = struct.unpack_from("<H", data, 0x36)
e_phnum, = struct.unpack_from("<H", data, 0x38)
maps = []
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    t, fl, poff, vaddr, paddr, fsz, msz = struct.unpack_from("<IIQQQQQ", data, off)
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
                maps.append((s, e, fo, paths[k].decode("utf-8", "replace") if k < len(paths) else "?"))
        pos += (descsz + 3) & ~3

for a in [0x57d05295fc, 0x57d02c87ec, 0x57d02c52d8, 0x57d02c2274]:
    for s, e, fo, path in maps:
        if s <= a < e:
            print(f"0x{a:x}: map 0x{s:x}-0x{e:x} foff=0x{fo:x} -> {path} +0x{a-s+fo:x}")
            break
    else:
        print(f"0x{a:x}: <no map>")
print("\nqemu 的所有映射：")
for s, e, fo, path in maps:
    if "qemu-system" in path:
        print(f"  0x{s:x}-0x{e:x} foff=0x{fo:x} size=0x{e-s:x}")
