#!/usr/bin/env python3
"""Loopback observer for root-owned main-app SSH settings acceptance.

Does not launch/operate an app or send Harness RPC. Reuses shared_forward's
owned listener/key/channel lifecycle. No shell process, exec, SFTP or remote
endpoint is provided. Native assertions belong to the root runner.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import socket
import threading
import time

import paramiko

from shared_forward import Connection, Peer


SENTINEL = b"ZW_SETTINGS_BUFFER_ONCE"


class SettingsConnection(Connection):
    def __init__(self, peer):
        super().__init__(peer)
        self.events = []
        self.accepted_at = time.monotonic()
        self.raw_socket = None
        self.shell_ready = threading.Event()

    def event(self, kind, **values):
        self.events.append(dict(kind=kind, monotonic_sec=time.monotonic(), **values))

    def get_allowed_auths(self, user):
        return "keyboard-interactive" if self.peer.profile == "otp" else "password"

    def check_auth_password(self, user, password):
        accepted = self.peer.profile == "normal" and (user, password) == ("shared-fixture", "shared-secret")
        self.event("password", accepted=accepted)
        return paramiko.AUTH_SUCCESSFUL if accepted else paramiko.AUTH_FAILED

    def check_auth_interactive(self, username, submethods):
        self.event("otp_challenge")
        return paramiko.InteractiveQuery("Owned settings OTP", "Explicit confirmation required", ("Verification code:", False))

    def check_auth_interactive_response(self, responses):
        # Shape only: never retain a seed, full code, or a brute-forceable hash.
        valid = len(responses) == 1 and re.fullmatch(r"[0-9]{6}", responses[0]) is not None
        self.event("otp_response", response_count=len(responses), six_digits=valid)
        return paramiko.AUTH_SUCCESSFUL if valid else paramiko.AUTH_FAILED

    def check_global_request(self, kind, message):
        self.event("global_request", request=kind)
        return True

    def check_channel_pty_request(self, channel, term, width, height, pixelwidth, pixelheight, modes):
        self.event("pty", term=term.decode("ascii", "replace"), width=width, height=height)
        return True

    def check_channel_shell_request(self, channel):
        self.event("shell", client_to_server_compression=self.transport.remote_compression,
                   server_to_client_compression=self.transport.local_compression)
        self.shell_ready.set()
        return True

    def check_channel_direct_tcpip_request(self, *args):
        # SOCKS remains covered by the existing multihop fixture. No endpoints.
        self.event("rejected_forward")
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def echo(self, channel):
        if not self.shell_ready.wait(5):
            channel.close()
            return
        channel.settimeout(0.05)
        try:
            # Real parser prompt markers permit reconnect replay readiness.
            channel.sendall(b"\r\nOwned SSH settings fixture\r\n\x1b]133;A\x07fixture$ \x1b]133;B\x07")
            self.event("prompt_sent")
            while self.transport.is_active() and not self.peer.stop_flag.is_set():
                try:
                    block = channel.recv(65536)
                except socket.timeout:
                    continue
                if not block:
                    break
                self.shell.extend(block)
                if len(self.shell) > 65536:
                    raise ValueError("FixtureInputLimit")
                self.event("input", bytes=len(block), sentinel_total=bytes(self.shell).count(SENTINEL))
                channel.sendall(block)
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            channel.close()

    def serve(self, sock):
        self.raw_socket = sock
        try:
            self.event("tcp_accept", mode=self.peer.accept_mode)
            mode = self.peer.accept_mode
            if mode == "reject":
                return
            if mode == "stall":
                # Consume but never send an SSH banner; observe client closure.
                sock.settimeout(0.1)
                while not self.peer.stop_flag.is_set():
                    try:
                        if not sock.recv(4096):
                            self.event("stalled_client_closed")
                            break
                    except socket.timeout:
                        continue
                return
            self.transport = paramiko.Transport(sock)
            self.transport.get_security_options().compression = ("zlib", "zlib@openssh.com", "none")
            self.transport.add_server_key(self.peer.key)
            self.transport.start_server(server=self)
            while self.transport.is_active() and not self.peer.stop_flag.is_set():
                channel = self.transport.accept(0.05)
                if channel is not None:
                    worker = threading.Thread(target=self.echo, args=(channel,), daemon=True)
                    self.peer.workers.append(worker)
                    worker.start()
        except (EOFError, OSError, paramiko.SSHException) as error:
            self.event("transport_ended", error_type=type(error).__name__)
        finally:
            if self.transport:
                self.transport.close()
            sock.close()
            self.closed.set()
            self.event("closed")


class SettingsPeer(Peer):
    def __init__(self, profile):
        super().__init__()
        self.profile = profile
        self.accept_mode = "stall" if profile == "timeout" else "normal"

    def serve(self):
        while not self.stop_flag.is_set():
            try:
                sock, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            connection = SettingsConnection(self)
            self.connections.append(connection)
            worker = threading.Thread(target=connection.serve, args=(sock,), daemon=True)
            self.workers.append(worker)
            worker.start()

    def close_connections(self):
        for connection in list(self.connections):
            if connection.transport:
                connection.transport.close()
            elif connection.raw_socket:
                try:
                    connection.raw_socket.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                connection.raw_socket.close()

    def snapshot(self):
        return {"profile": self.profile, "port": self.port, "accept_mode": self.accept_mode,
                "connections": [{"index": index + 1, "accepted_monotonic_sec": c.accepted_at,
                                 "closed": c.closed.is_set(), "events": list(c.events),
                                 "shell_input_bytes": len(c.shell),
                                 "buffer_sentinel_count": bytes(c.shell).count(SENTINEL),
                                 "unexpected_exec": "UNEXPECTED_EXEC" in c.calls}
                                for index, c in enumerate(list(self.connections))]}


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--serve", action="store_true", help="Root only: start localhost peers; default writes an unexecuted plan")
    parser.add_argument("--seconds", type=int, default=900)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 3600:
        parser.error("--seconds must be 1..3600")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("--out must be empty; never overwrite an earlier run")
    limits = ["Peer observations alone do not prove native settings controls or saved config consumption.",
              "No native run has been performed by preparing this script.",
              "OTP response validates six-digit shape only, not TOTP correctness; seed/prefill and manual-edit preservation require root native evidence.",
              "No seed/full OTP/raw shell input is written to this fixture's evidence.",
              "SOCKS defaults use the existing multihop fixture; this observer rejects forwarding."]
    plan = {"status": "prepared_not_run", "limits": limits, "native_accepted": False,
            "fields": ["ssh.term", "ssh.keepalive_sec", "ssh.connect_timeout_sec", "ssh.compression",
                       "ssh.auto_reconnect", "ssh.reconnect_max", "ssh.reconnect_backoff", "ssh.buffer_input",
                       "ssh.otp_modal", "ssh.totp_autofill"], "buffer_sentinel": SENTINEL.decode()}
    write_json(out / "plan.json", plan)
    if not args.serve:
        print(json.dumps(plan, indent=2))
        return
    peers = {profile: SettingsPeer(profile) for profile in ("normal", "otp", "timeout")}
    registry = '[registry]\nschema_version=2\nrevision=1\nnext_connection_id=4\nnext_group_id=1\n'
    ready = []
    for index, (profile, peer) in enumerate(peers.items(), 1):
        registry += (f'[[hosts]]\nconnection_id={index}\nrevision=1\nprotocol="ssh"\nauth_mode="password"\n'
                     f'options={{strict_host_key=true}}\nname="Owned settings {profile}"\n'
                     f'host="127.0.0.1"\nport={peer.port}\nuser="shared-fixture"\n')
        ready.append({"profile": profile, "port": peer.port, "fingerprint": "SHA256:" + base64.b64encode(hashlib.sha256(peer.key.asbytes()).digest()).decode().rstrip("=")})
        peer.thread.start()
    (out / "hosts.toml").write_text(registry)
    write_json(out / "ready.json", {"peers": ready, "password": "shared-secret", "limits": limits})
    failure = None
    commands = []
    try:
        deadline = time.monotonic() + args.seconds
        while time.monotonic() < deadline and not (out / "finish").exists():
            command_path = out / "command.json"
            if command_path.exists():
                command = json.loads(command_path.read_text())
                command_path.unlink()
                peer = peers[command["peer"]]
                if command["action"] == "drop":
                    next_mode = command.get("next_mode", "normal")
                    assert next_mode in ("normal", "reject", "stall")
                    peer.accept_mode = next_mode
                    peer.close_connections()
                elif command["action"] == "mode":
                    assert command["mode"] in ("normal", "reject", "stall")
                    peer.accept_mode = command["mode"]
                else:
                    raise ValueError("UnknownControlAction")
                commands.append(dict(command=command, monotonic_sec=time.monotonic()))
            write_json(out / "state.json", {"status": "peer_observations_only", "native_accepted": False,
                                            "peers": [p.snapshot() for p in peers.values()], "commands": commands})
            time.sleep(0.05)
    except Exception as error:
        failure = {"type": type(error).__name__, "message": str(error)}
        raise
    finally:
        write_json(out / "peer-report.json", {"status": "peer_observations_only", "native_accepted": False,
                                              "peers_before_cleanup": [p.snapshot() for p in peers.values()],
                                              "commands": commands, "failure": failure, "limits": limits})
        for peer in peers.values():
            peer.close_connections()
            peer.stop()


if __name__ == "__main__":
    main()
