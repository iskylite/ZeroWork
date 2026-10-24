#!/usr/bin/env python3
"""Real control-channel RTT and negotiated metadata, with no remote commands."""
import argparse
import base64
import hashlib
import json
import logging
from pathlib import Path
import re
import select
import socket
import subprocess
import tempfile
import threading
import time

import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class Fixture(paramiko.ServerInterface):
    def __init__(self, key, delay=0.12, reject_first=False, target_port=None):
        self.key, self.delay = key, delay
        self.reject_first, self.target_port = reject_first, target_port
        self.calls, self.errors, self.sessions = [], [], 0
        self.stopped = threading.Event()
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.settimeout(5)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.transport = None
        self.negotiated = {}

    def get_allowed_auths(self, user):
        return "password"

    def check_auth_password(self, user, password):
        self.negotiated = {"algorithm": self.transport.host_key_type, "c2s": self.transport.remote_cipher, "s2c": self.transport.local_cipher}
        return paramiko.AUTH_SUCCESSFUL if user == "operator" and password == "fixture-password" else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, channel_id):
        self.calls.append(kind)
        if kind != "session":
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        self.sessions += 1
        time.sleep(self.delay)
        if self.reject_first and self.sessions == 1:
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        return paramiko.OPEN_SUCCEEDED

    def check_channel_direct_tcpip_request(self, channel_id, origin, destination):
        self.calls.append("direct-tcpip")
        return paramiko.OPEN_SUCCEEDED if self.target_port and destination == ("127.0.0.1", self.target_port) else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, *args):
        self.calls.append("UNEXPECTED_pty")
        return False

    def check_channel_shell_request(self, *args):
        self.calls.append("UNEXPECTED_shell")
        return False

    def check_channel_exec_request(self, *args):
        self.calls.append("UNEXPECTED_exec")
        return False

    def check_channel_subsystem_request(self, *args):
        self.calls.append("UNEXPECTED_subsystem")
        return False

    def channel(self, channel, forwarded):
        peer = None
        try:
            if forwarded:
                peer = socket.create_connection(("127.0.0.1", self.target_port), timeout=3)
                while self.transport.is_active() and not self.stopped.is_set():
                    ready, _, _ = select.select([channel, peer], [], [], 0.01)
                    for source in ready:
                        payload = source.recv(65536)
                        if not payload:
                            return
                        (peer if source is channel else channel).sendall(payload)
            else:
                channel.settimeout(0.05)
                while not channel.closed and not self.stopped.is_set():
                    try:
                        data = channel.recv(1024)
                    except socket.timeout:
                        continue
                    if data:
                        self.errors.append("UnexpectedSamplePayload")
                    if not data:
                        return
        except (EOFError, OSError):
            pass
        finally:
            channel.close()
            if peer:
                peer.close()

    def run(self):
        try:
            connection, _ = self.listener.accept()
            self.transport = paramiko.Transport(connection)
            self.transport.add_server_key(self.key)
            self.transport.get_security_options().kex = ["diffie-hellman-group14-sha256"]
            self.transport.start_server(server=self)
            forward_pending = bool(self.target_port)
            while self.transport.is_active() and not self.stopped.is_set():
                channel = self.transport.accept(0.02)
                if channel is None:
                    continue
                self.negotiated = {"algorithm": self.transport.host_key_type, "c2s": self.transport.remote_cipher, "s2c": self.transport.local_cipher}
                forwarded = forward_pending
                forward_pending = False
                threading.Thread(target=self.channel, args=(channel, forwarded), daemon=True).start()
        except (EOFError, OSError, paramiko.SSHException):
            pass
        except Exception as error:
            self.errors.append(type(error).__name__ + ":" + str(error))
        finally:
            if self.transport:
                self.transport.close()
            self.listener.close()

    def stop(self):
        self.stopped.set()
        if self.transport:
            self.transport.close()
        self.listener.close()
        self.thread.join(timeout=2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", required=True)
    parser.add_argument("--output", required=True)
    options = parser.parse_args()
    output = Path(options.output)
    output.mkdir(parents=True, exist_ok=True)
    key = paramiko.RSAKey.generate(2048)
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    cases = []
    for mode in ["direct", "cancel", "timeout", "reject", "route", "probe", "probe-default"]:
        target = Fixture(key, reject_first=mode == "reject")
        parent = Fixture(key, delay=0.08, target_port=target.port) if mode == "route" else None
        fixtures = ([parent] if parent else []) + [target]
        with tempfile.TemporaryDirectory(prefix="zerowork-rtt-") as directory:
            store = Path(directory) / "known_hosts"
            store.write_text("".join(f"[127.0.0.1]:{fixture.port} {key.get_name()} {key.get_base64()}\n" for fixture in fixtures))
            before = store.read_bytes()
            for fixture in fixtures:
                fixture.thread.start()
            command = [options.runner, str(target.port), mode, str(store)] + ([str(parent.port)] if parent else [])
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=12)
            except subprocess.TimeoutExpired as error:
                result = subprocess.CompletedProcess(command, 124, "", str(error))
            finally:
                for fixture in reversed(fixtures):
                    fixture.stop()
            (output / f"{mode}.stdout.log").write_text(result.stdout)
            (output / f"{mode}.stderr.log").write_text(result.stderr)
            rows = re.findall(r"DETAILS_METADATA hop=(\d+) algorithm=(\S+) c2s=(\S+) s2c=(\S+) fingerprint=(\S+) rtt_ms=(\d+|none)", result.stderr)
            metadata_matches = len(rows) == len(fixtures)
            for index, algorithm, c2s, s2c, actual_fingerprint, _ in rows:
                fixture = fixtures[int(index)]
                metadata_matches &= fixture.negotiated == {"algorithm": algorithm, "c2s": c2s, "s2c": s2c} and actual_fingerprint == fingerprint
            expected_sessions = 0 if mode == "probe-default" else 1 if mode in ("direct", "route", "probe") else 2
            case = {"mode": mode, "exit_code": result.returncode, "metadata_matches_server": metadata_matches, "trust_store_unchanged": store.read_bytes() == before, "calls": [fixture.calls for fixture in fixtures], "sample_channels": [fixture.sessions for fixture in fixtures], "errors": [fixture.errors for fixture in fixtures]}
            case["passed"] = result.returncode == 0 and "DETAILS_RTT_OK" in result.stderr and metadata_matches and case["trust_store_unchanged"] and all(fixture.sessions == expected_sessions and not fixture.errors and not any(call.startswith("UNEXPECTED") for call in fixture.calls) for fixture in fixtures)
            cases.append(case)
    report = {"passed": sum(case["passed"] for case in cases), "total": len(cases), "cases": cases, "limits": ["No GUI or connection detail layout acceptance", "Fixture endpoints run SSH authentication and control channels only; no remote shell/PTY/exec/subsystem", "Queued Exec arbitration is exercised and cancelled before it can send a channel-open or command"]}
    (output / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["passed"] == report["total"] else 1)


if __name__ == "__main__":
    main()
