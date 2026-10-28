#!/usr/bin/env python3
"""Real one-connection PTY + SOCKS payload/stop and same-port reconnect.

The SSH peer is an owned in-memory echo service; no shell command is executed.
Only the production IO owner calls libssh2. Controller submission uses another
thread and exposes neither Session nor Listener pointers.
"""
import argparse
import base64
import hashlib
import json
import logging
from pathlib import Path
import socket
import subprocess
import threading
import time

import paramiko
from network_socks_loopback import recv_exact

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class Connection(paramiko.ServerInterface):
    def __init__(self, peer):
        self.peer = peer
        self.calls = []
        self.channels = {}
        self.transport = None
        self.closed = threading.Event()
        self.shell = bytearray()
        self.forward = bytearray()
        self.forward_by_channel = {}

    def get_allowed_auths(self, user):
        return "password"

    def check_auth_password(self, user, password):
        self.calls.append("auth")
        return paramiko.AUTH_SUCCESSFUL if (user, password) == ("shared-fixture", "shared-secret") else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, channel_id):
        self.calls.append(kind)
        self.channels[channel_id] = kind
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, channel, *args):
        self.calls.append("pty")
        return True

    def check_channel_shell_request(self, channel):
        self.calls.append("shell")
        return True

    def check_channel_exec_request(self, channel, command):
        # The production Worker queues this exact read-only OS probe at
        # startup. Refuse it without executing anything on the fixture.
        self.calls.append('os_probe' if command == b'sh -c "uname -s; cat /etc/os-release" || cmd /c ver' else "UNEXPECTED_EXEC")
        return False

    def check_channel_direct_tcpip_request(self, channel_id, origin, target):
        self.calls.append({"direct": list(target)})
        if target == self.peer.next_endpoint:
            self.channels[channel_id] = ("tunnel", target)
            return paramiko.OPEN_SUCCEEDED
        self.channels[channel_id] = "forward"
        return paramiko.OPEN_SUCCEEDED if target == ("shared.fixture", 4242) else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def echo(self, channel):
        kind = self.channels[channel.get_id()]
        if isinstance(kind, tuple):
            self.tunnel(channel, kind[1])
            return
        is_shell = self.channels[channel.get_id()] == "session"
        data = self.shell if is_shell else self.forward
        individual = bytearray()
        if not is_shell:
            self.forward_by_channel[channel.get_id()] = individual
        channel.settimeout(0.05)
        try:
            while self.transport.is_active() and not self.peer.stop_flag.is_set():
                try:
                    block = channel.recv(65536)
                except socket.timeout:
                    continue
                if not block:
                    break
                data.extend(block)
                individual.extend(block)
                if len(data) > 2 * 1024 * 1024:
                    raise ValueError("UnboundedFixtureBytes")
                channel.sendall(block)
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            try:
                channel.close()
            except (EOFError, OSError, paramiko.SSHException):
                pass

    def tunnel(self, channel, endpoint):
        sock = socket.create_connection(endpoint, timeout=3)
        sock.settimeout(0.05)
        channel.settimeout(0.05)
        def upstream():
            try:
                while self.transport.is_active() and not self.peer.stop_flag.is_set():
                    try:
                        data = channel.recv(32768)
                    except socket.timeout:
                        continue
                    if not data:
                        break
                    sock.sendall(data)
            except (EOFError, OSError, paramiko.SSHException):
                pass
            finally:
                try:
                    sock.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
        worker = threading.Thread(target=upstream, daemon=True)
        self.peer.workers.append(worker)
        worker.start()
        try:
            while self.transport.is_active() and not self.peer.stop_flag.is_set():
                try:
                    data = sock.recv(32768)
                except socket.timeout:
                    continue
                if not data:
                    break
                channel.sendall(data)
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            sock.close()
            try:
                channel.close()
            except (EOFError, OSError, paramiko.SSHException):
                pass

    def serve(self, sock):
        try:
            self.transport = paramiko.Transport(sock)
            if self.peer.hold_second_open or getattr(self.peer, 'direct_open_delay', 0):
                original_send = self.transport._send_message
                def send_message(message):
                    raw = message.asbytes()
                    if raw[0] == 91 and self.peer.hold_second_open and self.calls.count({"direct": ["shared.fixture", 4242]}) >= 2:
                        self.calls.append("open_reply_withheld")
                        self.peer.open_held.set()
                        return
                    if raw[0] == 91 and self.channels.get(int.from_bytes(raw[1:5], 'big')) == 'forward' and getattr(self.peer, 'direct_open_delay', 0):
                        if getattr(self.peer, 'delay_first_direct_only', False) and getattr(self, '_first_delayed', False):
                            original_send(message)
                            return
                        self._first_delayed = True
                        self.peer.open_held.set()
                        # sshd connects targets asynchronously. Delay only this
                        # confirmation, allowing other SSH requests to proceed.
                        def delayed():
                            if not self.peer.stop_flag.wait(self.peer.direct_open_delay) and self.transport.is_active():
                                self.calls.append('delayed_direct_confirmation')
                                original_send(message)
                        worker = threading.Thread(target=delayed, daemon=True)
                        self.peer.workers.append(worker)
                        worker.start()
                        return
                    original_send(message)
                self.transport._send_message = send_message
            if self.peer.hold_close_ack:
                handlers = dict(self.transport._channel_handler_table)
                handlers[97] = lambda channel, message: self.calls.append("close_ack_withheld")
                self.transport._channel_handler_table = handlers
            self.transport.add_server_key(self.peer.key)
            self.transport.start_server(server=self)
            while self.transport.is_active() and not self.peer.stop_flag.is_set():
                channel = self.transport.accept(0.01)
                if channel:
                    worker = threading.Thread(target=self.echo, args=(channel,), daemon=True)
                    self.peer.workers.append(worker)
                    worker.start()
            if not self.transport.is_active():
                self.closed.set()
        except (EOFError, OSError, paramiko.SSHException):
            self.closed.set()
        finally:
            if self.transport:
                self.transport.close()


class Peer:
    def __init__(self):
        self.key = paramiko.RSAKey.generate(2048)
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(2)
        self.listener.settimeout(0.1)
        self.port = self.listener.getsockname()[1]
        self.stop_flag = threading.Event()
        self.connections = []
        self.workers = []
        self.next_endpoint = None
        self.hold_close_ack = False
        self.hold_second_open = False
        self.open_held = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def serve(self):
        while not self.stop_flag.is_set():
            try:
                sock, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            connection = Connection(self)
            self.connections.append(connection)
            worker = threading.Thread(target=connection.serve, args=(sock,), daemon=True)
            self.workers.append(worker)
            worker.start()

    def stop(self):
        self.stop_flag.set()
        self.listener.close()
        for connection in self.connections:
            if connection.transport:
                connection.transport.close()
        self.thread.join(2)
        for worker in self.workers:
            worker.join(2)


def wait_file(path, child, seconds=10):
    deadline = time.monotonic() + seconds
    while not path.exists():
        if child.poll() is not None:
            raise RuntimeError("RunnerExitedBefore:" + path.name)
        if time.monotonic() > deadline:
            raise TimeoutError("Wait:" + path.name)
        time.sleep(0.005)
    return json.loads(path.read_text())


def connect_proxy(port, expected_reply=0):
    client = socket.create_connection(("127.0.0.1", port), timeout=4)
    client.settimeout(4)
    client.sendall(bytes([5, 1, 0]))
    assert recv_exact(client, 2) == bytes([5, 0])
    target = b"shared.fixture"
    client.sendall(bytes([5, 1, 0, 3, len(target)]) + target + (4242).to_bytes(2, "big"))
    reply = recv_exact(client, 10)
    assert reply[1] == expected_reply, reply.hex()
    return client


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--mode", choices=["plain", "multi", "reconnect", "parent-close", "parent-open-close"], default="plain")
    parser.add_argument("--worker", action="store_true", help="Use the production WorkerThread + shared controller runner")
    parser.add_argument("--hops", type=int, choices=[0, 1, 2], default=0)
    parser.add_argument("--exit", choices=["target", "0", "1"], default="target")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    controls = out / "controls"
    controls.mkdir()
    assert args.worker or (args.hops == 0 and args.exit == "target")
    assert args.exit == "target" or int(args.exit) < args.hops
    peers = [Peer() for _ in range(args.hops + 1)]
    selected = args.hops if args.exit == "target" else int(args.exit)
    peers[selected].hold_close_ack = args.mode == "parent-close"
    peers[selected].hold_second_open = args.mode == "parent-open-close"
    for index, current in enumerate(peers):
        if index + 1 < len(peers):
            current.next_endpoint = ("127.0.0.1", peers[index + 1].port)
        current.thread.start()
    peer = peers[-1]
    fingerprint = lambda current: "SHA256:" + base64.b64encode(hashlib.sha256(current.key.asbytes()).digest()).decode().rstrip("=")
    command = [str(args.runner.resolve()), args.mode, str(controls), fingerprint(peer), str(peer.port)]
    if args.worker:
        command += [str(args.hops), args.exit]
        for current in peers[:-1]:
            command += [str(current.port), fingerprint(current)]
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    report = {"passed": False, "scope": "real production WorkerThread/Relay + shared SOCKS host; one physical SSH connection per hop and attempt; owned in-memory PTY echo, no actual shell/GUI/external host; public SessionHost adapter authority fixture" if args.worker else "real one-Session shell+forward on sole native owner; no real shell/GUI/external host; public SessionHost authority lifecycle fixture", "runner_sha256": hashlib.sha256(args.runner.read_bytes()).hexdigest()}
    client = None
    try:
        ready = wait_file(controls / "ready.json", child)
        payload = b"shared-session-payload-" + bytes(range(256)) * 1024
        if args.mode == "multi":
            errors = []
            def roundtrip():
                sock = None
                try:
                    sock = connect_proxy(ready["local_port"])
                    sock.sendall(payload)
                    assert recv_exact(sock, len(payload)) == payload
                except Exception as error:
                    errors.append(type(error).__name__ + ": " + str(error))
                finally:
                    if sock:
                        sock.close()
            clients = [threading.Thread(target=roundtrip) for _ in range(4)]
            for worker in clients:
                worker.start()
            for worker in clients:
                worker.join(5)
            assert not errors and not any(worker.is_alive() for worker in clients), errors
        else:
            client = connect_proxy(ready["local_port"])
            client.sendall(payload)
            assert recv_exact(client, len(payload)) == payload
            if args.mode != "parent-close":
                client.close()
                client = None
        if args.mode == "reconnect":
            (controls / "pause").write_text("pause\n")
            if args.worker:
                peers[0].connections[0].transport.close()
            paused = wait_file(controls / "paused.json", child)
            assert paused["local_port"] == ready["local_port"]
            client = connect_proxy(ready["local_port"], expected_reply=3)
            client.close()
            client = None
            (controls / "resume").write_text("resume\n")
            resumed = wait_file(controls / "resumed.json", child)
            assert resumed["local_port"] == ready["local_port"] and resumed["generation"] > ready["generation"]
            client = connect_proxy(resumed["local_port"])
            client.sendall(payload)
            assert recv_exact(client, len(payload)) == payload
            client.close()
            client = None
        if args.mode == "parent-open-close":
            client = socket.create_connection(("127.0.0.1", ready["local_port"]), timeout=3)
            client.settimeout(3)
            client.sendall(bytes([5, 1, 0]))
            assert recv_exact(client, 2) == bytes([5, 0])
            name = b"shared.fixture"
            client.sendall(bytes([5, 1, 0, 3, len(name)]) + name + (4242).to_bytes(2, "big"))
            assert peers[selected].open_held.wait(3), "No actual pending channel open"
        (controls / "stop").write_text("stop\n")
        output, _ = child.communicate(timeout=10)
        (out / "runner.log").write_text(output)
        if child.returncode != 0:
            raise RuntimeError("Runner exit " + str(child.returncode) + "; see runner.log")
        result = json.loads((controls / "runner-report.json").read_text())
        for current in peers:
            for connection in current.connections:
                connection.closed.wait(2)
        attempts = 2 if args.mode == "reconnect" else 1
        reused = all(len(current.connections) == attempts for current in peers)
        expected_channels = 4 if args.mode == "multi" else 1
        for index, current in enumerate(peers):
            for connection in current.connections:
                shell_count = 1 if index == args.hops else 0
                proxy_count = (2 if args.mode == "parent-open-close" else expected_channels) if index == selected else 0
                payload_valid = all(data in (payload, b"") for data in connection.forward_by_channel.values()) if args.mode == "parent-open-close" else all(data == payload for data in connection.forward_by_channel.values())
                probe_count = shell_count if args.worker else 0
                reused &= connection.calls.count("auth") == 1 and connection.calls.count("session") == shell_count + probe_count and connection.calls.count('os_probe') == probe_count and connection.calls.count("pty") == shell_count and connection.calls.count("shell") == shell_count and connection.calls.count({"direct": ["shared.fixture", 4242]}) == proxy_count and "UNEXPECTED_EXEC" not in connection.calls and len(connection.forward_by_channel) == proxy_count and payload_valid
                if current.next_endpoint:
                    reused &= connection.calls.count({"direct": list(current.next_endpoint)}) == 1
        closed = all(connection.closed.is_set() for current in peers for connection in current.connections)
        parent_after_stop = b"AFTER_SOCKS_STOP\n" in peer.connections[-1].shell
        check = socket.socket()
        check.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        check.bind(("127.0.0.1", ready["local_port"]))
        check.close()
        trust_once = not (controls / "known_hosts").exists() and not (controls / "known_hosts.lock").exists()
        report.update({"runner": result, "only_actual_shell_connection_per_attempt": bool(reused), "transports_closed_before_fixture_cleanup": closed, "parent_shell_after_socks_stop": parent_after_stop, "local_port_rebind": True, "known_hosts_unchanged": trust_once, "payload_bytes_each_attempt": len(payload), "payload_sha256": hashlib.sha256(payload).hexdigest(), "connections": [{"calls": connection.calls, "shell_bytes": len(connection.shell), "forward_bytes": len(connection.forward), "closed": connection.closed.is_set()} for connection in peer.connections]})
        report["route_peers"] = [{"index": index, "port": current.port, "selected_exit": index == selected, "connections": [{"calls": connection.calls, "shell_bytes": len(connection.shell), "forward_bytes": len(connection.forward), "closed": connection.closed.is_set()} for connection in current.connections]} for index, current in enumerate(peers)]
        if args.mode == "parent-close":
            shell_receipt = result.get("parent_close_under_withheld_ack") and any("close_ack_withheld" in connection.calls for connection in peers[selected].connections)
        elif args.mode == "parent-open-close":
            shell_receipt = result.get("parent_close_under_withheld_open") and peers[selected].open_held.is_set()
        else:
            shell_receipt = parent_after_stop and result["tty_after_forward_stop"]
        report["passed"] = bool(child.returncode == 0 and output.count("PASS ") == 1 and reused and closed and shell_receipt and trust_once and result["forward_cleanup_released"] and result["parent_cleanup_released"] and result["stop_ms"] < 500)
    except Exception as error:
        report["error"] = type(error).__name__ + ": " + str(error)
        report["open_reply_withheld"] = peers[selected].open_held.is_set()
        child.kill()
        output, _ = child.communicate(timeout=3)
        (out / "runner.log").write_text(output)
    finally:
        if client:
            client.close()
        for current in peers:
            current.stop()
    (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "error": report.get("error"), "runner": report.get("runner")}, ensure_ascii=False))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
