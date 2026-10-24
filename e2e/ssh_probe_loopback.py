#!/usr/bin/env python3
"""Exercise the production wizard probe over isolated loopback SSH fixtures.

No GUI, shell, PTY, exec or user trust store. An explicit test sink consumes
real challenges only in the interactive cases; production has no such sink.
"""
import argparse
import json
import logging
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import threading
import time

import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class Fixture(paramiko.ServerInterface):
    def __init__(self, host_key, target_port=None):
        self.host_key = host_key
        self.target_port = target_port
        self.calls = []
        self.errors = []
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.settimeout(8)
        self.port = self.listener.getsockname()[1]
        self.finished = threading.Event()
        self.peer_closed = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def get_allowed_auths(self, username):
        return "password"

    def check_auth_none(self, username):
        self.calls.append("none")
        return paramiko.AUTH_FAILED

    def check_auth_password(self, username, password):
        self.calls.append("password")
        return paramiko.AUTH_SUCCESSFUL if username == "operator" and password == "fixture-password" else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        self.calls.append(f"UNEXPECTED_{kind}")
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_direct_tcpip_request(self, chanid, origin, destination):
        self.calls.append("direct-tcpip")
        if self.target_port is not None and destination == ("127.0.0.1", self.target_port):
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, *args):
        self.calls.append("UNEXPECTED_pty")
        return False

    def check_channel_shell_request(self, *args):
        self.calls.append("UNEXPECTED_shell")
        return False

    def check_channel_exec_request(self, *args):
        self.calls.append("UNEXPECTED_exec")
        return False

    def serve(self):
        transport = None
        relay = None
        channel = None
        try:
            connection, _ = self.listener.accept()
            transport = paramiko.Transport(connection)
            transport.add_server_key(self.host_key)
            transport.start_server(server=self)
            while transport.is_active() and not self.finished.is_set():
                channel = transport.accept(0.01)
                if channel is None:
                    continue
                if self.target_port is None:
                    self.errors.append("UnexpectedAcceptedChannel")
                    break
                relay = socket.create_connection(("127.0.0.1", self.target_port), timeout=3)
                while transport.is_active() and not self.finished.is_set():
                    readable, _, _ = select.select([channel, relay], [], [], 0.01)
                    if not readable:
                        continue
                    closed = False
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            closed = True
                            break
                        (relay if source is channel else channel).sendall(data)
                    if closed:
                        break
                channel.close()
                channel = None
                relay.close()
                relay = None
            if not transport.is_active():
                self.peer_closed.set()
        except (EOFError, ConnectionResetError, BrokenPipeError, paramiko.SSHException):
            self.peer_closed.set()
        except Exception as exc:
            self.errors.append(type(exc).__name__)
        finally:
            if channel:
                channel.close()
            if relay:
                relay.close()
            if transport:
                transport.close()
            self.listener.close()

    def start(self):
        self.thread.start()

    def stop(self):
        self.finished.set()
        self.listener.close()
        self.thread.join(timeout=2)


def run_case(runner, mode, directory, host_key):
    target = Fixture(host_key)
    hop = Fixture(host_key, target.port) if mode in ("route", "interactive-route") else None
    fixtures = ([hop] if hop else []) + [target]
    store = directory / f"{mode}.known_hosts"
    if mode in ("known", "unavailable-password", "route"):
        store.write_text("".join(f"[127.0.0.1]:{fixture.port} {host_key.get_name()} {host_key.get_base64()}\n" for fixture in fixtures))
    before = store.read_bytes() if store.exists() else None
    for fixture in fixtures:
        fixture.start()
    started = time.monotonic()
    command = [str(runner), str(target.port), mode, str(store)]
    if hop:
        command.append(str(hop.port))
    result = None
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=12)
        # The runner checks a release receipt before exit. Independently observe
        # that fixture transports have actually received peer closure.
        for fixture in fixtures:
            fixture.peer_closed.wait(timeout=0.5)
    finally:
        for fixture in fixtures:
            fixture.stop()
    after = store.read_bytes() if store.exists() else None
    output = (result.stdout + result.stderr).strip()
    calls = {"target": target.calls, **({"hop": hop.calls} if hop else {})}
    no_session_channel = all(not call.startswith("UNEXPECTED_") for fixture in fixtures for call in fixture.calls)
    closed = all(fixture.peer_closed.is_set() and not fixture.thread.is_alive() for fixture in fixtures)
    errors = [error for fixture in fixtures for error in fixture.errors]
    pass_lines = [line for line in output.splitlines() if line.startswith("PASS ")]
    passed = result.returncode == 0 and len(pass_lines) == 1 and no_session_channel and closed and not errors and before == after
    if mode == "unavailable-hostkey":
        passed &= target.calls == []
    if mode in ("unavailable-password", "cancel"):
        passed &= "password" not in target.calls
    if mode in ("known", "interactive", "route", "interactive-route"):
        passed &= all(fixture.calls.count("password") == 1 for fixture in fixtures)
    if hop:
        passed &= hop.calls.count("direct-tcpip") == 1 and "direct-tcpip" not in target.calls
    return {"case": mode, "passed": bool(passed), "exit_code": result.returncode, "elapsed_ms": round((time.monotonic() - started) * 1000), "calls": calls, "no_session_channel_pty_shell_exec": no_session_channel, "peer_transports_closed": closed, "isolated_store_unchanged": before == after, "server_errors": errors, "output": output}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("dist/local-acceptance/20261018/v031-probe-loopback/report.json"))
    args = parser.parse_args()
    key = paramiko.RSAKey.generate(2048)
    with tempfile.TemporaryDirectory(prefix="zerowork-probe-loopback-") as temporary:
        cases = [run_case(args.runner, mode, Path(temporary), key) for mode in ("known", "unavailable-hostkey", "unavailable-password", "interactive", "cancel", "route", "interactive-route")]
    for case in cases:
        print(f"{case['case']}: {'PASS' if case['passed'] else 'FAIL'}")
    report = {"scope": "production Controller typed authentication/progress API, Job/Session/Route; 127.0.0.1 fixture only; no GUI; no PTY, shell, exec or startup", "interaction_limit": "interactive cases register an explicit test consumer; actual native probe challenge presentation is verified separately", "cases": cases, "passed": all(case["passed"] for case in cases)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
