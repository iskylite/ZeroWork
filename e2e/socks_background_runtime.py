#!/usr/bin/env python3
"""Owned loopback acceptance for the registered no-Tab SSH background runtime.

Peers retain only in-memory echo data. No user host, shell, PTY, exec, remote
filesystem, or application window is involved in this backend acceptance.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import time

import paramiko
from socks_route_host import RoutePeer
from network_socks_loopback import recv_exact


class ReusablePeer(RoutePeer):
    def __init__(self, key, index, is_exit=False):
        super().__init__(key, index, is_exit)
        self.closed_connections = 0

    def serve(self):
        while not self.finished.is_set():
            before = self.accepted
            super().serve()
            if self.accepted > before:
                self.closed_connections += 1


def wait_file(path, child, timeout=15):
    deadline = time.monotonic() + timeout
    while not path.exists():
        if child.poll() is not None:
            raise RuntimeError(f"RunnerExited:{child.returncode}:{path.name}")
        if time.monotonic() > deadline:
            raise TimeoutError(path.name)
        time.sleep(0.005)
    return json.loads(path.read_text())


def proxy_connect(port, success=True):
    client = socket.create_connection(("127.0.0.1", port), timeout=4)
    client.settimeout(4)
    client.sendall(bytes([5, 1, 0]))
    assert recv_exact(client, 2) == bytes([5, 0])
    target = b"socks.fixture"
    client.sendall(bytes([5, 1, 0, 3, len(target)]) + target + (4242).to_bytes(2, "big"))
    result = recv_exact(client, 10)
    assert result[0] == 5 and result[1] == (0 if success else 3), result
    return client


def roundtrip(port, payload):
    client = proxy_connect(port)
    try:
        client.sendall(payload)
        assert recv_exact(client, len(payload)) == payload
    finally:
        client.close()


def run_case(binary, folder, key, mode):
    folder.mkdir()
    controls = folder / "controls"
    controls.mkdir()
    count = 0 if mode == "direct" else 2 if mode in ("two-hop", "exit-first", "reconnect", "reconnect-oom", "reconnect-cancel-auth") else 1
    selected = 0 if mode == "exit-first" else count
    peers = [ReusablePeer(key, index, index == selected) for index in range(count)] + [ReusablePeer(key, None, selected == count)]
    for index, peer in enumerate(peers[:-1]):
        peer.next_port = peers[index + 1].port
    for peer in peers:
        peer.thread.start()
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    command = [str(binary), mode, str(controls), fingerprint, str(peers[-1].port)] + [str(peer.port) for peer in peers[:-1]]
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    report = {"case": mode, "passed": False}
    expected_ready = mode not in ("cancel-auth", "reject-key")
    payload = b"ZeroWork-background-original-owner-" + bytes(range(256)) * 1024
    try:
        if expected_ready:
            ready = wait_file(controls / "ready.json", child)
            assert ready["hop_count"] == count + 1
            roundtrip(ready["local_port"], payload)
            if mode in ("reconnect", "reconnect-oom", "reconnect-cancel-auth"):
                for peer in reversed(peers):
                    peer.transport.close()
                if mode != "reconnect-cancel-auth":
                    paused = wait_file(controls / "paused.json", child)
                    assert paused["actual_parent_released"] and paused["old_binding_revoked"]
                    paused_client = proxy_connect(ready["local_port"], success=False)
                    paused_client.close()
                    (controls / "retry").write_text("new-original-domain-grant\n")
                resumed = wait_file(controls / "resumed.json", child)
                assert resumed["local_port"] == ready["local_port"] and resumed["generation"] == ready["generation"] + (2 if mode in ("reconnect-oom", "reconnect-cancel-auth") else 1)
                roundtrip(resumed["local_port"], payload)
            (controls / "stop").write_text("close-background-owner\n")
        output, _ = child.communicate(timeout=15)
        (folder / "runner.log").write_text(output)
        result = json.loads((controls / "runner-report.json").read_text())
        expected_connections = 3 if mode == "reconnect-cancel-auth" else 2 if mode in ("reconnect", "reconnect-oom", "reconnect-cancel-auth") else 1
        deadline = time.monotonic() + 2
        peer_expected = [3 if index == 0 else 2 for index in range(len(peers))] if mode == "reconnect-cancel-auth" else [expected_connections] * len(peers)
        while time.monotonic() < deadline and any(peer.closed_connections < expected for peer, expected in zip(peers, peer_expected)):
            time.sleep(0.005)
        snapshots = [{"role": "target" if peer.index is None else f"hop-{peer.index}", "accepted": peer.accepted,
                      "closed_connections_before_fixture_cleanup": peer.closed_connections, "calls": peer.calls,
                      "errors": peer.errors, "received": len(peer.received)} for peer in peers]
        actual_route = all(peer.accepted == expected for peer, expected in zip(peers, peer_expected))
        actual_route &= all(peer.calls.count({"direct": ["127.0.0.1", peers[index + 1].port]}) == (2 if mode == "reconnect-cancel-auth" else expected_connections) for index, peer in enumerate(peers[:-1]))
        no_shell = all(not any(isinstance(call, dict) and "unexpected_channel" in call for call in peer.calls) for peer in peers)
        all_closed = all(peer.closed_connections == expected for peer, expected in zip(peers, peer_expected))
        port_released = True
        if expected_ready:
            actual_route &= peers[selected].calls.count({"direct": ["socks.fixture", 4242]}) == (2 if mode == "reconnect-cancel-auth" else expected_connections)
            actual_route &= peers[selected].received == payload * (2 if mode == "reconnect-cancel-auth" else expected_connections)
            check = socket.socket()
            check.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                check.bind(("127.0.0.1", result["local_port"]))
            except OSError:
                port_released = False
            finally:
                check.close()
        trust_unchanged = not (controls / "known_hosts").exists() and not (controls / "known_hosts.lock").exists()
        report.update({"runner": result, "actual_ordered_full_route": bool(actual_route), "native_transports_closed": all_closed,
                       "local_port_rebind": port_released, "no_shell_pty_exec": no_shell, "known_hosts_unchanged": trust_unchanged,
                       "peers": snapshots, "payload_sha256": hashlib.sha256(payload).hexdigest(),
                       "actual_bytes_roundtrip": len(payload) * (2 if mode == "reconnect-cancel-auth" else expected_connections) if expected_ready else 0, "exit_code": child.returncode})
        report["passed"] = bool(child.returncode == 0 and output.count("PASS background ") == 1 and actual_route and all_closed and no_shell and trust_unchanged and port_released and all(not peer.errors for peer in peers) and result["no_tab"] and result["no_terminal_services"] and result["original_owner"] and result["cleanup_released"])
    except Exception as error:
        report["error"] = type(error).__name__ + ": " + str(error)
        child.kill()
        output, _ = child.communicate(timeout=3)
        (folder / "runner.log").write_text(output)
        report["peers"] = [{"accepted": peer.accepted, "calls": peer.calls, "errors": peer.errors, "received": len(peer.received)} for peer in peers]
    finally:
        for peer in peers:
            peer.stop()
    (folder / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--case", choices=["direct", "one-hop", "two-hop", "exit-first", "cancel-auth", "reject-key", "reconnect", "reconnect-oom", "reconnect-cancel-auth"], action="append")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    key = paramiko.RSAKey.generate(2048)
    results = [run_case(args.runner.resolve(), args.out / mode, key, mode) for mode in args.case or ["direct", "two-hop", "exit-first", "cancel-auth", "reject-key", "reconnect", "reconnect-oom", "reconnect-cancel-auth"]]
    report = {"scope": "registered no-Tab background SSH adapter/runtime, actual libssh2 full Route, per-hop typed authentication and owner-driven SOCKS; owned loopback only", "runner_sha256": hashlib.sha256(args.runner.read_bytes()).hexdigest(), "passed": all(case["passed"] for case in results), "cases": results}
    (args.out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "cases": [{"case": value["case"], "passed": value["passed"], "error": value.get("error")} for value in results]}, ensure_ascii=False))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
