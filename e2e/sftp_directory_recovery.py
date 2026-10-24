#!/usr/bin/env python3
"""Owned loopback peer for standalone directory FIN/recovery; no GUI or writes.

Actual libssh2 SourceFactory connections reauthenticate to the same generated
key and immutable RAM directory. Only connection 1 receives FIN on the test's
explicit control file. Evidence distinguishes peer FIN from test cleanup.
"""
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
from sftp_conflict_loopback import State, Server, Files

logging.getLogger("paramiko").setLevel(logging.CRITICAL)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("use a fresh output directory")
    state = State(out)
    key = paramiko.RSAKey.generate(2048)
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(4)
    listener.settimeout(0.1)
    transports, workers, sockets = {}, [], {}
    stop = threading.Event()
    control = out / "drop-first"
    fin = {"sent": False}

    def serve(connection, number):
        transport = paramiko.Transport(connection)
        channels = []
        transports[number], sockets[number] = transport, connection
        state.connections[number] = {"id": number, "active": True, "peer_closed_before_stop": False}
        try:
            transport.add_server_key(key)
            transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files)
            transport.start_server(server=Server(state, number))
            while transport.is_active() and not stop.is_set():
                channel = transport.accept(0.02)
                if channel is not None:
                    channels.append(channel)
            state.connections[number]["peer_closed_before_stop"] = not stop.is_set()
        except (EOFError, OSError, paramiko.SSHException):
            state.connections[number]["peer_closed_before_stop"] = not stop.is_set()
        finally:
            transport.close()
            state.connections[number]["active"] = False

    def accept():
        number = 0
        while not stop.is_set():
            if control.exists() and not fin["sent"] and 1 in sockets:
                fin.update(sent=True, connection=1, at=time.time())
                try:
                    sockets[1].shutdown(socket.SHUT_WR)
                except OSError:
                    pass
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            number += 1
            worker = threading.Thread(target=serve, args=(connection, number), daemon=True)
            workers.append(worker)
            worker.start()

    thread = threading.Thread(target=accept, daemon=True)
    thread.start()
    report = {"status": "running", "scope": "actual libssh2 directory FIN, explicit same-owner recovery/new trust/password, original path rebind; no GUI claim", "remote_writes": False, "user_vm_connections": 0, "port": listener.getsockname()[1], "fingerprint": fingerprint}
    try:
        environment = {**os.environ, "ZEROWORK_DIRECTORY_RECOVERY_PORT": str(report["port"]), "ZEROWORK_DIRECTORY_RECOVERY_FINGERPRINT": fingerprint, "ZEROWORK_DIRECTORY_RECOVERY_CONTROL": str(control)}
        result = subprocess.run([str(args.binary.resolve())], env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=50)
        (out / "native.log").write_bytes(result.stdout)
        report["exit_code"] = result.returncode
        deadline = time.time() + 3
        while any(item["active"] for item in state.connections.values()) and time.time() < deadline:
            time.sleep(0.01)
        report["peer_before_cleanup"] = state.snapshot()
        report["fin"] = fin
        assert result.returncode == 0, result.stdout.decode(errors="replace")[-4000:]
        assert fin["sent"]
        assert len(state.connections) == 2, state.snapshot()
        assert all(item["peer_closed_before_stop"] for item in state.connections.values())
        assert not state.forbidden and not state.errors, state.snapshot()
        assert sum(call["operation"] == "SUBSYSTEM" for call in state.calls) == 2
        assert b"SFTP_DIRECTORY_RECOVERY_NATIVE " in result.stdout
        report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", error=str(error))
    finally:
        stop.set()
        state.stopping.set()
        listener.close()
        for transport in transports.values():
            transport.close()
        thread.join(2)
        for worker in workers:
            worker.join(2)
        report["peer_final"] = state.snapshot()
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(report["status"] + ": " + str(out / "report.json"))
    return report["status"] != "passed"

if __name__ == "__main__":
    raise SystemExit(main())
