#!/usr/bin/env python3
"""Original domain FileBindingHost -> production bounded AI capture -> RAM SFTP.

The peer is owned localhost, permits only read-only SFTP, and creates no files.
This proves the reader/service slice, not the main SSH adapter or native picker.
"""
import argparse
import base64
import hashlib
import json
import logging
from pathlib import Path
import shutil
import socket
import subprocess
import threading
import time

import paramiko
import sftp_readonly as fixture

logging.getLogger("paramiko").setLevel(logging.CRITICAL)
original_data = fixture.data


def data(path):
    if path == "/large":
        return b"A" * 70000
    if path == "/exact":
        return b"E" * 65536
    return original_data(path)


fixture.data = data


def run_case(binary, mode, directory, key):
    state = fixture.State()
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(8)
    transports, channels, errors = [], [], []
    closed = threading.Event()

    def serve():
        try:
            connection, _ = listener.accept()
            transport = paramiko.Transport(connection)
            transports.append(transport)
            transport.add_server_key(key)
            transport.set_subsystem_handler("sftp", paramiko.SFTPServer, fixture.Files)
            transport.start_server(server=fixture.Server(state))
            while transport.is_active():
                channel = transport.accept(0.01)
                if channel is not None:
                    channels.append(channel)
            closed.set()
        except (EOFError, ConnectionResetError, BrokenPipeError):
            closed.set()
        except Exception as error:
            errors.append(type(error).__name__ + ": " + str(error))

    server = threading.Thread(target=serve, daemon=True)
    server.start()
    folder = directory / mode
    folder.mkdir()
    store = folder / "known_hosts"
    command = [str(binary), mode, str(store), fingerprint, str(listener.getsockname()[1])]
    start = time.monotonic()
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output = []

    def consume():
        for line in process.stdout:
            output.append(line)
            if "CANCEL_ACCEPTED_WHILE_READ_BLOCKED" in line:
                state.cancel_accepted.set()

    consumer = threading.Thread(target=consume, daemon=True)
    consumer.start()
    blocked = mode.removeprefix("aux-") in ("cancel", "late-source", "member-removed", "close-pending")
    gate_ok = True
    if blocked:
        gate_ok = state.read_entered.wait(8)
        if gate_ok:
            process.stdin.write("C")
            process.stdin.flush()
            gate_ok = state.cancel_accepted.wait(2)
        state.read_release.set()
    try:
        code = process.wait(timeout=25)
    except subprocess.TimeoutExpired:
        process.kill()
        code = process.wait()
    consumer.join(2)
    peer_released = closed.wait(2)
    for transport in transports:
        transport.close()
    listener.close()
    server.join(2)
    text = "".join(output)
    (folder / "runner.log").write_text(text)
    handles_closed = sorted(state.opens) == sorted(state.closes)
    passed = code == 0 and "PASS " in text and gate_ok and peer_released and handles_closed and not errors and not state.errors and not state.writes and state.shells == 0 and state.execs == 0 and not store.exists()
    return {"case": mode, "passed": passed, "exit_code": code, "elapsed_ms": round((time.monotonic() - start) * 1000),
            "real_blocked_read_cancel_gate": gate_ok if blocked else None, "native_peer_released_before_forced_cleanup": peer_released,
            "reads_opened": state.opens, "reads_closed": state.closes, "read_handles_closed": handles_closed,
            "no_remote_write": not state.writes, "no_shell_exec": state.shells == 0 and state.execs == 0,
            "isolated_known_hosts_unchanged": not store.exists(), "errors": errors + state.errors, "runner_output": text}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--close-pending-only", action="store_true", help="Run only the two pending picker-close lifecycle regressions")
    args = parser.parse_args()
    directory = args.output_dir.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    binary = directory / "ai-remote-file-frozen"
    shutil.copy2(args.runner.resolve(), binary)
    key = paramiko.RSAKey.generate(2048)
    modes = ("close-pending",) if args.close_pending_only else ("bounds", "cancel", "late-source", "member-removed", "queued-cancel", "oom")
    cases = [run_case(binary, prefix + mode, directory, key) for prefix in ("", "aux-") for mode in modes]
    report = {"passed": all(case["passed"] for case in cases), "scope": "Production AI Reader + FileBindingHost + SourceFactory + readonly SFTP against owned RAM-only 127.0.0.1 server",
              "limits": ["Fixture lifecycle adapter supplies original domain session; aux-* cases exercise production SSH readonly reservation, real native readiness, FileBindingHost and cleanup. Native picker UI and shared SSH worker are separate evidence.",
                         "No UI, AI endpoint, external/user host, shell, exec, remote write, or local file pretending to be remote."],
              "runner_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "cases": cases}
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    for case in cases:
        print(case["case"], "PASS" if case["passed"] else "FAIL")
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
