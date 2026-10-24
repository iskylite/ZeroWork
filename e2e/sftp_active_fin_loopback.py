#!/usr/bin/env python3
"""No-GUI active READ FIN reproduction; no application or injected pause/fault."""
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
import time

import paramiko
from sftp_retained_loopback import State, Peer, Files, AuditedSFTP, Handle, SOURCE, SOURCE_PATH

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("use a fresh output directory")
    state = State(output)
    key = paramiko.RSAKey.generate(2048)
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(8)
    listener.settimeout(.025)
    transports, workers = [], []
    gates = {}

    class FaultHandle(Handle):
        def read(self, offset, length):
            state.record(state.reads, connection=self.peer.identity, open=self.ordinal,
                         path=SOURCE_PATH, offset=offset, length=length)
            label = self.peer.label
            if self.ordinal == 2 and offset >= 6 * 32768 and label not in gates:
                gates[label] = {"connection": self.peer.identity, "offset": offset, "released": False}
                state.marker(label + ".read-entered").write_text("ready\n")
                deadline = time.monotonic() + 10
                while not state.marker(label + ".read-release").exists() and not state.stopping.is_set():
                    if time.monotonic() >= deadline:
                        state.record(state.errors, reason="Bounded fault test READ gate timed out", case=label)
                        return paramiko.SFTP_FAILURE
                    time.sleep(.002)
                gates[label]["released"] = True
            return SOURCE[offset:offset + length]

    class FaultFiles(Files):
        def open(self, path, flags, attrs):
            if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
                return self.peer.deny("writable OPEN")
            if path != SOURCE_PATH:
                return paramiko.SFTP_NO_SUCH_FILE
            with state.lock:
                ordinal = 1 + sum(item["connection"] == self.peer.identity for item in state.opens)
                state.record(state.opens, connection=self.peer.identity, open=ordinal, path=path)
            return FaultHandle(self.peer, ordinal)

    class FaultPeer(Peer):
        mode = ""
        label = ""

        def check_auth_password(self, user, password):
            self.mode = user
            accepted = user in ("idle", "aux", "retained") and password == "fault-fixture"
            self.state.record(self.state.calls, connection=self.identity, operation="PASSWORD_AUTH", user=user, accepted=accepted)
            if accepted:
                with self.state.lock:
                    ordinal = 1 + sum(item.get("case") == user for item in state.connections)
                    self.label = user if user == "idle" else user + "-" + str(ordinal)
                    self.state.connections[self.identity - 1].update({"case": user, "authenticated_at_ns": time.time_ns()})
            return paramiko.AUTH_SUCCESSFUL if accepted else paramiko.AUTH_FAILED

    def serve_connection(connection, identity):
        transport = paramiko.Transport(connection)
        transports.append(transport)
        peer = FaultPeer(state, identity)
        channels = []
        sent = False
        try:
            transport.add_server_key(key)
            transport.set_subsystem_handler("sftp", AuditedSFTP, FaultFiles)
            transport.start_server(server=peer)
            while transport.is_active() and not state.stopping.is_set():
                channel = transport.accept(.01)
                if channel is not None:
                    channels.append(channel)
                if peer.label and not sent and state.marker(peer.label + ".fin").exists():
                    # The test requests this with an actual blocked READ and nonzero local bytes.
                    # Full close emits TCP FIN without a synthetic Runtime hook.
                    transport.close()
                    state.marker(peer.label + ".fin-sent").write_text("ready\n")
                    sent = True
        except (EOFError, ConnectionResetError, BrokenPipeError):
            pass
        except Exception as exc:
            state.record(state.errors, connection=identity, reason=type(exc).__name__ + ": " + str(exc))
        finally:
            with state.lock:
                state.connections[identity - 1].update({"closed_at_ns": time.time_ns(), "fault_fin_sent": sent})
            transport.close()

    def serve():
        while not state.stopping.is_set():
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with state.lock:
                identity = len(state.connections) + 1
                state.connections.append({"id": identity, "accepted_at_ns": time.time_ns()})
            worker = threading.Thread(target=serve_connection, args=(connection, identity), daemon=True)
            workers.append(worker)
            worker.start()

    server = threading.Thread(target=serve, daemon=True)
    server.start()
    env = {**os.environ, "ZEROWORK_SFTP_ACTIVE_FIN_PORT": str(listener.getsockname()[1]),
           "ZEROWORK_SFTP_ACTIVE_FIN_FINGERPRINT": fingerprint,
           "ZEROWORK_SFTP_ACTIVE_FIN_CONTROLS": str(state.controls)}
    code, log = -1, ""
    try:
        result = subprocess.run([str(args.runner.resolve())], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=50, env=env)
        code, log = result.returncode, result.stdout
    except subprocess.TimeoutExpired as exc:
        log = exc.stdout.decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        state.record(state.errors, reason="Bounded no-GUI test runner timed out")
    finally:
        state.marker("read-release").write_text("finally release\n")
        for label in gates:
            state.marker(label + ".read-release").write_text("finally release\n")
        state.stopping.set()
        listener.close()
        for transport in transports:
            transport.close()
        server.join(2)
        for worker in workers:
            worker.join(2)
    snapshot = state.snapshot()
    report = {"status": "passed" if code == 0 and not snapshot["forbidden"] and not snapshot["errors"] else "failed",
              "native_app_started": False, "runner_exit_code": code,
              "runner_sha256": hashlib.sha256(args.runner.read_bytes()).hexdigest(),
              "scope": "Actual libssh2 Runtime with active READ and real peer TCP FIN; no pause/fault injection, GUI or VM", "gates": gates, **snapshot}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    (output / "runner.log").write_text(log)
    print(log, end="")
    print(report["status"] + ": " + str(output / "report.json"))
    raise SystemExit(0 if report["status"] == "passed" else 1)


if __name__ == "__main__":
    main()
