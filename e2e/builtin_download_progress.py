#!/usr/bin/env python3
"""Real libssh2/PTY/SFTP check with an owned RAM-only peer; no external host."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import paramiko
import sftp_readonly as fixture

fixture.data = lambda _: bytes((i * 29 + 17) % 251 for i in range(96 * 1024 + 53))

class Server(fixture.Server):
    def check_channel_pty_request(self, *args):
        return True
    def check_channel_window_change_request(self, *args):
        return True
    def check_channel_shell_request(self, channel):
        channel.sendall(b"ZW_SHARED_READY\r\n")
        def echo():
            try:
                while value := channel.recv(4096):
                    channel.sendall(b"ZW_ECHO:" + value + b"\r\n")
            except (OSError, EOFError):
                pass
        threading.Thread(target=echo, daemon=True).start()
        return True

parser = argparse.ArgumentParser()
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=False)
key = paramiko.RSAKey.generate(2048)
fingerprint = 'SHA256:' + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip('=')
listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen(1)
listener.settimeout(120)
transports = []
def serve():
    try:
        connection, _ = listener.accept()
        transport = paramiko.Transport(connection)
        transports.append(transport)
        transport.add_server_key(key)
        transport.set_subsystem_handler('sftp', paramiko.SFTPServer, fixture.Files)
        transport.start_server(server=Server(fixture.State()))
        channels = []
        while transport.is_active():
            channel = transport.accept(.05)
            if channel is not None:
                channels.append(channel)
    except (EOFError, OSError):
        pass
thread = threading.Thread(target=serve, daemon=True)
thread.start()
environment = {**os.environ, 'ZEROWORK_SHARED_SFTP_PORT': str(listener.getsockname()[1]),
               'ZEROWORK_SHARED_SFTP_FINGERPRINT': fingerprint, 'ZEROWORK_SHARED_SFTP_CONTROLS': str(args.out)}
try:
    run = subprocess.run(['zig', 'build', 'test-ui', '-Dui-test-filter=builtin download source read', '-Doptimize=ReleaseFast'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
    (args.out / 'runner.log').write_text(run.stdout)
    passed = run.returncode == 0 and 'BUILTIN_DOWNLOAD_NATIVE' in run.stdout
    (args.out / 'report.json').write_text(json.dumps({'passed': passed, 'real_shared_ssh_sftp': True, 'external_host': False, 'exit_code': run.returncode}, indent=2))
    print(run.stdout)
    raise SystemExit(0 if passed else 1)
finally:
    for transport in transports:
        transport.close()
    listener.close()
