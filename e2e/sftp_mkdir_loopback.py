#!/usr/bin/env python3
"""Gated in-memory SFTP directory peer for the production mkdir handler.

MKDIR mutates only this isolated Python dictionary. File writes, deletion,
rename, PTY, shell and exec are rejected and audited. Never connects to a VM.
"""
import argparse
import base64
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

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class State:
    def __init__(self, controls):
        self.controls = controls
        self.directories = {"/", "/existing"}
        self.created, self.calls, self.forbidden, self.errors = [], [], [], []
        self.race = False
        self.cancel_gate = False

    def attrs(self, path):
        if path not in self.directories:
            return paramiko.SFTP_NO_SUCH_FILE
        value = paramiko.SFTPAttributes()
        value.st_mode, value.st_size = stat.S_IFDIR | 0o755, 0
        value.st_mtime = value.st_atime = 1700000000
        return value


class Files(paramiko.SFTPServerInterface):
    def __init__(self, server, *args, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.state = server.state

    def canonicalize(self, path):
        return "/" if path == "." else path

    def stat(self, path):
        return self.state.attrs(path)

    lstat = stat

    def list_folder(self, path):
        if path not in self.state.directories:
            return paramiko.SFTP_NO_SUCH_FILE
        result = []
        for child in sorted(self.state.directories):
            if child == "/" or child.rsplit("/", 1)[0] != path.rstrip("/"):
                continue
            value = self.state.attrs(child)
            value.filename = child.rsplit("/", 1)[1]
            result.append(value)
        return result

    def mkdir(self, path, attrs):
        self.state.calls.append({"path": path, "mode": attrs.st_mode})
        if path == "/denied":
            return paramiko.SFTP_PERMISSION_DENIED
        if path == "/race":
            self.state.directories.add(path)
            self.state.race = True
            return paramiko.SFTP_FAILURE  # v3 generic conflict, must re-stat
        if path == "/created-after-cancel":
            (self.state.controls / "mkdir-entered").write_text("ready\n")
            deadline = time.monotonic() + 8
            while not (self.state.controls / "mkdir-release").exists():
                if time.monotonic() >= deadline:
                    self.state.errors.append("MKDIR gate timed out")
                    return paramiko.SFTP_FAILURE
                time.sleep(0.002)
            self.state.cancel_gate = True
        if path in self.state.directories:
            return 11  # SSH_FX_FILE_ALREADY_EXISTS
        self.state.directories.add(path)
        self.state.created.append(path)
        return paramiko.SFTP_OK

    def deny(self, operation):
        self.state.forbidden.append(operation)
        return paramiko.SFTP_PERMISSION_DENIED

    def open(self, path, flags, attrs):
        return self.deny("file_open")

    def remove(self, path):
        return self.deny("remove")

    def rename(self, old, new):
        return self.deny("rename")

    def rmdir(self, path):
        return self.deny("rmdir")


class Server(paramiko.ServerInterface):
    def __init__(self, state):
        self.state = state

    def check_auth_password(self, user, password):
        return paramiko.AUTH_SUCCESSFUL if (user, password) == ("fixture", "mkdir-fixture") else paramiko.AUTH_FAILED

    def get_allowed_auths(self, user):
        return "password"

    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_shell_request(self, channel):
        self.state.forbidden.append("shell")
        return False

    def check_channel_exec_request(self, channel, command):
        self.state.forbidden.append("exec")
        return False

    def check_channel_pty_request(self, *args):
        self.state.forbidden.append("pty")
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    controls = args.output_dir.resolve() / "controls"
    controls.mkdir(exist_ok=True)
    if any(controls.iterdir()):
        parser.error("use a fresh output directory")
    state = State(controls)
    key = paramiko.RSAKey.generate(2048)
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(8)
    transports, channels = [], []

    def serve():
        try:
            connection, _ = listener.accept()
            transport = paramiko.Transport(connection)
            transports.append(transport)
            transport.add_server_key(key)
            transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files)
            transport.start_server(server=Server(state))
            while transport.is_active():
                channel = transport.accept(0.01)
                if channel is not None:
                    channels.append(channel)
        except (EOFError, ConnectionResetError, BrokenPipeError):
            pass
        except Exception as exc:
            state.errors.append(type(exc).__name__ + ": " + str(exc))

    server = threading.Thread(target=serve, daemon=True)
    server.start()
    environment = os.environ.copy()
    environment.update({"ZEROWORK_MKDIR_PORT": str(listener.getsockname()[1]), "ZEROWORK_MKDIR_FINGERPRINT": fingerprint, "ZEROWORK_MKDIR_CONTROLS": str(controls)})
    result = subprocess.run([str(args.runner.resolve())], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=environment, timeout=35)
    deadline = time.monotonic() + 2
    while any(transport.is_active() for transport in transports) and time.monotonic() < deadline:
        time.sleep(0.01)
    released = bool(transports) and all(not transport.is_active() for transport in transports)
    listener.close()
    for transport in transports:
        transport.close()
    server.join(2)
    native = [json.loads(line.split("MKDIR_NATIVE ", 1)[1]) for line in result.stdout.splitlines() if "MKDIR_NATIVE " in line]
    expected = {"/created-from-native", "/created-after-cancel"}
    report = {
        "passed": result.returncode == 0 and len(native) == 1 and native[0].get("passed") and set(state.created) == expected and state.cancel_gate and state.race and released and not state.errors and not state.forbidden,
        "scope": "actual libssh2 + FileBindingHost + FileWorkspaceController, controlled SessionHost adapter, isolated in-memory loopback peer",
        "runner_sha256": hashlib.sha256(args.runner.read_bytes()).hexdigest(), "exit_code": result.returncode,
        "native": native, "mkdir_requests": state.calls, "created": state.created,
        "generic_failure_race_rechecked": state.race, "cancelled_inflight_mkdir_actual_success_preserved": state.cancel_gate,
        "connection_closed_before_peer_cleanup": released, "forbidden_operations": state.forbidden, "errors": state.errors,
    }
    (args.output_dir / "native.log").write_text(result.stdout)
    (args.output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(result.stdout, end="")
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
