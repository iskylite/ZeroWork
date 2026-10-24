#!/usr/bin/env python3
"""Prepare/run the actual main application's retained-connection FIN recovery.

Only an immutable loopback SFTP source and own local artifacts are used. The
peer gates two real reads and sends FIN solely to the retained attempt-2 socket.
By default it is already paused; --active-fin 1 faults the actual in-flight READ.
--prepare-only starts neither a listener nor a native application.
"""
import argparse
import base64
from collections import Counter
import hashlib
import json
import logging
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import threading
import time

import paramiko
from sftp_retained_loopback import State, Peer, Files, Handle, AuditedSFTP, SOURCE, SOURCE_PATH

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class FaultState(State):
    def __init__(self, output):
        super().__init__(output)
        self.gates, self.faults = {}, []

    def snapshot(self):
        with self.lock:
            return {**super().snapshot(), "gates": json.loads(json.dumps(self.gates)),
                    "faults": json.loads(json.dumps(self.faults))}


class FaultHandle(Handle):
    def read(self, offset, length):
        state = self.peer.state
        state.record(state.reads, connection=self.peer.identity, open=self.ordinal,
                     phase=self.peer.transfer_phase, path=SOURCE_PATH, offset=offset, length=length)
        phase = self.peer.transfer_phase
        threshold = 6 * 32768
        if phase == "retained":
            try:
                threshold = json.loads(state.marker("retained-gate.json").read_text())["min_offset"]
                if not isinstance(threshold, int) or threshold < 32768 or threshold >= len(SOURCE):
                    raise ValueError("invalid retained gate threshold")
            except (OSError, ValueError, KeyError) as exc:
                state.record(state.errors, reason="Retained gate was not armed before connector OPEN: " + str(exc))
                return paramiko.SFTP_FAILURE
        required_open = 2 if phase == "original" else 3
        with state.lock:
            should_gate = (phase in ("original", "retained") and self.ordinal == required_open
                           and offset >= threshold and phase not in state.gates)
            if should_gate:
                gate = {"connection": self.peer.identity, "open": self.ordinal,
                        "offset": offset, "length": length, "entered_at_ns": time.time_ns(),
                        "released": False}
                state.gates[phase] = gate
                if phase == "original":
                    state.gate = gate
        if should_gate:
            prefix = "" if phase == "original" else "retained-"
            state.marker(prefix + "read-entered").write_text("ready\n")
            deadline = time.monotonic() + 50
            while not state.marker(prefix + "read-release").exists() and not state.stopping.is_set():
                if time.monotonic() >= deadline:
                    state.record(state.errors, reason="Bounded " + phase + " READ gate timed out")
                    return paramiko.SFTP_FAILURE
                time.sleep(.005)
            with state.lock:
                state.gates[phase].update({
                    "released": True, "released_at_ns": time.time_ns(),
                    "pause_requested_before_release": state.marker(prefix + "pause-requested").exists(),
                    "pausing_visible_before_release": state.marker(prefix + "pausing-visible").exists(),
                    "paused_visible_before_release": state.marker(prefix + "paused-visible-before-release").exists(),
                    "failure_cleanup_release": state.marker("failure-cleanup").exists() or state.stopping.is_set(),
                })
        return SOURCE[offset:offset + length]


class FaultFiles(Files):
    def open(self, path, flags, attrs):
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
            return self.peer.deny("writable OPEN")
        if path != SOURCE_PATH:
            return paramiko.SFTP_NO_SUCH_FILE
        state = self.peer.state
        with state.lock:
            ordinal = 1 + sum(item["connection"] == self.peer.identity for item in state.opens)
            if ordinal == 1:
                self.peer.transfer_phase = ("original" if not state.marker("original-tab-closed").exists()
                                            else "fault_recovery" if state.marker("fault-fin-sent").exists()
                                            else "retained")
                state.connections[self.peer.identity - 1]["transfer_phase"] = self.peer.transfer_phase
            state.record(state.opens, connection=self.peer.identity, open=ordinal,
                         phase=self.peer.transfer_phase, path=path)
        return FaultHandle(self.peer, ordinal)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--expected-sha")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--node", default=shutil.which("node") or "/usr/local/bin/node")
    parser.add_argument("--prepare-only", choices=("1",))
    parser.add_argument("--active-fin", choices=("1",))
    parser.add_argument("--saved-md5", choices=("1",))
    args = parser.parse_args()
    if not args.prepare_only and (not args.binary or not args.expected_sha):
        parser.error("native run requires --binary and --expected-sha")
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("use a fresh, empty --out directory; failed evidence is retained")
    state = FaultState(output)
    key = paramiko.RSAKey.generate(2048)
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    listener, port = None, 1
    if not args.prepare_only:
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(8)
        listener.settimeout(.025)
        port = listener.getsockname()[1]
    metadata = {"host": "127.0.0.1", "port": port, "user": "fixture", "password": "retained-fixture",
                "fingerprint": fingerprint, "source": SOURCE_PATH, "source_size": len(SOURCE),
                "source_sha256": hashlib.sha256(SOURCE).hexdigest(), "source_md5": hashlib.md5(SOURCE).hexdigest(),
                "controls": str(state.controls), "state": str(output / "peer-state.json"),
                "fault_mode": "active" if args.active_fin else "paused"}
    (output / "peer.json").write_text(json.dumps(metadata, indent=2) + "\n")
    transports, workers = [], []

    def serve_connection(connection, identity):
        transport = paramiko.Transport(connection)
        channels, fault_sent = [], False
        peer = Peer(state, identity)
        peer.transfer_phase = ""
        with state.lock:
            transports.append(transport)
        try:
            transport.add_server_key(key)
            transport.set_subsystem_handler("sftp", AuditedSFTP, FaultFiles)
            transport.start_server(server=peer)
            while transport.is_active() and not state.stopping.is_set():
                channel = transport.accept(.01)
                if channel is not None:
                    channels.append(channel)
                if state.marker("fault-fin").exists() and not fault_sent:
                    try:
                        request = json.loads(state.marker("fault-fin").read_text())
                    except (OSError, ValueError):
                        continue
                    if request.get("connection") != identity:
                        continue
                    gate = state.gates.get("retained")
                    active_ready = (args.active_fin and gate and not gate["released"]
                                    and state.marker("retained-active-confirmed").exists()
                                    and not state.marker("retained-pause-requested").exists())
                    paused_ready = (not args.active_fin and gate and gate["released"]
                                    and state.marker("retained-paused").exists())
                    if peer.transfer_phase != "retained" or not gate or gate["connection"] != identity or not (active_ready or paused_ready):
                        state.record(state.errors, connection=identity, reason="FIN refused: exact retained READ mode gate is incomplete")
                        break
                    # Actual TCP teardown: no app control, fake fault or resource
                    # graph injection. The current client must detect this FIN.
                    transport.close()
                    fault_sent = True
                    with state.lock:
                        state.faults.append({"connection": identity, "fin_sent": True,
                                             "at_ns": time.time_ns(), "request": request,
                                             "active_read_at_fin": bool(active_ready),
                                             "read_gate_released_at_fin": gate["released"]})
                    state.marker("fault-fin-sent").write_text("ready\n")
        except (EOFError, ConnectionResetError, BrokenPipeError):
            pass
        except Exception as exc:
            state.record(state.errors, connection=identity, reason=type(exc).__name__ + ": " + str(exc))
        finally:
            with state.lock:
                state.connections[identity - 1].update({"closed_at_ns": time.time_ns(),
                    "client_closed_before_peer_cleanup": not fault_sent and not state.stopping.is_set() and not transport.is_active(),
                    "fault_fin_sent": fault_sent})
            transport.close()

    def serve():
        while not state.stopping.is_set():
            try:
                state.publish()
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

    server = None
    state.publish()
    if listener:
        server = threading.Thread(target=serve, daemon=True)
        server.start()
    command = [args.node, str(Path(__file__).with_name("sftp_retained_fault_native.ts").resolve()),
               "--peer", str(output / "peer.json"), "--out", str(output / "app")]
    if args.prepare_only:
        command += ["--prepare-only", "1"]
    else:
        command += ["--binary", str(args.binary.resolve()), "--expected-sha", args.expected_sha]
    if args.active_fin:
        command += ["--active-fin", "1"]
    if args.saved_md5:
        command += ["--saved-md5", "1"]
    code, log, process = -1, "", None
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True,
                                   cwd=Path(__file__).resolve().parent.parent)
        log, _ = process.communicate(timeout=300)
        code = process.returncode
    except subprocess.TimeoutExpired as exc:
        log = exc.stdout.decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        state.record(state.errors, reason="Bounded main-app fault runner timed out")
        os.killpg(process.pid, signal.SIGTERM)
        try:
            log, _ = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            log, _ = process.communicate()
    finally:
        # Release both real READ gates on every failure before closing only this
        # runner's listener/transports. Cleanup cannot count as a pause receipt.
        for marker in ("read-release", "retained-read-release"):
            state.marker(marker).write_text("finally release\n")
        state.stopping.set()
        if listener:
            listener.close()
        for transport in transports:
            transport.close()
        if server:
            server.join(2)
        for worker in workers:
            worker.join(2)
        state.publish()
    (output / "runner.log").write_text(log)
    app_report_path = output / "app" / "report.json"
    app = json.loads(app_report_path.read_text()) if app_report_path.exists() else {}
    snapshot = state.snapshot()
    opens = Counter((item["connection"], item["open"]) for item in snapshot["opens"])
    closes = Counter((item["connection"], item["open"]) for item in snapshot["closes"])
    connections = {item["id"]: item for item in snapshot["connections"]}
    original_ids = app.get("closed_original", {}).get("peer_connection_ids", [])
    resumed_ids = app.get("resumed", {}).get("peer_connection_ids", [])
    fault_id = app.get("fault_retained", {}).get("peer_connection_id")
    original_released = bool(original_ids) and all(connections[item].get("client_closed_before_peer_cleanup") for item in original_ids)
    resumed_released = bool(resumed_ids) and all(connections[item].get("client_closed_before_peer_cleanup") for item in resumed_ids)
    fault_exact = (len(snapshot["faults"]) == 1 and fault_id == snapshot["faults"][0]["connection"]
                   and connections.get(fault_id, {}).get("fault_fin_sent") is True)
    distinct = (bool(original_ids) and bool(resumed_ids) and fault_id is not None
                and not set(original_ids).intersection(resumed_ids) and fault_id not in original_ids + resumed_ids)
    original_gate = snapshot["gates"].get("original", {})
    original_gate_ok = bool(original_gate.get("released") and original_gate.get("pause_requested_before_release") and
                            original_gate.get("pausing_visible_before_release") and not original_gate.get("failure_cleanup_release"))
    retained_gate = snapshot["gates"].get("retained", {})
    if args.active_fin:
        retained_gate_ok = (bool(retained_gate.get("released")) and not retained_gate.get("pause_requested_before_release")
                            and not retained_gate.get("failure_cleanup_release") and fault_exact
                            and snapshot["faults"][0].get("active_read_at_fin") is True
                            and snapshot["faults"][0].get("read_gate_released_at_fin") is False)
    else:
        retained_gate_ok = bool(retained_gate.get("released") and retained_gate.get("pause_requested_before_release") and
                               (retained_gate.get("pausing_visible_before_release") or retained_gate.get("paused_visible_before_release")) and
                               not retained_gate.get("failure_cleanup_release"))
    gate_ok = original_gate_ok and retained_gate_ok
    readonly = all(item["flags"] == 1 for item in snapshot["wire_opens"])
    prepared = bool(args.prepare_only and code == 0 and app.get("status") == "prepared_not_run")
    passed = (not args.prepare_only and code == 0 and app.get("status") == "passed" and gate_ok and readonly
              and opens == closes and original_released and resumed_released and fault_exact and distinct
              and not snapshot["forbidden"] and not snapshot["errors"])
    report = {"status": "prepared_not_run" if prepared else "passed" if passed else "failed",
              "visual_status": "not_run" if prepared else "needs_review",
              "scope": "actual main app + libssh2 + readonly loopback; real retained connector FIN, synthetic public Harness input",
              "binary_sha256": app.get("binary_sha256"), "runner_exit_code": code,
              "app_report": str(app_report_path), "peer": metadata,
              "read_gate_contract_verified": gate_ok, "original_ui_pause_verified": original_gate_ok,
              "retained_read_fault_mode_verified": retained_gate_ok, "fault_mode": metadata["fault_mode"], "readonly_open_flags": readonly,
              "every_open_has_exact_close": opens == closes, "exact_retained_connector_fin": fault_exact,
              "original_connections_released_before_peer_cleanup": original_released,
              "final_connection_released_before_peer_cleanup": resumed_released,
              "all_three_connection_generations_distinct": distinct,
              "snapshot": snapshot, "native_started": not bool(args.prepare_only)}
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(log, end="")
    print(report["status"] + ": " + str(output / "report.json"))
    raise SystemExit(0 if prepared or passed else 1)


if __name__ == "__main__":
    main()
