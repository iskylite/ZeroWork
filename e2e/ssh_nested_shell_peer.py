#!/usr/bin/env python3
"""Isolated real-PTY SSH peer for native nested-shell acceptance."""
import argparse
import json
import re
from pathlib import Path
import signal
import threading
from ssh_shell_execution_loopback import Fixture

parser = argparse.ArgumentParser()
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--nested-ssh', action='store_true')
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=True)
home = args.out / 'home'
home.mkdir()
fixture = Fixture('/bin/zsh', 'nested' if args.nested_ssh else 'nominal', str(home))
stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
(args.out / 'ready.json').write_text(json.dumps({'port': fixture.port, 'user': 'shell-fixture', 'password': 'fixture-only'}))
try:
    while not stop.wait(.05):
        frames = re.findall(rb"\x1b\]133;P;zw_hello=[^\x07]*;zw_ctx=([0-9a-f]{32})", bytes(fixture.outputs))
        contexts = list(dict.fromkeys(frame.decode() for frame in frames))
        (args.out / 'state.json').write_text(json.dumps({'contexts': contexts}))
finally:
    fixture.close()
    (args.out / 'report.json').write_text(json.dumps({'actions': fixture.actions, 'errors': fixture.errors}))
