#!/usr/bin/env python3
"""Real loopback SSH/SFTP + native disposable BootstrapV1 shell acceptance.

The peer allows only one generated /tmp namespace per owned fixture plan.
It never reads user dotfiles, credentials, config, or connects to a real host.
"""
import argparse
import hashlib
import json
import logging
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time

import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)
DIRECTORY = re.compile(r"^/tmp/zw-bootstrap-v1-[0-9a-f]{32}$")


class Files(paramiko.SFTPServerInterface):
    def __init__(self, server, *args, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.fixture = server.fixture

    def allowed(self, path):
        root = path if DIRECTORY.fullmatch(path) else str(Path(path).parent)
        if root not in self.fixture.roots:
            raise PermissionError(path)
        if path != root and Path(path).name not in {"bootstrap", "zw_execution.so", "execution.zsh", ".zshrc", "shell.sock", "control.sock"}:
            raise PermissionError(path)
        return path

    def mkdir(self, path, attr):
        try:
            if not DIRECTORY.fullmatch(path) or Path(path).exists():
                return paramiko.SFTP_PERMISSION_DENIED
            os.mkdir(path, attr.st_mode)
            self.fixture.roots.add(path)
            self.fixture.files.append(["mkdir", path, oct(os.stat(path).st_mode & 0o777)])
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(os.lstat(self.allowed(path)))
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    lstat = stat

    def open(self, path, flags, attr):
        try:
            fd = os.open(self.allowed(path), flags | os.O_NOFOLLOW, attr.st_mode or 0o600)
            file = os.fdopen(fd, "r+b" if flags & os.O_RDWR else "wb" if flags & os.O_WRONLY else "rb", buffering=0)
            handle = paramiko.SFTPHandle(flags)
            handle.readfile = file
            handle.writefile = file
            handle.stat = lambda: paramiko.SFTPAttributes.from_stat(os.fstat(file.fileno()))
            self.fixture.files.append(["open", path, flags, oct(os.fstat(file.fileno()).st_mode & 0o777)])
            return handle
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def remove(self, path):
        try:
            os.unlink(self.allowed(path))
            self.fixture.files.append(["unlink", path])
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def rmdir(self, path):
        try:
            os.rmdir(self.allowed(path))
            self.fixture.files.append(["rmdir", path])
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)


class Peer(paramiko.ServerInterface):
    def __init__(self, fixture):
        self.fixture = fixture
        self.ptys = set()

    def check_auth_password(self, user, password):
        return paramiko.AUTH_SUCCESSFUL if user == "bootstrap-fixture" and password == "fixture-only" else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, channel, *args):
        self.ptys.add(channel.chanid)
        self.fixture.actions.append([channel.chanid, "pty"])
        return True

    def check_channel_shell_request(self, channel):
        self.fixture.actions.append([channel.chanid, "ordinary-shell"])
        self.fixture.spawn(channel, ["/bin/zsh", "-d", "-f", "-i"], True)
        return True

    def check_channel_exec_request(self, channel, command):
        words = shlex.split(command.decode())
        if words and Path(words[0]).name == "bootstrap":
            root = str(Path(words[0]).parent)
            if root not in self.fixture.roots or words[2] != root or words[1] not in {"shell", "control"}:
                return False
            if words[1] == "shell" and (len(words) != 7 or channel.chanid not in self.ptys):
                return False
            if words[1] == "control" and (len(words) != 3 or channel.chanid in self.ptys):
                return False
            if self.fixture.mode == "shared-control-reject" and words[1] == "control":
                self.fixture.actions.append([channel.chanid, "bootstrap-control-rejected"])
                return False
            self.fixture.actions.append([channel.chanid, "bootstrap-" + words[1]])
            self.fixture.spawn(channel, words, channel.chanid in self.ptys)
            return True
        # Worker OS diagnostics are a separate channel, never the trusted PTY.
        if b"uname" in command or b"ver" in command:
            self.fixture.actions.append([channel.chanid, "os-diagnostic"])
            def diagnostic():
                time.sleep(0.01)
                try:
                    channel.sendall(b"Darwin\n")
                    channel.send_exit_status(0)
                    channel.close()
                except OSError:
                    pass
            threading.Thread(target=diagnostic, daemon=True).start()
            return True
        self.fixture.errors.append("unexpected-exec:" + command.decode())
        return False


class Fixture:
    def __init__(self, mode):
        self.mode = mode
        self.outputs = {}
        self.roots, self.actions, self.files, self.errors, self.inputs = set(), [], [], [], {}
        self.jobs, self.transports = [], []
        self.stop = threading.Event()
        self.key = paramiko.RSAKey.generate(2048)
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(4)
        self.listener.settimeout(0.1)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while not self.stop.is_set():
            try:
                sock, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            transport = paramiko.Transport(sock)
            transport.add_server_key(self.key)
            transport.get_security_options().kex = ["diffie-hellman-group14-sha256"]
            transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files)
            self.transports.append(transport)
            try:
                transport.start_server(server=Peer(self))
            except (EOFError, OSError):
                pass

    def spawn(self, channel, argv, terminal):
        def run():
            master = child = process = None
            try:
                time.sleep(0.01)  # Native startup ACK precedes stream data.
                env = {"PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LC_ALL": "C.UTF-8"}
                if terminal:
                    child, master = pty.fork()
                    if child == 0:
                        os.execve(argv[0], argv, env)
                    read_fd = write_fd = master
                else:
                    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
                    read_fd, write_fd = process.stdout.fileno(), process.stdin.fileno()
                os.set_blocking(read_fd, False)
                while not self.stop.is_set() and not channel.closed:
                    if channel.recv_ready():
                        data = channel.recv(65536)
                        if data:
                            self.inputs.setdefault(str(channel.chanid), bytearray()).extend(data)
                            os.write(write_fd, data)
                    if select.select([read_fd], [], [], 0.01)[0]:
                        try:
                            data = os.read(read_fd, 65536)
                        except BlockingIOError:
                            continue
                        except OSError as error:
                            if error.errno == 5:
                                break
                            raise
                        if not data:
                            break
                        self.outputs.setdefault(str(channel.chanid), bytearray()).extend(data)
                        channel.sendall(data)
                        if self.mode == "protocol-loss" and len(argv) > 1 and argv[1] == "control" and b"7:started," in data:
                            channel.close()
                            break
                channel.send_exit_status(0)
            except (EOFError, OSError):
                pass
            except BaseException as error:
                self.errors.append(repr(error))
            finally:
                channel.close()
                if master is not None:
                    os.close(master)
                if process and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                if child:
                    try:
                        os.kill(child, signal.SIGTERM)
                        os.waitpid(child, 0)
                    except ProcessLookupError:
                        pass
        job = threading.Thread(target=run, daemon=True)
        self.jobs.append(job)
        job.start()

    def close(self):
        self.stop.set()
        self.listener.close()
        for transport in self.transports:
            transport.close()
        self.thread.join(2)
        for job in self.jobs:
            job.join(3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", required=True)
    parser.add_argument("--resources", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["unapproved", "independent", "shared", "shared-control-reject", "recording-unavailable", "protocol-loss"], required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    fixture = Fixture(args.mode)
    result = None
    try:
        with tempfile.TemporaryDirectory(prefix="zw-bootstrap-worker-recording-", dir="/tmp") as directory:
            result = subprocess.run([args.runner, str(fixture.port), args.resources, directory, args.mode], capture_output=True, text=True, timeout=50)
            (args.output / "stdout.log").write_text(result.stdout)
            (args.output / "stderr.log").write_text(result.stderr)
            leftovers = [path for path in fixture.roots if Path(path).exists()]
            report = {"status": "passed" if result.returncode == 0 and not fixture.errors and not leftovers else "failed", "returncode": result.returncode, "mode": args.mode, "ssh_transports": len(fixture.transports), "actions": fixture.actions, "sftp": fixture.files, "errors": fixture.errors, "temporary_resource_leftovers": leftovers, "limits": ["Controlled Darwin arm64/zsh5.9 loopback peer; no real host or Linux execution.", "Headless production Worker/recording, not the native App/Provider UI."]}
            (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            if args.mode == "unapproved":
                assert not fixture.transports and not fixture.files
            elif args.mode == "recording-unavailable":
                assert result.returncode == 0 and not leftovers, report
                pty_ids = [str(row[0]) for row in fixture.actions if row[1] == "bootstrap-shell"]
                assert len(pty_ids) == 1 and not fixture.inputs.get(pty_ids[0]), fixture.inputs
                report["checks"] = ["private hello cannot bypass durable recording gate", "recording unavailable rejects user command with zero PTY/private command input", "exact temporary resource cleanup remains available"]
            elif args.mode == "protocol-loss":
                assert result.returncode == 0 and not leftovers, report
                shutil.copytree(directory, args.output / "artifacts", dirs_exist_ok=True)
                saved = list(Path(directory).rglob("*.session.json"))
                assert len(saved) == 1, saved
                manifest = json.loads(saved[0].read_bytes())
                report["manifest"] = manifest
                assert len(manifest["execution_ranges"]) == 1
                row = manifest["execution_ranges"][0]
                assert not row["interval_saved"] and not row["sealed"] and row["process_receipt"] is None and row["completion_evidence"] == "unknown", row
                report["checks"] = ["real private channel loss after submit preserves unknown foreground effect", "no fake finish/END/interval_saved or input-handoff receipt", "ordinary human input remains possible and command is never replayed", "exact resource cleanup completes"]
            elif args.mode == "shared-control-reject":
                assert result.returncode == 0 and not leftovers, report
                ordinary_ids = [str(row[0]) for row in fixture.actions if row[1] == "ordinary-shell"]
                assert len(ordinary_ids) == 1 and b"SIBLING_STILL_ALIVE" in fixture.outputs.get(ordinary_ids[0], b""), fixture.outputs
                report["checks"] = ["rejected private control startup sends zero user commands", "original shared SSH transport and sibling shell survive", "partially created Bootstrap resources have exact released receipts"]
            else:
                shutil.copytree(directory, args.output / "artifacts", dirs_exist_ok=True)
                (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
                if result.returncode != 0:
                    raise AssertionError(report)
                saved = list(Path(directory).rglob("*.session.json"))
                assert len(saved) == 1, saved
                manifest = json.loads(saved[0].read_bytes())
                report["manifest"] = manifest
                assert len(manifest["execution_ranges"]) == 4
                assert all(row["interval_saved"] and not row["sealed"] for row in manifest["execution_ranges"])
                assert manifest["execution_ranges"][0]["process_receipt"]["exit_code"] == 1
                assert manifest["state"] == "closed"
                for file in manifest["files"]:
                    data = (Path(directory) / file["path"]).read_bytes()
                    assert len(data) == file["committed_length"] and hashlib.sha256(data).hexdigest() == file["checksum"]
                shutil.copytree(directory, args.output / "artifacts", dirs_exist_ok=True)
                pty_ids = [str(action[0]) for action in fixture.actions if action[1] == "bootstrap-shell"]
                assert len(pty_ids) == 1
                pty_input = bytes(fixture.inputs.get(pty_ids[0], b""))
                assert pty_input.replace(b"\0", b"") == b"human-value\n", repr(pty_input)
                report["trusted_pty_input_hex"] = pty_input.hex()
                if args.mode == "shared":
                    ordinary_ids = [str(row[0]) for row in fixture.actions if row[1] == "ordinary-shell"]
                    assert len(ordinary_ids) == 1 and b"SIBLING_STILL_ALIVE" in fixture.outputs.get(ordinary_ids[0], b""), fixture.outputs
                report["checks"] = ["user commands travel only on private SSH control channel", "four truthful foreground/session_interval receipts", "same-PTY START/END event positions persist in one manifest", "explicit handoff keeps original observer, human read completes", "temporary SFTP resources read back/hash checked and exactly removed"]
            (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            assert report["status"] == "passed", report
    finally:
        fixture.close()
        # Preserve the pre-cleanup leftovers result. This removes only this
        # fixture's exact registered namespaces after a failed acceptance run.
        for path in fixture.roots:
            if Path(path).exists():
                shutil.rmtree(path)


if __name__ == "__main__":
    main()
