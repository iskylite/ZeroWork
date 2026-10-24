#!/usr/bin/env python3
"""Actual native release receipts against an owned loopback SSH peer.

The per-transport close handler withholds CHANNEL_CLOSE acknowledgements.
Exec packets are acknowledged, but no process, PTY or shell is created.
"""
import argparse
import json
import logging
from pathlib import Path
import socket
import subprocess
import threading

import paramiko
from paramiko.common import MSG_CHANNEL_CLOSE

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class Server(paramiko.ServerInterface):
    def __init__(self):
        self.execs = []
        self.close_packets = 0
        self.unexpected = []

    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL

    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED

    def check_channel_exec_request(self, channel, command):
        self.execs.append(command.decode())
        return True

    def check_channel_pty_request(self, *args):
        self.unexpected.append("pty")
        return False

    def check_channel_shell_request(self, channel):
        self.unexpected.append("shell")
        return False


def run_case(runner, key, mode):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(4)
    port = listener.getsockname()[1]
    server = Server()
    errors = []
    transports = []
    channels = []
    peer_eof = threading.Event()

    def serve():
        try:
            connection, _ = listener.accept()
            with connection:
                transport = paramiko.Transport(connection)
                transports.append(transport)
                handlers = transport._channel_handler_table.copy()

                def hold_close(channel, message):
                    server.close_packets += 1

                handlers[MSG_CHANNEL_CLOSE] = hold_close
                transport._channel_handler_table = handlers
                transport.add_server_key(key)
                transport.start_server(server=server)
                while transport.is_active():
                    channel = transport.accept(0.02)
                    if channel is not None:
                        channels.append(channel)
                peer_eof.set()
        except (EOFError, ConnectionResetError, BrokenPipeError, paramiko.SSHException):
            peer_eof.set()
        except Exception as exc:
            errors.append(type(exc).__name__ + ": " + str(exc))

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    try:
        process = subprocess.run([str(runner), str(port), mode], text=True, capture_output=True, timeout=5)
        output = (process.stdout + process.stderr).strip()
        eof = peer_eof.wait(1)
    except subprocess.TimeoutExpired:
        output = "runner timeout"
        process = None
        eof = False
    finally:
        for transport in transports:
            transport.close()
        listener.close()
        worker.join(1)
    expected = ["fixture-no-process-first"]
    if mode == "child-isolation":
        expected.append("fixture-no-process-second")
    passed = process is not None and process.returncode == 0 and "PASS " in output and server.execs == expected and server.close_packets >= 1 and eof and not errors and not server.unexpected and not worker.is_alive()
    return {"mode": mode, "passed": passed, "output": output, "exec_packets_acknowledged_without_process": server.execs, "close_packets_withheld": server.close_packets, "peer_observed_eof": eof, "errors": errors, "unexpected": server.unexpected}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=Path("dist/ssh-acceptance/20261019/release-receipts/report.json"))
    args = parser.parse_args()
    key = paramiko.RSAKey.generate(2048)
    cases = [run_case(args.runner, key, mode) for mode in ("child-isolation", "native-awaiting")]
    report = {"scope": "actual native allocation/free, EAGAIN owner retention, child close isolation and final owned FD release", "passed": sum(case["passed"] for case in cases), "total": len(cases), "cases": cases, "limits": ["Owned loopback peer only; no remote host or process, GUI or application build.", "Fixture pins the existing diffie-hellman-group14-sha256 KEX so every counted LIBSSH2_ALLOC allocation has an observable matching callback free. This is a release test, not an all-KEX crypto test.", "The mbedTLS ECDH backend allocates its private-key struct through LIBSSH2_ALLOC but frees it directly through mbedtls_free; allocator-observer-ecdh.json records why that first probe cannot use this callback counter as a total leak detector.", "Crypto library global allocations are outside this counter."]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    for case in cases:
        print(f"{case['mode']}: {'PASS' if case['passed'] else 'FAIL'} {case['output']}")
    raise SystemExit(0 if report["passed"] == report["total"] else 1)


if __name__ == "__main__":
    main()
