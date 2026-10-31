#!/usr/bin/env python3
"""Production SSH worker + real disposable shell, one PTY, no upload facility.

Uses the repository's existing Paramiko loopback pattern. It neither connects to
real hosts nor loads user shell configuration. SFTP and user exec requests fail.
"""
import argparse
import errno
import hashlib
import json
import logging
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time

import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class Peer(paramiko.ServerInterface):
    def __init__(self, fixture):
        self.fixture = fixture

    def get_allowed_auths(self, user):
        return "password"

    def check_auth_password(self, user, password):
        return paramiko.AUTH_SUCCESSFUL if user == "shell-fixture" and password == "fixture-only" else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, channel_id):
        self.fixture.actions.append([channel_id, "channel", kind])
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, channel, *args):
        self.fixture.actions.append([channel.chanid, "pty"])
        return True

    def check_channel_shell_request(self, channel):
        self.fixture.actions.append([channel.chanid, "shell"])
        self.fixture.spawn(channel)
        return True

    def check_channel_subsystem_request(self, channel, name):
        self.fixture.errors.append("forbidden-subsystem:" + name)
        return False

    def check_channel_exec_request(self, channel, command):
        # Existing Worker OS detection is not command execution under test.
        if command == b'sh -c "uname -s; cat /etc/os-release" || cmd /c ver':
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
        self.fixture.errors.append("forbidden-exec:" + command.decode(errors="replace"))
        return False


class Fixture:
    def __init__(self, shell, mode, home):
        self.shell, self.mode, self.home = shell, mode, home
        if mode in {"existing", "disabled-existing"}:
            # Preconfigured server fixture, created before its SSH listener.
            # The client cannot upload it and must discover the existing events.
            kind = "bash" if Path(shell).name == "bash" else "zsh"
            script = Path(__file__).resolve().parents[1] / "src/vt/shell" / ("integration." + kind)
            (Path(home) / (".bashrc" if kind == "bash" else ".zshrc")).write_bytes(script.read_bytes())
        self.initial_home_files = {path.name: path.read_bytes() for path in Path(home).iterdir()}
        self.actions, self.errors, self.jobs, self.transports = [], [], [], []
        self.inputs, self.outputs = bytearray(), bytearray()
        self.stop = threading.Event()
        self.key = paramiko.RSAKey.generate(2048)
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(3)
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
            self.transports.append(transport)
            try:
                transport.start_server(server=Peer(self))
            except (EOFError, OSError):
                pass

    def spawn(self, channel):
        shell_ordinal = sum(1 for entry in self.actions if entry[1] == "shell")
        suppress_initialization = (self.mode == "init-retry-success" and shell_ordinal == 1) or (self.mode == "init-retry-fail" and shell_ordinal <= 2)
        def run():
            master = child = None
            try:
                time.sleep(0.01)
                args = [self.shell, "--noprofile", "--norc", "-i"] if Path(self.shell).name == "bash" else [self.shell, "-d", "-f", "-i"]
                if self.mode in {"existing", "disabled-existing"}:
                    args = [self.shell, "--noprofile", "--rcfile", str(Path(self.home) / ".bashrc"), "-i"] if Path(self.shell).name == "bash" else [self.shell, "-d", "-i"]
                env = {"HOME": self.home, "ZDOTDIR": self.home, "HISTFILE": "", "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LC_ALL": "C.UTF-8", "SHELL": self.shell, "PS1": "fixture> "}
                child, master = pty.fork()
                if child == 0:
                    os.chdir(self.home)
                    os.execve(args[0], args, env)
                os.set_blocking(master, False)
                pending = bytearray()
                while not self.stop.is_set() and not channel.closed:
                    if channel.recv_ready():
                        data = channel.recv(65536)
                        self.inputs.extend(data)
                        if not suppress_initialization:
                            pending.extend(data)
                    readable, writable, _ = select.select([master], [master] if pending else [], [], 0.005)
                    if writable:
                        try:
                            count = os.write(master, pending)
                            del pending[:count]
                        except BlockingIOError:
                            pass
                    if readable:
                        try:
                            data = os.read(master, 65536)
                        except BlockingIOError:
                            continue
                        except OSError as error:
                            if error.errno == errno.EIO:
                                break
                            raise
                        if not data:
                            break
                        self.outputs.extend(data)
                        channel.sendall(data)
                        if self.mode == "disconnect" and b"DISCONNECT_armed" in self.outputs:
                            channel.transport.close()
                            break
            except (EOFError, OSError):
                pass
            except BaseException as error:
                self.errors.append(repr(error))
            finally:
                channel.close()
                if master is not None:
                    os.close(master)
                if child:
                    try:
                        reaped, _ = os.waitpid(child, os.WNOHANG)
                        if not reaped:
                            # Kill only this unreaped fixture child and its
                            # own process group; an already exited child needs
                            # no signal and cannot leave a recycled PGID race.
                            if os.getpgid(child) == child:
                                os.killpg(child, signal.SIGKILL)
                            else:
                                os.kill(child, signal.SIGKILL)
                            os.waitpid(child, 0)
                    except ProcessLookupError:
                        try:
                            os.waitpid(child, 0)
                        except ChildProcessError:
                            pass
                    except ChildProcessError:
                        pass
                    except OSError as error:
                        # On Darwin the group can become empty between the
                        # WNOHANG check and killpg (EPERM for a zombie-only
                        # group). Reap that exact child before declaring failure.
                        try:
                            reaped, _ = os.waitpid(child, os.WNOHANG)
                            if not reaped:
                                os.kill(child, signal.SIGKILL)
                                os.waitpid(child, 0)
                        except ChildProcessError:
                            pass
                        except OSError as cleanup_error:
                            self.errors.append("fixture-child-cleanup:" + repr(error) + ":" + repr(cleanup_error))

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


def execute(args, shell, mode, output):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="zw-shell-worker-", dir="/tmp") as directory:
        home = Path(directory) / "home"
        home.mkdir()
        fixture = Fixture(shell, mode, str(home))
        try:
            env = dict(os.environ, ZEROWORK_DATA_DIR=directory)
            result = subprocess.run([args.runner, str(fixture.port), directory, mode], capture_output=True, text=True, timeout=65, env=env)
        finally:
            fixture.close()
        (output / "stdout.log").write_text(result.stdout)
        (output / "stderr.log").write_text(result.stderr)
        (output / "pty-input.bin").write_bytes(fixture.inputs)
        (output / "pty-output.bin").write_bytes(fixture.outputs)
        shell_channels = [entry[0] for entry in fixture.actions if entry[1] == "shell"]
        checks = {
            "runner_passed": result.returncode == 0 and "SHELL_EXECUTION_PASS" in result.stderr,
            "expected_shell_channels": len(shell_channels) == (2 if mode == "init-retry-success" else 3 if mode == "init-retry-fail" else 1),
            "expected_transport_count": len(fixture.transports) == (2 if mode == "init-retry-success" else 3 if mode == "init-retry-fail" else 1),
            "no_remote_upload_or_exec": not fixture.errors,
            "no_shell_configuration_written": {path.name: path.read_bytes() for path in home.iterdir()} == fixture.initial_home_files,
        }
        if mode == "nominal":
            checks["initializer_payload_not_echoed"] = b"_zwP=" not in fixture.outputs and b"_zwP+=" not in fixture.outputs
            checks["initializer_echo_absent_from_vt_and_recording"] = all(
                marker in result.stderr for marker in
                ("INITIALIZER_ECHO_PASS vt=true", "INITIALIZER_ECHO_PASS recording=true"))
        if mode == "disconnect":
            checks["command_not_replayed"] = fixture.inputs.count(b"DISCONNECT_%s") == 1
        if mode == "recording-unavailable":
            checks["no_user_command_sent"] = b"NEVER_UNRECORDED" not in fixture.inputs
        if mode == "disabled":
            checks["zero_initialization_bytes"] = fixture.inputs == b"printf 'DISABLED_%s\\n' ordinary\n"
            checks["ordinary_input_remains_available"] = b"DISABLED_ordinary" in fixture.outputs
        if mode in {"existing", "disabled-existing"}:
            checks["zero_initialization_bytes"] = b"__zw_osc" not in fixture.inputs and b"BASH_VERSION" not in fixture.inputs
        if mode.startswith("init-retry-"):
            checks["no_startup_or_business_replay"] = b"NEVER_REPLAY_STARTUP" not in fixture.inputs and b"NEVER_REPLAY_INITIAL" not in fixture.inputs
            checks["ordinary_command_sent_once"] = fixture.inputs.count(b"RECOVERY_%s") == 1
            checks["initializer_once_per_enabled_generation"] = fixture.inputs.count(b"_zwR()") == 2
            if mode == "init-retry-success":
                checks["new_generation_ai_recorded"] = "reconnected_ai_recorded=true" in result.stderr
        if mode == "history-reopen":
            checks["durable_repeated_history"] = "repeated=3 ai=2 manual=1 manifest=true archive_reopened=true" in result.stderr
        manifests = list(Path(directory).rglob("*.session.json"))
        manifest = json.loads(manifests[0].read_bytes()) if len(manifests) == 1 else None
        if mode in {"nominal", "existing", "disabled-existing"} and manifest is not None:
            ranges = manifest["execution_ranges"]
            checks["seven_saved_intervals"] = len(ranges) == 7 and all(row["interval_saved"] and not row["sealed"] for row in ranges)
            checks["exit_statuses"] = [(row.get("process_receipt") or {}).get("exit_code") for row in ranges] == [0, 1, 0, 0, 0, 0, 0]
            checks["shell_reported_source"] = all(row.get("completion_source") == "shell_reported" for row in ranges)
            checks["recording_file_checksums"] = all(len((Path(directory) / file["path"]).read_bytes()) == file["committed_length"] and hashlib.sha256((Path(directory) / file["path"]).read_bytes()).hexdigest() == file["checksum"] for file in manifest["files"])
        elif mode in {"nominal", "existing", "disabled-existing"}:
            checks["manifest_present"] = False
        shutil.copytree(directory, output / "artifacts", dirs_exist_ok=True)
        version = subprocess.run([shell, "--version"], capture_output=True, text=True, check=True).stdout.splitlines()[0]
        report = {"passed": all(checks.values()), "shell": shell, "version": version, "mode": mode, "returncode": result.returncode, "checks": checks, "actions": fixture.actions, "errors": fixture.errors, "manifest": manifest, "fixture_setup": "Server fixture has known integration in its own isolated rc before client connection" if mode in {"existing", "disabled-existing"} else "Clean interactive shell with isolated empty HOME/ZDOTDIR and history saving disabled", "scope": "Production Session/SshWorker/VT/recording over real loopback SSH and an actual persistent PTY shell", "limits": ["Controlled login fixture does not establish safe initialization for arbitrary remote rc or foreground applications", "No actual remote Linux/bash4.2 host was accessed", "No native App/provider UI or secret entry path is exercised", "OSC reports cooperative shell behavior, not hostile-output authenticity"]}
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--shell", action="append", choices=["/bin/bash", "/bin/zsh"])
    parser.add_argument("--mode", choices=["nominal", "disconnect", "recording-unavailable", "disabled", "existing", "disabled-existing", "history-reopen", "init-retry-success", "init-retry-fail"])
    args = parser.parse_args()
    reports = []
    for shell in args.shell or ["/bin/bash", "/bin/zsh"]:
        for mode in [args.mode] if args.mode else ["nominal", "disconnect", "recording-unavailable", "disabled", "existing", "disabled-existing"]:
            reports.append(execute(args, shell, mode, args.output / (Path(shell).name + "-" + mode)))
    summary = {"passed": sum(report["passed"] for report in reports), "total": len(reports), "cases": [{key: report[key] for key in ("shell", "version", "mode", "passed", "checks", "errors")} for report in reports]}
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "report.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    raise SystemExit(0 if summary["passed"] == summary["total"] else 1)


if __name__ == "__main__":
    main()
