#!/usr/bin/env python3
"""Owned three-peer fixture for serial main-app SOCKS acceptance.

The root operator owns the native window. This fixture only creates loopback SSH
peers, writes an isolated registry, and performs requested SOCKS byte roundtrips.
No remote command is executed: the target PTY is an in-memory echo channel.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import socket
import time

from shared_forward import Peer, connect_proxy
from network_socks_loopback import recv_exact


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    assert not any(out.iterdir()), 'Use a fresh evidence directory'
    peers = [Peer() for _ in range(3)]
    for index, peer in enumerate(peers):
        if index < 2:
            peer.next_endpoint = ('127.0.0.1', peers[index + 1].port)
        peer.thread.start()
    port_socket = socket.socket()
    port_socket.bind(('127.0.0.1', 0))
    socks_port = port_socket.getsockname()[1]
    port_socket.close()
    fingerprint = lambda peer: 'SHA256:' + base64.b64encode(hashlib.sha256(peer.key.asbytes()).digest()).decode().rstrip('=')
    registry = '[registry]\nschema_version=2\nrevision=1\nnext_connection_id=4\nnext_group_id=1\n'
    for index, peer in enumerate(peers):
        registry += f'[[hosts]]\nconnection_id={index + 1}\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={{strict_host_key=true}}\nname="Owned multihop {index + 1}"\nhost="127.0.0.1"\nport={peer.port}\nuser="shared-fixture"\n'
        if index == 2:
            registry += f'route=[1,2]\nsocks_enabled=true\nsocks_port={socks_port}\nsocks_bind="127.0.0.1"\nsocks_auto_start=false\n'
    (out / 'hosts.toml').write_text(registry)
    (out / 'fixture.json').write_text(json.dumps({'peers': [{'index': index, 'port': peer.port, 'fingerprint': fingerprint(peer)} for index, peer in enumerate(peers)], 'target_name': 'Owned multihop 3', 'user': 'shared-fixture', 'password': 'shared-secret', 'socks_port': socks_port, 'scope': 'Owned loopback three-hop PTY echo; no actual shell commands; does not start a native window'}, indent=2))
    results = []
    failure = None
    def snapshot():
        return [{'index': i, 'connections': [{'calls': c.calls, 'shell_bytes': len(c.shell), 'forward_bytes': len(c.forward), 'closed_before_fixture_cleanup': c.closed.is_set()} for c in p.connections]} for i, p in enumerate(peers)]
    try:
        deadline = time.monotonic() + 900
        while not (out / 'finish').exists() and time.monotonic() < deadline:
            request_path = out / 'probe.json'
            if request_path.exists():
                request = json.loads(request_path.read_text())
                request_path.unlink()
                selected = int(request['exit'])
                assert 0 <= selected <= 2
                payload = b'ZW_MULTIHOP_GUI_' + bytes([selected]) + bytes(range(256)) * 128
                before = [sum(len(c.forward) for c in peer.connections) for peer in peers]
                client = connect_proxy(int(request.get('port', socks_port)))
                try:
                    client.sendall(payload)
                    assert recv_exact(client, len(payload)) == payload
                finally:
                    client.close()
                after = [sum(len(c.forward) for c in peer.connections) for peer in peers]
                deltas = [a - b for a, b in zip(after, before)]
                passed = deltas == [len(payload) if i == selected else 0 for i in range(3)]
                result = {'passed': passed, 'selected_exit': selected, 'payload_bytes': len(payload), 'payload_sha256': hashlib.sha256(payload).hexdigest(), 'actual_peer_byte_deltas': deltas}
                results.append(result)
                (out / 'probe-result.json').write_text(json.dumps(result, indent=2))
                assert passed, result
            snapshot_request = out / 'snapshot-request'
            if snapshot_request.exists():
                snapshot_request.unlink()
                (out / 'snapshot.json').write_text(json.dumps({'peers': snapshot(), 'fixture_alive': True}, indent=2))
            disconnect = out / 'disconnect'
            if disconnect.exists():
                disconnect.unlink()
                assert peers[0].connections
                peers[0].connections[-1].transport.close()
                (out / 'disconnected.json').write_text(json.dumps({'explicit_owned_first_transport_close': True}))
            time.sleep(.025)
    except Exception as error:
        failure = {'type': type(error).__name__, 'message': str(error)}
        (out / 'probe-result.json').write_text(json.dumps({'passed': False, 'error': failure, 'peers_before_fixture_cleanup': snapshot()}, indent=2))
    finally:
        # Persist real state before teardown even when a probe is interrupted.
        (out / 'peer-report.json').write_text(json.dumps({'probes': results, 'peers': snapshot(), 'failure': failure, 'normal_finish_requested': (out / 'finish').exists()}, indent=2))
        for peer in peers:
            peer.stop()


if __name__ == '__main__':
    main()
