#!/usr/bin/env python3
"""Real wizard Controller/SFTP probe against isolated read-only loopback peers."""
import argparse
import hashlib
import json
import logging
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import threading
import time
import paramiko

logging.getLogger('paramiko').setLevel(logging.CRITICAL)

class Directory(paramiko.SFTPServerInterface):
    def __init__(self, server, *args, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.peer = server
    def canonicalize(self, path):
        self.peer.calls.append('REALPATH ' + path)
        return '/fixture'
    def stat(self, path):
        self.peer.calls.append('STAT ' + path)
        a = paramiko.SFTPAttributes()
        a.st_mode = (stat.S_IFREG if self.peer.mode == 'sftp-not-directory' else stat.S_IFDIR) | 0o755
        a.st_size = 0
        a.st_mtime = a.st_atime = 1700000000
        return a
    def list_folder(self, path):
        self.peer.calls.append('LIST ' + path)
        return paramiko.SFTP_PERMISSION_DENIED if self.peer.mode == 'sftp-read-denied' else []

class Peer(paramiko.ServerInterface):
    def __init__(self, mode, host_key):
        self.mode, self.key, self.calls, self.errors = mode, host_key, [], []
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(8)
        self.port = self.listener.getsockname()[1]
        self.closed = threading.Event()
        self.transport = None
        self.thread = threading.Thread(target=self.serve, daemon=True)
    def get_allowed_auths(self, username): return 'password'
    def check_auth_password(self, username, password):
        self.calls.append('password')
        return paramiko.AUTH_SUCCESSFUL if username == 'operator' and password == 'fixture-password' else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, chanid):
        self.calls.append('channel ' + kind)
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_subsystem_request(self, channel, name):
        self.calls.append('subsystem ' + name)
        if self.mode == 'sftp-subsystem-denied': return False
        return super().check_channel_subsystem_request(channel, name)
    def check_channel_pty_request(self, *args): self.calls.append('UNEXPECTED pty'); return False
    def check_channel_shell_request(self, *args): self.calls.append('UNEXPECTED shell'); return False
    def check_channel_exec_request(self, *args): self.calls.append('UNEXPECTED exec'); return False
    def serve(self):
        try:
            connection, _ = self.listener.accept()
            self.transport = paramiko.Transport(connection)
            self.transport.add_server_key(self.key)
            self.transport.set_subsystem_handler('sftp', paramiko.SFTPServer, Directory)
            self.transport.start_server(server=self)
            deadline = time.monotonic() + 10
            while self.transport.is_active() and time.monotonic() < deadline:
                time.sleep(.005)
            if not self.transport.is_active(): self.closed.set()
        except Exception as exc:
            self.errors.append(type(exc).__name__ + ': ' + str(exc))
        finally:
            if self.transport: self.transport.close()
            self.listener.close()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runner', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    cases = []
    host_key = paramiko.RSAKey.generate(2048)
    with tempfile.TemporaryDirectory(prefix='zerowork-sftp-probe-') as temporary:
        for mode in ('sftp-known', 'sftp-subsystem-denied', 'sftp-not-directory', 'sftp-read-denied'):
            peer = Peer(mode, host_key)
            store = Path(temporary) / (mode + '.known_hosts')
            store.write_text(f'[127.0.0.1]:{peer.port} {host_key.get_name()} {host_key.get_base64()}\n')
            before = store.read_bytes()
            peer.thread.start()
            result = subprocess.run([str(args.runner.resolve()), str(peer.port), mode, str(store)], text=True, capture_output=True, timeout=12)
            peer.thread.join(2)
            no_shell = not any(c.startswith('UNEXPECTED') for c in peer.calls)
            output = result.stdout + result.stderr
            passed = result.returncode == 0 and 'PASS ' in output and peer.closed.is_set() and not peer.errors and no_shell and before == store.read_bytes()
            passed &= peer.calls.count('password') == 1 and peer.calls.count('subsystem sftp') == 1
            if mode == 'sftp-known': passed &= 'LIST /fixture' in peer.calls and 'STAT /fixture' in peer.calls
            if mode == 'sftp-subsystem-denied': passed &= not any(c.startswith(('STAT ', 'REALPATH ', 'LIST ')) for c in peer.calls)
            if mode == 'sftp-not-directory': passed &= 'STAT /fixture' in peer.calls and 'LIST /fixture' not in peer.calls
            cases.append(dict(mode=mode, passed=bool(passed), exit_code=result.returncode, calls=peer.calls, no_pty_shell_exec=no_shell, peer_closed_before_cleanup=peer.closed.is_set(), store_unchanged=before == store.read_bytes(), server_errors=peer.errors, output=output))
            print(mode + ': ' + ('PASS' if passed else 'FAIL'))
    report = dict(passed=all(c['passed'] for c in cases), runner_sha256=hashlib.sha256(args.runner.read_bytes()).hexdigest(), scope='Production wizard Controller/Job/Session; actual libssh2 no-shell SFTP subsystem, REALPATH, STAT and directory access; loopback only, no GUI claim', cases=cases)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    raise SystemExit(0 if report['passed'] else 1)

if __name__ == '__main__': main()
