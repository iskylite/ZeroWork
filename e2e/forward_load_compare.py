#!/usr/bin/env python3
"""Opt-in real-host comparison of production WorkerThread forwarding and OpenSSH.

Uses one temporary loopback HTTP server, identical payloads/concurrency/ciphers,
PTYs on every SSH connection, alternating rounds and strict existing host trust.
Credentials are supplied via a private file, never command-line arguments.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shlex
import socket
import statistics
import struct
import subprocess
import threading
import time

import paramiko


def wait_json(path, process, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            try:
                return json.loads(path.read_text())
            except json.JSONDecodeError:  # Writer may still be publishing.
                pass
        if process.poll() is not None:
            raise RuntimeError(f"runner exited {process.returncode}; see {path.parent}/runner.log")
        time.sleep(.01)
    raise TimeoutError(str(path))


def exact(sock, count):
    result = bytearray()
    while len(result) < count:
        block = sock.recv(count - len(result))
        if not block:
            raise EOFError()
        result.extend(block)
    return bytes(result)


def request(proxy, remote_port, size):
    started = time.monotonic()
    with socket.create_connection(('127.0.0.1', proxy), 5) as sock:
        sock.settimeout(20)
        sock.sendall(b'\x05\x01\x00')
        assert exact(sock, 2) == b'\x05\x00'
        sock.sendall(b'\x05\x01\x00\x01\x7f\x00\x00\x01' + struct.pack('!H', remote_port))
        assert exact(sock, 10)[1] == 0
        connected = time.monotonic()
        sock.sendall(f'GET /{size} HTTP/1.0\r\nHost: localhost\r\n\r\n'.encode())
        result = bytearray()
        first = body_done = expected = None
        while True:
            block = sock.recv(65536)
            if not block:
                break
            if first is None:
                first = time.monotonic()
            result.extend(block)
            if expected is None and b'\r\n\r\n' in result:
                expected = result.index(b'\r\n\r\n') + 4 + size
            if expected is not None and len(result) >= expected and body_done is None:
                body_done = time.monotonic()
        end = time.monotonic()
    body = result.split(b'\r\n\r\n', 1)[1]
    assert body == (bytes(range(256)) * ((size + 255) // 256))[:size]
    return dict(connect_ms=round((connected-started)*1000, 2),
                first_ms=round((first-started)*1000, 2),
                body_ms=round((body_done-started)*1000, 2),
                total_ms=round((end-started)*1000, 2), bytes=len(body),
                sha256=hashlib.sha256(body).hexdigest())


REMOTE = '''import http.server,threading
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  if self.path=='/stop':
   self.send_response(200);self.end_headers();threading.Thread(target=self.server.shutdown).start();return
  n=int(self.path[1:]);data=(bytes(range(256))*((n+255)//256))[:n]
  self.send_response(200);self.send_header('Content-Length',str(n));self.end_headers();self.wfile.write(data)
 def log_message(self,*a):pass
class S(http.server.ThreadingHTTPServer):request_queue_size=64
s=S(('127.0.0.1',0),H);print(s.server_port,flush=True)
t=threading.Timer(300,s.shutdown);t.start();s.serve_forever();s.server_close();t.cancel()
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True)
    parser.add_argument('--user', required=True)
    parser.add_argument('--credential-file', type=Path, required=True)
    parser.add_argument('--runner', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, help='Also compare an archived pre-fix runner')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--rounds', type=int, default=6)
    parser.add_argument('--size', type=int, default=262144)
    parser.add_argument('--count', type=int, default=16)
    parser.add_argument('--concurrency', type=int, default=8)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    password = args.credential_file.read_text()
    trusted = subprocess.check_output(['ssh-keygen', '-F', args.host], text=True)
    ssh = paramiko.SSHClient()
    ssh.load_system_host_keys()
    ssh.connect(args.host, username=args.user, password=password, timeout=10,
                allow_agent=False, look_for_keys=False,
                disabled_algorithms={'keys': ['ssh-ed25519', 'ecdsa-sha2-nistp256',
                                             'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521']})
    natives, ports, reports, logs = {}, {}, [], []
    remote_port = openssh = None
    askpass = out / 'askpass'
    try:
        _, stdout, _ = ssh.exec_command('python3 -u -c ' + shlex.quote(REMOTE))
        remote_port = int(stdout.readline())
        runners = {'native': args.runner}
        if args.baseline:
            runners['before'] = args.baseline
        for kind, binary in runners.items():
            control = out / kind
            control.mkdir()
            (control / 'known_hosts').write_text(trusted)
            log = open(control / 'runner.log', 'w')
            logs.append(log)
            process = subprocess.Popen([str(binary.resolve()), str(control)],
                env=dict(os.environ, ZW_LOAD_HOST=args.host, ZW_LOAD_USER=args.user,
                         ZW_LOAD_PASSWORD=password), stdout=log, stderr=log)
            natives[kind] = dict(process=process, control=control, index=0)
            ready = wait_json(control / 'ready.json', process)
            ports[kind] = ready['port']
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            ports['openssh'] = sock.getsockname()[1]
        askpass.write_text('#!/bin/sh\ncat "$ZW_LOAD_PASSWORD_FILE"\n')
        askpass.chmod(0o700)
        log = open(out / 'openssh.log', 'w')
        logs.append(log)
        openssh = subprocess.Popen(['ssh', '-vv', '-tt', '-D', f"127.0.0.1:{ports['openssh']}",
            '-c', ready['cipher'], '-m', 'hmac-sha2-256', '-o', 'Compression=no',
            '-o', 'ExitOnForwardFailure=yes', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'HostKeyAlgorithms=rsa-sha2-512,rsa-sha2-256',
            '-o', 'PreferredAuthentications=password', '-o', 'NumberOfPasswordPrompts=1',
            f'{args.user}@{args.host}'], stdin=subprocess.PIPE, stdout=log, stderr=log,
            start_new_session=True, env=dict(os.environ, SSH_ASKPASS=str(askpass),
                SSH_ASKPASS_REQUIRE='force', DISPLAY='review',
                ZW_LOAD_PASSWORD_FILE=str(args.credential_file.resolve())))
        deadline = time.monotonic() + 20
        while True:
            if openssh.poll() is not None:
                raise RuntimeError('OpenSSH failed; see openssh.log')
            try:
                with socket.create_connection(('127.0.0.1', ports['openssh']), .1):
                    break
            except OSError:
                if time.monotonic() >= deadline:
                    raise TimeoutError('OpenSSH startup')
                time.sleep(.05)
        for proxy in ports.values():
            request(proxy, remote_port, 256)
        time.sleep(1)
        order = ['before', 'native', 'openssh', 'openssh', 'native', 'before'] if args.baseline else ['native', 'openssh', 'openssh', 'native']
        conditions = dict(host=args.host, remote_port=remote_port, cipher=ready['cipher'],
            mac='hmac-sha2-256', pty=True, size=args.size, count=args.count,
            concurrency=args.concurrency, order=order,
            runners={k: hashlib.sha256(v.read_bytes()).hexdigest() for k, v in runners.items()})
        for round_no in range(args.rounds):
            kind = order[round_no % len(order)]
            proxy = ports[kind]
            started = time.monotonic()
            samples, errors, health = [], [], []
            done = threading.Event()
            def sample_load():
                state = natives[kind]
                try:
                    if done.wait(.25):
                        return
                    while not done.is_set():
                        index = state['index']
                        (state['control'] / f'sample-{index}').touch()
                        samples.append(wait_json(state['control'] / f'sample-{index}.json', state['process']))
                        state['index'] += 1
                        done.wait(.1)
                except Exception as error:
                    errors.append(error)
            sampler = threading.Thread(target=sample_load) if kind in natives else None
            try:
                with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
                    futures = [pool.submit(request, proxy, remote_port, args.size) for _ in range(args.count)]
                    if sampler:
                        sampler.start()
                    time.sleep(.05)
                    for _ in range(3):
                        health.append(request(proxy, remote_port, 256))
                        time.sleep(.05)
                    requests = [future.result() for future in futures]
            finally:
                done.set()
                wall_ms = round((time.monotonic() - started)*1000, 2)
                if sampler:
                    sampler.join()
            if errors:
                raise errors[0]
            row = dict(kind=kind, round=round_no, wall_ms=wall_ms, requests=requests,
                       health=health, rtt=samples,
                       median_ms=statistics.median(v['total_ms'] for v in requests))
            reports.append(row)
            (out / 'results.json').write_text(json.dumps(dict(conditions=conditions, rounds=reports), indent=2))
            print(json.dumps({k: row[k] for k in ['kind', 'round', 'wall_ms', 'median_ms', 'rtt']} |
                             {'health_ms': [v['total_ms'] for v in health]}), flush=True)
            time.sleep(.5)
    finally:
        for state in natives.values():
            (state['control'] / 'stop').touch()
            try:
                state['process'].wait(timeout=8)
            except subprocess.TimeoutExpired:
                state['process'].kill()
                state['process'].wait()
        if openssh:
            openssh.terminate()
            openssh.wait(timeout=5)
        if remote_port:
            try:
                channel = ssh.get_transport().open_channel('direct-tcpip', ('127.0.0.1', remote_port), ('127.0.0.1', 0), timeout=5)
                channel.settimeout(3)
                channel.sendall(b'GET /stop HTTP/1.0\r\n\r\n')
                channel.recv(1024)
                channel.close()
            except (OSError, EOFError, paramiko.SSHException):
                pass  # The fixture also has an independent 300-second expiry.
        ssh.close()
        askpass.unlink(missing_ok=True)
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
