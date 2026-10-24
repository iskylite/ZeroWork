#!/usr/bin/env python3
"""Real SSH packets to the production Zig IO worker; loopback only, no GUI."""
import argparse
import json
import logging
from pathlib import Path
import socket
import subprocess
import threading
import time
import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class Peer(paramiko.ServerInterface):
    def __init__(self):
        self.shell = threading.Event()

    def get_allowed_auths(self, user):
        return "password"

    def check_auth_password(self, user, password):
        return paramiko.AUTH_SUCCESSFUL if user == "fixture" and password == "fixture-password" else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, *args):
        return True

    def check_channel_shell_request(self, *args):
        self.shell.set()
        return True


class Fixture:
    def __init__(self, mode, key):
        self.mode, self.key = mode, key
        self.count, self.errors, self.protocol_end = 0, [], False
        self.stop = threading.Event()
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(3)
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
            peer = Peer()
            try:
                transport.start_server(server=peer)
                channel = transport.accept(2)
                if channel is None or not peer.shell.wait(2):
                    raise RuntimeError("shell-not-opened")
                channel.settimeout(2)
                if index == 2:
                    channel.sendall(b"second-ready\r\n")
                else:
                    channel.sendall(b"first-ready\r\n")
                    received = bytearray()
                    while b"END\n" not in received:
                        received.extend(channel.recv(1024))
                    if self.mode == "network":
                        # Raw TCP failure without SSH CHANNEL_EOF/CLOSE.
                        connection.shutdown(socket.SHUT_RDWR)
                    else:
                        channel.sendall(b"shell-final-tail\r\n")
                        if self.mode == "late0":
                            channel.shutdown_write()
                            time.sleep(0.06)
                        if self.mode != "unknown":
                            channel.send_exit_status(7 if self.mode == "exit7" else 0)
                        channel.shutdown_write()
                        channel.close()
                        self.protocol_end = True
                        if self.mode == "fast0":
                            transport.close()
                while transport.is_active() and not self.stop.wait(0.01):
                    pass
            except (EOFError, OSError):
                pass
            except Exception as error:
                self.errors.append(type(error).__name__ + ":" + str(error))
            finally:
                transport.close()

    def close(self):
        self.stop.set()
        self.listener.close()
        self.thread.join(3)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--mode", choices=["exit0", "exit7", "unknown", "late0", "fast0", "network"])
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    key = paramiko.RSAKey.generate(2048)
    cases = []
    for mode in ([args.mode] if args.mode else ["exit0", "exit7", "unknown", "late0", "fast0", "network"]):
        fixture = Fixture(mode, key)
        fixture.thread.start()
        try:
            result = subprocess.run([args.runner, str(fixture.port), mode], capture_output=True, text=True, timeout=10)
        finally:
            fixture.close()
        (output / (mode + ".stdout.log")).write_text(result.stdout)
        (output / (mode + ".stderr.log")).write_text(result.stderr)
        cases.append({"mode": mode, "exit_code": result.returncode, "connections": fixture.count, "protocol_end": fixture.protocol_end, "server_errors": fixture.errors, "passed": result.returncode == 0 and "PASS mode=" in result.stderr and fixture.count == (2 if mode == "network" else 1) and not fixture.errors})
    report = {"passed": sum(case["passed"] for case in cases), "total": len(cases), "cases": cases, "scope": "Production Session/SshWorker/Thread and actual Ghostty VT; no GUI or AppHost timer projection", "limits": ["Loopback SSH shell channel packets are fixture-generated; no remote OS process was executed", "Native 38px tombstone and host binding invalidation are verified separately by the main task"]}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["passed"] == report["total"] else 1)


if __name__ == "__main__":
    main()
