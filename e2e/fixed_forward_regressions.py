#!/usr/bin/env python3
"""Owned SSH regressions: both half-close directions, recovery and startup stop.

The production fixed-forward runner retains a real PTY on the same SSH session.
Peers execute no commands. Every listener and client is owned by this fixture.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import threading
import time

import paramiko
from fixed_forward import Connection, Echo, Peer, remote_listen
from shared_forward import recv_exact, wait_file

RESPONSE = bytes(range(256)) * 4096 + b'response-after-fin'
PAYLOAD = bytes(range(256)) * 513 + b'request-before-fin'
original_echo = Connection.echo
original_direct = Connection.check_channel_direct_tcpip_request


def shutdown_write(stream):
    if isinstance(stream, paramiko.Channel):
        stream.shutdown_write()
    else:
        stream.shutdown(socket.SHUT_WR)


def serve(stream, records):
    try:
        stream.settimeout(5)
        command = recv_exact(stream, 1)
        if command == b'H':
            stream.sendall(RESPONSE)
            shutdown_write(stream)
        data = bytearray()
        while True:
            block = stream.recv(65536)
            if not block:
                break
            data.extend(block)
        records.append({'command': command.decode(), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
        if command == b'F':
            stream.sendall(RESPONSE)
            shutdown_write(stream)
    except (OSError, EOFError, paramiko.SSHException) as exc:
        records.append({'error': type(exc).__name__})
    finally:
        stream.close()


def echo(self, channel):
    if self.channels[channel.get_id()] == 'forward' and self.peer.half_close:
        return serve(channel, self.peer.records)
    return original_echo(self, channel)


def direct(self, channel_id, origin, target):
    result = original_direct(self, channel_id, origin, target)
    if self.peer.reject_next:
        self.peer.reject_next = False
        return paramiko.OPEN_FAILED_CONNECT_FAILED
    return result


def listen(self, address, port):
    self.peer.listen_seen.set()
    if self.peer.listen_delay:
        time.sleep(self.peer.listen_delay)
    return remote_listen(self, address, port)


Connection.echo = echo
Connection.check_channel_direct_tcpip_request = direct
Connection.check_port_forward_request = listen


class HalfCloseEcho(Echo):
    def echo(self, client):
        serve(client, self.records)

    def __init__(self):
        self.records = []
        super().__init__()


def wait_status(path, predicate, child, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            status = json.loads(path.read_text())
            if predicate(status):
                return status
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        if child.poll() is not None:
            raise AssertionError(f'runner exited: {path.parent}/runner.log')
        time.sleep(.01)
    raise TimeoutError(str(path))


def run(runner, out, mode):
    controls = out / mode
    controls.mkdir()
    peer = Peer()
    peer.records = []
    peer.half_close = mode.endswith('half-close')
    peer.reject_next = mode == 'local-recovery'
    peer.listen_seen = threading.Event()
    peer.listen_delay = .4 if mode == 'remote-cancel' else 10.3 if mode == 'remote-timeout' else 0
    peer.deny_remote = False
    peer.remote_cancelled = threading.Event()
    peer.thread.start()
    target = HalfCloseEcho() if peer.half_close else Echo()
    if mode == 'remote-recovery':
        target_port = target.port
        target.close()
        target = None
    else:
        target_port = target.port
    fingerprint = 'SHA256:' + base64.b64encode(hashlib.sha256(peer.key.asbytes()).digest()).decode().rstrip('=')
    log = (controls / 'runner.log').open('w')
    child = subprocess.Popen([str(runner), mode, str(controls), fingerprint, str(peer.port), str(target_port if mode.startswith('remote') else 4242)], stdout=log, stderr=subprocess.STDOUT)
    case = {'mode': mode}
    try:
        if mode == 'remote-timeout':
            child.wait(15)
            assert child.returncode != 0
            status = json.loads((controls / 'status.json').read_text())
            assert status['phase'] == 'failed' and status['failure'] == 'RemoteForwardListenTimeout', status
            assert not (controls / 'ready.json').exists()
            assert peer.remote_cancelled.wait(2), 'late listening request was not cancelled'
            case.update(passed=True, timeout=status)
            return case
        if mode == 'remote-cancel':
            assert peer.listen_seen.wait(5), 'fixture did not see pending tcpip-forward'
        else:
            ready = wait_file(controls / 'ready.json', child)
            port = ready['local_port']
            if peer.half_close:
                for command in (b'F', b'H'):
                    with socket.create_connection(('127.0.0.1', port), 4) as sock:
                        sock.settimeout(5)
                        sock.sendall(command)
                        if command == b'F':
                            sock.sendall(PAYLOAD)
                            sock.shutdown(socket.SHUT_WR)
                        # Small reads force the response across many relay buffers.
                        received = bytearray()
                        while True:
                            block = sock.recv(4096)
                            if not block:
                                break
                            received.extend(block)
                        assert bytes(received) == RESPONSE, (mode, command, len(received))
                        if command == b'H':
                            sock.sendall(PAYLOAD)
                            sock.shutdown(socket.SHUT_WR)
                records = peer.records if mode.startswith('local') else target.records
                deadline = time.monotonic() + 3
                while len(records) < 2 and time.monotonic() < deadline:
                    time.sleep(.01)
                assert records == [{'command': c, 'bytes': len(PAYLOAD), 'sha256': hashlib.sha256(PAYLOAD).hexdigest()} for c in ('F', 'H')], records
                case.update(response_bytes_each=len(RESPONSE), request_bytes_each=len(PAYLOAD), directions=['socket EOF before response', 'channel EOF before request tail'])
            else:
                with socket.create_connection(('127.0.0.1', port), 4) as sock:
                    sock.settimeout(3)
                    try:
                        sock.sendall(b'failed-target')
                        assert not sock.recv(1)
                    except (ConnectionResetError, BrokenPipeError):
                        pass
                failed = wait_status(controls / 'status.json', lambda s: s['failure'] != 'none', child)
                assert failed['phase'] == 'running', failed
                if mode == 'remote-recovery':
                    # Restore the same target address, preserving the active rule.
                    target = Echo(target_port)
                with socket.create_connection(('127.0.0.1', port), 4) as sock:
                    sock.settimeout(4)
                    sock.sendall(PAYLOAD)
                    assert recv_exact(sock, len(PAYLOAD)) == PAYLOAD
                recovered = wait_status(controls / 'status.json', lambda s: s['failure'] == 'none', child)
                case.update(failed=failed, recovered=recovered)
        (controls / 'stop').write_text('stop\n')
        child.wait(8)
        assert child.returncode == 0, (controls / 'runner.log').read_text()
        native = json.loads((controls / 'runner-report.json').read_text())
        assert native['tty_after_forward_stop'] and native['forward_cleanup_released'] and native['parent_cleanup_released'], native
        if mode == 'remote-cancel':
            assert not (controls / 'ready.json').exists(), 'cancelled start published ready'
            assert peer.remote_cancelled.wait(2)
        assert len(peer.connections) == 1
        case.update(passed=True, native=native)
        return case
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        log.close()
        if target:
            target.close()
        peer.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runner', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    modes = ('local-half-close', 'remote-half-close', 'local-recovery', 'remote-recovery', 'remote-cancel', 'remote-timeout')
    parser.add_argument('--mode', choices=modes)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    results = []
    try:
        for mode in (args.mode,) if args.mode else modes:
            result = run(args.runner.resolve(), args.out.resolve(), mode)
            results.append(result)
            print(json.dumps({'mode': mode, 'passed': result['passed']}), flush=True)
    finally:
        (args.out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
