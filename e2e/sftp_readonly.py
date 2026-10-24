#!/usr/bin/env python3
"""Actual production SFTP service against a read-only in-memory loopback peer.

No local/remote file is created by SFTP. The READ reply for /cancel is held
until the production mailbox has accepted cancellation of that exact key.
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
TEXT = b'NAME="Loopback read only"\nID=fixture\n' * 4


class State:
    def __init__(self):
        self.read_entered = threading.Event()
        self.read_release = threading.Event()
        self.cancel_accepted = threading.Event()
        self.opens = []
        self.closes = []
        self.writes = []
        self.shells = 0
        self.execs = 0
        self.changed = False
        self.errors = []


def attributes(path, state):
    if path == "/denied":
        return paramiko.SFTP_PERMISSION_DENIED
    if path == "/missing":
        return paramiko.SFTP_NO_SUCH_FILE
    value = paramiko.SFTPAttributes()
    value.st_mode = stat.S_IFDIR | 0o755 if path in ("/", "/many", "/root") else stat.S_IFREG | 0o644
    if path == "/device":
        value.st_mode = stat.S_IFCHR | 0o600
    value.st_size = len(data(path))
    value.st_mtime = 2 if path == "/change" and state.changed else 1
    value.st_atime = 1
    return value


def data(path):
    return {"/binary": b"hello\0tail", "/invalid": b"bad\xff", "/broken": b"end\xe4\xbd", "/utf8": "你好".encode(), "/empty": b""}.get(path, TEXT)


class Handle(paramiko.SFTPHandle):
    def __init__(self, path, state):
        super().__init__(os.O_RDONLY)
        self.path = path
        self.state = state

    def read(self, offset, length):
        if self.path == "/cancel":
            self.state.read_entered.set()
            if not self.state.read_release.wait(5):
                self.state.errors.append("READ gate not released")
                return paramiko.SFTP_FAILURE
        if self.path == "/change":
            self.state.changed = True
        return data(self.path)[offset:offset + length]

    def stat(self):
        return attributes(self.path, self.state)

    def close(self):
        self.state.closes.append(self.path)
        return paramiko.SFTP_OK


class Files(paramiko.SFTPServerInterface):
    def __init__(self, server, *args, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.state = server.state

    def canonicalize(self, path):
        return "/root" if path == "." else path

    def stat(self, path):
        return attributes(path, self.state)

    lstat = stat

    def list_folder(self, path):
        result = []
        for index in range(21 if path == "/" else 5):
            item = attributes("/entry", self.state)
            item.filename = f"entry {index:02}"
            if index == 3:
                item.st_mode = stat.S_IFLNK | 0o777
            result.append(item)
        return result

    def open(self, path, flags, attrs):
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
            self.state.writes.append(path)
            return paramiko.SFTP_PERMISSION_DENIED
        self.state.opens.append(path)
        return Handle(path, self.state)

    def remove(self, path):
        self.state.writes.append(path)
        return paramiko.SFTP_PERMISSION_DENIED

    def mkdir(self, path, attrs):
        self.state.writes.append(path)
        return paramiko.SFTP_PERMISSION_DENIED


class Server(paramiko.ServerInterface):
    def __init__(self, state):
        self.state = state

    def check_auth_password(self, user, password):
        return paramiko.AUTH_SUCCESSFUL

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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=Path("dist/ssh-acceptance/20261020/sftp-readonly"))
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    state = State()
    key = paramiko.RSAKey.generate(2048)
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(8)
    port = listener.getsockname()[1]
    transports = []
    channels = []

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
    environment["ZEROWORK_VM_PASSWORD"] = "fixture-password"
    environment["ZEROWORK_SFTP_FINGERPRINT"] = fingerprint
    process = subprocess.Popen([str(args.runner), "127.0.0.1", str(port), "fixture"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=environment)
    output = []

    def consume():
        for line in process.stdout:
            output.append(line)
            if "CANCEL_ACCEPTED_WHILE_READ_BLOCKED" in line:
                state.cancel_accepted.set()

    reader = threading.Thread(target=consume, daemon=True)
    reader.start()
    gate_ok = state.read_entered.wait(8)
    if gate_ok:
        process.stdin.write("C")
        process.stdin.flush()
        gate_ok = state.cancel_accepted.wait(2)
    state.read_release.set()
    try:
        code = process.wait(timeout=12)
    except subprocess.TimeoutExpired:
        process.kill()
        code = process.wait()
    reader.join(2)
    for transport in transports:
        transport.close()
    listener.close()
    server.join(2)
    text = "".join(output)
    (args.output_dir / "loopback.log").write_text(text)
    report = {
        "passed": code == 0 and gate_ok and "PASS fixture_errors=true" in text and not state.errors and not state.writes and state.shells == 0 and state.execs == 0 and sorted(state.opens) == sorted(state.closes),
        "exit_code": code, "real_blocked_read_cancel_gate": gate_ok,
        "reads_opened": state.opens, "reads_closed": state.closes,
        "write_operations": state.writes, "shell_requests": state.shells, "exec_requests": state.execs,
        "same_file_open_close_multiset": sorted(state.opens) == sorted(state.closes),
        "errors": state.errors,
    }
    (args.output_dir / "loopback-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(text, end="")
    print(json.dumps(report))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
