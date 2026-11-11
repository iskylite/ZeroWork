#!/usr/bin/env python3
"""Two authenticated loopback SSH hops and a disposable HTTP origin.

The last peer maps one documentation-range IP/port to the local fixture.
Neither peer opens any caller-supplied socket address.
"""
import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import select
import signal
import socket
import threading
import time

import paramiko

from network_socks_loopback import Peer

LOOPBACK = "127.0.0.1"
TARGET = "192.0.2.40"


class Hop(Peer):
    def __init__(self, key, label, destination, outlet, record):
        super().__init__(key)
        self.label = label
        self.destination = destination
        self.outlet = outlet
        self.record = record

    def check_channel_direct_tcpip_request(self, channel_id, origin, destination):
        allowed = destination == self.destination
        self.record({"hop": self.label, "destination": destination, "allowed": allowed})
        return paramiko.OPEN_SUCCEEDED if allowed else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def serve(self):
        while not self.finished.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self.record({"ssh_connection": self.label})
            with connection:
                transport = paramiko.Transport(connection)
                self.transport = transport
                try:
                    transport.add_server_key(self.key)
                    transport.start_server(server=self)
                    while transport.is_active() and not self.finished.is_set():
                        channel = transport.accept(0.05)
                        if channel is not None:
                            worker = threading.Thread(target=self.echo, args=(channel,), daemon=True)
                            self.workers.append(worker)
                            worker.start()
                except (EOFError, OSError, paramiko.SSHException):
                    pass
                finally:
                    transport.close()
                    self.transport = None

    def echo(self, channel):
        channel.settimeout(3)
        try:
            with socket.create_connection(self.outlet, timeout=3) as socket_out:
                source_to_target = {channel: socket_out, socket_out: channel}
                while source_to_target and not self.finished.is_set():
                    ready, _, _ = select.select(list(source_to_target), [], [], 0.1)
                    for source in ready:
                        destination = source_to_target[source]
                        data = source.recv(32 * 1024)
                        if data:
                            destination.sendall(data)
                        else:
                            source_to_target.pop(source)
                            destination.shutdown(socket.SHUT_WR)
        except (OSError, EOFError, paramiko.SSHException):
            pass
        finally:
            channel.close()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.record({"path": self.path, "host": self.headers.get("Host")})
        if self.path == "/auth-fixture":
            expected = "Basic " + base64.b64encode(b"web-fixture:local-auth-only").decode()
            authenticated = self.headers.get("Authorization") == expected
            self.server.record({"authentication": authenticated})
            if not authenticated:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="Web fixture"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        if self.path == "/resource-stream":
            self.stream()
            return
        body = b"<!doctype html><title>ZeroWork Web Fixture</title><main><h1>ZeroWork Web Fixture</h1><p>Page loaded.</p></main>"
        if self.path == "/interaction-fixture":
            body += b"""<script>
window.addEventListener('load', () => {
    alert('fixture visible alert');
    const accepted = confirm('fixture accept confirmation');
    const rejected = confirm('fixture cancel confirmation');
    const empty = prompt('fixture empty prompt', 'default text');
    const cancelled = prompt('fixture cancel prompt', 'keep this text');
    const result = new URLSearchParams({accepted, rejected, empty:JSON.stringify(empty), cancelled:JSON.stringify(cancelled)});
    fetch('/interaction-result?' + result).catch(() => {});
});
</script>"""
        if self.path == "/native-controls":
            body += b"""<main><label>Page input <input id="page-input" aria-label="Page input"></label>
<button onclick="alert('native alert')">Show alert</button>
<button onclick="confirm('native confirm')">Show confirm</button>
<button onclick="prompt('native prompt','default text')">Show prompt</button>
<label>Upload file <input type="file" aria-label="Upload file"></label>
<a href="/download-fixture" download="fixture.txt">Download fixture</a>
<button onclick="window.open('/popup-fixture')">Open popup</button></main>"""
        if self.path == "/resource-probe":
            body += b"""<script>
window.addEventListener('load', () => {
    alert('fixture alert');
    confirm('fixture confirm');
    prompt('fixture prompt');
    fetch('/resource-stream').catch(() => {});
});
</script>"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        if self.path == "/download-fixture":
            self.send_header("Content-Disposition", 'attachment; filename="fixture.txt"')
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def stream(self):
        # Keep a real proxied flow in flight when the client closes or loses SSH.
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(320 * 1024))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            for _ in range(320):
                self.wfile.write(bytes(1024))
                time.sleep(0.1)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    stop = threading.Event()
    lock = threading.Lock()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    def record(event):
        with lock, (args.directory / "traffic.jsonl").open("a") as log:
            print(json.dumps(event), file=log)

    with ThreadingHTTPServer((LOOPBACK, 0), Page) as origin:
        origin.record = record
        origin_thread = threading.Thread(target=origin.serve_forever, daemon=True)
        origin_thread.start()
        port = origin.server_port
        exit_hop = Hop(paramiko.RSAKey.generate(2048), "exit", (TARGET, port), (LOOPBACK, port), record)
        entry = Hop(paramiko.RSAKey.generate(2048), "entry", (LOOPBACK, exit_hop.port), (LOOPBACK, exit_hop.port), record)
        hops = (entry, exit_hop)
        for hop in hops:
            hop.thread.start()
        try:
            ready = {
                "direct": f"http://{LOOPBACK}:{port}/direct",
                "routed": f"http://{TARGET}:{port}/routed",
                "target": [TARGET, port],
                "ports": [hop.port for hop in hops],
                "known_hosts": "".join(f"[{LOOPBACK}]:{hop.port} ssh-rsa {hop.key.get_base64()}\n" for hop in hops),
            }
            temporary = args.directory / "ready.tmp"
            temporary.write_text(json.dumps(ready))
            temporary.rename(args.directory / "ready.json")
            drop = args.directory / "drop"
            while not stop.wait(0.05):
                if drop.exists():
                    drop.unlink()
                    entry.disconnect()
        finally:
            for hop in hops:
                hop.stop()
            origin.shutdown()
            origin_thread.join()


if __name__ == "__main__":
    main()
