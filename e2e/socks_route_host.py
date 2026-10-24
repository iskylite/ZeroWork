#!/usr/bin/env python3
"""Production SocksRouteHost -> SourceFactory -> real libssh2 Route/Listener.

SessionHost identity/services use an authority-only fixture adapter in the
runner. This is backend acceptance, not native terminal or GUI validation.
All SSH peers and exact proxy destinations are owned loopback/in-memory data.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import select
import socket
import subprocess
import threading
import time

import paramiko
from network_socks_loopback import Peer, recv_exact


class RoutePeer(Peer):
    def __init__(self, key, index, is_exit=False):
        super().__init__(key, "multi")
        self.index = index
        self.next_port = None
        self.is_exit = is_exit
        self.accepted = 0
        self.destinations = {}

    def check_auth_password(self, user, password):
        self.calls.append("password")
        expected = ("target-user", "target-secret") if self.index is None else (f"hop-user-{self.index}", f"hop-secret-{self.index}")
        if (user, password) != expected:
            self.errors.append("FrozenCredentialMismatch")
            return paramiko.AUTH_FAILED
        return paramiko.AUTH_SUCCESSFUL

    def check_channel_direct_tcpip_request(self, channel_id, origin, destination):
        self.calls.append({"direct": list(destination)})
        if self.next_port and destination == ("127.0.0.1", self.next_port):
            self.destinations[channel_id] = "relay"
            return paramiko.OPEN_SUCCEEDED
        if self.is_exit and destination == ("socks.fixture", 4242):
            self.destinations[channel_id] = "echo"
            return paramiko.OPEN_SUCCEEDED
        self.errors.append("UnexpectedDestination")
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def serve(self):
        try:
            connection = None
            while not self.finished.is_set():
                try:
                    connection, _ = self.listener.accept()
                    break
                except socket.timeout:
                    continue
            if connection is None:
                return
            self.accepted += 1
            self.transport = paramiko.Transport(connection)
            self.transport.add_server_key(self.key)
            self.transport.start_server(server=self)
            while self.transport.is_active() and not self.finished.is_set():
                channel = self.transport.accept(0.01)
                if channel is None:
                    continue
                self.channels.append(channel)
                target = self.relay if self.destinations[channel.get_id()] == "relay" else self.echo
                worker = threading.Thread(target=target, args=(channel,), daemon=True)
                self.workers.append(worker)
                worker.start()
            if not self.transport.is_active():
                self.closed.set()
        except (EOFError, ConnectionResetError, BrokenPipeError, paramiko.SSHException):
            self.closed.set()
        except Exception as error:
            if not self.finished.is_set():
                self.errors.append(type(error).__name__ + ": " + str(error))
        finally:
            if self.transport:
                self.transport.close()

    def relay(self, channel):
        downstream = None
        try:
            downstream = socket.create_connection(("127.0.0.1", self.next_port), timeout=3)
            while self.transport.is_active() and not self.finished.is_set():
                readable, _, _ = select.select([channel, downstream], [], [], 0.01)
                ended = False
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        ended = True
                        break
                    (downstream if source is channel else channel).sendall(data)
                if ended:
                    break
        except (EOFError, ConnectionResetError, BrokenPipeError, paramiko.SSHException, OSError):
            pass
        finally:
            # The real client closes the full Route before fixture teardown;
            # a final close packet cannot be sent after that transport EOF.
            try:
                channel.close()
            except (EOFError, OSError, paramiko.SSHException):
                pass
            if downstream:
                downstream.close()


def run_case(binary, folder, key, mode):
    folder.mkdir()
    controls = folder / "controls"
    controls.mkdir()
    count = 0 if mode == "direct" else 2 if mode in ("two-hop", "exit-first", "exit-second") else 1
    selected = 0 if mode == "exit-first" else 1 if mode == "exit-second" else count
    peers = [RoutePeer(key, index, index == selected) for index in range(count)] + [RoutePeer(key, None, selected == count)]
    for index, peer in enumerate(peers[:-1]):
        peer.next_port = peers[index + 1].port
    for peer in peers:
        peer.thread.start()
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    command = [str(binary), mode, str(controls), fingerprint, str(peers[-1].port)] + [str(peer.port) for peer in peers[:-1]]
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    client = None
    report = {"case": mode, "passed": False}
    try:
        deadline = time.monotonic() + 12
        expected_ready = mode not in ("cancel-auth", "reject-key")
        while not (controls / "ready.json").exists() and child.poll() is None:
            if time.monotonic() >= deadline:
                raise TimeoutError("HostReadyTimeout")
            time.sleep(0.005)
        payload = b"ZeroWork-SocksRouteHost-actual-payload-" + bytes(range(256)) * 1024
        if expected_ready:
            ready = json.loads((controls / "ready.json").read_text())
            if ready["hop_count"] != selected + 1:
                raise AssertionError("WrongExitCount")
            client = socket.create_connection(("127.0.0.1", ready["local_port"]), timeout=4)
            client.settimeout(4)
            client.sendall(bytes([5, 1, 0]))
            assert recv_exact(client, 2) == bytes([5, 0])
            target = b"socks.fixture"
            client.sendall(bytes([5, 1, 0, 3, len(target)]) + target + (4242).to_bytes(2, "big"))
            assert recv_exact(client, 10) == bytes([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
            client.sendall(payload)
            echo = recv_exact(client, len(payload))
            assert echo == payload
            report["payload_sha256"] = hashlib.sha256(payload).hexdigest()
            report["actual_bytes_roundtrip"] = len(payload)
            client.close()
            client = None
            (controls / "stop").write_text("stop\n")
        output, _ = child.communicate(timeout=12)
        (folder / "runner.log").write_text(output)
        result = json.loads((controls / "runner-report.json").read_text())
        for peer in peers[:selected + 1]:
            peer.closed.wait(2)
        snapshots = [{"role": "target" if peer.index is None else f"hop-{peer.index}", "accepted": peer.accepted, "calls": peer.calls,
                      "closed_before_fixture_cleanup": peer.closed.is_set(), "errors": peer.errors, "received": len(peer.received)} for peer in peers]
        actual_route = all(peer.accepted == (1 if index <= selected else 0) for index, peer in enumerate(peers))
        actual_route &= all(peer.calls.count({"direct": ["127.0.0.1", peers[index + 1].port]}) == 1 for index, peer in enumerate(peers[:selected]))
        actual_route &= all(not peer.calls for peer in peers[selected + 1:])
        actual_closed = all(peer.closed.is_set() for peer in peers[:selected + 1])
        no_shell = all(not any(isinstance(call, dict) and "unexpected_channel" in call for call in peer.calls) for peer in peers)
        trust_unchanged = not (controls / "known_hosts").exists() and not (controls / "known_hosts.lock").exists()
        port_released = True
        if expected_ready:
            check = socket.socket()
            check.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                check.bind(("127.0.0.1", result["local_port"]))
            except OSError:
                port_released = False
            finally:
                check.close()
            actual_route &= peers[selected].calls.count({"direct": ["socks.fixture", 4242]}) == 1
            actual_route &= peers[selected].received == payload
        report.update({"runner": result, "actual_ordered_route": bool(actual_route), "native_transports_closed": actual_closed,
                       "local_port_rebind": port_released, "no_shell_pty_exec": no_shell, "known_hosts_unchanged": trust_unchanged, "peers": snapshots, "exit_code": child.returncode})
        report["passed"] = bool(child.returncode == 0 and output.count("PASS ") == 1 and actual_route and actual_closed and port_released and no_shell and trust_unchanged and all(not peer.errors for peer in peers) and result["cleanup_released"] and result["original_owner"] and result["original_journal_cleanup"] and result["stop_ms"] < 1500)
    except Exception as error:
        report["error"] = type(error).__name__ + ": " + str(error)
        child.kill()
        output, _ = child.communicate(timeout=3)
        (folder / "runner.log").write_text(output)
    finally:
        if client:
            client.close()
        for peer in peers:
            peer.stop()
    (folder / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--case", choices=["direct", "one-hop", "two-hop", "exit-first", "exit-second", "cancel-auth", "reject-key", "owner-close"], action="append")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    key = paramiko.RSAKey.generate(2048)
    results = [run_case(args.runner.resolve(), out / mode, key, mode) for mode in args.case or ["direct", "one-hop", "two-hop", "exit-first", "exit-second", "cancel-auth", "reject-key", "owner-close"]]
    report = {"scope": "backend SocksRouteHost real libssh2 Route/Listener; SessionHost authority fixture; no native GUI, terminal adapter acceptance or external host", "runner_sha256": hashlib.sha256(args.runner.read_bytes()).hexdigest(), "passed": all(case["passed"] for case in results), "cases": results}
    (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "cases": [{"case": case["case"], "passed": case["passed"], "error": case.get("error")} for case in results]}, ensure_ascii=False))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
