#!/usr/bin/env python3
"""Production Exec mailbox over actual loopback SSH channels; no processes.

Streams exceed the default SSH receive window. The peer counts all received
exec and terminal-input packets, so cancellation cannot pass via PTY injection.
"""
import argparse
import json
import logging
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

import paramiko
from paramiko.common import MSG_CHANNEL_CLOSE, MSG_CHANNEL_SUCCESS

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class Server(paramiko.ServerInterface):
    def __init__(self, mode, release):
        self.mode = mode
        self.release = release
        self.execs = []
        self.shells = []
        self.commands = []
        self.jobs = []
        self.stdout_bytes = 0
        self.stderr_bytes = 0
        self.errors = []
        self.open_count = 0

    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL

    def check_channel_request(self, kind, channel_id):
        self.open_count += 1
        if self.mode == "open-cancel" and self.open_count == 2:
            time.sleep(0.2)  # The real channel-open reply arrives after cancel.
        if self.mode == "open-unknown" and self.open_count == 2:
            self.release.wait(8)  # No open confirmation before parent release.
        return paramiko.OPEN_SUCCEEDED

    def check_channel_pty_request(self, *args):
        return True

    def check_channel_shell_request(self, channel):
        self.shells.append(channel)
        channel.sendall(b"PTY-INDEPENDENT\r\n")
        return True

    def check_channel_exec_request(self, channel, command):
        self.execs.append(channel)
        self.commands.append(command.decode())
        if self.mode == "reject":
            return False
        if self.mode == "request-unknown":
            return True  # The transport fixture holds this request's ACK.

        def produce():
            try:
                # Return this request's ACK before sending output/exit.
                time.sleep(0.005)
                if self.mode == "capture":
                    for _ in range(3 * 1024 * 1024 // 4096):
                        channel.sendall(b"A" * 4096)
                        self.stdout_bytes += 4096
                        channel.sendall_stderr(b"B" * 4096)
                        self.stderr_bytes += 4096
                    channel.send_exit_status(7)
                    channel.close()
                elif self.mode == "result-close-unknown":
                    channel.sendall(b"OBSERVED-OUT\n")
                    self.stdout_bytes += 13
                    channel.sendall_stderr(b"OBSERVED-ERR\n")
                    self.stderr_bytes += 13
                    channel.send_exit_status(7)
                    channel.shutdown_write()
                    self.release.wait(8)
                elif self.mode in ("cancel", "timeout", "close-unknown", "eof-timeout"):
                    channel.sendall(b"PREFIX-BEFORE-INTERRUPTION\n")
                    self.stdout_bytes += 27
                    if self.mode == "eof-timeout":
                        channel.shutdown_write()
                    while not self.release.wait(0.01) and not channel.closed:
                        pass
                else:
                    channel.sendall(b"RESULT\n")
                    self.stdout_bytes += 7
                    channel.shutdown_write()
                    if self.mode != "no-exit":
                        if self.mode == "late-exit":
                            time.sleep(0.08)
                        channel.send_exit_status(0)
                    channel.close()
            except (EOFError, OSError, paramiko.SSHException):
                # A cancelling client may close between request ACK and output.
                if self.mode not in ("cancel", "timeout", "close-unknown", "eof-timeout", "result-close-unknown"):
                    self.errors.append("producer closed before completion")

        job = threading.Thread(target=produce, daemon=True)
        self.jobs.append(job)
        job.start()
        return True


def run_case(runner, key, mode, log_root=None):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(4)
    port = listener.getsockname()[1]
    release = threading.Event()
    server = Server(mode, release)
    errors = []
    transports = []
    channels = []
    terminal_input = bytearray()
    exec_input = bytearray()
    held_closes = []
    held_request_acks = []
    pty_after = []
    log_directory = Path(tempfile.mkdtemp(prefix=f"{mode}-", dir=log_root)) if log_root is not None else None

    def serve():
        try:
            connection, _ = listener.accept()
            with connection:
                transport = paramiko.Transport(connection)
                transports.append(transport)
                if mode in ("close-unknown", "request-unknown", "result-close-unknown"):
                    handlers = transport._channel_handler_table.copy()
                    original = handlers[MSG_CHANNEL_CLOSE]

                    def hold_close(channel, message):
                        if channel in server.execs:
                            held_closes.append(channel.chanid)
                        else:
                            original(channel, message)

                    handlers[MSG_CHANNEL_CLOSE] = hold_close
                    transport._channel_handler_table = handlers
                if mode == "request-unknown":
                    original_send = transport._send_user_message

                    def hold_request_ack(message):
                        payload = message.asbytes()
                        if payload[0] == MSG_CHANNEL_SUCCESS and int.from_bytes(payload[1:5], "big") in [channel.remote_chanid for channel in server.execs]:
                            held_request_acks.append(True)
                            return
                        original_send(message)

                    transport._send_user_message = hold_request_ack
                transport.add_server_key(key)
                transport.start_server(server=server)
                while transport.is_active() and not release.is_set():
                    channel = transport.accept(0.002)
                    if channel is not None:
                        channels.append(channel)
                    for channel in channels:
                        while channel.recv_ready():
                            value = channel.recv(4096)
                            if channel in server.shells:
                                terminal_input.extend(value)
                            elif channel in server.execs:
                                exec_input.extend(value)
                    child_closed = any(channel not in server.shells and channel.closed for channel in channels)
                    if not pty_after and server.shells and (child_closed or held_closes):
                        server.shells[0].sendall(b"PTY-AFTER-EXEC\r\n")
                        pty_after.append(True)
        except (EOFError, ConnectionResetError, BrokenPipeError, paramiko.SSHException):
            pass
        except Exception as exc:
            errors.append(type(exc).__name__ + ": " + str(exc))

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    process = None
    try:
        process = subprocess.run([str(runner), str(port), mode] + ([str(log_directory)] if log_directory else []), capture_output=True, text=True, timeout=10)
        output = (process.stdout + process.stderr).strip()
    except subprocess.TimeoutExpired:
        output = "runner timed out"
    finally:
        release.set()
        for transport in transports:
            transport.close()
        listener.close()
        worker.join(1)
        for job in server.jobs:
            job.join(1)
    expected_commands = [] if mode in ("queued-cancel", "open-cancel", "open-unknown") else [f"fixture-{mode}"]
    if mode == "cwd":
        expected_commands = ["cd '/tmp/a'\\''b\n$(not-a-command)' && fixture-cwd"]
    passed = process is not None and process.returncode == 0 and "PASS " in output and server.commands == expected_commands and not terminal_input and not exec_input and not errors and not server.errors and not worker.is_alive() and not any(job.is_alive() for job in server.jobs)
    if mode == "capture":
        passed = passed and server.stdout_bytes == 3 * 1024 * 1024 and server.stderr_bytes == 3 * 1024 * 1024
    if mode in ("close-unknown", "request-unknown", "result-close-unknown"):
        passed = passed and bool(held_closes) and "unknown_before_parent=true" in output
    if mode == "request-unknown":
        passed = passed and len(held_request_acks) == 1
    if mode == "open-unknown":
        passed = passed and "request_started=false" in output and "unknown_before_parent=true" in output
    if mode == "late-exit":
        passed = passed and not held_closes
    if mode not in ("queued-cancel", "open-unknown"):
        passed = passed and bool(pty_after)
    diagnostic_lines = []
    if log_directory is not None:
        for path in log_directory.glob("*.log"):
            diagnostic_lines.extend(line for line in path.read_text().splitlines() if "exec receipt " in line)
        expected_lines = 2 if mode in ("open-unknown", "request-unknown", "close-unknown", "result-close-unknown") else 1
        passed = passed and len(diagnostic_lines) == expected_lines and all(len(line) < 2048 for line in diagnostic_lines)
        passed = passed and all("request_started=" in line and "stdout_bytes=" in line and "close_error=" in line and "operation=" in line for line in diagnostic_lines)
        passed = passed and not any(secret in line for line in diagnostic_lines for secret in (f"fixture-{mode}", "fixture-password", "OBSERVED-OUT", "OBSERVED-ERR", "PREFIX-BEFORE-INTERRUPTION", "/tmp/a'"))
    return {"mode": mode, "passed": bool(passed), "output": output, "exec_packets": server.commands, "stdout_bytes_sent": server.stdout_bytes, "stderr_bytes_sent": server.stderr_bytes, "terminal_input_bytes": len(terminal_input), "exec_stdin_bytes": len(exec_input), "held_close_packets": len(held_closes), "held_request_acks": len(held_request_acks), "pty_output_after_child_close_sent": bool(pty_after), "diagnostic_directory": str(log_directory) if log_directory else None, "diagnostic_lines": diagnostic_lines, "errors": errors + server.errors}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=Path("dist/ssh-acceptance/20261019/exec-service/report.json"))
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    log_root = args.output.parent.resolve() / "logs"
    log_root.mkdir(exist_ok=True)
    key = paramiko.RSAKey.generate(2048)
    cases = []
    for mode in ("capture", "no-exit", "late-exit", "cancel", "timeout", "eof-timeout", "reject", "queued-cancel", "open-cancel", "open-unknown", "request-unknown", "close-unknown", "result-close-unknown", "cwd"):
        result = run_case(args.runner, key, mode, log_root)
        cases.append(result)
        print(f"{mode}: {'PASS' if result['passed'] else 'FAIL'} {result['output']}", flush=True)
    report = {"scope": "real SSH Exec request/stream/exit/close packets on the production Session and mailbox with a single owned IO thread", "passed": sum(case["passed"] for case in cases), "total": len(cases), "cases": cases, "limits": ["Owned loopback only; the server sends protocol fixture outputs and never starts a process or remote command.", "The unrelated real PTY/shell channel remains live and receives no injected command, Enter or Ctrl-C.", "Binding fields are controlled identity fixtures. Runtime/SessionHost service discovery and GUI are outside this runner.", "No real remote effect can be inferred from local child channel cancellation or timeout."]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    raise SystemExit(0 if report["passed"] == report["total"] else 1)


if __name__ == "__main__":
    main()
