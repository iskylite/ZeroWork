#!/usr/bin/env python3
"""Owned loopback RSA peer and actual disposable ZSH PTY for native key auth.
Private keys are generated under --out with mode 0600; no external endpoint.
"""
import argparse
import base64
import fcntl
import hashlib
import json
import logging
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import termios
import threading
import time
import paramiko
from cryptography.hazmat.primitives import serialization

logging.getLogger("paramiko").setLevel(logging.CRITICAL)
parser = argparse.ArgumentParser()
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--authorized-key", type=Path, help="Optional additional public key, never a private key")
args = parser.parse_args()
out = args.out.resolve(); out.mkdir(parents=True, exist_ok=True)
stop = threading.Event(); lock = threading.Lock(); threads = []; events = []
signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())
host_key = paramiko.RSAKey.generate(2048)
client_key = paramiko.RSAKey.generate(2048)
authorized = [client_key.asbytes()]
if args.authorized_key:
    authorized.append(base64.b64decode(args.authorized_key.read_text().split()[1]))
for name, encryption in (("clear-openssh-key", serialization.NoEncryption()), ("encrypted-openssh-key", serialization.BestAvailableEncryption(b"fixture-key-passphrase"))):
    path = out / name
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as file:
        file.write(client_key.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH, encryption))
    path.chmod(0o600)
(out / ".zshrc").write_text("bindkey -e\nPS1='keyfixture%# '\n")
listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen(8); listener.settimeout(.2)
port = listener.getsockname()[1]
fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(host_key.asbytes()).digest()).decode().rstrip("=")
(out / "ready.json").write_text(json.dumps({"host": "127.0.0.1", "port": port, "user": "key-fixture", "key": str(out / "encrypted-openssh-key"), "clear_key": str(out / "clear-openssh-key"), "fingerprint": fingerprint, "known_host": f"[127.0.0.1]:{port} {host_key.get_name()} {host_key.get_base64()}\n"}))

def record(event):
    with lock:
        events.append(event)
        (out / "events.json").write_text(json.dumps(events))

class Server(paramiko.ServerInterface):
    def __init__(self):
        self.shell = threading.Event(); self.size = (100, 30); self.master = None
    def get_allowed_auths(self, _): return "publickey"
    def check_auth_publickey(self, user, key):
        accepted = user == "key-fixture" and key.asbytes() in authorized
        record({"type": "publickey", "accepted": accepted})
        return paramiko.AUTH_SUCCESSFUL if accepted else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, _): return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_pty_request(self, channel, term, width, height, *rest): self.size = (width, height); return True
    def check_channel_window_change_request(self, channel, width, height, *rest):
        self.size = (width, height)
        if self.master is not None:
            try: fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))
            except OSError: pass
        return True
    def check_channel_shell_request(self, _): self.shell.set(); return True

def serve(connection, index):
    transport = paramiko.Transport(connection); transport.add_server_key(host_key)
    server = Server(); process = None; master = None
    try:
        transport.start_server(server=server)
        channel = transport.accept(15)
        if channel is None or not server.shell.wait(10): return
        master, slave = os.openpty(); server.master = master
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", server.size[1], server.size[0], 0, 0))
        def own_tty():
            os.setsid(); fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        process = subprocess.Popen(["/bin/zsh", "-i"], stdin=slave, stdout=slave, stderr=slave, cwd=out, preexec_fn=own_tty, env={**os.environ, "HOME": str(out), "ZDOTDIR": str(out), "TERM": "xterm-256color"})
        os.close(slave)
        record({"type": "shell", "connection": index})
        received = bytearray()
        while not stop.is_set() and transport.is_active() and process.poll() is None:
            readable, _, _ = select.select([master, channel], [], [], .1)
            if master in readable:
                try: block = os.read(master, 65536)
                except OSError: break
                if not block: break
                channel.sendall(block)
            if channel in readable:
                block = channel.recv(65536)
                if not block: break
                received.extend(block)
                if len(received) > 65536: raise ValueError("FixtureInputLimit")
                os.write(master, block)
        (out / f"received-{index}.bin").write_bytes(received)
    except (OSError, EOFError, paramiko.SSHException): pass
    finally:
        transport.close()
        if process is not None and process.poll() is None:
            process.terminate()
            try: process.wait(2)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        if master is not None: os.close(master)
        record({"type": "closed", "connection": index})

print("Owned SSH key fixture ready", flush=True)
try:
    while not stop.is_set():
        try: connection, _ = listener.accept()
        except socket.timeout: continue
        thread = threading.Thread(target=serve, args=(connection, len(threads) + 1), daemon=True)
        threads.append(thread); thread.start()
finally:
    listener.close()
    for thread in threads: thread.join(3)
    for name in ("clear-openssh-key", "encrypted-openssh-key"):
        (out / name).unlink(missing_ok=True)
