#!/usr/bin/env python3
"""Real SSH authentication packets over loopback; no shell/channel/remote IO.

Run after building src/ssh_auth_loopback_runner.zig against the vendored SSH
library: python3 e2e/ssh_auth_loopback.py --runner /tmp/zerowork-auth-loopback-runner
Only test method names/counts and outcomes are written to the report.
"""
import argparse
import json
import logging
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

import paramiko
from paramiko.common import cMSG_USERAUTH_FAILURE
from paramiko.message import Message

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class Server(paramiko.ServerInterface):
    def __init__(self, mode, fixture_key):
        self.mode = mode
        self.fixture_key = fixture_key
        self.first_accepted = False
        self.password_refused = False
        self.methods = []
        self.transport = None

    def get_allowed_auths(self, username):
        if self.mode == "cache":
            return "password"
        if self.mode in ("key", "agent") and not self.first_accepted:
            return "publickey"
        if self.first_accepted or self.password_refused or self.mode == "cancel":
            return "keyboard-interactive"
        return "password,keyboard-interactive"

    def check_auth_none(self, username):
        self.methods.append("none")
        return paramiko.AUTH_FAILED

    def check_auth_password(self, username, password):
        self.methods.append("password")
        if self.mode == "cache":
            return paramiko.AUTH_PARTIALLY_SUCCESSFUL if password == "stage-one" else paramiko.AUTH_SUCCESSFUL if password == "stage-two" else paramiko.AUTH_FAILED
        if self.mode == "malformed":
            packet = Message()
            packet.add_byte(cMSG_USERAUTH_FAILURE)
            packet.add_string("keyboard-interactive")
            packet.add_boolean(True)
            packet.add_byte(b"x")  # Invalid trailing byte: cannot count as PARTIAL.
            self.transport._send_message(packet)
            return paramiko.AUTH_FAILED
        if self.mode == "no-partial":
            self.password_refused = True
            return paramiko.AUTH_FAILED
        if password == "fixture-password":
            self.first_accepted = True
            return paramiko.AUTH_PARTIALLY_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        self.methods.append("publickey")
        if key == self.fixture_key:
            self.first_accepted = True
            return paramiko.AUTH_PARTIALLY_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_auth_interactive(self, username, submethods):
        self.methods.append("keyboard-interactive")
        return paramiko.InteractiveQuery("Loopback", "Two distinct prompts", ("Account:", True), ("Recovery phrase:", False))

    def check_auth_interactive_response(self, responses):
        self.methods.append("interactive-response")
        return paramiko.AUTH_SUCCESSFUL if responses == ["operator", "arbitrary-length-response"] else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        self.methods.append("UNEXPECTED_CHANNEL")
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


def run_case(runner, mode, host_key, fixture_key, key_file, env):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(8)
    port = listener.getsockname()[1]
    server = Server(mode, fixture_key)
    errors = []
    finished = threading.Event()

    def serve():
        transport = None
        try:
            connection, _ = listener.accept()
            transport = paramiko.Transport(connection)
            transport.add_server_key(host_key)
            server.transport = transport
            transport.start_server(server=server)
            while transport.is_active() and not finished.wait(0.01):
                pass
        except (EOFError, ConnectionResetError, BrokenPipeError, paramiko.SSHException):
            pass  # Expected after a cancelled or deliberately malformed exchange.
        except Exception as exc:
            errors.append(type(exc).__name__)
        finally:
            if transport:
                transport.close()
            listener.close()

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    started = time.monotonic()
    try:
        result = subprocess.run([str(runner), str(port), mode, str(key_file)], env=env, capture_output=True, text=True, timeout=12)
    finally:
        finished.set()
        worker.join(timeout=2)
        listener.close()
    output = (result.stdout + result.stderr).strip()
    passed = result.returncode == 0 and "PASS " in output and not errors and not worker.is_alive() and "UNEXPECTED_CHANNEL" not in server.methods
    record = {"case": mode, "passed": passed, "exit_code": result.returncode, "elapsed_ms": round((time.monotonic() - started) * 1000), "methods": server.methods, "output": output, "server_errors": errors, "no_shell_or_channel": "UNEXPECTED_CHANNEL" not in server.methods}
    if mode in ("password", "no-partial"):
        record["one_password_attempt"] = server.methods.count("password") == 1
        record["passed"] &= record["one_password_attempt"]
    return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("dist/ssh-acceptance/20261018/auth-loopback/report.json"))
    args = parser.parse_args()
    host_key = paramiko.RSAKey.generate(2048)
    fixture_key = paramiko.RSAKey.generate(2048)
    records = []
    with tempfile.TemporaryDirectory(prefix="zerowork-auth-loopback-") as directory:
        key_file = Path(directory) / "encrypted-fixture.pem"
        fixture_key.write_private_key_file(str(key_file), password="fixture-key-passphrase")
        os.chmod(key_file, 0o600)
        for mode in ("password", "no-partial", "key", "cancel", "malformed", "cache"):
            record = run_case(args.runner, mode, host_key, fixture_key, key_file, os.environ.copy())
            if mode == "key":
                record["case"] = "key-high-bit"
                record["fixture_modulus_bits"] = fixture_key.get_bits()
            records.append(record)
            print(f"{mode}: {'PASS' if record['passed'] else 'FAIL'}")
        ordinary_key = paramiko.RSAKey.generate(2047)
        ordinary_path = Path(directory) / "ordinary-fixture.pem"
        ordinary_key.write_private_key_file(str(ordinary_path), password="fixture-key-passphrase")
        os.chmod(ordinary_path, 0o600)
        record = run_case(args.runner, "key", host_key, ordinary_key, ordinary_path, os.environ.copy())
        record["case"] = "key-ordinary"
        record["fixture_modulus_bits"] = ordinary_key.get_bits()
        records.append(record)
        print(f"key-ordinary: {'PASS' if record['passed'] else 'FAIL'}")
        # Own this agent and isolated socket. Rejected identities surround the
        # accepted one; a later identity must not overwrite its PARTIAL result.
        agent_socket = Path(directory) / "agent.sock"
        agent = subprocess.Popen(["/usr/bin/ssh-agent", "-D", "-a", str(agent_socket)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(100):
                if agent_socket.exists():
                    break
                time.sleep(0.01)
            env = os.environ.copy()
            env["SSH_AUTH_SOCK"] = str(agent_socket)
            for index, key in enumerate((paramiko.RSAKey.generate(2048), fixture_key, paramiko.RSAKey.generate(2048))):
                path = Path(directory) / f"agent-{index}.pem"
                key.write_private_key_file(str(path))
                os.chmod(path, 0o600)
                subprocess.run(["/usr/bin/ssh-add", str(path)], env=env, check=True, capture_output=True)
            record = run_case(args.runner, "agent", host_key, fixture_key, key_file, env)
            # Rejected probe + accepted probe + accepted signed request.
            record["stopped_after_accepted_identity"] = record["methods"].count("publickey") == 3
            record["passed"] &= record["stopped_after_accepted_identity"]
            records.append(record)
            print(f"agent: {'PASS' if record['passed'] else 'FAIL'}")
        finally:
            agent.terminate()
            agent.wait(timeout=2)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"transport": "127.0.0.1 ephemeral port; Paramiko SSH server", "scope": "real auth packets only; no PTY, shell, exec or remote endpoints", "cases": records, "passed": all(item["passed"] for item in records)}, ensure_ascii=False, indent=2) + "\n")
    raise SystemExit(0 if all(item["passed"] for item in records) else 1)


if __name__ == "__main__":
    main()
