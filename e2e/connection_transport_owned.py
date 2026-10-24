#!/usr/bin/env python3
"""Production libssh2 facade: 1/2/8 SSH nodes, two owners, concurrent streams.
Owned loopback peers do not execute commands or allocate a PTY/shell. The final
TCP destination is an echo service, and never an extra authenticated SSH node.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import socketserver
import threading
import time
from shared_forward import Peer


def run(runner, count):
    peers = [Peer() for _ in range(count)]
    class Echo(socketserver.BaseRequestHandler):
        def handle(self):
            try:
                while True:
                    block = self.request.recv(32768)
                    if not block:
                        break
                    self.request.sendall(block)
            except OSError:
                pass
    class Server(socketserver.ThreadingTCPServer):
        daemon_threads = True
    direct = Server(('127.0.0.1', 0), Echo) if count == 0 else None
    if direct:
        threading.Thread(target=direct.serve_forever, daemon=True).start()
    for index, peer in enumerate(peers):
        if index + 1 < count:
            peer.next_endpoint = ('127.0.0.1', peers[index + 1].port)
        peer.thread.start()
    try:
        environment = dict(os.environ, ZEROWORK_TRANSPORT_HOST='127.0.0.1',
                           ZEROWORK_TRANSPORT_PORT=str(peers[0].port if peers else 22),
                           ZEROWORK_TRANSPORT_USER='shared-fixture',
                           ZEROWORK_TRANSPORT_PASSWORD='shared-secret',
                           ZEROWORK_TRANSPORT_EXTRA_PORTS=','.join(str(p.port) for p in peers[1:]),
                           ZEROWORK_TRANSPORT_DESTINATION='shared.fixture',
                           ZEROWORK_TRANSPORT_DESTINATION_PORT='4242')
        environment.pop('ZEROWORK_TRANSPORT_KEY', None)
        environment.pop('ZEROWORK_TRANSPORT_DIRECT', None)
        if direct:
            environment.update(ZEROWORK_TRANSPORT_DIRECT='1',
                               ZEROWORK_TRANSPORT_DESTINATION='127.0.0.1',
                               ZEROWORK_TRANSPORT_DESTINATION_PORT=str(direct.server_address[1]))
        child = subprocess.run([str(runner), 'fixture'], env=environment,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, timeout=90)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and any(not c.closed.is_set() for p in peers for c in p.connections):
            time.sleep(.02)
        observations = []
        for index, peer in enumerate(peers):
            assert len(peer.connections) == 2, (index, len(peer.connections), child.stdout)
            for connection in peer.connections:
                assert 'pty' not in connection.calls and 'shell' not in connection.calls
                assert 'UNEXPECTED_EXEC' not in connection.calls
                assert connection.closed.is_set(), (index, connection.calls, child.stdout)
                if index + 1 < count:
                    assert connection.calls.count({'direct': ['127.0.0.1', peers[index + 1].port]}) == 1
                else:
                    assert connection.calls.count({'direct': ['shared.fixture', 4242]}) in (2, 3)
            observations.append({'ssh_node': index, 'native_connections': 2,
                                 'closed_before_fixture_cleanup': True,
                                 'shell_requests': 0, 'exec_requests': 0})
        assert child.returncode == 0, child.stdout
        return {'ssh_nodes': count, 'tcp_destination_extra_ssh_login': False,
                'runner_output': child.stdout, 'peers': observations}
    finally:
        for peer in peers:
            peer.stop()
        if direct:
            direct.shutdown()
            direct.server_close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runner', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    reports = [run(args.runner.resolve(), count) for count in (0, 1, 2, 8)]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({'kind': 'owned_loopback_libssh2', 'real_remote': False,
                                    'passed': True, 'routes': reports}, indent=2))
    print(json.dumps({'passed': True, 'ssh_node_counts': [0, 1, 2, 8],
                      'owners_per_route': 2, 'streams_per_owner': 2,
                      'report': str(args.out)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
