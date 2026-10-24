"""Owned loopback SSH/SFTP peer for native libssh2 acceptance.

This is a controlled server, not the user's VM or a replacement SSH engine.
Only a nonce /tmp directory is exposed through SFTP. Password/key material stays
in memory or mode-600 private.json; the JSONL audit contains no credentials.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import socket
import subprocess
import threading
import time
import uuid

import paramiko


parser = argparse.ArgumentParser()
parser.add_argument("--state-dir", required=True)
parser.add_argument("--root", required=True)
args = parser.parse_args()
assert re.fullmatch(r"/tmp/zerowork-unified-[0-9a-f]{16}", args.root)
root = Path(args.root).resolve()
assert root.is_dir()
state = Path(args.state_dir).resolve()
state.mkdir(mode=0o700, parents=True, exist_ok=True)
os.chmod(state, 0o700)
password = "v021-" + uuid.uuid4().hex
host_key = paramiko.RSAKey.generate(2048)
stop = threading.Event()
lock = threading.Lock()
transports = []
threads = []
audit_path = state / "audit.jsonl"


def audit(event, **fields):
    with lock:
        with audit_path.open("a") as stream:
            stream.write(json.dumps({"event": event, "time": time.time(), **fields}) + "\n")


class ScopedHandle(paramiko.SFTPHandle):
    def __init__(self, flags, stream, path, connection_id):
        super().__init__(flags)
        self.stream = stream
        self.path = path
        self.connection_id = connection_id

    def stat(self):
        return paramiko.SFTPAttributes.from_stat(os.fstat(self.stream.fileno()))

    def chattr(self, attr):
        try:
            paramiko.SFTPServer.set_file_attr(str(self.path), attr)
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno or 13)

    def close(self):
        super().close()
        try:
            content = self.path.read_bytes()
            audit("file_closed", connection_id=self.connection_id, path=str(self.path),
                  bytes=len(content), sha256=hashlib.sha256(content).hexdigest())
        except OSError:
            pass


class ScopedSFTP(paramiko.SFTPServerInterface):
    def __init__(self, server, *a, **kw):
        super().__init__(server, *a, **kw)
        self.connection_id = server.connection_id
        audit("sftp_open", connection_id=self.connection_id)

    def session_ended(self):
        audit("sftp_closed", connection_id=self.connection_id)

    def path(self, value):
        candidate = (Path(value) if value.startswith("/") else root / value).resolve()
        if candidate != root and root not in candidate.parents:
            raise PermissionError("Outside owned nonce directory")
        return candidate

    def canonicalize(self, path):
        try:
            return str(Path(args.root) / self.path(path).relative_to(root))
        except OSError:
            return args.root

    def list_folder(self, path):
        try:
            directory = self.path(path)
            audit("list", connection_id=self.connection_id, path=str(directory))
            result = []
            for child in directory.iterdir():
                attributes = paramiko.SFTPAttributes.from_stat(child.lstat())
                attributes.filename = child.name
                result.append(attributes)
            return result
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno or 13)

    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self.path(path).stat())
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno or 13)

    lstat = stat

    def open(self, path, flags, attr):
        try:
            owned_path = self.path(path)
            fd = os.open(owned_path, flags, 0o600)
            mode = "r+b" if flags & os.O_RDWR else "wb" if flags & os.O_WRONLY else "rb"
            stream = os.fdopen(fd, mode)
            handle = ScopedHandle(flags, stream, owned_path, self.connection_id)
            if flags & (os.O_WRONLY | os.O_RDWR):
                handle.writefile = stream
            if not flags & os.O_WRONLY:
                handle.readfile = stream
            audit("file_open", connection_id=self.connection_id, path=str(owned_path), flags=flags)
            return handle
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno or 13)

    def remove(self, path):
        return self.mutate("remove", path, lambda p: p.unlink())

    def mkdir(self, path, attr):
        return self.mutate("mkdir", path, lambda p: p.mkdir(mode=0o700))

    def rmdir(self, path):
        return self.mutate("rmdir", path, lambda p: p.rmdir())

    def rename(self, oldpath, newpath):
        try:
            self.path(oldpath).rename(self.path(newpath))
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno or 13)

    def chattr(self, path, attr):
        try:
            paramiko.SFTPServer.set_file_attr(str(self.path(path)), attr)
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno or 13)

    def mutate(self, event, path, action):
        try:
            target = self.path(path)
            action(target)
            audit(event, connection_id=self.connection_id, path=str(target))
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno or 13)


class SSHServer(paramiko.ServerInterface):
    def __init__(self, connection_id):
        self.connection_id = connection_id
        self.shell = threading.Event()

    def get_allowed_auths(self, username):
        return "password"

    def check_auth_password(self, username, submitted):
        accepted = username == "root" and submitted == password
        audit("auth", connection_id=self.connection_id, accepted=accepted)
        return paramiko.AUTH_SUCCESSFUL if accepted else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, channel_id):
        audit("channel", connection_id=self.connection_id, channel_id=channel_id, kind=kind)
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, channel, term, width, height, pixelwidth, pixelheight, modes):
        audit("pty", connection_id=self.connection_id, width=width, height=height)
        return True

    def check_channel_window_change_request(self, channel, width, height, pixelwidth, pixelheight):
        audit("resize", connection_id=self.connection_id, width=width, height=height)
        return True

    def check_channel_shell_request(self, channel):
        self.shell.set()
        return True


def bridge_shell(channel, server):
    if not server.shell.wait(5):
        return  # The independent SFTP subsystem is owned by Paramiko's handler.
    master, slave = pty.openpty()
    child = subprocess.Popen(["/bin/sh", "-i"], cwd=root, stdin=slave, stdout=slave,
                             stderr=slave, start_new_session=True,
                             env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(root), "PS1": "v021> "})
    os.close(slave)
    audit("shell_open", connection_id=server.connection_id, pid=child.pid)
    try:
        while not stop.is_set() and not channel.closed and child.poll() is None:
            readable, _, _ = select.select([master, channel], [], [], 0.1)
            if master in readable:
                data = os.read(master, 32768)
                if not data:
                    break
                channel.sendall(data)
            if channel in readable:
                data = channel.recv(32768)
                if not data:
                    break
                os.write(master, data)
    except (OSError, EOFError):
        pass
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        os.close(master)
        channel.close()
        audit("shell_closed", connection_id=server.connection_id, pid=child.pid)


def connection(client, connection_id):
    transport = paramiko.Transport(client)
    with lock:
        transports.append(transport)
    server = SSHServer(connection_id)
    transport.add_server_key(host_key)
    transport.set_subsystem_handler("sftp", paramiko.SFTPServer, ScopedSFTP)
    try:
        transport.start_server(server=server)
        while transport.is_active() and not stop.is_set():
            channel = transport.accept(0.2)
            if channel is not None:
                worker = threading.Thread(target=bridge_shell, args=(channel, server), daemon=True)
                threads.append(worker)
                worker.start()
    except (OSError, EOFError, paramiko.SSHException) as error:
        audit("connection_error", connection_id=connection_id, error=type(error).__name__)
    finally:
        transport.close()
        audit("connection_closed", connection_id=connection_id)


listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(16)
listener.settimeout(0.2)
port = listener.getsockname()[1]
private = {"direct": {"host": "127.0.0.1", "port": port, "user": "root", "password": password}}
fd = os.open(state / "private.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as stream:
    json.dump(private, stream)
fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(host_key.asbytes()).digest()).decode().rstrip("=")
(state / "ready.json").write_text(json.dumps({"pid": os.getpid(), "host": "127.0.0.1", "port": port,
                                            "root": str(root), "fingerprint": fingerprint,
                                            "environment": "controlled_loopback_paramiko"}))
signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())
print("ready: controlled loopback SSH/SFTP peer", flush=True)
counter = 0
try:
    while not stop.is_set():
        try:
            client, address = listener.accept()
        except socket.timeout:
            continue
        counter += 1
        audit("connection_open", connection_id=counter, peer_port=address[1])
        worker = threading.Thread(target=connection, args=(client, counter), daemon=True)
        threads.append(worker)
        worker.start()
finally:
    listener.close()
    for transport in transports:
        transport.close()
    for worker in threads:
        worker.join(timeout=3)
    audit("server_stopped", connections=counter)
