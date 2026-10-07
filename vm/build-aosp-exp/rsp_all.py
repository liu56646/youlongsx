#!/usr/bin/env python3
# RSP 完整枚举：qfThreadInfo 列出所有 vCPU 线程，逐个 Hg + g 读 PC
import socket
import sys

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2] if len(sys.argv) > 2 else "1234")

def csum(b):
    c = 0
    for x in b:
        c ^= x
    return c

def send_pkt(s, cmd):
    b = cmd if isinstance(cmd, bytes) else cmd.encode()
    pkt = b"$" + b + b"#%02x" % csum(b)
    s.sendall(pkt)
    out = b""
    s.settimeout(2)
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

def parse_g(pkt):
    regs = {}
    for i in range(34):
        chunk = pkt[i * 16 : i * 16 + 16]
        if len(chunk) < 16:
            break
        # hex 字符串是小端字节序，反转字节后转 int
        b = bytes.fromhex(chunk.decode())
        val = int.from_bytes(b, "little")
        if i < 31:
            regs["x%d" % i] = val
        elif i == 31:
            regs["sp"] = val
        elif i == 32:
            regs["pc"] = val
        elif i == 33:
            regs["cpsr"] = val
    return regs

def main():
    s = socket.create_connection((HOST, PORT), timeout=5)
    s.settimeout(4)
    # 枚举线程
    threads = []
    r = send_pkt(s, b"qfThreadInfo")
    if r.startswith(b"m"):
        threads += [t for t in r[1:].split(b",") if t]
    while True:
        r = send_pkt(s, b"qsThreadInfo")
        if r.startswith(b"m"):
            threads += [t for t in r[1:].split(b",") if t]
        else:
            break
    if not threads:
        # 回退：试 1..8
        threads = [b"%x" % i for i in range(1, 9)]
    print("threads:", [t.decode() for t in threads])
    for t in threads:
        send_pkt(s, b"Hg" + t)
        r = send_pkt(s, b"g")
        regs = parse_g(r)
        if regs:
            mode = regs.get("cpsr", 0) & 0xf
            print("cpu=%s pc=0x%x sp=0x%x cpsr=0x%x mode=%x" % (
                t.decode(), regs.get("pc", 0), regs.get("sp", 0),
                regs.get("cpsr", 0), mode))
        else:
            print("cpu=%s g fail len=%d" % (t.decode(), len(r)))
    s.close()

if __name__ == "__main__":
    main()
