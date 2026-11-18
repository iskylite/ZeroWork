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

# Match the exact bounded metadata probe in src/proto/ssh/remote_os.zig.
# Refuse this request too: recording it separately does not allow execution.
OS_PROBE = b'sh -c "uname -s || exit; if test -r /etc/os-release; then cat /etc/os-release; elif test -r /usr/lib/os-release; then cat /usr/lib/os-release; fi" || cmd /c ver'


class DirectoryServer(Server):
    def check_channel_exec_request(self, channel, command):
        if command == OS_PROBE:
            self.state.record(self.connection, "REFUSED_OS_PROBE")
            return False
        return super().check_channel_exec_request(channel, command)

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
    fin_ack = out / "fin-sent"
    fin = {"sent": False}

    def serve(connection, number):
        transport = paramiko.Transport(connection)
        channels = []
        with state.lock:
            transports[number], sockets[number] = transport, connection
            state.connections[number] = {"id": number, "active": True, "peer_closed_before_stop": False}
        try:
            transport.add_server_key(key)
            transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files)
            transport.start_server(server=DirectoryServer(state, number))
            while transport.is_active() and not stop.is_set():
                channel = transport.accept(0.02)
                if channel is not None:
                    channels.append(channel)
            with state.lock:
                state.connections[number]["peer_closed_before_stop"] = not stop.is_set()
        except (EOFError, OSError, paramiko.SSHException):
            with state.lock:
                state.connections[number]["peer_closed_before_stop"] = not stop.is_set()
        finally:
            transport.close()
            with state.lock:
                state.connections[number]["active"] = False

    def accept():
        number = 0
        while not stop.is_set():
            if control.exists() and not fin["sent"]:
                with state.lock:
                    first = sockets.get(1)
                if first is not None:
                    try:
                        first.shutdown(socket.SHUT_WR)
                        fin.update(sent=True, connection=1, at=time.time())
                        fin_ack.touch()
                    except OSError as error:
                        with state.lock:
                            state.errors.append(f"directory FIN acknowledgement failed: {error}")
                        return
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
        environment = {
            **os.environ,
            "ZEROWORK_DIRECTORY_RECOVERY_PORT": str(report["port"]),
            "ZEROWORK_DIRECTORY_RECOVERY_FINGERPRINT": fingerprint,
            "ZEROWORK_DIRECTORY_RECOVERY_CONTROL": str(control),
            "ZEROWORK_DIRECTORY_RECOVERY_ACK": str(fin_ack),
        }
        result = subprocess.run([str(args.binary.resolve())], env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=50)
        (out / "native.log").write_bytes(result.stdout)
        report["exit_code"] = result.returncode
        deadline = time.monotonic() + 3
        peer = state.snapshot()
        while peer["active_connections"] and time.monotonic() < deadline:
            time.sleep(0.01)
            peer = state.snapshot()
        report["peer_before_cleanup"] = peer
        report["fin"] = dict(fin)
        assert result.returncode == 0, result.stdout.decode(errors="replace")[-4000:]
        assert fin["sent"]
        assert len(peer["connections"]) == 2, peer
        assert all(item["peer_closed_before_stop"] for item in peer["connections"])
        assert not peer["forbidden_operations"] and not peer["errors"], peer
        assert sum(call["operation"] == "SUBSYSTEM" for call in peer["calls"]) == 2
        assert sorted(call["connection"] for call in peer["calls"] if call["operation"] == "REFUSED_OS_PROBE") == [1, 2], peer
        assert not peer["remote_bytes_mutated"], peer
        assert b"SFTP_DIRECTORY_RECOVERY_NATIVE " in result.stdout
        report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", error=str(error))
    finally:
        stop.set()
        state.stopping.set()
        listener.close()
        thread.join(2)
        with state.lock:
            owned_transports = list(transports.values())
        for transport in owned_transports:
            transport.close()
        for worker in workers:
            worker.join(2)
        report["peer_final"] = state.snapshot()
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(report["status"] + ": " + str(out / "report.json"))
    return report["status"] != "passed"

if __name__ == "__main__":
    raise SystemExit(main())
