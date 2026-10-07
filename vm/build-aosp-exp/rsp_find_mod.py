#!/usr/bin/env python3
# 用 RSP 读 guest 内存，搜索 virtio_gpu_probe 的特征机器码，定位模块基址。
# 特征：sub sp,#0x50; str x30,[x18],#8; stp x29,x30,[sp,#0x20]
import socket
import sys

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2] if len(sys.argv) > 2 else "1234")
START = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0xffff000008000000
LEN = int(sys.argv[4], 16) if len(sys.argv) > 4 else 0x4000000  # 64MB

PAT = bytes.fromhex("ff4301d15e8600f8fd7b02a9")  # virtio_gpu_probe 开头

def csum(b):
    c = 0
    for x in b:
        c ^= x
    return c

def rsp(s, cmd):
    b = cmd if isinstance(cmd, bytes) else cmd.encode()
    s.sendall(b"$" + b + b"#%02x" % csum(b))
    out = b""
    s.settimeout(5)
    try:
        while True:
            ch = s.recv(1)
            if not ch:
                break
            if ch == b"$":
                body = b""
                while True:
                    c = s.recv(1)
                    if c == b"#":
                        s.recv(2)
                        break
                    body += c
                out = body
                break
            elif ch in (b"+", b"-"):
                continue
    except socket.timeout:
        pass
    return out

s = socket.create_connection((HOST, PORT), timeout=5)
CHUNK = 0x100000  # 1MB/次
found = []
addr = START
end = START + LEN
while addr < end:
    ln = min(CHUNK, end - addr)
    r = rsp(s, b"m%x,%x" % (addr, ln))
    if len(r) == ln * 2 and not r.startswith(b"E"):
        data = bytes.fromhex(r.decode())
        idx = 0
        while True:
            i = data.find(PAT, idx)
            if i < 0:
                break
            found.append(addr + i)
            idx = i + 1
    else:
        print("read fail @ 0x%x len=%d r=%r" % (addr, ln, r[:20]))
    addr += ln
    if len(found) > 0:
        break
s.close()
print("found:", ["0x%x" % f for f in found])
