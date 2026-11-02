#!/usr/bin/env python3
"""Disposable SSH terminal + readonly SFTP peer for mixed-group acceptance.
No command execution or host filesystem access. Bind only to loopback.
"""
import argparse, base64, hashlib, json, signal, socket, stat, threading, time
from pathlib import Path
import paramiko
p = argparse.ArgumentParser(); p.add_argument('--out', required=True); args = p.parse_args()
out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
key = paramiko.RSAKey.generate(2048)
running = True
transports = []
files = {'README.md': b'Mixed session group fixture\n', 'app.log': b'Fixture file panel\n'}
class File(paramiko.SFTPHandle):
    def __init__(self, name): super().__init__(); self.name = name
    def read(self, offset, length): return files[self.name][offset:offset + length]
    def stat(self): return attrs(self.name)
def attrs(name):
    a = paramiko.SFTPAttributes(); a.st_atime = a.st_mtime = 1700000000
    a.st_mode = (stat.S_IFREG | 0o400) if name in files else (stat.S_IFDIR | 0o555)
    a.st_size = len(files.get(name, b'')); return a
class Sftp(paramiko.SFTPServerInterface):
    def canonicalize(self, path): return '/fixture' if path in ['', '.'] else path
    def stat(self, path): return attrs(path.rsplit('/', 1)[-1])
    lstat = stat
    def list_folder(self, path):
        result = []
        for name in files:
            a = attrs(name); a.filename = name; result.append(a)
        return result
    def open(self, path, flags, attr):
        name = path.rsplit('/', 1)[-1]
        return File(name) if flags == 0 and name in files else paramiko.SFTP_PERMISSION_DENIED
class Server(paramiko.ServerInterface):
    def check_auth_password(self, user, password): return paramiko.AUTH_SUCCESSFUL if (user, password) == ('fixture', 'fixture-only') else paramiko.AUTH_FAILED
    def get_allowed_auths(self, user): return 'password'
    def check_channel_request(self, kind, channel_id): return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_pty_request(self, *args): return True
    def check_channel_window_change_request(self, *args): return True
    def check_channel_shell_request(self, channel):
        def terminal():
            try:
                channel.send(b'Owned loopback SSH fixture\r\nfixture@server:~$ ')
                while running and not channel.closed:
                    data = channel.recv(4096)
                    if not data: break
                    channel.send(data)
                    if b'\r' in data: channel.send(b'\nfixture@server:~$ ')
            except (OSError, EOFError): pass
        threading.Thread(target=terminal, daemon=True).start(); return True
listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(); listener.settimeout(.2)
(out / 'ready.json').write_text(json.dumps({'host': '127.0.0.1', 'port': listener.getsockname()[1], 'user': 'fixture', 'password': 'fixture-only', 'fingerprint': 'SHA256:' + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip('=')}))
def connect(sock):
    t = paramiko.Transport(sock); transports.append(t); t.add_server_key(key); t.set_subsystem_handler('sftp', paramiko.SFTPServer, Sftp)
    try:
        t.start_server(server=Server())
        while running and t.is_active(): time.sleep(.05)
    except (EOFError, OSError): pass
    finally: t.close()
def stop(*args):
    global running
    running = False
signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
while running:
    try:
        client, _ = listener.accept(); threading.Thread(target=connect, args=(client,), daemon=True).start()
    except socket.timeout: pass
for transport in transports: transport.close()
listener.close()
