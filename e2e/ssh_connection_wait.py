#!/usr/bin/env python3
"""Real SSH creation waits against owned loopback servers; no remote commands.

The server signals only after it actually receives the selected request. The
test then sets the runner's ordinary cancel token through its stdin driver.
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

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class Server(paramiko.ServerInterface):
    def __init__(self, stage, reached, release):
        self.stage = stage
        self.reached = reached
        self.release = release
        self.calls = []

    def hold(self, stage):
        self.calls.append(stage)
        if self.stage == stage:
            self.reached.set()
            self.release.wait(5)

    def get_allowed_auths(self, username):
        if self.stage.startswith("agent"):
            return "publickey"
        if self.stage.startswith("keyboard"):
            return "keyboard-interactive"
        return "password"

    def check_auth_none(self, username):
        self.hold("methods")
        return paramiko.AUTH_FAILED

    def check_auth_password(self, username, password):
        self.hold("password")
        return paramiko.AUTH_SUCCESSFUL

    def check_auth_interactive(self, username, submethods):
        self.calls.append("keyboard-prompt")
        return paramiko.InteractiveQuery("fixture", "fixture", ("Response:", False))

    def check_auth_interactive_response(self, responses):
        self.hold("keyboard-response")
        if self.stage == "keyboard-delay":
            self.reached.set()
        return paramiko.AUTH_SUCCESSFUL

    def check_channel_request(self, kind, channel_id):
        self.hold("channel")
        return paramiko.OPEN_SUCCEEDED

    def check_channel_pty_request(self, *args):
        self.hold("pty")
        return True

    def check_channel_shell_request(self, channel):
        self.hold("shell")
        if self.stage == "shell-success":
            self.reached.set()
        return True

    def check_channel_exec_request(self, channel, command):
        self.calls.append("UNEXPECTED_EXEC")
        return False


def run_case(runner, host_key, stage, mode, directory):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(5)
    port = listener.getsockname()[1]
    reached = threading.Event()
    release = threading.Event()
    server = Server(stage, reached, release)
    errors = []
    connections = []
    channels = []
    transport_holder = []

    def serve():
        try:
            connection, _ = listener.accept()
            connections.append(connection)
            if stage == "banner":
                connection.settimeout(3)
                if not connection.recv(1024).startswith(b"SSH-2.0-"):
                    raise AssertionError("client did not send its real SSH banner")
                server.calls.append("banner")
                reached.set()
                release.wait(5)
                return
            transport = paramiko.Transport(connection)
            transport_holder.append(transport)
            transport.add_server_key(host_key)
            transport.start_server(server=server)
            while transport.is_active() and not release.is_set():
                channel = transport.accept(0.02)
                if channel is not None:
                    channels.append(channel)  # Retain protocol channel; no shell exists.
        except (EOFError, ConnectionResetError, BrokenPipeError, paramiko.SSHException):
            pass
        except Exception as exc:
            errors.append(type(exc).__name__ + ": " + str(exc))

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    agent_worker = None
    agent_listener = None
    env = os.environ.copy()
    if stage == "agent-identities":
        path = Path(directory) / f"agent-{mode}.sock"
        agent_listener = socket.socket(socket.AF_UNIX)
        agent_listener.bind(str(path))
        agent_listener.listen(1)
        agent_listener.settimeout(5)
        env["SSH_AUTH_SOCK"] = str(path)

        def silent_agent():
            try:
                connection, _ = agent_listener.accept()
                connections.append(connection)
                connection.settimeout(3)
                request = connection.recv(1024)
                if len(request) < 5 or request[4] != 11:
                    raise AssertionError("not an SSH_AGENTC_REQUEST_IDENTITIES request")
                server.calls.append("agent-identities")
                reached.set()
                release.wait(5)
            except Exception as exc:
                errors.append(type(exc).__name__ + ": " + str(exc))

        agent_worker = threading.Thread(target=silent_agent, daemon=True)
        agent_worker.start()
    started = time.monotonic()
    process = subprocess.Popen([str(runner), str(port), stage, mode], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    reached_in_time = False
    try:
        reached_in_time = reached.wait(3)
        if reached_in_time and mode == "cancel":
            process.stdin.write("cancel\n")
            process.stdin.flush()
        stdout, stderr = process.communicate(timeout=4)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        errors.append("runner did not converge within4s")
    finally:
        release.set()
        for transport in transport_holder:
            transport.close()
        for connection in connections:
            connection.close()
        listener.close()
        if agent_listener:
            agent_listener.close()
        worker.join(1)
        if agent_worker:
            agent_worker.join(1)
    output = (stdout + stderr).strip()
    passed = reached_in_time and process.returncode == 0 and "PASS " in output and not errors and "UNEXPECTED_EXEC" not in server.calls and not worker.is_alive() and (agent_worker is None or not agent_worker.is_alive())
    return {"stage": stage, "mode": mode, "passed": passed, "reached_actual_wire_wait": reached_in_time, "exit_code": process.returncode, "elapsed_ms": round((time.monotonic() - started) * 1000), "calls": server.calls, "output": output, "server_errors": errors, "remote_process_started": False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("dist/ssh-acceptance/20261019/connection-wait/report.json"))
    args = parser.parse_args()
    records = []
    host_key = paramiko.RSAKey.generate(2048)
    with tempfile.TemporaryDirectory(prefix="zerowork-connection-wait-") as directory:
        cases = [("banner", "cancel"), ("banner", "timeout"), ("methods", "cancel"), ("methods", "timeout"), ("password", "cancel"), ("password", "timeout"), ("keyboard-response", "cancel"), ("channel", "cancel"), ("pty", "cancel"), ("shell", "cancel"), ("agent-identities", "cancel"), ("agent-identities", "timeout"), ("shell-success", "success"), ("keyboard-delay", "success")]
        for stage, mode in cases:
            result = run_case(args.runner, host_key, stage, mode, directory)
            records.append(result)
            print(f"{stage}/{mode}: {'PASS' if result['passed'] else 'FAIL'}", flush=True)
            if not result["passed"]:
                print(result["output"], result["server_errors"], flush=True)
    report = {"scope": "real loopback SSH network waits and UNIX-agent identities wait, native cancellation/timeout, actual owned FD closure", "passed": sum(result["passed"] for result in records), "total": len(records), "cases": records, "limits": ["No remote server, GUI, app build or exec command.", "Agent UNIX connect itself is still libssh2's local blocking connect; this suite covers subsequent identities read, not a saturated UNIX listen backlog.", "Filesystem key read and local crypto are synchronous between cancellation checkpoints; they are not forcibly interrupted."]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    raise SystemExit(0 if report["passed"] == report["total"] else 1)


if __name__ == "__main__":
    main()
