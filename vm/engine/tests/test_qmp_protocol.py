"""Exercise the real C QMP client against a local fake server (Linux/WSL, cc).

Run: python3 vm/engine/tests/test_qmp_protocol.py
"""
import ctypes
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest


class QmpProtocolTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="vm-qmp-test-")
        root = Path(cls.build.name)
        (root / "android").mkdir()
        (root / "android/log.h").write_text(
            "#define ANDROID_LOG_INFO 4\n#define ANDROID_LOG_WARN 5\n"
            "static inline int __android_log_print(int p, const char *t, "
            "const char *f, ...) {(void)p;(void)t;(void)f;return 0;}\n"
        )
        source = Path(__file__).resolve().parents[1] / "src/main/cpp/src/vm_qmp.c"
        binary = root / "libqmp.so"
        subprocess.run(["cc", "-shared", "-fPIC", "-pthread", "-Wall", "-Wextra",
                        "-I", str(root), str(source), "-o", str(binary)], check=True)
        cls.client = ctypes.CDLL(str(binary))
        cls.client.vm_qmp_connect.argtypes = [ctypes.c_char_p]
        cls.client.vm_qmp_connect.restype = ctypes.c_bool
        cls.client.vm_qmp_connect_for_restore.argtypes = [ctypes.c_char_p]
        cls.client.vm_qmp_connect_for_restore.restype = ctypes.c_bool
        cls.client.vm_qmp_key.argtypes = [ctypes.c_int, ctypes.c_bool]
        cls.client.vm_qmp_request.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
                                            ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int]

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def run_server(self, exchange, action, connector=None):
        errors = []
        path = str(Path(self.build.name) / "qmp.sock")
        Path(path).unlink(missing_ok=True)
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(path)
            listener.listen(1)
            listener.settimeout(3)

            def serve():
                try:
                    conn, _ = listener.accept()
                    with conn:
                        conn.settimeout(3)
                        with conn.makefile("rwb", buffering=0) as stream:
                            def send(value):
                                stream.write(json.dumps(value).encode() + b"\n")
                            def receive():
                                return json.loads(stream.readline())
                            send({"QMP": {"version": {}}})
                            self.assertEqual(receive()["execute"], "qmp_capabilities")
                            send({"return": {}})
                            exchange(send, receive)
                except BaseException as exc:
                    errors.append(exc)

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            try:
                self.assertTrue((connector or self.client.vm_qmp_connect)(path.encode()))
                action()
            finally:
                self.client.vm_qmp_disconnect()
                thread.join(4)
            self.assertFalse(thread.is_alive(), "server did not finish")
            if errors:
                raise errors[0]

    def request(self, command, timeout=1000):
        reply = ctypes.create_string_buffer(4096)
        rc = self.client.vm_qmp_request(command.encode(), None, reply, len(reply), timeout)
        return rc, json.loads(reply.value) if reply.value else None

    def test_restore_retries_before_input_throttle_expires(self):
        path = Path(self.build.name) / "qmp.sock"
        path.unlink(missing_ok=True)
        self.assertFalse(self.client.vm_qmp_connect(str(path).encode()))
        time.sleep(.08)

        def connect(encoded):
            # Normal input still respects the one-second failure throttle.
            self.assertFalse(self.client.vm_qmp_connect(encoded))
            return self.client.vm_qmp_connect_for_restore(encoded)

        self.run_server(lambda send, receive: None, lambda: None, connector=connect)

    def test_pending_input_and_wrong_request_cannot_acknowledge_snapshot(self):
        def exchange(send, receive):
            self.assertEqual(receive()["execute"], "input-send-event")
            stop = receive()
            send({"return": {}})  # delayed input reply, no ID
            send({"event": "STOP"})
            send({"return": {}, "id": "vmhost-request-wrong"})
            send({"error": {"class": "GenericError", "desc": "stop rejected"},
                  "id": stop["id"]})
            save = receive()
            self.assertNotEqual(save["id"], stop["id"])
            send({"error": {"desc": "old error"}, "id": stop["id"]})
            send({"return": "saved", "id": save["id"]})

        def action():
            self.client.vm_qmp_key(30, True)
            rc, reply = self.request("stop")
            self.assertEqual(rc, 1)
            self.assertEqual(reply["error"]["desc"], "stop rejected")
            rc, reply = self.request("human-monitor-command")
            self.assertEqual(rc, 0)
            self.assertEqual(reply["return"], "saved")

        self.run_server(exchange, action)

    def test_late_reply_after_timeout_cannot_complete_next_request(self):
        def exchange(send, receive):
            stop = receive()
            time.sleep(.12)
            send({"return": "late stop", "id": stop["id"]})
            cont = receive()
            send({"return": "continued", "id": cont["id"]})

        def action():
            self.assertEqual(self.request("stop", timeout=30), (-1, None))
            rc, reply = self.request("cont")
            self.assertEqual(rc, 0)
            self.assertEqual(reply["return"], "continued")

        self.run_server(exchange, action)


if __name__ == "__main__":
    unittest.main(verbosity=2)
