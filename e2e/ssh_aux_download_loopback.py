#!/usr/bin/env python3
"""Loopback SSH terminal + separate read-only SFTP connections for native UI.

The single original terminal is a protocol fixture, not a subprocess. SFTP uses
our existing immutable conflict peer. No user VM, shell command, write, PTY on
an auxiliary connection, or external host is used by this fixture.
"""
import argparse
import base64
import hashlib
import json
import logging
from pathlib import Path
import signal
import socket
import threading
import time
import uuid

import paramiko
import sftp_conflict_loopback as file_fixture
from sftp_conflict_loopback import State as FileState, Server as FileServer, Files, PAYLOAD, REMOTE, USER, PASSWORD

logging.getLogger("paramiko").setLevel(logging.CRITICAL)
TERMINAL_INPUT_LIMIT = 4096


class State(FileState):
    def __init__(self, output):
        super().__init__(output)
        self.terminal_connection = None
        self.terminal_channel = None
        self.shell_requests = []
        self.pty_requests = []
        self.clipboard_sentinel = "ZW_CLIP_SSH_" + uuid.uuid4().hex[:12]
        self.terminal_received = bytearray()
        self.terminal_received_total = 0

    def snapshot(self):
        with self.lock:
            return {**super().snapshot(), "terminal_connection": self.terminal_connection,
                    "terminal_channel": self.terminal_channel, "shell_requests": list(self.shell_requests),
                    "pty_requests": list(self.pty_requests), "clipboard_sentinel": self.clipboard_sentinel,
                    "terminal_received_hex": self.terminal_received.hex(),
                    "terminal_received_total": self.terminal_received_total,
                    "terminal_received_truncated": self.terminal_received_total > TERMINAL_INPUT_LIMIT}


class Server(FileServer):
    def check_channel_pty_request(self, channel, term, width, height, pixelwidth, pixelheight, modes):
        with self.state.lock:
            accepted = not self.state.pty_requests
            item = {"connection": self.connection, "channel": channel.get_id(), "accepted": accepted,
                    "term": term.decode("ascii", "replace"), "width": width, "height": height}
            self.state.pty_requests.append(item)
        self.state.record(self.connection, "PTY", **{k: v for k, v in item.items() if k != "connection"})
        return accepted

    def check_channel_shell_request(self, channel):
        with self.state.lock:
            accepted = not self.state.shell_requests
            item = {"connection": self.connection, "channel": channel.get_id(), "accepted": accepted}
            self.state.shell_requests.append(item)
            if accepted:
                self.state.terminal_connection = self.connection
                self.state.terminal_channel = channel.get_id()
        self.state.record(self.connection, "SHELL", channel=channel.get_id(), accepted=accepted)
        if not accepted:
            return False

        def terminal():
            try:
                # Send after the actual SSH shell-request acknowledgement.
                time.sleep(0.01)
                # A run-unique visible line proves selection/copy/paste cannot
                # accidentally reuse another run's clipboard contents.
                banner = ("ZW_AUX_SOURCE_READY\r\n" + self.state.clipboard_sentinel +
                          "\r\n\x1b]7;file://localhost/fixture\x07fixture@loopback:/fixture $ ").encode("ascii")
                channel.sendall(banner)
                channel.settimeout(0.1)
                while not self.state.stopping.is_set() and not channel.closed:
                    try:
                        data = channel.recv(4096)
                    except socket.timeout:
                        continue
                    if not data:
                        break
                    with self.state.lock:
                        self.state.terminal_received_total += len(data)
                        remaining = max(0, TERMINAL_INPUT_LIMIT - len(self.state.terminal_received))
                        captured = data[:remaining]
                        self.state.terminal_received.extend(captured)
                    self.state.record(self.connection, "TERMINAL_INPUT", channel=channel.get_id(),
                                      bytes=len(data), hex=captured.hex(), truncated=len(captured) != len(data))
            except (EOFError, OSError, paramiko.SSHException):
                pass
            finally:
                self.state.record(self.connection, "TERMINAL_CLOSED", channel=channel.get_id())

        worker = threading.Thread(target=terminal, daemon=True)
        worker.start()
        return True

    def check_channel_window_change_request(self, channel, width, height, pixelwidth, pixelheight):
        self.state.record(self.connection, "WINDOW_CHANGE", channel=channel.get_id(), width=width, height=height)
        return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--ai-material", action="store_true", help="Use short run-unique UTF-8 content for real AI attachment acceptance")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    if args.self_test and args.prepare_only:
        parser.error("select one mode")
    global PAYLOAD
    file_sentinel = "ZW_REMOTE_FILE_" + uuid.uuid4().hex[:16] if args.ai_material else None
    if file_sentinel:
        PAYLOAD = ("Controlled remote attachment.\nFile sentinel: " + file_sentinel + "\n").encode("utf-8")
        file_fixture.PAYLOAD = PAYLOAD
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("use a fresh output directory")
    if args.prepare_only:
        (output / "prepared.json").write_text(json.dumps({"listener_started": False, "native_started": False,
            "remote_path": REMOTE, "size": len(PAYLOAD), "md5": hashlib.md5(PAYLOAD).hexdigest(),
            "sha256": hashlib.sha256(PAYLOAD).hexdigest(), "terminal": "one original synthetic SSH shell",
            "auxiliary": "separate read-only SFTP; shell and exec rejected"}, indent=2) + "\n")
        return
    state = State(output)
    host_key = paramiko.RSAKey.generate(2048)
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(4)
    listener.settimeout(0.1)
    transports, workers = [], []

    def serve(connection, number):
        transport = paramiko.Transport(connection)
        channels = []
        with state.lock:
            transports.append(transport)
            state.connections[number] = {"id": number, "active": True, "peer_closed_before_stop": False}
        try:
            transport.add_server_key(host_key)
            transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files)
            transport.start_server(server=Server(state, number))
            while transport.is_active() and not state.stopping.is_set():
                channel = transport.accept(0.02)
                if channel is not None:
                    channels.append(channel)
            with state.lock:
                state.connections[number]["peer_closed_before_stop"] = not state.stopping.is_set() and not transport.is_active()
        except (EOFError, ConnectionResetError, BrokenPipeError):
            pass
        except Exception as error:
            if not state.stopping.is_set():
                with state.lock:
                    state.errors.append(type(error).__name__ + ": " + str(error))
        finally:
            transport.close()
            with state.lock:
                state.connections[number]["active"] = False
            state.record(number, "CONNECTION_CLOSED")

    def accept():
        while not state.stopping.is_set():
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            number = len(workers) + 1
            worker = threading.Thread(target=serve, args=(connection, number), daemon=True)
            workers.append(worker)
            worker.start()

    accepting = threading.Thread(target=accept, daemon=True)
    accepting.start()
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(host_key.asbytes()).digest()).decode().rstrip("=")
    ready = {"host": "127.0.0.1", "port": listener.getsockname()[1], "user": USER, "password": PASSWORD,
             "remote_path": REMOTE, "source_size": len(PAYLOAD), "source_md5": hashlib.md5(PAYLOAD).hexdigest(),
             "source_sha256": hashlib.sha256(PAYLOAD).hexdigest(), "fingerprint": fingerprint,
             "clipboard_sentinel": state.clipboard_sentinel, "file_sentinel": file_sentinel}
    (output / "ready.json").write_text(json.dumps(ready, indent=2) + "\n")
    (output / "source.bin").write_bytes(PAYLOAD)
    signal.signal(signal.SIGTERM, lambda *_: state.stopping.set())
    signal.signal(signal.SIGINT, lambda *_: state.stopping.set())
    passed = None
    try:
        if args.self_test:
            def connect():
                client = paramiko.SSHClient()
                # Protocol self-test only; the native runner uses real trust-once UI.
                client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
                client.connect("127.0.0.1", port=ready["port"], username=USER, password=PASSWORD,
                               look_for_keys=False, allow_agent=False, timeout=3)
                return client
            original = connect()
            auxiliary = None
            try:
                shell = original.invoke_shell(term="xterm-256color")
                shell.settimeout(3)
                data = b""
                while state.clipboard_sentinel.encode("ascii") not in data:
                    data += shell.recv(4096)
                # Protocol self-test, not native input evidence: verify the
                # bounded recorder observes precisely these SSH bytes and no CR.
                sentinel = state.clipboard_sentinel.encode("ascii")
                shell.sendall(sentinel)
                deadline = time.monotonic() + 3
                while state.snapshot()["terminal_received_total"] < len(sentinel) and time.monotonic() < deadline:
                    time.sleep(0.01)
                assert state.snapshot()["terminal_received_hex"] == sentinel.hex()
                assert state.snapshot()["terminal_received_total"] == len(sentinel)
                assert not state.snapshot()["terminal_received_truncated"]
                auxiliary = connect()
                sftp = auxiliary.open_sftp()
                assert sftp.normalize(".") == "/fixture"
                with sftp.open(REMOTE, "rb") as source:
                    assert source.stat().st_size == len(PAYLOAD)
                    assert source.read() == PAYLOAD
                sftp.close()
            finally:
                if auxiliary:
                    auxiliary.close()
                original.close()
            deadline = time.monotonic() + 3
            while state.snapshot()["active_connections"] and time.monotonic() < deadline:
                time.sleep(0.01)
            result = state.snapshot()
            assert len(result["shell_requests"]) == len(result["pty_requests"]) == 1
            assert len(result["connections"]) == 2
            assert sorted(result["read_handles_opened"]) == sorted(result["read_handles_closed"])
            assert not result["active_connections"] and not result["errors"] and not result["forbidden_operations"]
            passed = True
        else:
            deadline = time.monotonic() + 600
            while not state.stopping.wait(0.1):
                if time.monotonic() >= deadline:
                    state.errors.append("Peer lifetime exceeded 600 seconds")
                    break
                temporary = output / "state.next.json"
                temporary.write_text(json.dumps(state.snapshot(), indent=2) + "\n")
                temporary.replace(output / "state.json")
    finally:
        state.stopping.set()
        listener.close()
        for transport in transports:
            transport.close()
        accepting.join(2)
        for worker in workers:
            worker.join(2)
        result = {"kind": "ssh_terminal_and_readonly_auxiliary_sftp", "self_test_passed": passed,
                  "main_application_started": False, **state.snapshot()}
        (output / "report.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"self_test_passed": passed, "connections": len(result["connections"]), "errors": result["errors"]}))


if __name__ == "__main__":
    main()
