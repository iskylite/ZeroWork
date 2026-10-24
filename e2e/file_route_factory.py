#!/usr/bin/env python3
"""RouteFactory -> real libssh2 Route -> read-only SFTP loopback acceptance.

Reuses the existing in-memory SFTP implementation. No GUI, AI, external host,
PTY, shell, exec, remote write, or user known_hosts is involved.
"""
import argparse
import base64
import hashlib
import json
import logging
from pathlib import Path
import select
import shutil
import socket
import subprocess
import threading
import time

import paramiko
from sftp_readonly import Files, State

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class Peer(paramiko.ServerInterface):
    def __init__(self, key, index=None, next_port=None, reject_password=False):
        self.key, self.index, self.next_port = key, index, next_port
        self.reject_password = reject_password
        self.state = State()
        self.calls, self.errors = [], []
        self.accepted = 0
        self.finished = threading.Event()
        self.peer_closed = threading.Event()
        self.transport = None
        self.channels = []
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.settimeout(0.1)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def get_allowed_auths(self, user):
        return "password"

    def check_auth_password(self, user, password):
        self.calls.append("password")
        expected_user = "target-user" if self.index is None else f"hop-user-{self.index}"
        expected_password = "target-secret" if self.index is None else f"hop-secret-{self.index}"
        if user != expected_user or password != expected_password:
            self.errors.append("FrozenCredentialMismatch")
            return paramiko.AUTH_FAILED
        return paramiko.AUTH_FAILED if self.reject_password else paramiko.AUTH_SUCCESSFUL

    def check_channel_request(self, kind, channel_id):
        self.calls.append(kind)
        return paramiko.OPEN_SUCCEEDED if self.index is None and kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_direct_tcpip_request(self, channel_id, origin, destination):
        self.calls.append({"direct-tcpip": list(destination)})
        return paramiko.OPEN_SUCCEEDED if self.next_port is not None and destination == ("127.0.0.1", self.next_port) else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_subsystem_request(self, channel, name):
        self.calls.append({"subsystem": name})
        return super().check_channel_subsystem_request(channel, name)

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
        relay = None
        channel = None
        try:
            connection = None
            while not self.finished.is_set() and connection is None:
                try:
                    connection, _ = self.listener.accept()
                except socket.timeout:
                    continue
            if connection is None:
                return
            self.accepted += 1
            self.transport = paramiko.Transport(connection)
            self.transport.add_server_key(self.key)
            if self.index is None:
                self.transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files)
            self.transport.start_server(server=self)
            while self.transport.is_active() and not self.finished.is_set():
                channel = self.transport.accept(0.01)
                if channel is None:
                    continue
                if self.index is None:
                    # The subsystem thread owns the accepted channel.
                    self.channels.append(channel)
                    continue
                relay = socket.create_connection(("127.0.0.1", self.next_port), timeout=3)
                while self.transport.is_active() and not self.finished.is_set():
                    readable, _, _ = select.select([channel, relay], [], [], 0.01)
                    ended = False
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            ended = True
                            break
                        (relay if source is channel else channel).sendall(data)
                    if ended:
                        break
                channel.close()
                channel = None
                relay.close()
                relay = None
            if not self.transport.is_active():
                self.peer_closed.set()
        except (EOFError, ConnectionResetError, BrokenPipeError, paramiko.SSHException):
            if not self.finished.is_set():
                self.peer_closed.set()
        except Exception as error:
            if not self.finished.is_set():
                self.errors.append(type(error).__name__ + ": " + str(error))
        finally:
            if channel:
                channel.close()
            if relay:
                relay.close()
            if self.transport:
                self.transport.close()

    def stop(self):
        self.finished.set()
        self.listener.close()
        if self.transport:
            self.transport.close()
        self.thread.join(2)


def run_case(binary, mode, directory, key, wrong_key):
    count = 2 if mode == "two-hop" else 1
    target = Peer(key, reject_password=mode == "auth-fail")
    route = []
    next_port = target.port
    for index in reversed(range(count)):
        hop = Peer(key, index=index, next_port=next_port)
        route.insert(0, hop)
        next_port = hop.port
    peers = route + [target]
    for peer in peers:
        peer.thread.start()
    folder = directory / mode
    folder.mkdir()
    store = folder / "known_hosts"
    if mode in ("known-route", "target-changed-nonstrict", "hop-changed-strict"):
        records = []
        for peer in peers:
            changed = (mode == "target-changed-nonstrict" and peer.index is None) or (mode == "hop-changed-strict" and peer.index == 0)
            stored = wrong_key if changed else key
            records.append(f"[127.0.0.1]:{peer.port} {stored.get_name()} {stored.get_base64()}\n")
        store.write_text("".join(records))
    before_store = store.read_bytes() if store.exists() else None
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    command = [str(binary), mode, str(store), fingerprint, str(target.port)] + [str(peer.port) for peer in route]
    started = time.monotonic()
    try:
        process = subprocess.run(command, capture_output=True, text=True, timeout=25)
        output = process.stdout + process.stderr
        for peer in peers:
            if peer.accepted:
                peer.peer_closed.wait(1)
        closed = all(not peer.accepted or peer.peer_closed.is_set() for peer in peers)
        snapshots = [{"role": f"hop-{peer.index}" if peer.index is not None else "target", "accepted_connections": peer.accepted,
                      "calls": peer.calls, "peer_closed_before_forced_cleanup": peer.peer_closed.is_set(), "errors": peer.errors,
                      "reads_opened": peer.state.opens, "reads_closed": peer.state.closes, "writes": peer.state.writes} for peer in peers]
    finally:
        for peer in peers:
            peer.stop()
    no_shell = all(not any(isinstance(call, str) and call.startswith("UNEXPECTED_") for call in peer.calls) for peer in peers)
    no_write = all(not peer.state.writes for peer in peers)
    no_errors = all(not peer.errors and not peer.state.errors for peer in peers)
    route_ok = all(peer.calls.count({"direct-tcpip": ["127.0.0.1", peer.next_port]}) == 1 and "session" not in peer.calls for peer in route)
    reads_closed = sorted(target.state.opens) == sorted(target.state.closes)
    workspace = mode == "workspace-blocked"
    if workspace:
        route_ok = all(peer.accepted == 0 and not peer.calls for peer in peers)
    elif mode == "hop-changed-strict":
        route_ok = route[0].accepted == 1 and not route[0].calls and target.accepted == 0
    else:
        route_ok &= all(peer.accepted == 1 for peer in peers)
    normal = mode in ("one-hop", "two-hop", "known-route", "target-changed-nonstrict")
    if normal:
        route_ok &= target.calls.count("session") == 1 and target.calls.count({"subsystem": "sftp"}) == 1 and len(target.state.opens) == 1
    else:
        route_ok &= "session" not in target.calls
    after_store = store.read_bytes() if store.exists() else None
    passed = process.returncode == 0 and output.count("PASS ") == 1 and closed and no_shell and no_write and no_errors and route_ok and reads_closed and before_store == after_store
    (folder / "runner.log").write_text(output)
    return {"case": mode, "passed": bool(passed), "exit_code": process.returncode, "elapsed_ms": round((time.monotonic() - started) * 1000),
            "actual_ordered_route": route_ok, "native_peer_transports_closed": closed, "no_pty_shell_exec": no_shell, "no_remote_write": no_write,
            "read_handles_closed": reads_closed, "known_hosts_unchanged": before_store == after_store, "peers": snapshots, "runner_output": output}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=Path("dist/ssh-acceptance/20261020/file-route-factory"))
    args = parser.parse_args()
    args.output_dir = args.output_dir.resolve()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    frozen_runner = args.output_dir / "file-route-factory-frozen"
    shutil.copy2(args.runner.resolve(), frozen_runner)
    key = paramiko.RSAKey.generate(2048)
    wrong_key = paramiko.RSAKey.generate(2048)
    cases = [run_case(frozen_runner, mode, args.output_dir, key, wrong_key) for mode in ("one-hop", "two-hop", "known-route", "target-changed-nonstrict", "hop-changed-strict", "cancel-auth", "auth-fail", "hostkey-reject", "workspace-blocked")]
    report = {"passed": all(case["passed"] for case in cases), "scope": "Production RouteFactory + original libssh2 Session/Route/relay + readonly.Service; controlled 127.0.0.1 only",
              "identity_limit": "Runner supplies a controlled original SessionHandle and real operation Journal; this does not claim main-app FileBindingHost factory integration or native auth UI acceptance.",
              "frozen_runner": str(frozen_runner), "runner_sha256": hashlib.sha256(frozen_runner.read_bytes()).hexdigest(), "cases": cases}
    (args.output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    for case in cases:
        print(case["case"], "PASS" if case["passed"] else "FAIL")
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
