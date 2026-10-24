#!/usr/bin/env python3
"""Real production libssh2 + SOCKS controlled localhost byte/stop check.

No GUI, shell, exec, remote files or external endpoint is involved. The peer
accepts only one exact in-memory target and all bytes are bounded.
"""
import argparse
import base64
import hashlib
import json
import logging
from pathlib import Path
import socket
import subprocess
import threading
import time
import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)

class Peer(paramiko.ServerInterface):
    def __init__(self, key, scenario="single"):
        self.key = key
        self.scenario = scenario
        self.lock = threading.Lock()
        self.workers = []
        self.channels = []
        self.by_channel = {}
        self.open_entered = threading.Event()
        self.release_open = threading.Event()
        self.blocked_ids = set()
        self.blocked_buffered = threading.Event()
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(0.1)
        self.port = self.listener.getsockname()[1]
        self.finished = threading.Event()
        self.closed = threading.Event()
        self.transport = None
        self.calls = []
        self.received = bytearray()
        self.errors = []
        self.thread = threading.Thread(target=self.serve, daemon=True)
    def get_allowed_auths(self, user):
        return 'password'
    def check_auth_password(self, user, password):
        self.calls.append('password')
        return paramiko.AUTH_SUCCESSFUL if (user, password) == ('socks-fixture', 'local-controlled-only') else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, channel_id):
        self.calls.append({'unexpected_channel': kind})
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_direct_tcpip_request(self, channel_id, origin, destination):
        self.calls.append({'direct': list(destination)})
        if destination == ('socks.fixture', 4244):
            self.blocked_ids.add(channel_id)
        self.open_entered.set()
        if self.scenario == 'open-stop':
            self.release_open.wait(5)
        return paramiko.OPEN_SUCCEEDED if destination in [('socks.fixture', 4242), ('socks.fixture', 4244)] else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def serve(self):
        channel = None
        try:
            while not self.finished.is_set():
                try:
                    connection, _ = self.listener.accept()
                    break
                except socket.timeout:
                    pass
            else:
                return
            self.transport = paramiko.Transport(connection)
            if self.scenario == 'close-stop':
                handlers = dict(self.transport._channel_handler_table)
                handlers[97] = lambda channel, message: self.calls.append('close_ack_withheld')
                self.transport._channel_handler_table = handlers
            self.transport.add_server_key(self.key)
            self.transport.start_server(server=self)
            while self.transport.is_active() and not self.finished.is_set():
                channel = self.transport.accept(0.05)
                if channel is None:
                    continue
                self.channels.append(channel)
                worker = threading.Thread(target=self.echo, args=(channel,), daemon=True)
                self.workers.append(worker)
                worker.start()
                channel = None
            if not self.transport.is_active():
                self.closed.set()
        except (EOFError, ConnectionResetError, BrokenPipeError, paramiko.SSHException):
            self.closed.set()
        except Exception as error:
            self.errors.append(type(error).__name__)
        finally:
            if channel:
                channel.close()
            if self.transport:
                self.transport.close()
    def echo(self, channel):
        channel.settimeout(0.1)
        received = bytearray()
        try:
            if channel.get_id() in self.blocked_ids:
                while self.transport.is_active() and not self.finished.is_set():
                    if len(channel.in_buffer) >= 2 * 1024 * 1024 - 32768:
                        self.blocked_buffered.set()
                    time.sleep(0.005)
                return
            while self.transport.is_active() and not self.finished.is_set():
                try:
                    data = channel.recv(4096)
                except socket.timeout:
                    continue
                if not data:
                    break
                received.extend(data)
                if len(received) > 2 * 1024 * 1024:
                    raise ValueError('UnexpectedUnboundedPayload')
                with self.lock:
                    self.received.extend(data)
                channel.sendall((b'ECHO:' if self.scenario == 'single' else b'') + data)
        except (EOFError, ConnectionResetError, BrokenPipeError, paramiko.SSHException, socket.timeout):
            pass
        except Exception as error:
            self.errors.append(type(error).__name__)
        finally:
            with self.lock:
                self.by_channel[str(channel.get_id())] = {'bytes': len(received), 'sha256': hashlib.sha256(received).hexdigest()}
            channel.close()

    def disconnect(self):
        if self.transport:
            self.transport.close()
    def stop(self):
        self.finished.set()
        self.release_open.set()
        self.listener.close()
        self.disconnect()
        self.thread.join(2)
        for worker in self.workers:
            worker.join(2)

def recv_exact(client, length):
    result = bytearray()
    while len(result) < length:
        data = client.recv(length - len(result))
        if not data:
            raise EOFError('ShortResponse')
        result.extend(data)
    return bytes(result)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runner', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--scenario', choices=['single', 'multi', 'open-stop', 'close-stop', 'fair'], default='single')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    controls = out / 'controls'
    controls.mkdir()
    peer = Peer(paramiko.RSAKey.generate(2048), args.scenario)
    fp = 'SHA256:' + base64.b64encode(hashlib.sha256(peer.key.asbytes()).digest()).decode().rstrip('=')
    peer.thread.start()
    report = {'status': 'running', 'scope': 'controlled loopback real SOCKS listener + libssh2; no GUI or external endpoints', 'runner_sha256': hashlib.sha256(args.runner.read_bytes()).hexdigest()}
    log = (out / 'runner.log').open('w')
    child = subprocess.Popen([str(args.runner.resolve()), str(peer.port), fp, str(controls)], stdout=log, stderr=subprocess.STDOUT)
    client = None
    stalled = None
    slow = None
    slow_sender = None
    try:
        deadline = time.monotonic() + 8
        while not (controls / 'ready.json').exists():
            if child.poll() is not None:
                raise RuntimeError('RunnerExitedBeforeReady')
            if time.monotonic() >= deadline:
                raise TimeoutError('RunnerReadyTimeout')
            time.sleep(0.005)
        ready = json.loads((controls / 'ready.json').read_text())
        def open_client(target_port=4242):
            sock = socket.create_connection(('127.0.0.1', ready['local_port']), timeout=4)
            sock.settimeout(4)
            sock.sendall(bytes([5, 1, 0]))
            assert recv_exact(sock, 2) == bytes([5, 0])
            target = b'socks.fixture'
            sock.sendall(bytes([5, 1, 0, 3, len(target)]) + target + target_port.to_bytes(2, 'big'))
            assert recv_exact(sock, 10) == bytes([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
            return sock
        if args.scenario in ('single', 'close-stop'):
            client = socket.create_connection(('127.0.0.1', ready['local_port']), timeout=2)
            client.settimeout(2)
            client.sendall(bytes([5, 1, 0]))
            report['method'] = recv_exact(client, 2).hex()
            target = b'socks.fixture'
            client.sendall(bytes([5, 1, 0, 3, len(target)]) + target + (4242).to_bytes(2, 'big'))
            report['connect_reply'] = recv_exact(client, 10).hex()
            sentinel = b'ZeroWork-real-socks-payload'
            client.sendall(sentinel)
            try:
                response = recv_exact(client, len(sentinel) + (5 if args.scenario == 'single' else 0))
                report['actual_payload_echo'] = response == (b'ECHO:' if args.scenario == 'single' else b'') + sentinel
            except (TimeoutError, socket.timeout, EOFError) as error:
                report['actual_payload_echo'] = False
                report['payload_failure'] = type(error).__name__
            client.close()
            client = None
        elif args.scenario == 'open-stop':
            client = socket.create_connection(('127.0.0.1', ready['local_port']), timeout=2)
            client.settimeout(2)
            client.sendall(bytes([5, 1, 0]))
            assert recv_exact(client, 2) == bytes([5, 0])
            target = b'socks.fixture'
            client.sendall(bytes([5, 1, 0, 3, len(target)]) + target + (4242).to_bytes(2, 'big'))
            assert peer.open_entered.wait(2), 'NoRealPendingOpen'
            report['actual_open_reply_pending_at_stop'] = not peer.release_open.is_set()
            report['actual_payload_echo'] = None
            report['payload_check_applicable'] = False
        else:
            # A deliberately incomplete greeting must not block four real
            # channels, each sending and receiving independent bounded bytes.
            stalled = socket.create_connection(('127.0.0.1', ready['local_port']), timeout=2)
            stalled.sendall(b'\x05')
            if args.scenario == 'fair':
                slow = open_client(4244)
                slow.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 32768)
                def flood():
                    try:
                        slow.sendall(b'X' * (4 * 1024 * 1024))
                    except (OSError, TimeoutError):
                        pass
                slow_sender = threading.Thread(target=flood, daemon=True)
                slow_sender.start()
                assert peer.blocked_buffered.wait(2), 'NoActualSSHWindowBackpressure'
                report['actual_ssh_window_backpressure'] = True
                report['blocked_sender_still_pending_before_fair_clients'] = slow_sender.is_alive()
            clients = [open_client() for _ in range(4)]
            results = [None] * len(clients)
            started = time.monotonic()
            def exchange(index, sock):
                payload = bytes([index + 17]) * (512 * 1024) + bytes(range(256))
                sent_error = []
                def send():
                    try:
                        sock.sendall(payload)
                    except Exception as error:
                        sent_error.append(type(error).__name__)
                sender = threading.Thread(target=send, daemon=True)
                sender.start()
                try:
                    actual = recv_exact(sock, len(payload))
                    sender.join(4)
                    results[index] = {'passed': actual == payload and not sent_error and not sender.is_alive(), 'bytes': len(actual), 'sha256': hashlib.sha256(actual).hexdigest(), 'elapsed_ms': round((time.monotonic() - started) * 1000)}
                except Exception as error:
                    results[index] = {'passed': False, 'failure': type(error).__name__}
                finally:
                    sock.close()
            workers = [threading.Thread(target=exchange, args=(i, sock), daemon=True) for i, sock in enumerate(clients)]
            for worker in workers: worker.start()
            for worker in workers: worker.join(8)
            report['multi_clients'] = results
            report['actual_payload_echo'] = all(item and item['passed'] for item in results)
            # Leave this real accepted greeting stalled when stop is signalled.
            report['incomplete_greeting_did_not_block_channels'] = report['actual_payload_echo']
        (controls / 'stop').write_text('stop owned fixture\n')
        try:
            child.wait(timeout=0.6)
            report['stop_completed_before_peer_disconnect'] = True
        except subprocess.TimeoutExpired:
            report['stop_completed_before_peer_disconnect'] = False
            peer.disconnect()  # Release a stuck native read; never claim app cleanup.
            child.wait(timeout=5)
        if args.scenario == 'open-stop':
            report['open_reply_released_only_after_stop'] = not peer.release_open.is_set()
            peer.release_open.set()
        peer.closed.wait(1)
        report['exit_code'] = child.returncode
        if (controls / 'runner-report.json').exists():
            report['runner'] = json.loads((controls / 'runner-report.json').read_text())
        report['peer'] = {'calls': peer.calls, 'received_hex': bytes(peer.received[:64]).hex(), 'received_bytes': len(peer.received), 'received_sha256': hashlib.sha256(peer.received).hexdigest(), 'channels': peer.by_channel, 'errors': peer.errors, 'closed_before_fixture_stop': peer.closed.is_set()}
        port_probe = socket.socket()
        port_probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        port_probe.bind(('127.0.0.1', ready['local_port']))
        port_probe.close()
        report['local_port_reusable_after_stop'] = True
        report['trust_once_store_unchanged'] = not (controls / 'known_hosts').exists() and not (controls / 'known_hosts.lock').exists()
        report['passed'] = (report.get('actual_open_reply_pending_at_stop') and report.get('open_reply_released_only_after_stop') if args.scenario == 'open-stop' else report['actual_payload_echo']) and report['stop_completed_before_peer_disconnect'] and child.returncode == 0 and not peer.errors and peer.closed.is_set() and report['runner']['active'] == 0 and report['runner']['transport_released'] and report['trust_once_store_unchanged'] and not any(isinstance(call, dict) and 'unexpected_channel' in call for call in peer.calls)
        report['status'] = 'passed' if report['passed'] else 'failed'
    except Exception as error:
        report.update(status='failed', passed=False, error=type(error).__name__ + ': ' + str(error))
    finally:
        if client:
            client.close()
        if stalled:
            stalled.close()
        if slow:
            slow.close()
        if slow_sender:
            slow_sender.join(2)
        peer.stop()
        if child.poll() is None:
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.terminate()
                child.wait(timeout=3)
                report['forced_runner_cleanup'] = True
        log.close()
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(report['status'] + ': ' + str(out / 'report.json'))
    raise SystemExit(0 if report.get('passed') else 1)

if __name__ == '__main__':
    main()
