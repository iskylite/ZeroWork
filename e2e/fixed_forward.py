#!/usr/bin/env python3
"""Real local/remote/SOCKS traffic on one production SSH owner + PTY.
Uses owned loopback Paramiko peers only. Does not run a shell command.
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
from shared_forward import Peer, Connection, wait_file, connect_proxy, recv_exact


def relay(sock, channel):
    def pump(source, target):
        try:
            while True:
                data = source.recv(32768)
                if not data:
                    break
                target.sendall(data)
        except (OSError, EOFError, paramiko.SSHException):
            pass
        finally:
            try:
                target.shutdown(socket.SHUT_WR)
            except (OSError, AttributeError, paramiko.SSHException):
                pass
    worker = threading.Thread(target=pump, args=(sock, channel), daemon=True)
    worker.start()
    pump(channel, sock)
    sock.close()
    channel.close()
    worker.join(2)


def remote_listen(self, address, port):
    self.calls.append({'remote-listen': [address, port]})
    if self.peer.deny_remote:
        return 0
    listener = socket.socket()
    try:
        listener.bind((address, port))
        listener.listen(8)
    except OSError:
        listener.close()
        return 0
    listener.settimeout(.05)
    actual = listener.getsockname()[1]
    self.forward_listener = listener
    self.forward_actual = actual
    def accept():
        while self.transport.is_active() and not self.peer.stop_flag.is_set():
            try:
                client, origin = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            try:
                channel = self.transport.open_forwarded_tcpip_channel(origin, (address, actual))
            except (EOFError, OSError, paramiko.SSHException):
                client.close()
                continue
            thread = threading.Thread(target=relay, args=(client, channel), daemon=True)
            self.peer.workers.append(thread)
            thread.start()
    thread = threading.Thread(target=accept, daemon=True)
    self.peer.workers.append(thread)
    thread.start()
    return actual


def remote_cancel(self, address, port):
    self.calls.append({'remote-cancel': [address, port]})
    if getattr(self, 'forward_listener', None):
        self.forward_listener.close()
        self.forward_listener = None
    self.peer.remote_cancelled.set()


Connection.check_port_forward_request = remote_listen
Connection.cancel_port_forward_request = remote_cancel


class Echo:
    def __init__(self):
        self.socket = socket.socket()
        self.socket.bind(('127.0.0.1', 0))
        self.socket.listen(8)
        self.socket.settimeout(.05)
        self.port = self.socket.getsockname()[1]
        self.stop = threading.Event()
        self.bytes = 0
        self.clients = []
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()
    def accept(self):
        while not self.stop.is_set():
            try:
                client, _ = self.socket.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.clients.append(client)
            threading.Thread(target=self.echo, args=(client,), daemon=True).start()
    def echo(self, client):
        try:
            while not self.stop.is_set():
                data = client.recv(65536)
                if not data:
                    return
                self.bytes += len(data)
                client.sendall(data)
        except OSError:
            pass
        finally:
            client.close()
    def close(self):
        self.stop.set()
        self.socket.close()
        for client in self.clients:
            client.close()
        self.thread.join(1)


def run_mode(runner, out, mode):
    controls = out / mode
    controls.mkdir()
    peer = Peer()
    peer.deny_remote = mode == 'denied'
    peer.remote_cancelled = threading.Event()
    peer.thread.start()
    echo = Echo()
    fingerprint = 'SHA256:' + base64.b64encode(hashlib.sha256(peer.key.asbytes()).digest()).decode().rstrip('=')
    child = subprocess.Popen([str(runner), mode, str(controls), fingerprint, str(peer.port), str(echo.port if mode in ('remote','denied') else 4242)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    result = {'mode': mode, 'passed': False}
    try:
        if mode == 'denied':
            output, _ = child.communicate(timeout=10)
            (controls / 'runner.log').write_text(output)
            assert child.returncode != 0 and 'RemoteForwardListenDenied' in output, output
            assert not (controls / 'ready.json').exists(), 'denied must not publish ready'
            result.update(passed=True, rejection='RemoteForwardListenDenied', false_ready=False)
            return result
        ready = wait_file(controls/'ready.json', child)
        payload = bytes(range(256)) * 513 + b'fixed-forward-payload'
        errors=[]
        def roundtrip():
            client = None
            try:
                client = connect_proxy(ready['local_port']) if mode == 'socks5' else socket.create_connection(('127.0.0.1',ready['local_port']), timeout=4)
                client.settimeout(5)
                client.sendall(payload)
                assert recv_exact(client,len(payload)) == payload
            except Exception as error:
                errors.append(repr(error))
            finally:
                if client:
                    client.close()
        clients=[threading.Thread(target=roundtrip) for _ in range(2)]
        for worker in clients: worker.start()
        for worker in clients: worker.join(7)
        assert not errors and not any(worker.is_alive() for worker in clients), errors
        (controls/'stop').write_text('stop\n')
        output,_=child.communicate(timeout=10)
        (controls/'runner.log').write_text(output)
        assert child.returncode==0,output
        native=json.loads((controls/'runner-report.json').read_text())
        assert native['same_native_session'] and native['tty_after_forward_stop'] and native['forward_cleanup_released']
        assert native['bytes_up']==len(payload)*2 and native['bytes_down']==len(payload)*2,native
        if mode=='remote':
            assert peer.remote_cancelled.wait(2),'server did not observe cancellation'
            assert echo.bytes==len(payload)*2,echo.bytes
        with socket.socket() as probe:
            probe.settimeout(.3)
            assert probe.connect_ex(('127.0.0.1',ready['local_port']))!=0,'listener remained after stop'
        result.update(passed=True,native=native,payload_bytes_each_client=len(payload),clients=2,ssh_connections=len(peer.connections),remote_cancelled=peer.remote_cancelled.is_set(),calls=[connection.calls for connection in peer.connections])
        assert len(peer.connections)==1,'forward opened duplicate SSH transport'
        assert 'UNEXPECTED_EXEC' not in str(result['calls'])
        return result
    finally:
        if child.poll() is None:
            child.kill();child.communicate()
        echo.close();peer.stop()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--runner',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    args.out.mkdir(parents=True,exist_ok=False)
    results=[]
    try:
        for mode in ('local','remote','socks5','denied'):
            result=run_mode(args.runner.resolve(),args.out.resolve(),mode)
            results.append(result)
            print(json.dumps({'mode':mode,'passed':result['passed']}),flush=True)
    finally:
        (args.out/'results.json').write_text(json.dumps({'scope':'owned real SSH loopback, production sole native owner, no GUI/system host','results':results},indent=2)+'\n')
    assert len(results)==4 and all(r['passed'] for r in results)

if __name__=='__main__':main()
