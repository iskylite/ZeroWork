#!/usr/bin/env python3
"""Production host/worker sharing and reconnect against an owned loopback peer."""
import argparse, json, os, subprocess, sys, tempfile, time
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('--runner', required=True)
p.add_argument('--output', required=True)
p.add_argument('--jump', action='store_true')
p.add_argument('--scenario', choices=['baseline', 'details', 'reconnect-fallback', 'source-first', 'child-first', 'interleaved', 'simultaneous-live', 'simultaneous-broken', 'close-during-reconnect', 'cancel-open', 'cancel-pty', 'cancel-shell', 'timeout-open', 'timeout-pty', 'timeout-shell', 'eof-loss', 'jump-forwards'], default='baseline')
a = p.parse_args()
out = Path(a.output).resolve(); out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='zw-shared-acceptance-') as directory:
    root = Path(directory)
    peer_log = (out / 'peer.log').open('w')
    peer_command=[sys.executable, str(Path(__file__).with_name('ssh_tab_connections_peer.py')), '--out', str(root / 'peer')]
    if a.scenario.startswith(('cancel-','timeout-')): peer_command+=['--hold-request',a.scenario.split('-',1)[1]]
    if a.scenario=='reconnect-fallback': peer_command+=['--hold-request','open']
    if a.scenario=='eof-loss': peer_command+=['--drop-after-eof']
    peer = subprocess.Popen(peer_command, stdout=peer_log, stderr=subprocess.STDOUT)
    jump = None
    try:
        ready = root / 'peer' / 'ready.json'
        deadline = time.monotonic() + 8
        while not ready.exists() and time.monotonic() < deadline: time.sleep(.02)
        info = json.loads(ready.read_text())
        command = [str(Path(a.runner).resolve()), str(info['port'])]
        if a.jump:
            from ssh_connection_details import Fixture
            import paramiko
            class SharedJump(Fixture):
                def __init__(self, *args, **kwargs):
                    super().__init__(*args, **kwargs)
                    self.forward_ids = set()
                def check_channel_direct_tcpip_request(self, channel_id, origin, destination):
                    result = super().check_channel_direct_tcpip_request(channel_id, origin, destination)
                    if result == paramiko.OPEN_SUCCEEDED: self.forward_ids.add(channel_id)
                    return result
                def channel(self, channel, forwarded):
                    super().channel(channel, channel.get_id() in self.forward_ids)
            jump = SharedJump(paramiko.RSAKey.generate(2048), delay=0, target_port=info['port'])
            jump.thread.start()
            command.append(str(jump.port))
        else:
            command.append('0')
        command.extend([a.scenario, str(root / "peer")])
        result = subprocess.run(command, env={**os.environ, 'ZEROWORK_DATA_DIR':str(root / 'data')}, capture_output=True, text=True, timeout=60)
        (out / 'runner.log').write_text(result.stderr + result.stdout)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            connections = list((root / 'peer').glob('connection-*.json'))
            closed = list((root / 'peer').glob('closed-*.json'))
            if len(connections) == len(closed) and (jump is None or jump.transport is not None and not jump.transport.is_active()): break
            time.sleep(.02)
        shells = [json.loads(path.read_text()) for path in (root / 'peer').glob('shell-*.json')]
        if a.scenario == 'baseline':
            expected_connections, expected_shells = (1, 3) if a.jump else (4, 8)
        elif a.scenario == 'details':
            expected_connections, expected_shells = 1, 4
        elif a.scenario == 'reconnect-fallback':
            expected_connections, expected_shells = 2, 3
        elif a.scenario.startswith(('cancel-', 'timeout-')):
            expected_connections, expected_shells = 1, (2 if a.scenario.endswith(('open','pty')) else 3)
        elif a.scenario=='eof-loss':
            expected_connections,expected_shells=3,4
        elif a.scenario=='jump-forwards':
            expected_connections,expected_shells=8,4
        elif a.scenario == 'simultaneous-broken':
            expected_connections, expected_shells = 5, 8
        else:
            expected_connections, expected_shells = 1, (6 if a.scenario == 'simultaneous-live' else 4)
        report = dict(scenario=a.scenario, exit_code=result.returncode, connections=len(connections), closed=len(closed), shells=shells, passed=result.returncode == 0 and len(connections) == expected_connections and len(closed) == expected_connections and (5 <= len({s['pid'] for s in shells}) <= 6 if a.scenario == 'close-during-reconnect' else len({s['pid'] for s in shells}) == expected_shells))
        if a.scenario.startswith(('cancel-','timeout-')):
            report['held_request'] = json.loads((root/'peer'/'held-request.json').read_text())
            if a.scenario.endswith('open'): report['passed'] = report['passed'] and (root/'peer'/'released-request.json').exists()
        if a.scenario=='eof-loss':
            report['passed'] = report['passed'] and (root/'peer'/'held-eof-close.json').exists() and 'Session is NULL' not in result.stderr
        if jump is not None:
            report.update(jump_calls=jump.calls, jump_errors=jump.errors, jump_transport_closed=jump.transport is not None and not jump.transport.is_active())
            report['passed'] = report['passed'] and report['jump_transport_closed'] and jump.calls.count('direct-tcpip') == (8 if a.scenario=='jump-forwards' else 1) and not jump.errors
        (out / 'report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report))
        if not report['passed']: sys.exit(1)
    finally:
        if jump is not None: jump.stop()
        peer.terminate()
        try: peer.wait(timeout=8)
        except subprocess.TimeoutExpired: peer.kill(); peer.wait()
        peer_log.close()
