#!/usr/bin/env python3
"""Owned PTY + SFTP + 16 active forwards + one exhausted-window forward."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import threading
import time
import traceback
import paramiko
import shared_forward as shared


class Files(paramiko.SFTPServerInterface):
    def __init__(self, server):
        super().__init__(server)
        self.peer = server.peer

    def stat(self, path):
        attrs = paramiko.SFTPAttributes()
        if path == '/':
            attrs.st_mode = stat.S_IFDIR | 0o755
            attrs.st_size = 0
        elif path in self.peer.files:
            attrs.st_mode = stat.S_IFREG | 0o644
            attrs.st_size = len(self.peer.files[path])
        else:
            return paramiko.SFTP_NO_SUCH_FILE
        return attrs
    lstat = stat

    def open(self, path, flags, attr):
        if flags & os.O_CREAT:
            self.peer.files.setdefault(path, bytearray())
        if path not in self.peer.files:
            return paramiko.SFTP_NO_SUCH_FILE
        if flags & os.O_TRUNC:
            self.peer.files[path] = bytearray()
        owner = self
        class Handle(paramiko.SFTPHandle):
            def stat(self):
                return owner.stat(path)
            def read(self, offset, length):
                time.sleep(.015)  # real native EAGAIN, while siblings keep moving
                owner.peer.read_calls += 1
                return bytes(owner.peer.files[path][offset:offset+length])
            def write(self, offset, data):
                time.sleep(.015)
                owner.peer.files[path][offset:offset+len(data)] = data
                return paramiko.SFTP_OK
        return Handle(flags)


class Connection(shared.Connection):
    def check_channel_subsystem_request(self, channel, name):
        self.channels[channel.get_id()] = 'sftp'
        result = super().check_channel_subsystem_request(channel, name)
        self.started.add(channel.get_id())
        return result

    def echo(self, channel):
        # accept() can run before the later shell/subsystem request arrives.
        while channel.get_id() not in self.started and self.transport.is_active():
            time.sleep(.001)
        if self.channels.get(channel.get_id()) == 'sftp':
            return
        if self.channels.get(channel.get_id()) == 'blocked':
            self.peer.blocked_channel = channel
            return  # never consume input: exhaust the advertised window
        if self.channels.get(channel.get_id()) == 'forward':
            channel.settimeout(.1)
            try:
                while self.transport.is_active():
                    try:
                        block = channel.recv(32768)
                    except socket.timeout:
                        continue
                    if not block:
                        return  # peer CLOSE handler owns close acknowledgement
                    channel.sendall(block)
            except (OSError, EOFError):
                return
        return super().echo(channel)

    def __init__(self, peer):
        super().__init__(peer)
        self.started = set()

    def check_channel_shell_request(self, channel):
        result = super().check_channel_shell_request(channel)
        self.started.add(channel.get_id())
        return result

    def check_channel_exec_request(self, channel, command):
        self.started.add(channel.get_id())
        return super().check_channel_exec_request(channel, command)

    def check_channel_direct_tcpip_request(self, channel_id, origin, target):
        self.transport.mixed_owner = self
        if target == ('blocked.fixture', 4242):
            self.channels[channel_id] = 'blocked'
            self.started.add(channel_id)
            return paramiko.OPEN_SUCCEEDED
        result = super().check_channel_direct_tcpip_request(channel_id, origin, target)
        self.started.add(channel_id)
        return result

# Scope monkeypatches to this standalone process, retaining the existing fixture.
original_transport = paramiko.Transport
class Transport(original_transport):
    def __init__(self, *args, **kwargs):
        kwargs["default_window_size"] = 32768
        super().__init__(*args, **kwargs)
        self.set_subsystem_handler('sftp', paramiko.SFTPServer, Files)
        handlers = dict(self._channel_handler_table)
        original_close = handlers[97]
        self.first_close_held = False
        self.holding_close = False
        self.sibling_closes_during_hold = 0
        def close(channel, message):
            owner = getattr(self, 'mixed_owner', None)
            if owner and owner.channels.get(channel.get_id()) == 'forward':
                if not self.first_close_held:
                    self.first_close_held = True
                    self.holding_close = True
                    def release():
                        original_close(channel, message)
                        self.holding_close = False
                    timer = threading.Timer(.3, release)
                    owner.peer.workers.append(timer)
                    timer.start()
                    return
                if self.holding_close:
                    self.sibling_closes_during_hold += 1
            original_close(channel, message)
        handlers[97] = close
        self._channel_handler_table = handlers
paramiko.Transport = Transport
shared.Connection = Connection


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runner', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    peer = shared.Peer()
    peer.files = {'/source.bin': bytearray(b'D' * (8 * 1024 * 1024))}
    peer.read_calls = 0
    peer.blocked_channel = None
    peer.thread.start()
    fingerprint = 'SHA256:' + base64.b64encode(hashlib.sha256(peer.key.asbytes()).digest()).decode().rstrip('=')
    log = (out / 'runner.log').open('w')
    child = subprocess.Popen([str(args.runner.resolve()), 'mixed', str(out), fingerprint, str(peer.port)], stdout=log, stderr=subprocess.STDOUT)
    report = {'passed': False}
    workers = []
    stop = threading.Event()
    errors = []
    latencies = []
    counts = [0] * 16
    blocked = None
    try:
        ready = shared.wait_file(out / 'ready.json', child)
        blocked = socket.create_connection(('127.0.0.1', ready['local_port']), timeout=4)
        blocked.sendall(bytes([5, 1, 0]))
        assert shared.recv_exact(blocked, 2) == bytes([5, 0])
        name = b'blocked.fixture'
        blocked.sendall(bytes([5, 1, 0, 3, len(name)]) + name + (4242).to_bytes(2, 'big'))
        assert shared.recv_exact(blocked, 10)[1] == 0
        blocked.sendall(b'B' * (128 * 1024))
        def exchange(index):
            try:
                with shared.connect_proxy(ready['local_port']) as client:
                    payload = bytes([index]) * 2048
                    while not stop.is_set():
                        start = time.monotonic()
                        client.sendall(payload)
                        assert shared.recv_exact(client, len(payload)) == payload
                        latencies.append((time.monotonic() - start) * 1000)
                        counts[index] += 1
                        time.sleep(.02)
            except Exception as error:
                errors.append(repr(error))
        workers = [threading.Thread(target=exchange, args=(i,)) for i in range(16)]
        for worker in workers:
            worker.start()
        time.sleep(3)
        stop.set()
        for worker in workers:
            worker.join(5)
        assert not errors and not any(worker.is_alive() for worker in workers), errors
        assert all(count >= 20 for count in counts), counts
        assert max(latencies) < 500, 'forward stalled for more than 500 ms'
        assert peer.blocked_channel is not None and len(peer.blocked_channel.in_buffer) == 32768, 'remote window was not exhausted'
        assert peer.read_calls > 0 and peer.files.get('/upload.bin') == b'U' * (256 * 1024)
        (out / 'stop').write_text('stop')
        assert child.wait(timeout=10) == 0, 'runner failed; see runner.log'
        mixed = json.loads((out / 'mixed-report.json').read_text())
        final = json.loads((out / 'runner-report.json').read_text())
        assert mixed['eagain_count'] > 0 and mixed['cancel_released'] and mixed['sftp_released']
        assert final['stop_ms'] < 1000, 'mixed cancellation exceeded one second'
        assert final['tty_after_forward_stop'] and final['parent_cleanup_released'] and final['active'] == 0
        assert len(peer.connections) == 1 and peer.connections[0].calls.count('auth') == 1
        assert not list(out.glob('*.part'))
        independent_closes = peer.connections[0].transport.sibling_closes_during_hold
        assert independent_closes > 0, 'sibling closes blocked by one withheld acknowledgement'
        check = socket.socket()
        check.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        check.bind(('127.0.0.1', ready['local_port']))
        check.close()
        report.update(passed=True, clients=16, exchanges=counts, forward_p95_ms=sorted(latencies)[int(len(latencies)*.95)], forward_max_ms=max(latencies), transfer=mixed, worker=final, sibling_closes_during_withheld_ack=independent_closes, zero_window_cancel_released=True, upload_exact=True, partial_files_removed=True, port_rebound=True)
    except Exception as error:
        report['error'] = repr(error)
        report['traceback'] = traceback.format_exc()
        report['peer_read_calls'] = peer.read_calls
        report['peer_upload_bytes'] = len(peer.files.get('/upload.bin', b''))
        report['exchanges'] = counts
    finally:
        stop.set()
        if child.poll() is None:
            child.kill()
        child.wait()
        if blocked:
            blocked.close()
        peer.stop()
        for worker in workers:
            worker.join(5)
        log.close()
    (out / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1

if __name__ == '__main__':
    raise SystemExit(main())
