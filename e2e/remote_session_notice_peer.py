#!/usr/bin/env python3
"""Disposable loopback SSH peer for exit/loss/retry notice acceptance."""
import argparse
import json
import logging
from pathlib import Path
import signal
import socket
import threading
import time
import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    stop = threading.Event()
    key = paramiko.RSAKey.generate(2048)
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(4)
    listener.settimeout(.1)
    report = {"connections": 0, "inputs": [], "errors": []}

    class Attempt(paramiko.ServerInterface):
        def __init__(self):
            self.shell = threading.Event()

        def get_allowed_auths(self, user):
            return "password"

        def check_auth_password(self, user, password):
            while (args.out / "slow").exists() and not stop.wait(.01):
                pass
            return paramiko.AUTH_SUCCESSFUL if user == "operator" and password == "fixture-password" else paramiko.AUTH_FAILED

        def check_channel_request(self, kind, channel_id):
            return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

        def check_channel_pty_request(self, *unused):
            return not (args.out / "reject").exists()

        def check_channel_shell_request(self, *unused):
            self.shell.set()
            return True

    signal.signal(signal.SIGTERM, lambda *unused: stop.set())
    (args.out / "ready.json").write_text(json.dumps({"port": listener.getsockname()[1], "user": "operator", "password": "fixture-password"}))
    try:
        while not stop.is_set():
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            report["connections"] += 1
            index = report["connections"]
            transport = paramiko.Transport(connection)
            transport.add_server_key(key)
            transport.get_security_options().kex = ["diffie-hellman-group14-sha256"]
            attempt = Attempt()
            channel = None
            try:
                transport.start_server(server=attempt)
                while transport.is_active() and not stop.is_set():
                    channel = transport.accept(.05)
                    if channel is None:
                        continue
                    if not attempt.shell.wait(2):
                        break
                    channel.settimeout(.1)
                    channel.sendall((f"REMOTE_HISTORY_{index}\r\n\x1b]133;A\x07fixture $ \x1b]133;B\x07").encode())
                    pending = b""
                    while transport.is_active() and not stop.is_set():
                        try:
                            payload = channel.recv(4096)
                        except socket.timeout:
                            continue
                        if not payload:
                            break
                        report["inputs"].append({"connection": index, "text": payload.decode(errors="replace")})
                        pending += payload
                        if b"exit 7\r" in pending:
                            channel.send_exit_status(7)
                            channel.shutdown_write()
                            time.sleep(.05)
                            break
                        if b"DROP\r" in pending:
                            transport.close()
                            break
                    break
            except (EOFError, OSError, paramiko.SSHException):
                pass
            finally:
                if channel is not None:
                    channel.close()
                transport.close()
                (args.out / "report.json").write_text(json.dumps(report))
    finally:
        listener.close()
        (args.out / "report.json").write_text(json.dumps(report))


if __name__ == "__main__":
    main()
