#!/usr/bin/env python3
"""通过 QMP 把 QEMU 的整机状态（迁移流）抓成一个文件，用于 quickboot 可行性验证。

用法（在 PC 上跑，设备侧 QEMU 通过 adb 端口转发暴露 QMP 与迁移落点）：

    # 一次性的端口转发：PC -> 设备 QMP；设备 -> PC 的快照落点
    adb forward tcp:4444 tcp:4444
    adb reverse tcp:5555 tcp:5555

    # 抓快照：QEMU 会连到设备侧 127.0.0.1:5555（即本脚本监听的端口）
    python vm/tools/qmp_snapshot.py --out snapshot.bin

注意：这条路径要绕 adb（`adb reverse`），实测只有 ~16 Mbps，3GB 档位要十几分钟；
真正做快照应让**落盘点在设备本地**（引擎进程自己监听回环端口写文件），
设备本地实测 270 MB/s。

2026-10-16 实测结论（见 docs/改动说明-启动提速(前台服务+大核).md §6）：
导出侧一切正常，但把这条流用 `-incoming` 喂回去会被 QEMU 拒绝
（`Unknown ramblock "", cannot accept migration`）—— ranchu/gfxstream 这套
QEMU 的迁移路径被 Android 模拟器改过，期望的是 aemu 自己的 snapshot 框架。
所以本脚本目前只用于**导出侧**的诊断/取数，不能直接当作可用的快照方案。

恢复侧不需要本脚本：引擎在实例目录里看到 snapshot.bin 就会用
`-incoming unix:<dataDir>/logs/mig.sock` 起，并自己把文件喂进去（失败会自动删档
回退冷启动）。
"""

import argparse
import json
import os
import socket
import sys
import time


class Qmp:
    def __init__(self, host: str, port: int, timeout: float = 15.0) -> None:
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.buf = b""
        greeting = self._read_message()
        if "QMP" not in greeting:
            raise RuntimeError(f"不是 QMP 问候：{greeting!r}")
        self.execute("qmp_capabilities")

    def _read_message(self) -> dict:
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("QMP 连接被关闭")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line.decode("utf-8", "replace"))

    def drain_events(self) -> list:
        """把已经排队的异步事件读掉，避免影响下一条命令的应答。"""
        events = []
        self.sock.settimeout(0.05)
        try:
            while True:
                try:
                    msg = self._read_message()
                except socket.timeout:
                    break
                if "event" in msg:
                    events.append(msg)
        finally:
            self.sock.settimeout(15.0)
        return events

    def execute(self, command: str, arguments: dict | None = None) -> dict:
        self.drain_events()
        payload = {"execute": command}
        if arguments:
            payload["arguments"] = arguments
        self.sock.sendall(json.dumps(payload).encode() + b"\n")
        while True:
            msg = self._read_message()
            if "event" in msg:
                continue
            if "error" in msg:
                raise RuntimeError(f"{command} 失败：{msg['error']}")
            return msg


def snapshot(qmp: Qmp, listen_port: int, out_path: str) -> int:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("0.0.0.0", listen_port))
    listener.listen(1)
    listener.settimeout(60.0)

    uri = f"tcp:127.0.0.1:{listen_port}"
    print(f"[qmp] migrate -> {uri}", flush=True)
    qmp.execute("migrate", {"uri": uri})

    print(f"[net] 等待 QEMU 连入 {listen_port} …", flush=True)
    conn, peer = listener.accept()
    listener.close()
    print(f"[net] 已连接 {peer}，开始落盘 {out_path}", flush=True)

    tmp_path = out_path + ".part"
    total = 0
    started = time.time()
    with open(tmp_path, "wb") as fh:
        while True:
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            fh.write(chunk)
            total += len(chunk)
            if total % (256 << 20) < (1 << 20):
                rate = total / max(time.time() - started, 1e-6) / (1 << 20)
                print(f"[net] {total >> 20} MiB ({rate:.0f} MiB/s)", flush=True)
    conn.close()
    os.replace(tmp_path, out_path)
    print(f"[net] 完成：{total} 字节，用时 {time.time() - started:.1f}s", flush=True)

    deadline = time.time() + 60
    while time.time() < deadline:
        status = qmp.execute("query-migrate")
        state = status.get("return", {}).get("status")
        print(f"[qmp] migration status={state}", flush=True)
        if state in ("completed", "failed", "cancelled"):
            return 0 if state == "completed" else 1
        time.sleep(2)
    print("[qmp] 等待迁移完成超时", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--qmp-host", default="127.0.0.1")
    parser.add_argument("--qmp-port", type=int, default=4444)
    parser.add_argument("--listen-port", type=int, default=5555,
                        help="QEMU 回连的端口（需配合 adb reverse）")
    parser.add_argument("--out", default="snapshot.bin")
    parser.add_argument("--status", action="store_true", help="只查一次迁移状态")
    args = parser.parse_args()

    qmp = Qmp(args.qmp_host, args.qmp_port)
    if args.status:
        print(json.dumps(qmp.execute("query-migrate"), ensure_ascii=False, indent=2))
        return 0
    return snapshot(qmp, args.listen_port, args.out)


if __name__ == "__main__":
    raise SystemExit(main())
