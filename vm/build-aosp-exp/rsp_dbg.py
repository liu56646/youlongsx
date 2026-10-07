#!/usr/bin/env python3
# RSP 调试版：最小握手，打印原始响应
import socket
import sys
import binascii

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
    # 读响应：可能先 + / - 然后 $包#
    out = b""
    s.settimeout(3)
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
                out += b"PKT:" + body + b" "
            elif ch == b"+":
                out += b"+ "
            elif ch == b"-":
                out += b"- "
            else:
                out += ch
    except socket.timeout:
        pass
    return out

s = socket.create_connection((HOST, PORT), timeout=5)
print("connected")

# 1. 发送空包试探（gdb 客户端连接后会发 qSupported 或 ?）
print("qSupported:", send_pkt(s, b"qSupported:multiprocess+;qRelocInsn+"))

# 2. 查询状态
print("?:", send_pkt(s, b"?"))

# 3. 读寄存器 g
print("g:", send_pkt(s, b"g"))

# 4. Hg0 选线程
print("Hg0:", send_pkt(s, b"Hg0"))

# 5. 再读 g
print("g2:", send_pkt(s, b"g"))
s.close()
