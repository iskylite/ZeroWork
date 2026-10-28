#!/usr/bin/env python3
"""Headless production SessionHost/Workspace reconnect; isolated loopback only."""
import argparse
import json
import logging
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class Attempt(paramiko.ServerInterface):
    def __init__(self, fixture, index):
        self.fixture, self.index = fixture, index
        self.shell = threading.Event()
        self.pty_rejected = threading.Event()

    def get_allowed_auths(self, user):
        return "password"

    def check_auth_password(self, user, password):
        return paramiko.AUTH_SUCCESSFUL if user == "operator" and password == "fixture-password" else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, channel_id):
        self.fixture.calls.append([self.index, kind])
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, *args):
        self.fixture.calls.append([self.index, "pty"])
        if self.fixture.mode == "initial-failure" and self.index == 1:
            self.pty_rejected.set()
            return False
        return True

    def check_channel_shell_request(self, *args):
        self.fixture.calls.append([self.index, "shell"])
        self.shell.set()
        return True

    def check_channel_exec_request(self, *args):
        self.fixture.calls.append([self.index, "UNEXPECTED_exec"])
        return False


class Fixture:
    def __init__(self, mode, key):
        self.mode, self.key = mode, key
        self.calls, self.errors = [], []
        self.count = 0
        self.received = {}
        self.stop = threading.Event()
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(4)
        self.listener.settimeout(0.1)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.count += 1
            index = self.count
            transport = paramiko.Transport(connection)
            transport.add_server_key(self.key)
            transport.get_security_options().kex = ["diffie-hellman-group14-sha256"]
            attempt = Attempt(self, index)
            channel = None
            try:
                transport.start_server(server=attempt)
                while transport.is_active() and not self.stop.is_set():
                    channel = transport.accept(0.05)
                    if channel is None:
                        continue
                    until = time.monotonic() + 2
                    while not attempt.shell.is_set() and not attempt.pty_rejected.is_set() and time.monotonic() < until:
                        time.sleep(0.002)
                    if attempt.pty_rejected.is_set():
                        break
                    if not attempt.shell.is_set():
                        raise RuntimeError("missing-shell")
                    channel.settimeout(0.1)
                    if index == 1:
                        channel.sendall(b"first-ready\r\n" + b"retained output\r\n" * 60)
                    else:
                        if self.mode == "manual-clear":
                            channel.sendall(b"\x1b[3J\x1b[2J\x1b[H")
                        channel.sendall(b"second-ready\r\n")
                    while transport.is_active() and not self.stop.is_set():
                        try:
                            payload = channel.recv(65536)
                        except socket.timeout:
                            continue
                        if not payload:
                            break
                        self.received.setdefault(index, bytearray()).extend(payload)
                        if b"DROP" in payload:
                            # Simulate transport loss, without SSH CHANNEL_EOF.
                            connection.shutdown(socket.SHUT_RDWR)
                            break
                    break
            except (EOFError, OSError):
                pass
            except Exception as error:
                self.errors.append(type(error).__name__ + ":" + str(error))
            finally:
                transport.close()
                if channel is not None:
                    channel.close()

    def close(self):
        self.stop.set()
        self.listener.close()
        self.thread.join(timeout=3)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--mode", choices=["manual", "manual-clear", "automatic", "manual-race", "initial-failure", "cancel-reconnect"])
    options = parser.parse_args()
    output = Path(options.output)
    output.mkdir(parents=True, exist_ok=True)
    key = paramiko.RSAKey.generate(2048)
    cases = []
    for mode in ([options.mode] if options.mode else ["manual", "manual-clear", "automatic", "manual-race", "initial-failure", "cancel-reconnect"]):
        fixture = Fixture(mode, key)
        fixture.thread.start()
        with tempfile.TemporaryDirectory(prefix="zerowork-reconnect-") as directory:
            environment = dict(os.environ, ZEROWORK_DATA_DIR=directory)
            try:
                result = subprocess.run([options.runner, str(fixture.port), mode], env=environment, capture_output=True, text=True, timeout=15)
            except subprocess.TimeoutExpired as error:
                result = subprocess.CompletedProcess([], 124, (error.stdout or b"").decode() if isinstance(error.stdout, bytes) else (error.stdout or ""), (error.stderr or b"").decode() if isinstance(error.stderr, bytes) else (error.stderr or ""))
            finally:
                fixture.close()
            (output / (mode + ".stdout.log")).write_text(result.stdout)
            (output / (mode + ".stderr.log")).write_text(result.stderr)
            case = {"mode": mode, "exit_code": result.returncode, "connections": fixture.count, "calls": fixture.calls, "received": {str(index): bytes(data).decode("utf-8", "replace") for index, data in fixture.received.items()}, "server_errors": fixture.errors, "passed": result.returncode == 0 and fixture.count == 2 and not fixture.errors and ("RECONNECT_OK" in result.stderr or "RECONNECT_CANCEL_OK" in result.stderr)}
            if mode not in ("initial-failure", "cancel-reconnect"):
                case["passed"] = case["passed"] and bytes(fixture.received.get(1, b"")) == b"DROP\n" and bytes(fixture.received.get(2, b"")) == "CACHED_中\n".encode()
            if mode == "cancel-reconnect":
                case["passed"] = case["passed"] and bytes(fixture.received.get(1, b"")) == b"DROP\n" and not fixture.received.get(2)
            cases.append(case)
    report = {"passed": sum(case["passed"] for case in cases), "total": len(cases), "cases": cases, "limits": ["No native window or visual banner verification", "Partial-write/UTF8 capacity/mode mismatch/invalidations are covered by focused controller tests", "Shell channels are fixture byte streams, not real remote processes"]}
    (output / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["passed"] == report["total"] else 1)


if __name__ == "__main__":
    main()
