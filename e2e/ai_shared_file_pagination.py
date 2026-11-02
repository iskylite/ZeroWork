#!/usr/bin/env python3
"""Owned RAM-only SFTP peer for the real shared SSH IO-owner pagination test."""
import argparse
import base64
import hashlib
import json
import logging
import os
from pathlib import Path
import socket
import subprocess
import threading
import paramiko
import sftp_readonly as fixture

logging.getLogger("paramiko").setLevel(logging.CRITICAL)
original_data = fixture.data
fixture.data = lambda path: b"A" * 70000 if path == "/large" else original_data(path)


class Server(fixture.Server):
    def check_channel_pty_request(self, *args):
        return True

    def check_channel_window_change_request(self, *args):
        return True

    def check_channel_shell_request(self, channel):
        self.state.shells += 1
        channel.send(b"ZW_SHARED_READY\r\n")
        return True


class Files(fixture.Files):
    def list_folder(self, path):
        if path != "/many":
            return super().list_folder(path)
        entries = []
        for index in range(5000):
            attrs = fixture.attributes("/entry", self.state)
            attrs.filename = f"entry {index:04}"
            entries.append(attrs)
        return entries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    controls = out / "controls"
    controls.mkdir(exist_ok=True)
    state = fixture.State()
    key = paramiko.RSAKey.generate(2048)
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(10)
    transports, channels, errors = [], [], []

    def serve():
        try:
            connection, _ = listener.accept()
            transport = paramiko.Transport(connection)
            transports.append(transport)
            transport.add_server_key(key)
            transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files)
            transport.start_server(server=Server(state))
            while transport.is_active():
                channel = transport.accept(0.01)
                if channel is not None:
                    channels.append(channel)
        except (EOFError, ConnectionResetError, BrokenPipeError):
            pass
        except Exception as error:
            errors.append(repr(error))

    server = threading.Thread(target=serve, daemon=True)
    server.start()
    environment = {**os.environ, "ZEROWORK_SHARED_SFTP_PORT": str(listener.getsockname()[1]),
                   "ZEROWORK_SHARED_SFTP_FINGERPRINT": fingerprint, "ZEROWORK_SHARED_SFTP_CONTROLS": str(controls)}
    try:
        process = subprocess.run([str(args.binary.resolve())], env=environment, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, timeout=60)
        output = process.stdout
    finally:
        for transport in transports:
            transport.close()
        listener.close()
        server.join(3)
    (out / "runner.log").write_text(output)
    passed = (process.returncode == 0 and "SHARED_PAGINATION" in output and not errors and not state.errors
              and not state.writes and sorted(state.opens) == sorted(state.closes)
              and all(command == fixture.OS_PROBE for command in state.exec_commands))
    report = {"passed": passed, "exit_code": process.returncode, "file_read_bytes": 70000,
              "directory_size": 5000, "tested_directory_offsets": [0, 4096, 4099],
              "read_handles_closed": sorted(state.opens) == sorted(state.closes), "remote_writes": state.writes,
              "rejected_exec_requests": state.exec_commands, "errors": errors + state.errors,
              "scope": "Real shared SSH worker and readonly mailbox, with only owned RAM fixtures on 127.0.0.1"}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
