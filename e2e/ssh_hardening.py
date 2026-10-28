#!/usr/bin/env python3
"""Owned idle SSH peers: fallback negotiation and authenticated liveness."""
import argparse
import json
import logging
from pathlib import Path
import socket
import subprocess
import threading
import time
import paramiko
from paramiko.common import MSG_GLOBAL_REQUEST
logging.getLogger('paramiko').setLevel(logging.CRITICAL)

class Server(paramiko.ServerInterface):
    def check_channel_direct_tcpip_request(self, *args):
        time.sleep(0.35)
        return paramiko.OPEN_SUCCEEDED
    def get_allowed_auths(self, user): return 'password'
    def check_auth_password(self, user, password): return paramiko.AUTH_SUCCESSFUL
    def check_channel_request(self, kind, channel): return paramiko.OPEN_SUCCEEDED
    def check_channel_pty_request(self, *args): return True
    def check_channel_shell_request(self, channel): return True
    def check_channel_exec_request(self, *args): raise AssertionError('unexpected remote exec')


def run(runner, key, mode):
    listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(1)
    listener.settimeout(3)
    stop = threading.Event(); transports = []; channels = []; errors = []; heartbeats = []
    def serve():
        try:
            connection, _ = listener.accept()
            with connection:
                t = paramiko.Transport(connection); transports.append(t)
                if mode == 'fallback': t.get_security_options().ciphers = ('aes128-cbc',)
                if mode == 'unsupported': t.get_security_options().ciphers = ('aes128-gcm@openssh.com',)
                if mode == 'silent':
                    handlers = t._handler_table.copy()
                    handlers[MSG_GLOBAL_REQUEST] = lambda message: heartbeats.append(time.monotonic())
                    t._handler_table = handlers
                t.add_server_key(key); t.start_server(server=Server())
                while t.is_active() and not stop.is_set():
                    channel = t.accept(0.05)
                    if channel is not None: channels.append(channel)
        except (EOFError, ConnectionResetError, BrokenPipeError, paramiko.SSHException): pass
        except Exception as exc: errors.append(repr(exc))
    thread = threading.Thread(target=serve, daemon=True); thread.start()
    try:
        result = subprocess.run([str(runner), str(listener.getsockname()[1]), mode], capture_output=True, text=True, timeout=12)
    finally:
        stop.set()
        for t in transports: t.close()
        listener.close(); thread.join(2)
    output = result.stdout + result.stderr
    passed = result.returncode == 0 and 'PASS ' in output and not errors and not thread.is_alive()
    if mode == 'silent': passed &= len(heartbeats) >= 2
    return dict(mode=mode, passed=passed, output=output, errors=errors, unanswered_heartbeats=len(heartbeats))


def main():
    p = argparse.ArgumentParser(); p.add_argument('--runner', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True); args = p.parse_args()
    key = paramiko.RSAKey.generate(2048)
    records = []
    for mode in ('fallback', 'unsupported', 'tunnel-timeout', 'silent', 'alive'):
        record = run(args.runner.resolve(), key, mode); records.append(record)
        print(mode, 'PASS' if record['passed'] else 'FAIL', record['output'], flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(records, ensure_ascii=False, indent=2)+'\n')
    raise SystemExit(0 if all(r['passed'] for r in records) else 1)
if __name__ == '__main__': main()
