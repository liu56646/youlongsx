#!/usr/bin/env python3
# 从 core 头部（notes+phdrs）+ 可选栈内存块，还原崩溃线程的调用链。
# 用法： python3 bt_core.py <head.bin> <main_pid> [stack_blob.bin] [stack_blob_base_hex]
import os
import struct
import subprocess
import sys

NDK = "/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin"
QEMU = "/mnt/k/youlongsx/vm/engine/src/main/cpp/prebuilt/qemu-aosp/arm64-v8a/qemu-system-aarch64"
LIBC = "/mnt/k/youlongsx/vm/build-aosp-exp/libc_host.so"

head = sys.argv[1]
main_pid = int(sys.argv[2])
blob_path = sys.argv[3] if len(sys.argv) > 3 else None
blob_base = int(sys.argv[4], 16) if len(sys.argv) > 4 else 0

data = open(head, "rb").read()
e_phoff, = struct.unpack_from("<Q", data, 0x20)
e_phentsize, = struct.unpack_from("<H", data, 0x36)
e_phnum, = struct.unpack_from("<H", data, 0x38)

phdrs = []
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    t, fl, poff, vaddr, paddr, fsz, msz = struct.unpack_from("<IIQQQQQ", data, off)
    phdrs.append((t, poff, vaddr, fsz, msz))

# notes
parsed = []
for (t, poff, vaddr, fsz, msz) in phdrs:
    if t != 4:
        continue
    pos, end = poff, poff + fsz
    while pos + 12 <= min(end, len(data)):
        namesz, descsz, ntype = struct.unpack_from("<III", data, pos)
        pos += 12
        name = data[pos:pos + namesz]
        pos += (namesz + 3) & ~3
        parsed.append((ntype, pos, descsz))
        pos += (descsz + 3) & ~3

maps = []
for ntype, doff, dsz in parsed:
    if ntype != 0x46494c45:
        continue
    d = data[doff:doff + dsz]
    count, page = struct.unpack_from("<QQ", d, 0)
    p = 16
    ents = []
    for _ in range(count):
        s, e, fo = struct.unpack_from("<QQQ", d, p)
        p += 24
        ents.append((s, e, fo))
    paths = d[p:].split(b"\0")
    for i, (s, e, fo) in enumerate(ents):
        maps.append((s, e, fo, paths[i].decode("utf-8", "replace") if i < len(paths) else "?"))

regs = None
for ntype, doff, dsz in parsed:
    if ntype != 1:
        continue
    d = data[doff:doff + dsz]
    pid, = struct.unpack_from("<i", d, 32)
    if pid != main_pid:
        continue
    r = struct.unpack_from("<34Q", d, 112)
    regs = {"x": list(r[0:31]), "sp": r[31], "pc": r[32]}
    break

if regs is None:
    print("没找到该 pid 的 PRSTATUS"); sys.exit(1)

print(f"main pid={main_pid} pc=0x{regs['pc']:x} sp=0x{regs['sp']:x} fp=0x{regs['x'][29]:x} lr=0x{regs['x'][30]:x}")

# 找 sp 所在段
for (t, poff, vaddr, fsz, msz) in phdrs:
    if t == 1 and vaddr <= regs["sp"] < vaddr + msz:
        print(f"stack seg: vaddr=0x{vaddr:x} filesz=0x{fsz:x} -> "
              f"dd skip={(poff)//4096} count={(fsz+4095)//4096}")
        break

def resolve(addr):
    for s, e, fo, path in maps:
        if s <= addr < e:
            return path, addr - s + fo
    return None, None

def sym(path, off):
    if "qemu-system" in path and os.path.exists(QEMU):
        obj = QEMU
    elif "libc.so" in path and os.path.exists(LIBC):
        obj = LIBC
    else:
        return ""
    try:
        r = subprocess.run([os.path.join(NDK, "llvm-symbolizer"), "--obj=" + obj, f"0x{off:x}"],
                           capture_output=True, text=True, timeout=20)
        lines = [l for l in r.stdout.strip().splitlines() if l.strip()]
        return "  | " + " | ".join(lines[:2]) if lines else ""
    except Exception:
        return ""

def show(tag, addr):
    path, off = resolve(addr)
    if path:
        print(f"  {tag}=0x{addr:x} -> {os.path.basename(path)} +0x{off:x}{sym(path, off)}")
    else:
        print(f"  {tag}=0x{addr:x} -> <no map>")

show("pc", regs["pc"])
show("lr", regs["x"][30])

if blob_path:
    blob = open(blob_path, "rb").read()
    print(f"blob {len(blob)} bytes @ 0x{blob_base:x}")
    def rd64(a):
        o = a - blob_base
        if o < 0 or o + 8 > len(blob):
            return None
        return struct.unpack_from("<Q", blob, o)[0]
    print("--- fp walk ---")
    cur = regs["x"][29]
    for i in range(80):
        if not cur:
            break
        nxt = rd64(cur)
        ret = rd64(cur + 8)
        if ret is None:
            print(f"  [fp 0x{cur:x} 超出 blob]")
            break
        if ret:
            show(f"#{i}", ret)
        if not nxt or nxt <= cur:
            break
        cur = nxt
