#!/usr/bin/env python3
# 用 gdb 远程串行协议(RSP) 连 QEMU gdbstub，读每个 vCPU 的 PC/状态，
# 定位 guest 的 virtio_gpu probe 线程卡在哪个地址。
import socket
import sys
import struct

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2] if len(sys.argv) > 2 else "1234")

def conn():
    s = socket.create_connection((HOST, PORT), timeout=10)
    s.settimeout(5)
    return s

def rsp_cmd(s, cmd):
    # 发送 $cmd#csum
    pkt = b"$" + cmd.encode() + b"#"
    csum = 0
    for b in cmd.encode():
        csum = csum ^ b  # gdb RSP 校验和是 XOR
    pkt += ("%02x" % csum).encode()
    s.sendall(pkt)
    # 读响应（可能有多包 +/+ 确认）
    data = b""
    s.settimeout(8)
    try:
        while True:
            ch = s.recv(1)
            if not ch:
                break
            if ch == b"$":
                # 包开始，读到 # 和 2 位校验
                body = b""
                while True:
                    c = s.recv(1)
                    if c == b"#":
                        s.recv(2)
                        break
                    body += c
                data += body
            elif ch == b"+":
                pass  # ack
            elif ch == b"-":
                data += b"NACK"
            else:
                data += ch
            if data and data[-1:] in (b"\x00",) or b"\n" in data:
                break
            if b"$" not in data and len(data) > 0 and ch == b"+" and data == b"":
                continue
    except socket.timeout:
        pass
    return data

def parse_regs_g(pkt):
    # g 包：AArch64 gdb 顺序：x0..x30 (31), sp, pc, cpsr, v0..v31(128bit=32bytes each), fpsr, fpcr
    # 前 34 个是 8 字节。
    regs = {}
    if len(pkt) < 34 * 16:
        return None
    for i in range(34):
        chunk = pkt[i * 16 : i * 16 + 16]  # 每寄存器 16 个 hex 字符 = 8 字节 LE
        if len(chunk) < 16:
            break
        val = int(chunk, 16) if chunk else 0
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
    s = conn()
    # 查询 stop 状态
    r = rsp_cmd(s, "?")
    # 枚举 CPU：gdbstub 线程是每个 vCPU
    s.sendall(b"$qC#00")
    # 读所有 CPU 的 PC：每个 vCPU 一个线程，先 Hg 到每个 threadid
    # 简单方式：直接 g（当前 CPU）。多核枚举复杂，先读默认（CPU0）。
    r = rsp_cmd(s, "g")
    regs = parse_regs_g(r)
    if regs:
        print("CPU? pc=0x%x sp=0x%x cpsr=0x%x" % (regs["pc"], regs["sp"], regs["cpsr"]))
        print("x0=0x%x x1=0x%x x2=0x%x x3=0x%x" % (regs["x0"], regs["x1"], regs["x2"], regs["x3"]))
        print("x29=0x%x x30=0x%x" % (regs["x29"], regs["x30"]))
    else:
        print("g 包解析失败 len=%d head=%r" % (len(r), r[:40]))
    # 尝试枚举线程（vCPU）
    r = rsp_cmd(s, "qThreadExtraInfo,0")
    s.close()

if __name__ == "__main__":
    main()
