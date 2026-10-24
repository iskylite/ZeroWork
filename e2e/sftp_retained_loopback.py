#!/usr/bin/env python3
"""Drive the real main app against one bounded, read-only SFTP peer.

The native runner owns its app/config/RPC/local download. This peer owns only
an immutable byte string, a loopback listener and evidence/control files. No VM
or user remote host is contacted. --prepare-only checks preparation without
starting either a listener or a native application.
"""
import argparse
import base64
from collections import Counter
import hashlib
import json
import logging
import os
from pathlib import Path
import posixpath
import shutil
import signal
import socket
import stat
import subprocess
import threading
import time

import paramiko
from paramiko.sftp import CMD_OPEN, CMD_WRITE

logging.getLogger("paramiko").setLevel(logging.CRITICAL)
SOURCE = bytes(33 + index % 89 for index in range(2 * 1024 * 1024 + 17))
SOURCE_PATH = "/retained-fixture.bin"


class State:
    def __init__(self, output):
        self.output = output
        self.controls = output / "controls"
        self.controls.mkdir()
        self.lock = threading.RLock()
        self.connections, self.opens, self.closes, self.reads = [], [], [], []
        self.wire_opens, self.calls, self.forbidden, self.errors = [], [], [], []
        self.gate = None
        self.stopping = threading.Event()

    def marker(self, name):
        return self.controls / name

    def record(self, collection, **values):
        with self.lock:
            collection.append({"at_ns": time.time_ns(), **values})

    def snapshot(self):
        with self.lock:
            return json.loads(json.dumps({
                "connections": self.connections, "opens": self.opens,
                "closes": self.closes, "reads": self.reads,
                "wire_opens": self.wire_opens, "calls": self.calls,
                "forbidden": self.forbidden, "errors": self.errors,
                "gate": self.gate,
            }))

    def publish(self):
        target = self.output / "peer-state.json"
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.snapshot(), indent=2) + "\n")
        temporary.replace(target)

    def attributes(self, path):
        if path not in ("/", SOURCE_PATH):
            return paramiko.SFTP_NO_SUCH_FILE
        value = paramiko.SFTPAttributes()
        value.st_mode = (stat.S_IFDIR | 0o555) if path == "/" else (stat.S_IFREG | 0o444)
        value.st_size = 0 if path == "/" else len(SOURCE)
        value.st_mtime = value.st_atime = 1700000000
        return value


class Handle(paramiko.SFTPHandle):
    def __init__(self, peer, ordinal):
        super().__init__(os.O_RDONLY)
        self.peer, self.ordinal, self.closed_once = peer, ordinal, False

    def read(self, offset, length):
        state = self.peer.state
        state.record(state.reads, connection=self.peer.identity, open=self.ordinal,
                     path=SOURCE_PATH, offset=offset, length=length)
        # First OPEN hashes the complete source. Second OPEN transfers it.
        # libssh2 prefetches several packets; gate a later READ after actual
        # 32 KiB writes can have reached Manager and the local owned .part.
        with state.lock:
            should_gate = self.ordinal == 2 and offset >= 6 * 32768 and state.gate is None
            if should_gate:
                state.gate = {"connection": self.peer.identity, "open": self.ordinal,
                              "offset": offset, "length": length,
                              "entered_at_ns": time.time_ns(), "released": False}
        if should_gate:
            state.marker("read-entered").write_text("ready\n")
            deadline = time.monotonic() + 50
            while not state.marker("read-release").exists() and not state.stopping.is_set():
                if time.monotonic() >= deadline:
                    state.record(state.errors, reason="Bounded original READ gate timed out")
                    return paramiko.SFTP_FAILURE
                time.sleep(0.005)
            with state.lock:
                state.gate.update({
                    "released": True, "released_at_ns": time.time_ns(),
                    "pause_requested_before_release": state.marker("pause-requested").exists(),
                    "pausing_visible_before_release": state.marker("pausing-visible").exists(),
                    "failure_cleanup_release": state.marker("failure-cleanup").exists(),
                })
        return SOURCE[offset:offset + length]

    def stat(self):
        return self.peer.state.attributes(SOURCE_PATH)

    def close(self):
        if not self.closed_once:
            self.peer.state.record(self.peer.state.closes, connection=self.peer.identity,
                                   open=self.ordinal, path=SOURCE_PATH)
            self.closed_once = True
        return paramiko.SFTP_OK

    def write(self, offset, data):
        return self.peer.deny("WRITE")

    def chattr(self, attr):
        return self.peer.deny("FSETSTAT")


class Files(paramiko.SFTPServerInterface):
    def __init__(self, server, *args, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.peer = server

    def canonicalize(self, path):
        self.peer.state.record(self.peer.state.calls, connection=self.peer.identity,
                               operation="REALPATH", path=path)
        return "/" if path in ("", ".", "~") else posixpath.normpath("/" + path.lstrip("/"))

    def stat(self, path):
        self.peer.state.record(self.peer.state.calls, connection=self.peer.identity,
                               operation="STAT", path=path)
        return self.peer.state.attributes(path)

    lstat = stat

    def list_folder(self, path):
        self.peer.state.record(self.peer.state.calls, connection=self.peer.identity,
                               operation="LIST", path=path)
        if path != "/":
            return paramiko.SFTP_NO_SUCH_FILE
        item = self.peer.state.attributes(SOURCE_PATH)
        item.filename = SOURCE_PATH.lstrip("/")
        return [item]

    def open(self, path, flags, attrs):
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
            return self.peer.deny("writable OPEN")
        if path != SOURCE_PATH:
            return paramiko.SFTP_NO_SUCH_FILE
        state = self.peer.state
        with state.lock:
            ordinal = len(state.opens) + 1
            state.record(state.opens, connection=self.peer.identity, open=ordinal, path=path)
        return Handle(self.peer, ordinal)

    def remove(self, path):
        return self.peer.deny("REMOVE")

    def rename(self, old, new):
        return self.peer.deny("RENAME")

    def posix_rename(self, old, new):
        return self.peer.deny("POSIX_RENAME")

    def mkdir(self, path, attrs):
        return self.peer.deny("MKDIR")

    def rmdir(self, path):
        return self.peer.deny("RMDIR")

    def chattr(self, path, attr):
        return self.peer.deny("SETSTAT")

    def symlink(self, target, path):
        return self.peer.deny("SYMLINK")


class AuditedSFTP(paramiko.SFTPServer):
    def _process(self, kind, request_number, message):
        if kind == CMD_OPEN:
            copy = paramiko.Message(message.get_remainder())
            self.server.peer.state.record(self.server.peer.state.wire_opens,
                                     connection=self.server.peer.identity,
                                     path=copy.get_text(), flags=copy.get_int())
        elif kind == CMD_WRITE:
            self.server.peer.deny("wire WRITE")
        return super()._process(kind, request_number, message)


class Peer(paramiko.ServerInterface):
    def __init__(self, state, identity):
        self.state, self.identity = state, identity

    def deny(self, operation):
        self.state.record(self.state.forbidden, connection=self.identity, operation=operation)
        return paramiko.SFTP_PERMISSION_DENIED

    def check_auth_password(self, user, password):
        accepted = (user, password) == ("fixture", "retained-fixture")
        self.state.record(self.state.calls, connection=self.identity,
                          operation="PASSWORD_AUTH", user=user, accepted=accepted)
        if accepted:
            with self.state.lock:
                self.state.connections[self.identity - 1]["authenticated_at_ns"] = time.time_ns()
        return paramiko.AUTH_SUCCESSFUL if accepted else paramiko.AUTH_FAILED

    def get_allowed_auths(self, user):
        return "password"

    def check_channel_request(self, kind, channel_id):
        self.state.record(self.state.calls, connection=self.identity, operation="CHANNEL", kind=kind)
        if kind != "session":
            self.deny("non-session channel " + kind)
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        return paramiko.OPEN_SUCCEEDED

    def check_channel_subsystem_request(self, channel, name):
        self.state.record(self.state.calls, connection=self.identity, operation="SUBSYSTEM", name=name)
        if name != "sftp":
            self.deny("non-SFTP subsystem " + name)
            return False
        return super().check_channel_subsystem_request(channel, name)

    def check_channel_shell_request(self, channel):
        self.deny("SHELL")
        return False

    def check_channel_exec_request(self, channel, command):
        self.deny("EXEC")
        return False

    def check_channel_pty_request(self, *args):
        self.deny("PTY")
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--expected-sha")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--node", default=shutil.which("node") or "/usr/local/bin/node")
    parser.add_argument("--prepare-only", choices=("1",))
    args = parser.parse_args()
    if not args.prepare_only and (not args.binary or not args.expected_sha):
        parser.error("native run requires --binary and --expected-sha")
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("use a fresh, empty --out directory; failed evidence is retained")
    state = State(output)
    key = paramiko.RSAKey.generate(2048)
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    listener = None
    port = 1
    if not args.prepare_only:
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(8)
        listener.settimeout(0.025)
        port = listener.getsockname()[1]
    metadata = {"host": "127.0.0.1", "port": port, "user": "fixture",
                "password": "retained-fixture", "fingerprint": fingerprint,
                "source": SOURCE_PATH, "source_size": len(SOURCE),
                "source_sha256": hashlib.sha256(SOURCE).hexdigest(),
                "source_md5": hashlib.md5(SOURCE).hexdigest(),
                "controls": str(state.controls), "state": str(output / "peer-state.json")}
    (output / "peer.json").write_text(json.dumps(metadata, indent=2) + "\n")
    transports, workers = [], []

    def serve_connection(connection, identity):
        transport = paramiko.Transport(connection)
        channels = []
        with state.lock:
            transports.append(transport)
        try:
            transport.add_server_key(key)
            transport.set_subsystem_handler("sftp", AuditedSFTP, Files)
            transport.start_server(server=Peer(state, identity))
            while transport.is_active() and not state.stopping.is_set():
                channel = transport.accept(0.01)
                if channel is not None:
                    channels.append(channel)
        except (EOFError, ConnectionResetError, BrokenPipeError):
            pass
        except Exception as exc:
            state.record(state.errors, connection=identity, reason=type(exc).__name__ + ": " + str(exc))
        finally:
            with state.lock:
                state.connections[identity - 1].update({
                    "closed_at_ns": time.time_ns(),
                    "client_closed_before_peer_cleanup": not state.stopping.is_set() and not transport.is_active(),
                })
            transport.close()

    def serve():
        while not state.stopping.is_set():
            try:
                state.publish()
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with state.lock:
                identity = len(state.connections) + 1
                state.connections.append({"id": identity, "accepted_at_ns": time.time_ns()})
            worker = threading.Thread(target=serve_connection, args=(connection, identity), daemon=True)
            workers.append(worker)
            worker.start()

    server = None
    state.publish()
    if listener:
        server = threading.Thread(target=serve, daemon=True)
        server.start()
    command = [args.node, str(Path(__file__).with_name("sftp_retained_native.ts").resolve()),
               "--peer", str(output / "peer.json"), "--out", str(output / "app")]
    if args.prepare_only:
        command += ["--prepare-only", "1"]
    else:
        command += ["--binary", str(args.binary.resolve()), "--expected-sha", args.expected_sha]
    code, log, process = -1, "", None
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True,
                                   cwd=Path(__file__).resolve().parent.parent)
        log, _ = process.communicate(timeout=210)
        code = process.returncode
    except subprocess.TimeoutExpired as exc:
        log = exc.stdout.decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        state.record(state.errors, reason="Bounded main-app runner timed out")
        # This new process group belongs only to this runner and its app.
        # Killing merely Node would strand its native child on timeout.
        os.killpg(process.pid, signal.SIGTERM)
        try:
            tail, _ = process.communicate(timeout=3)
            log = tail
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            log, _ = process.communicate()
    finally:
        # Every failure releases its own in-flight READ and transports. A
        # cleanup release never counts as paused/released or normal close.
        state.marker("read-release").write_text("finally release\n")
        state.stopping.set()
        if listener:
            listener.close()
        for transport in transports:
            transport.close()
        if server:
            server.join(2)
        for worker in workers:
            worker.join(2)
        state.publish()
    (output / "runner.log").write_text(log)
    app_report_path = output / "app" / "report.json"
    app = json.loads(app_report_path.read_text()) if app_report_path.exists() else {}
    snapshot = state.snapshot()
    opens = Counter((item["connection"], item["open"]) for item in snapshot["opens"])
    closes = Counter((item["connection"], item["open"]) for item in snapshot["closes"])
    original_ids = app.get("closed_original", {}).get("peer_connection_ids", [])
    resume_ids = app.get("resumed", {}).get("peer_connection_ids", [])
    connections = {item["id"]: item for item in snapshot["connections"]}
    original_released = bool(original_ids) and all(connections[item].get("client_closed_before_peer_cleanup") for item in original_ids)
    resumed_released = bool(resume_ids) and all(connections[item].get("client_closed_before_peer_cleanup") for item in resume_ids)
    distinct_resume = bool(resume_ids) and not set(original_ids).intersection(resume_ids)
    gate_ok = bool(snapshot["gate"] and snapshot["gate"].get("released") and
                   snapshot["gate"].get("pause_requested_before_release") and
                   snapshot["gate"].get("pausing_visible_before_release") and
                   not snapshot["gate"].get("failure_cleanup_release"))
    readonly = all(item["flags"] == 1 for item in snapshot["wire_opens"])
    prepared = bool(args.prepare_only and code == 0 and app.get("status") == "prepared_not_run")
    passed = (not args.prepare_only and code == 0 and app.get("status") == "passed" and
              gate_ok and readonly and opens == closes and original_released and
              resumed_released and distinct_resume and not snapshot["forbidden"] and not snapshot["errors"])
    report = {"status": "prepared_not_run" if prepared else "passed" if passed else "failed",
              "visual_status": "not_run" if prepared else "needs_review",
              "scope": "actual native main app + actual libssh2 + bounded read-only in-memory loopback; synthetic Harness input",
              "binary_sha256": app.get("binary_sha256"), "runner_exit_code": code,
              "app_report": str(app_report_path), "peer": metadata,
              "gate_pause_receipt_verified": gate_ok, "readonly_open_flags": readonly,
              "every_open_has_exact_close": opens == closes,
              "original_connections_released_before_peer_cleanup": original_released,
              "resumed_connections_released_before_peer_cleanup": resumed_released,
              "new_authenticated_connections_distinct_from_original": distinct_resume,
              "snapshot": snapshot, "native_started": not bool(args.prepare_only)}
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(log, end="")
    print(report["status"] + ": " + str(output / "report.json"))
    raise SystemExit(0 if prepared or passed else 1)


if __name__ == "__main__":
    main()
