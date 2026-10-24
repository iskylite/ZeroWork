#!/usr/bin/env python3
"""Actual libssh2 pause/resume against a gated, read-only Paramiko peer.

The only writes are fixture control markers and the native runner's owned local
downloads. Source changes are in-memory test controls, never SFTP write requests.
"""
import argparse
import base64
from collections import Counter
import hashlib
import json
import logging
import os
from pathlib import Path
import socket
import stat
import subprocess
import threading
import time

import paramiko
from paramiko.sftp import CMD_OPEN, CMD_WRITE, SFTP_FLAG_CREATE, SFTP_FLAG_TRUNC, SFTP_FLAG_WRITE

logging.getLogger("paramiko").setLevel(logging.CRITICAL)
SOURCE = bytes(33 + index % 89 for index in range(8 * 32768 + 17))
CASES = ("unchanged", "mtime", "prefix")


class State:
    def __init__(self, controls):
        self.controls = controls
        self.lock = threading.Lock()
        self.payloads = {"/" + name: SOURCE for name in CASES}
        self.mtimes = {path: 1700000000 for path in self.payloads}
        self.opens = []
        self.closes = []
        self.wire_opens = []
        self.reads = []
        self.gates = {}
        self.mutations = {}
        self.write_requests = []
        self.shells = self.execs = self.ptys = 0
        self.errors = []

    def marker(self, name, suffix):
        return self.controls / f"{name}.{suffix}"

    def apply_mutations(self):
        with self.lock:
            for name in ("mtime", "prefix"):
                if name in self.mutations or not self.marker(name, "mutate").exists():
                    continue
                path = "/" + name
                if name == "mtime":
                    self.mtimes[path] += 1
                else:
                    changed = bytearray(self.payloads[path])
                    changed[17] ^= 1
                    self.payloads[path] = bytes(changed)
                self.mutations[name] = {
                    "size": len(self.payloads[path]),
                    "mtime": self.mtimes[path],
                    "sha256": hashlib.sha256(self.payloads[path]).hexdigest(),
                }
                self.marker(name, "mutated").write_text("ready\n")

    def attributes(self, path):
        if path == "/":
            value = paramiko.SFTPAttributes()
            value.st_mode, value.st_size, value.st_mtime, value.st_atime = stat.S_IFDIR | 0o555, 0, 1700000000, 1700000000
            return value
        with self.lock:
            if path not in self.payloads:
                return paramiko.SFTP_NO_SUCH_FILE
            value = paramiko.SFTPAttributes()
            value.st_mode = stat.S_IFREG | 0o444
            value.st_size = len(self.payloads[path])
            value.st_mtime = value.st_atime = self.mtimes[path]
            return value


class Handle(paramiko.SFTPHandle):
    def __init__(self, state, path, ordinal):
        super().__init__(os.O_RDONLY)
        self.state, self.path, self.ordinal = state, path, ordinal
        self.closed_once = False

    def read(self, offset, length):
        name = self.path.lstrip("/")
        self.state.reads.append({"path": self.path, "open": self.ordinal, "offset": offset, "length": length})
        # libssh2 prefetches up to four 32KiB buffers (rounded to 30KiB
        # packets). Hold a later request, after an earlier native read must
        # have returned, so pause deterministically retains nonempty data.
        if self.ordinal == 2 and offset >= 6 * 32768 and name not in self.state.gates:
            gate = {"offset": offset, "length": length, "pause_seen_before_release": False, "released": False}
            self.state.gates[name] = gate
            self.state.marker(name, "read-entered").write_text("ready\n")
            deadline = time.monotonic() + 12
            while not self.state.marker(name, "release").exists():
                if time.monotonic() >= deadline:
                    self.state.errors.append(f"{name}: native READ gate timed out")
                    return paramiko.SFTP_FAILURE
                time.sleep(0.002)
            gate["pause_seen_before_release"] = self.state.marker(name, "pause-requested").exists()
            gate["released"] = True
        with self.state.lock:
            return self.state.payloads[self.path][offset:offset + length]

    def stat(self):
        return self.state.attributes(self.path)

    def write(self, offset, data):
        self.state.write_requests.append({"operation": "write", "path": self.path, "offset": offset, "bytes": len(data)})
        return paramiko.SFTP_PERMISSION_DENIED

    def close(self):
        if not self.closed_once:
            self.state.closes.append({"path": self.path, "open": self.ordinal})
            self.closed_once = True
        return paramiko.SFTP_OK


class Files(paramiko.SFTPServerInterface):
    def __init__(self, server, *args, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.state = server.state

    def canonicalize(self, path):
        return "/" if path == "." else path

    def stat(self, path):
        return self.state.attributes(path)

    lstat = stat

    def list_folder(self, path):
        if path != "/":
            return paramiko.SFTP_NO_SUCH_FILE
        items = []
        for name in CASES:
            item = self.state.attributes("/" + name)
            item.filename = name
            items.append(item)
        return items

    def open(self, path, flags, attrs):
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
            # The explicit missing append probe is allowed to ask, never to
            # create a handle/file. Any CREATE/TRUNCATE is a test failure.
            return paramiko.SFTP_PERMISSION_DENIED
        if path not in self.state.payloads:
            return paramiko.SFTP_NO_SUCH_FILE
        ordinal = 1 + sum(item["path"] == path for item in self.state.opens)
        self.state.opens.append({"path": path, "open": ordinal})
        return Handle(self.state, path, ordinal)

    def reject(self, operation, *args):
        self.state.write_requests.append({"operation": operation})
        return paramiko.SFTP_PERMISSION_DENIED

    def remove(self, path):
        return self.reject("remove", path)

    def rename(self, oldpath, newpath):
        return self.reject("rename", oldpath, newpath)

    def mkdir(self, path, attrs):
        return self.reject("mkdir", path)

    def rmdir(self, path):
        return self.reject("rmdir", path)

    def chattr(self, path, attr):
        return self.reject("setstat", path)

    def symlink(self, target_path, path):
        return self.reject("symlink", path)


class AuditedSFTPServer(paramiko.SFTPServer):
    def _process(self, kind, request_number, message):
        if kind == CMD_OPEN:
            copy = paramiko.Message(message.get_remainder())
            self.server.state.wire_opens.append({"path": copy.get_text(), "flags": copy.get_int()})
        elif kind == CMD_WRITE:
            self.server.state.write_requests.append({"operation": "wire_write"})
        return super()._process(kind, request_number, message)


class Server(paramiko.ServerInterface):
    def __init__(self, state):
        self.state = state

    def check_auth_password(self, user, password):
        return paramiko.AUTH_SUCCESSFUL if (user, password) == ("fixture", "resume-fixture") else paramiko.AUTH_FAILED

    def get_allowed_auths(self, user):
        return "password"

    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_shell_request(self, channel):
        self.state.shells += 1
        return False

    def check_channel_exec_request(self, channel, command):
        self.state.execs += 1
        return False

    def check_channel_pty_request(self, *args):
        self.state.ptys += 1
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True, help="compiled Zig test binary filtered to sftp resume native loopback")
    parser.add_argument("--output-dir", type=Path, default=Path("dist/ssh-acceptance/20261021/sftp-resume-native"))
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    controls = args.output_dir.resolve() / "controls"
    controls.mkdir(exist_ok=True)
    if any(controls.iterdir()):
        parser.error("control directory must be empty; use a fresh output directory")
    state = State(controls)
    key = paramiko.RSAKey.generate(2048)
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(4)
    listener.settimeout(0.05)
    transports, channels, workers = [], [], []
    stopping = threading.Event()

    def serve_connection(connection):
        transport = paramiko.Transport(connection)
        transports.append(transport)
        try:
            transport.add_server_key(key)
            transport.set_subsystem_handler("sftp", AuditedSFTPServer, Files)
            transport.start_server(server=Server(state))
            while transport.is_active() and not stopping.is_set():
                channel = transport.accept(0.01)
                if channel is not None:
                    channels.append(channel)
        except (EOFError, ConnectionResetError, BrokenPipeError):
            pass
        except Exception as exc:
            state.errors.append(type(exc).__name__ + ": " + str(exc))

    def serve():
        while not stopping.is_set():
            state.apply_mutations()
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            worker = threading.Thread(target=serve_connection, args=(connection,), daemon=True)
            workers.append(worker)
            worker.start()

    server = threading.Thread(target=serve, daemon=True)
    server.start()
    environment = os.environ.copy()
    environment.update({"ZEROWORK_SFTP_RESUME_PORT": str(listener.getsockname()[1]), "ZEROWORK_SFTP_RESUME_FINGERPRINT": fingerprint, "ZEROWORK_SFTP_RESUME_CONTROL_DIR": str(controls)})
    try:
        result = subprocess.run([str(args.runner.resolve())], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=environment, timeout=85)
        code, output = result.returncode, result.stdout
    except subprocess.TimeoutExpired as exc:
        code, output = -1, (exc.stdout or b"").decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        state.errors.append("native runner timed out")
    deadline = time.monotonic() + 2
    while any(transport.is_active() for transport in transports) and time.monotonic() < deadline:
        time.sleep(0.01)
    released_before_peer_cleanup = bool(transports) and all(not transport.is_active() for transport in transports)
    stopping.set()
    listener.close()
    for transport in transports:
        transport.close()
    server.join(2)
    for worker in workers:
        worker.join(2)
    cases = []
    for line in output.splitlines():
        if "RESUME_NATIVE " in line:
            cases.append(json.loads(line.split("RESUME_NATIVE ", 1)[1]))
    append_opens = [item for item in state.wire_opens if item["path"] == "/missing-append-probe"]
    append_safe = len(append_opens) == 1 and append_opens[0]["flags"] == SFTP_FLAG_WRITE and not (append_opens[0]["flags"] & (SFTP_FLAG_CREATE | SFTP_FLAG_TRUNC))
    readonly_opens = all(item["flags"] == 1 for item in state.wire_opens if item["path"] != "/missing-append-probe")
    closed = Counter((item["path"], item["open"]) for item in state.opens) == Counter((item["path"], item["open"]) for item in state.closes)
    gates_pass = set(state.gates) == set(CASES) and all(gate["released"] and gate["pause_seen_before_release"] for gate in state.gates.values())
    cases_pass = {item["case"] for item in cases if item.get("passed")} == set(CASES) | {"append_zero_missing"}
    mutations_pass = set(state.mutations) == {"mtime", "prefix"} and state.mutations["mtime"]["mtime"] == 1700000001 and state.mutations["prefix"]["mtime"] == 1700000000
    created_paths = sorted(set(state.payloads) - {"/" + name for name in CASES})
    report = {
        "passed": code == 0 and cases_pass and gates_pass and mutations_pass and append_safe and readonly_opens and closed and released_before_peer_cleanup and not state.errors and not state.write_requests and state.shells == state.execs == state.ptys == 0,
        "transport": "actual production libssh2 + in-memory Paramiko loopback; no UI or provider involved",
        "exit_code": code, "runner_sha256": hashlib.sha256(args.runner.read_bytes()).hexdigest(),
        "fingerprint": fingerprint, "source_bytes": len(SOURCE), "source_sha256": hashlib.sha256(SOURCE).hexdigest(),
        "cases": cases, "gates": state.gates, "mutations": state.mutations,
        "wire_opens": state.wire_opens, "opens": state.opens, "closes": state.closes,
        "all_accepted_handles_closed": closed, "all_download_opens_readonly": readonly_opens,
        "append_zero_missing_probe": {"passed": append_safe, "wire_opens": append_opens, "created_files": len(created_paths), "created_paths": created_paths, "write_data_requests": len(state.write_requests)},
        "read_requests": state.reads, "write_requests": state.write_requests,
        "shell_requests": state.shells, "exec_requests": state.execs, "pty_requests": state.ptys,
        "connections": len(transports), "connections_closed_before_peer_cleanup": released_before_peer_cleanup, "errors": state.errors,
    }
    (args.output_dir / "native.log").write_text(output)
    (args.output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(output, end="")
    print(json.dumps({key: value for key, value in report.items() if key not in ("read_requests", "wire_opens", "opens", "closes")}, indent=2))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
