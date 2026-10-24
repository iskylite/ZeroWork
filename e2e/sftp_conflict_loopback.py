#!/usr/bin/env python3
"""Read-only loopback SFTP peer for the real application's download conflict UI.

Reuses the existing read-only peer's protocol classes. Remote bytes are an
immutable in-memory fixture; only the native runner's private local destination
is overwritten. This process never opens a shell, PTY, exec or external host.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import posixpath
import signal
import socket
import stat
import threading
import time

import paramiko
from sftp_readonly import Files as ReadOnlyFiles, Handle as ReadOnlyHandle, Server as ReadOnlyServer, State as ReadOnlyState

PAYLOAD = b"ZEROWORK_LOOPBACK_CONFLICT_SOURCE_V1\n" + bytes(range(256)) * 257
REMOTE = "/fixture/release.txt"
USER, PASSWORD = "fixture", "conflict-fixture"


class State(ReadOnlyState):
    def __init__(self, output):
        super().__init__()
        self.output = output
        self.lock = threading.RLock()
        self.calls, self.connections, self.forbidden = [], {}, []
        self.stopping = threading.Event()

    def record(self, connection, operation, **fields):
        with self.lock:
            value = {"sequence": len(self.calls) + 1, "connection": connection, "operation": operation, **fields}
            self.calls.append(value)
            with (self.output / "protocol.jsonl").open("a") as stream:
                stream.write(json.dumps(value) + "\n")

    def deny(self, connection, operation, **fields):
        with self.lock:
            self.forbidden.append({"connection": connection, "operation": operation, **fields})
        self.record(connection, "DENIED_" + operation, **fields)
        return paramiko.SFTP_PERMISSION_DENIED

    def snapshot(self):
        with self.lock:
            return {"calls": list(self.calls), "connections": list(self.connections.values()),
                    "active_connections": sum(value["active"] for value in self.connections.values()),
                    "read_handles_opened": list(self.opens), "read_handles_closed": list(self.closes),
                    "forbidden_operations": list(self.forbidden), "errors": list(self.errors),
                    "remote_sha256": hashlib.sha256(PAYLOAD).hexdigest(), "remote_md5": hashlib.md5(PAYLOAD).hexdigest(),
                    "remote_size": len(PAYLOAD), "remote_bytes_mutated": False}


def normalized(path):
    return "/fixture" if path == "." else posixpath.normpath(path)


def attributes(path):
    path = normalized(path)
    if path not in ("/", "/fixture", REMOTE):
        return paramiko.SFTP_NO_SUCH_FILE
    value = paramiko.SFTPAttributes()
    value.st_mode = (stat.S_IFREG | 0o644) if path == REMOTE else (stat.S_IFDIR | 0o755)
    value.st_size = len(PAYLOAD) if path == REMOTE else 0
    value.st_mtime = value.st_atime = 1700000000
    return value


class Handle(ReadOnlyHandle):
    def __init__(self, path, state, connection, handle):
        super().__init__(path, state)
        self.connection, self.handle = connection, handle

    def read(self, offset, length):
        result = PAYLOAD[offset:offset + length]
        self.state.record(self.connection, "READ", path=self.path, handle=self.handle, offset=offset, requested=length, returned=len(result))
        return result

    def stat(self):
        self.state.record(self.connection, "FSTAT", path=self.path, handle=self.handle)
        return attributes(self.path)

    def close(self):
        with self.state.lock:
            self.state.closes.append(self.handle)
        self.state.record(self.connection, "CLOSE", path=self.path, handle=self.handle)
        return paramiko.SFTP_OK


class Files(ReadOnlyFiles):
    def __init__(self, server, *args, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.connection = server.connection

    def canonicalize(self, path):
        self.state.record(self.connection, "REALPATH", path=path)
        return normalized(path)

    def stat(self, path):
        self.state.record(self.connection, "STAT", path=path)
        if normalized(path) == "/denied-visual-directory":
            return paramiko.SFTP_PERMISSION_DENIED
        return attributes(path)

    lstat = stat

    def list_folder(self, path):
        self.state.record(self.connection, "LIST", path=path)
        path = normalized(path)
        if path == "/denied-visual-directory":
            return paramiko.SFTP_PERMISSION_DENIED
        if path not in ("/", "/fixture"):
            return paramiko.SFTP_NO_SUCH_FILE
        item = attributes("/fixture" if path == "/" else REMOTE)
        item.filename = "fixture" if path == "/" else "release.txt"
        return [item]

    def open(self, path, flags, attrs):
        self.state.record(self.connection, "OPEN", path=path, flags=flags)
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND | os.O_EXCL):
            return self.state.deny(self.connection, "WRITE_OPEN", path=path, flags=flags)
        if normalized(path) != REMOTE:
            return paramiko.SFTP_NO_SUCH_FILE
        with self.state.lock:
            handle = f"{self.connection}:{len(self.state.opens) + 1}"
            self.state.opens.append(handle)
        return Handle(REMOTE, self.state, self.connection, handle)

    def remove(self, path):
        return self.state.deny(self.connection, "REMOVE", path=path)

    def rename(self, old, new):
        return self.state.deny(self.connection, "RENAME", old=old, new=new)

    posix_rename = rename

    def mkdir(self, path, attrs):
        return self.state.deny(self.connection, "MKDIR", path=path)

    def rmdir(self, path):
        return self.state.deny(self.connection, "RMDIR", path=path)

    def chattr(self, path, attrs):
        return self.state.deny(self.connection, "SETSTAT", path=path)


class Server(ReadOnlyServer):
    def __init__(self, state, connection):
        super().__init__(state)
        self.connection = connection

    def check_auth_password(self, user, password):
        accepted = (user, password) == (USER, PASSWORD)
        self.state.record(self.connection, "AUTH", user=user, accepted=accepted)
        return paramiko.AUTH_SUCCESSFUL if accepted else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, channel_id):
        self.state.record(self.connection, "CHANNEL", kind=kind, channel_id=channel_id)
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_subsystem_request(self, channel, name):
        self.state.record(self.connection, "SUBSYSTEM", name=name)
        return super().check_channel_subsystem_request(channel, name) if name == "sftp" else False

    def check_channel_pty_request(self, *args):
        self.state.deny(self.connection, "PTY")
        return False

    def check_channel_shell_request(self, *args):
        self.state.deny(self.connection, "SHELL")
        return False

    def check_channel_exec_request(self, channel, command):
        self.state.deny(self.connection, "EXEC")
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--self-test", action="store_true", help="Exercise this peer over actual local SFTP; never starts the app")
    parser.add_argument("--directory-fin", action="store_true", help="Allow this run-owned drop-first marker to FIN only the directory connector")
    args = parser.parse_args()
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("use a fresh peer output directory")
    state = State(output)
    host_key = paramiko.RSAKey.generate(2048)
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(host_key.asbytes()).digest()).decode().rstrip("=")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(4)
    listener.settimeout(0.1)
    transports, workers = [], []
    sockets = {}
    fin_sent = False

    def connection_loop(connection, number):
        transport = paramiko.Transport(connection)
        channels = []
        with state.lock:
            transports.append(transport)
            sockets[number] = connection
            state.connections[number] = {"id": number, "active": True, "peer_closed_before_stop": False}
        try:
            transport.add_server_key(host_key)
            transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files)
            transport.start_server(server=Server(state, number))
            while transport.is_active() and not state.stopping.is_set():
                channel = transport.accept(0.02)
                if channel is not None:
                    channels.append(channel)
            with state.lock:
                state.connections[number]["peer_closed_before_stop"] = not state.stopping.is_set() and not transport.is_active()
        except (EOFError, ConnectionResetError, BrokenPipeError):
            pass
        except Exception as error:
            with state.lock:
                state.errors.append(type(error).__name__ + ": " + str(error))
        finally:
            transport.close()
            with state.lock:
                state.connections[number]["active"] = False
            state.record(number, "CONNECTION_CLOSED")

    def accept_loop():
        nonlocal fin_sent
        while not state.stopping.is_set():
            if args.directory_fin and not fin_sent and (output / "drop-first").exists():
                with state.lock:
                    directories = [call["connection"] for call in state.calls if call["operation"] == "LIST"]
                if directories and directories[0] in sockets:
                    number = directories[0]
                    fin_sent = True
                    state.record(number, "CONTROL_FIN", trigger="owned drop-first marker", directory_only=True)
                    try:
                        sockets[number].shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
            try:
                connection, address = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            assert address[0] == "127.0.0.1"
            worker = threading.Thread(target=connection_loop, args=(connection, len(workers) + 1), daemon=True)
            workers.append(worker)
            worker.start()

    thread = threading.Thread(target=accept_loop, daemon=True)
    thread.start()
    ready = {"host": "127.0.0.1", "port": listener.getsockname()[1], "user": USER, "password": PASSWORD,
             "fingerprint": fingerprint, "remote_path": REMOTE, "size": len(PAYLOAD),
             "sha256": hashlib.sha256(PAYLOAD).hexdigest(), "md5": hashlib.md5(PAYLOAD).hexdigest()}
    (output / "source.bin").write_bytes(PAYLOAD)
    (output / "ready.json").write_text(json.dumps(ready, indent=2) + "\n")
    signal.signal(signal.SIGTERM, lambda *_: state.stopping.set())
    signal.signal(signal.SIGINT, lambda *_: state.stopping.set())
    self_test = None
    try:
        if args.self_test:
            client = paramiko.SSHClient()
            client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            try:
                client.connect(ready["host"], port=ready["port"], username=USER, password=PASSWORD, look_for_keys=False, allow_agent=False, timeout=3)
                sftp = client.open_sftp()
                assert sftp.normalize(".") == "/fixture"
                assert sftp.listdir("/fixture") == ["release.txt"]
                with sftp.open(REMOTE, "rb") as source:
                    assert source.stat().st_size == len(PAYLOAD)
                    assert source.read() == PAYLOAD
                sftp.close()
            finally:
                client.close()
            deadline = time.monotonic() + 3
            while state.snapshot()["active_connections"] and time.monotonic() < deadline:
                time.sleep(0.01)
            result = state.snapshot()
            self_test = not result["errors"] and not result["forbidden_operations"] and not result["active_connections"] and sorted(result["read_handles_opened"]) == sorted(result["read_handles_closed"])
            assert self_test
        else:
            deadline = time.monotonic() + 300
            while not state.stopping.wait(0.1):
                if time.monotonic() >= deadline:
                    state.errors.append("Peer lifetime exceeded 300 seconds")
                    break
                temporary = output / "state.next.json"
                temporary.write_text(json.dumps(state.snapshot(), indent=2) + "\n")
                temporary.replace(output / "state.json")
    finally:
        state.stopping.set()
        listener.close()
        for transport in transports:
            transport.close()
        thread.join(2)
        for worker in workers:
            worker.join(2)
        report = {"kind": "read_only_loopback_protocol_fixture", "self_test_passed": self_test,
                  "main_application_started": False, **state.snapshot()}
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"self_test_passed": self_test, "connections": len(report["connections"]), "errors": report["errors"]}))


if __name__ == "__main__":
    main()
