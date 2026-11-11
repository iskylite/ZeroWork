#!/usr/bin/env python3
"""Exercise the production WebKit SOCKS5 bridge with local fixtures.

Returns nonzero if authentication, generation isolation, routing, or the
HTTPS and WSS checks fail.
"""
import base64
import argparse
import contextlib
import hashlib
import hmac
import http.server
import ipaddress
import json
from pathlib import Path
import secrets
import select
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading
from urllib.request import parse_http_list, parse_keqv_list


LOOPBACK = "127.0.0.1"
DOMAIN = "web-proxy-test.invalid"
RESOURCE_DOMAIN = "web-resource-test.invalid"
REMOTE_TARGET_IP = "192.0.2.42"
HTTPS_DOMAIN = "web-https-test.invalid"
WSS_DOMAIN = "web-wss-test.invalid"
WRONG_CERT_DOMAIN = "web-cert-mismatch.invalid"


def fixture_target_ip():
    output = subprocess.check_output(["/sbin/ifconfig"], text=True)
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 2 or fields[0] != "inet":
            continue
        address = ipaddress.IPv4Address(fields[1])
        if not address.is_loopback and not address.is_unspecified:
            return str(address)
    raise RuntimeError("The target-IP fixture requires an assigned non-loopback IPv4 address")


def reachable_fixture_hostname(target_ip):
    # Use only the computer's own mDNS name and only if it resolves to an
    # address owned by one of the fixture listeners.
    try:
        label = subprocess.check_output(
            ["/usr/sbin/scutil", "--get", "LocalHostName"], text=True, stderr=subprocess.DEVNULL
        ).strip().lower()
        if not label or not all(character.isascii() and (character.isalnum() or character == "-") for character in label):
            return None
        name = label + ".local"
        addresses = {entry[4][0] for entry in socket.getaddrinfo(name, None, socket.AF_INET)}
    except (OSError, subprocess.CalledProcessError):
        return None
    return name if addresses & {LOOPBACK, target_ip} else None


@contextlib.contextmanager
def running(server):
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class Origin(http.server.ThreadingHTTPServer):
    def __init__(self, name, address=(LOOPBACK, 0)):
        self.name = name
        self.requests = []
        self.pages = {}
        self.redirects = {}
        self.redirect_status = {}
        self.authentication = {}
        self.authenticated = []
        self.posts = []
        self.downloads = set()
        self.auth_nonce = secrets.token_hex(16)
        self.websocket_origins = []
        super().__init__(address, Page)

    def verify_request(self, request, client_address):
        # The target-IP control listens on one assigned interface address. Only
        # test connections from this Mac should reach the fixture handler.
        return client_address[0] in {LOOPBACK, "::1", self.server_address[0]}

    @property
    def port(self):
        return self.server_address[1]


class IPv6Origin(Origin):
    address_family = socket.AF_INET6


class TLSOrigin(Origin):
    def __init__(self, certificate, key):
        self.sni = []
        super().__init__("TLS proxy origin")
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context.load_cert_chain(certificate, key)
        self.context.set_servername_callback(lambda _, name, __: self.sni.append(name))

    def process_request_thread(self, request, client_address):
        request.settimeout(5)
        try:
            with self.context.wrap_socket(request, server_side=True) as secured:
                super().process_request_thread(secured, client_address)
        except OSError:
            request.close()


class Page(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.server.requests.append((self.path, self.headers["Host"]))
        if self.path in self.server.authentication:
            method, username, password = self.server.authentication[self.path]
            supplied = self.headers.get("Authorization", "")
            realm = "Web fixture " + self.path
            valid = False
            if method == "Basic":
                expected = "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode()
                valid = hmac.compare_digest(supplied, expected)
                challenge = f'Basic realm="{realm}"'
            else:
                challenge = f'Digest realm="{realm}", nonce="{self.server.auth_nonce}", algorithm=MD5, qop="auth"'
                if supplied.startswith("Digest "):
                    fields = parse_keqv_list(parse_http_list(supplied[7:]))
                    md5 = lambda text: hashlib.md5(text.encode()).hexdigest()
                    first = md5(f"{username}:{realm}:{password}")
                    second = md5(f"{self.command}:{self.path}")
                    expected = md5(f'{first}:{self.server.auth_nonce}:{fields.get("nc")}:{fields.get("cnonce")}:auth:{second}')
                    valid = (fields.get("username") == username and fields.get("realm") == realm
                             and fields.get("nonce") == self.server.auth_nonce and fields.get("uri") == self.path
                             and fields.get("qop") == "auth" and hmac.compare_digest(fields.get("response", ""), expected))
            if not valid:
                self.send_response(401)
                self.send_header("WWW-Authenticate", challenge)
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                return
            self.server.authenticated.append(self.path)
        websocket_key = self.headers.get("Sec-WebSocket-Key")
        if self.path in {"/remote-websocket", "/secure-websocket"} and websocket_key:
            self.server.websocket_origins.append(self.headers.get("Origin"))
            accept = hashlib.sha1((websocket_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", base64.b64encode(accept).decode())
            self.end_headers()
            self.wfile.write(b"\x81\x02ok\x88\x02\x03\xe8")
            self.close_connection = True
            return
        if self.path in self.server.redirects:
            self.send_response(self.server.redirect_status.get(self.path, 302))
            self.send_header("Location", self.server.redirects[self.path])
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            return
        body = self.server.pages.get(self.path, f"<!doctype html><title>{self.server.name}</title>".encode())
        self.send_response(200)
        if self.path in self.server.downloads:
            self.send_header("Content-Disposition", 'attachment; filename="fixture.txt"')
        if self.path.endswith(".svg"):
            self.send_header("Content-Type", "image/svg+xml")
            body = b'<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>'
        else:
            self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.server.posts.append(self.path)
        self.do_GET()

    def log_message(self, *_):
        pass


class Proxy(socketserver.ThreadingTCPServer):
    allow_reuse_address = True

    def __init__(self, name, targets, target_port, backend_port, bind_port=0):
        self.name = name
        self.credentials = (secrets.token_hex(16), secrets.token_hex(16))
        self.targets = targets
        self.target_port = target_port
        self.backend_port = backend_port
        self.events = []
        super().__init__((LOOPBACK, bind_port), Socks5)

    @property
    def port(self):
        return self.server_address[1]


class Socks5(socketserver.BaseRequestHandler):
    def record(self, *event):
        self.server.events.append(event)

    def handle(self):
        self.request.settimeout(5)
        try:
            self.exchange()
        except (OSError, EOFError, UnicodeError, ValueError):
            # A browser can abandon speculative sockets without an HTTP request.
            return

    def receive(self, length):
        data = bytearray()
        while len(data) < length:
            chunk = self.request.recv(length - len(data))
            if not chunk:
                raise EOFError
            data.extend(chunk)
        return bytes(data)

    def exchange(self):
        version, count = self.receive(2)
        methods = self.receive(count)
        if version != 5 or 2 not in methods:
            self.record("no_password_method", list(methods))
            self.request.sendall(b"\x05\xff")
            return
        self.request.sendall(b"\x05\x02")
        auth_version, length = self.receive(2)
        username = self.receive(length)
        password = self.receive(self.receive(1)[0])
        expected_user, expected_password = self.server.credentials
        username_matches = hmac.compare_digest(username, expected_user.encode())
        password_matches = hmac.compare_digest(password, expected_password.encode())
        valid = auth_version == 1 and username_matches and password_matches
        self.record("authenticated" if valid else "rejected")
        self.request.sendall(b"\x01\x00" if valid else b"\x01\x01")
        if not valid:
            return
        version, command, reserved, address_type = self.receive(4)
        if address_type in (1, 4):
            host = str(ipaddress.ip_address(self.receive(4 if address_type == 1 else 16)))
        elif address_type == 3:
            host = self.receive(self.receive(1)[0]).decode("ascii")
        else:
            raise ValueError("unsupported address type")
        port, = struct.unpack("!H", self.receive(2))
        if (version, command, reserved) != (5, 1, 0) or host not in self.server.targets or port != self.server.target_port:
            self.record("unexpected_destination", address_type, host, port)
            self.request.sendall(b"\x05\x02\x00\x01\x00\x00\x00\x00\x00\x00")
            return
        # All allowed destinations resolve to the alternate fixture origin.
        # A direct connection hits a separate HTTP server on the original port.
        with socket.create_connection((LOOPBACK, self.server.backend_port), timeout=5) as backend:
            self.record("connect", address_type, host, port)
            self.request.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
            self.relay(backend)

    def relay(self, backend):
        peers = {self.request: backend, backend: self.request}
        while peers:
            ready, _, _ = select.select(list(peers), [], [], 5)
            if not ready:
                return
            for source in ready:
                destination = peers[source]
                data = source.recv(16384)
                if data:
                    destination.sendall(data)
                else:
                    del peers[source]
                    destination.shutdown(socket.SHUT_WR)


class Probe:
    def __init__(self, process):
        self.process = process

    def call(self, operation, view, **args):
        self.process.stdin.write(json.dumps({"operation": operation, "view": view, **args}) + "\n")
        self.process.stdin.flush()
        if not select.select([self.process.stdout], [], [], 10)[0]:
            raise RuntimeError("WebKit probe timed out without replying")
        response = self.process.stdout.readline()
        if not response:
            raise RuntimeError("WebKit probe exited without replying")
        return json.loads(response)

    def create(self, name, proxy=None, *, credentials=None, fixture_ca=False, expected="created"):
        options = {"proxyPort": proxy.port} if proxy is not None else {}
        if credentials is not None:
            options["username"], options["password"] = credentials
        if fixture_ca:
            options["fixtureCA"] = True
        result = self.call("create", name, **options)
        if result["status"] != expected:
            raise RuntimeError(f"WebKit view creation failed: {result}")


def run(probe, direct, direct_v6, direct_target, backend):
    failures = []
    checks = 0
    target_ip = direct_target.server_address[0]
    origins = (direct, direct_v6, direct_target)
    hostname = reachable_fixture_hostname(target_ip)
    targets = {target_ip, REMOTE_TARGET_IP, DOMAIN, RESOURCE_DOMAIN}
    if hostname:
        targets.add(hostname)

    def check(label, passed, detail):
        nonlocal checks
        checks += 1
        verdict = "PASS" if passed else "FAIL"
        message = str(detail).replace(target_ip, "<Mac fixture IP>")
        if hostname:
            message = message.replace(hostname, "<Mac fixture hostname>")
        print(f"{verdict} {label}: {message}", flush=True)
        if not passed:
            failures.append(label)

    def load(view, host, path, title=None):
        options = {"expectedTitle": title} if title else {}
        return probe.call("load", view, url=f"http://{host}:{direct.port}{path}", **options)

    def reached(origin, path):
        return any(request[0] == path for request in origin.requests)

    def through_proxy(name, host, path, proxy, address_types, title=None):
        before = len(proxy.events)
        result = load(name, host, path, title)
        events = proxy.events[before:]
        expected_host = host.strip("[]")
        target_seen = any(
            event == ("connect", kind, expected_host, direct.port) for event in events for kind in address_types
        )
        proxied = (path, f"{host}:{direct.port}") in backend.requests
        direct_hit = any(reached(origin, path) for origin in origins)
        check(
            path,
            result["status"] == "loaded" and result["get"] and result["url"] == f"http://{host}:{direct.port}{path}"
            and ("authenticated",) in events and target_seen and proxied and not direct_hit,
            {"navigation": result, "proxy": proxy.name, "events": events, "proxy_origin": proxied,
             "direct_origin": direct_hit},
        )

    def blocked(name, host, path, proxy=None, auth_events=()):
        before = len(proxy.events) if proxy else 0
        result = load(name, host, path)
        events = proxy.events[before:] if proxy else []
        direct_hit = any(reached(origin, path) for origin in origins)
        backend_hit = reached(backend, path)
        connect = any(event[0] in {"connect", "authenticated"} for event in events)
        auth_seen = not auth_events or any(event[0] in auth_events for event in events)
        check(
            path,
            result["status"] == "failed" and not direct_hit and not backend_hit and not connect and auth_seen,
            {"navigation": result, "events": events, "direct_origin": direct_hit, "proxy_origin": backend_hit},
        )

    def direct_control(host, path, origin):
        result = load("direct", host, path)
        check(path, result["status"] == "loaded" and reached(origin, path), result)

    def local_loopback(host, path, proxy=None):
        before = len(proxy.events) if proxy else 0
        result = load("A", host, path)
        events = proxy.events[before:] if proxy else []
        local = reached(direct, path) or reached(direct_v6, path)
        check(path, result["status"] == "loaded" and local and not events and not reached(backend, path),
              {"navigation": result, "local_origin": local, "proxy_events": events})

    def observe_assigned_ip(path, proxy=None):
        before = len(proxy.events) if proxy else 0
        result = load("A", target_ip, path)
        events = proxy.events[before:] if proxy else []
        local = reached(direct_target, path)
        print(f"OBSERVED {path}: status={result['status']} local_origin={local} "
              f"proxy_connect={any(event[0] == 'connect' for event in events)}", flush=True)

    probe.create("direct")
    direct_control(LOOPBACK, "/direct-ipv4-control", direct)
    direct_control("[::1]", "/direct-ipv6-control", direct_v6)
    direct_control(target_ip, "/direct-target-ip-control", direct_target)
    if hostname:
        path = "/direct-hostname-control"
        result = load("direct", hostname, path)
        check(path, result["status"] == "loaded" and any(reached(origin, path) for origin in origins), result)
    else:
        print("SKIP reachable-hostname comparison: no local hostname resolves to a fixture listener", flush=True)

    with running(Proxy("B", targets, direct.port, backend.port)) as proxy_b:
        with running(Proxy("A", targets, direct.port, backend.port)) as proxy_a:
            reused_port = proxy_a.port
            probe.create("A", proxy_a, credentials=proxy_a.credentials)
            probe.create("B", proxy_b, credentials=proxy_b.credentials)
            through_proxy("A", DOMAIN, "/domain-a", proxy_a, {3})
            through_proxy("B", DOMAIN, "/domain-b", proxy_b, {3})
            through_proxy("A", REMOTE_TARGET_IP, "/remote-target-ip", proxy_a, {1})
            if hostname:
                through_proxy("A", hostname, "/reachable-hostname-via-proxy", proxy_a, {3})
            observe_assigned_ip("/assigned-ip-with-proxy", proxy_a)
            local_loopback(LOOPBACK, "/ipv4-loopback-local", proxy_a)
            local_loopback("localhost", "/localhost-local", proxy_a)
            local_loopback("[::1]", "/ipv6-loopback-local", proxy_a)

            backend.pages["/subresources"] = (
                "<!doctype html>"
                f'<img src="http://{RESOURCE_DOMAIN}:{direct.port}/domain-image.svg">'
                f'<img src="http://{LOOPBACK}:{direct.port}/loopback-image.svg">'
                f'<img src="http://{RESOURCE_DOMAIN}:{direct.port}/redirect-image.svg">'
            ).encode()
            backend.redirects["/redirect-image.svg"] = f"http://{LOOPBACK}:{direct.port}/redirected-loopback-image.svg"
            backend.redirects["/redirect-to-local"] = f"http://{LOOPBACK}:{direct.port}/redirected-loopback-page"
            through_proxy("A", DOMAIN, "/subresources", proxy_a, {3})
            domain_image = ("/domain-image.svg", f"{RESOURCE_DOMAIN}:{direct.port}") in backend.requests
            check("cross-origin domain image", domain_image and not reached(direct, "/domain-image.svg"),
                  {"proxy_origin": domain_image})
            for path in ("/loopback-image.svg", "/redirected-loopback-image.svg"):
                direct_hit = any(reached(origin, path) for origin in origins)
                backend_hit = reached(backend, path)
                check(path, direct_hit and not backend_hit,
                      {"proxy_origin": backend_hit, "direct_origin": direct_hit})
            result = load("A", DOMAIN, "/redirect-to-local")
            direct_hit = any(reached(origin, "/redirected-loopback-page") for origin in origins)
            check("top-level redirect to local loopback",
                  result["status"] == "loaded" and reached(backend, "/redirect-to-local")
                  and direct_hit and not reached(backend, "/redirected-loopback-page"),
                  {"navigation": result, "direct_origin": direct_hit})

            backend.pages["/remote-network"] = b"""<!doctype html><script>
const websocket = new Promise((resolve, reject) => {
    const socket = new WebSocket("ws://" + location.host + "/remote-websocket");
    socket.onmessage = (event) => event.data === "ok" ? resolve() : reject();
    socket.onerror = reject;
});
const request = fetch("/remote-fetch").then((response) => {
    if (!response.ok) throw new Error();
    return response.text();
});
Promise.all([websocket, request]).then(() => document.title = "network-checks-done");
</script>"""
            through_proxy("A", REMOTE_TARGET_IP, "/remote-network", proxy_a, {1}, "network-checks-done")
            for path in ("/remote-fetch", "/remote-websocket"):
                check(path, (path, f"{REMOTE_TARGET_IP}:{direct.port}") in backend.requests,
                      {"proxy_origin": reached(backend, path)})

            probe.create("no-credentials", proxy_a, expected="configurationRejected")
            check("no credentials", True, {"surface": "configurationRejected"})
            probe.create("wrong-credentials", proxy_a, credentials=proxy_b.credentials)
            blocked("wrong-credentials", DOMAIN, "/wrong-credentials", proxy_a, ("rejected",))

        blocked("A", REMOTE_TARGET_IP, "/proxy-down-remote-target-ip")
        if hostname:
            blocked("A", hostname, "/proxy-down-reachable-hostname")
        observe_assigned_ip("/assigned-ip-after-proxy-down")
        local_loopback(LOOPBACK, "/proxy-down-loopback-stays-local")
        direct_control(target_ip, "/direct-target-ip-control-after-proxy-down", direct_target)
        direct_control(LOOPBACK, "/direct-ipv4-control-after-proxy-down", direct)

        with running(Proxy("C", targets, direct.port, backend.port, reused_port)) as replacement:
            probe.create("C", replacement, credentials=replacement.credentials)
            blocked("A", DOMAIN, "/old-store-after-port-reuse", replacement, ("rejected",))
            through_proxy("C", DOMAIN, "/new-store-reused-port", replacement, {3})
            blocked("A", DOMAIN, "/old-store-after-new-auth", replacement, ("rejected",))
            through_proxy("B", DOMAIN, "/unaffected-store-b", proxy_b, {3})

    print(f"{checks - len(failures)}/{checks} WebKit proxy checks passed", flush=True)
    return not failures


def tls_credentials(directory):
    anchor, ca_key = directory / "ca.pem", directory / "ca.key"
    anchor_der = directory / "ca.der"
    leaf, leaf_key, csr = directory / "origin.pem", directory / "origin.key", directory / "origin.csr"
    config = directory / "tls.cnf"
    config.write_text(
        "[req]\ndistinguished_name = dn\n[dn]\n"
        "[root]\nbasicConstraints = critical,CA:true\nkeyUsage = critical,keyCertSign,cRLSign\n"
        "[leaf]\nbasicConstraints = critical,CA:false\n"
        "keyUsage = critical,digitalSignature,keyEncipherment\nextendedKeyUsage = serverAuth\n"
        f"subjectAltName = DNS:{HTTPS_DOMAIN},DNS:{WSS_DOMAIN}\n"
    )

    def openssl(*args):
        subprocess.run(["/usr/bin/openssl", *args], check=True, capture_output=True)

    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "2", "-subj",
            "/CN=ZeroWork Web Fixture CA", "-config", config, "-extensions", "root", "-keyout", ca_key, "-out", anchor)
    openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", f"/CN={HTTPS_DOMAIN}",
            "-config", config, "-keyout", leaf_key, "-out", csr)
    openssl("x509", "-req", "-in", csr, "-CA", anchor, "-CAkey", ca_key, "-CAcreateserial", "-sha256",
            "-days", "2", "-extfile", config, "-extensions", "leaf", "-out", leaf)
    openssl("x509", "-in", anchor, "-outform", "DER", "-out", anchor_der)
    return anchor_der, leaf, leaf_key


def run_interactions(probe, backend):
    checks = []
    origin = f"http://{DOMAIN}:{backend.port}"
    frame_origin = f"http://{RESOURCE_DOMAIN}:{backend.port}"

    def check(name, passed, detail):
        checks.append(passed)
        print(f"{'PASS' if passed else 'FAIL'} {name}: {detail}", flush=True)

    def load(view, path, **options):
        return probe.call("load", view, url=origin + path, **options)

    backend.pages["/dialogs"] = b"""<!doctype html><script>
alert('hello');
const yes = confirm('accept');
const no = confirm('cancel');
const empty = prompt('empty', 'default text');
const cancelled = prompt('cancel prompt', 'retained default');
document.title = yes && !no && empty === '' && cancelled === null ? 'dialogs-ok' : 'dialogs-wrong';
</script>"""
    backend.pages["/iframe-dialog"] = b"""<!doctype html><script>
alert('frame message'); parent.postMessage('frame-ok', '*');
</script>"""
    backend.pages["/frame-parent"] = (
        "<!doctype html><script>addEventListener('message', event => document.title = event.data);</script>"
        f'<iframe src="{frame_origin}/iframe-dialog"></iframe>'
    ).encode()
    backend.pages["/get-origin"] = b'<!doctype html><title>get-origin</title><a id="next" href="/linked-get">next</a>'
    backend.pages["/linked-get"] = b'<!doctype html><title>linked-get</title>'
    backend.pages["/form"] = b'<!doctype html><title>form</title><form method="post" action="/posted"><input name="x" value="one"></form>'
    backend.pages["/posted"] = b'<!doctype html><title>posted</title>'
    backend.downloads.add("/unsupported-download")
    backend.redirects["/redirect-get"] = "/linked-get"
    backend.redirects["/post-to-get"] = "/linked-get"
    backend.redirect_status["/post-to-get"] = 303
    backend.redirects["/post-preserved"] = "/posted"
    backend.redirect_status["/post-preserved"] = 307
    for path, method in (("/basic-login", "Basic"), ("/digest-login", "Digest"), ("/basic-retry", "Basic")):
        backend.authentication[path] = (method, "web-user", "web-fixture-password")
        backend.pages[path] = b'<!doctype html><title>authenticated</title>'

    with running(Proxy("INTERACTIONS", {DOMAIN, RESOURCE_DOMAIN}, backend.port, backend.port)) as proxy:
        probe.create("interactions", proxy, credentials=proxy.credentials)
        result = load("interactions", "/dialogs", expectedTitle="dialogs-ok", answers=[
            {"accepted": True}, {"accepted": True}, {"accepted": False},
            {"accepted": True, "value": ""}, {"accepted": False},
        ])
        requests = result.get("requests", [])
        check("real JavaScript alert/confirm/prompt round trip with empty versus cancellation",
              result["status"] == "loaded" and result.get("title") == "dialogs-ok" and result.get("repliesValid")
              and [request["kind"] for request in requests] == [1, 2, 2, 3, 3]
              and all(request["origin"] == origin for request in requests)
              and requests[3]["default"] == "default text", result)
        result = load("interactions", "/frame-parent", expectedTitle="frame-ok", answers=[{"accepted": True}])
        check("iframe dialog uses its own origin", result["status"] == "loaded"
              and result.get("requests", [{}])[0].get("origin") == frame_origin and result.get("repliesValid"), result)

        load("interactions", "/get-origin", expectedTitle="get-origin")
        result = probe.call("script", "interactions", script="document.getElementById('next').click()", expectedTitle="linked-get")
        check("site link tracks actual GET", result["status"] == "loaded" and result.get("get") == 1
              and result.get("url") == origin + "/linked-get", result)
        result = probe.call("reload", "interactions", expectedTitle="linked-get")
        check("reload tracks actual GET", result["status"] == "loaded" and result.get("get") == 1, result)
        result = load("interactions", "/redirect-get", expectedTitle="linked-get")
        check("GET redirect remains replayable GET", result["status"] == "loaded" and result.get("get") == 1
              and result.get("url") == origin + "/linked-get", result)
        for action, expected_title, expected_get in (("/posted", "posted", 0), ("/post-preserved", "posted", 0), ("/post-to-get", "linked-get", 1)):
            load("interactions", "/form", expectedTitle="form")
            result = probe.call("script", "interactions", script=f"document.forms[0].action = '{action}'; document.forms[0].submit()",
                                expectedTitle=expected_title)
            check(f"request method after {action}", result["status"] == "loaded"
                  and result.get("get") == expected_get and action in backend.posts, result)

        for path in ("/basic-login", "/digest-login"):
            result = load("interactions", path, expectedTitle="authenticated", answers=[
                {"accepted": True, "value": "web-user", "secret": "web-fixture-password"},
            ])
            requests = result.get("requests", [])
            check(f"HTTP authentication {path}", result["status"] == "loaded" and result.get("repliesValid")
                  and len(requests) == 1 and requests[0]["kind"] == 4 and requests[0]["origin"] == origin
                  and requests[0]["realm"] == "Web fixture " + path and path in backend.authenticated, result)
        # Exercise the cancellation boundary several times: a new load must
        # wait for the real WebKit terminal event, not an eager local flag.
        for attempt in range(3):
            probe.create("authentication-isolated", proxy, credentials=proxy.credentials)
            authenticated_before = len(backend.authenticated)
            result = load("authentication-isolated", "/basic-login", answers=[{"accepted": False}])
            # WebKit may either fail the load or display the server's empty
            # 401 response. Neither result may authenticate or stay loading.
            check(f"isolated HTTP cancellation completes ({attempt + 1})", result["status"] in {"failed", "loaded"}
                  and result.get("repliesValid") and len(result.get("requests", [])) == 1
                  and len(backend.authenticated) == authenticated_before, result)
            result = load("authentication-isolated", "/get-origin", expectedTitle="get-origin")
            check(f"navigation after HTTP cancellation ({attempt + 1})", result["status"] == "loaded", result)
        probe.create("authentication-retry", proxy, credentials=proxy.credentials)
        result = load("authentication-retry", "/basic-retry", expectedTitle="authenticated", answers=[
            {"accepted": True, "value": "wrong", "secret": "wrong"},
            {"accepted": True, "value": "web-user", "secret": "web-fixture-password"},
        ])
        check("HTTP rejected credentials can be corrected once", result["status"] == "loaded"
              and result.get("repliesValid") and len(result.get("requests", [])) == 2, result)
        result = load("interactions", "/unsupported-download", answers=[{"accepted": True}])
        check("attachment download finishes with an explicit notice", result["status"] == "failed"
              and result.get("repliesValid") and len(result.get("requests", [])) == 1
              and result["requests"][0]["kind"] == 5
              and result["requests"][0]["message"] == "暂不支持下载文件。", result)

    print(f"{sum(checks)}/{len(checks)} WebKit interaction checks passed", flush=True)
    return all(checks)


def run_tls(probe, backend):
    checks = []
    targets = {HTTPS_DOMAIN, WSS_DOMAIN, WRONG_CERT_DOMAIN}
    # Keep the requested port distinct from the alternate TLS fixture. The
    # browser can only resolve these names via the SOCKS5 destination.
    with socket.socket() as destination, running(backend):
        destination.bind((LOOPBACK, 0))
        port = destination.getsockname()[1]
        with running(Proxy("TLS", targets, port, backend.port)) as proxy:
            def check(name, passed, detail):
                print(f"{'PASS' if passed else 'FAIL'} {name}: {detail}", flush=True)
                checks.append(passed)

            def load(view, host, path, title=None):
                url = f"https://{host}:{port}{path}"
                args = {"expectedTitle": title} if title else {}
                return url, probe.call("load", view, url=url, **args)

            def used_tls_route(host, start, sni_start):
                events = proxy.events[start:]
                return (("authenticated",) in events
                        and ("connect", 3, host, port) in events
                        and host in backend.sni[sni_start:])

            probe.create("tls-system-trust", proxy, credentials=proxy.credentials)
            start, sni_start = len(proxy.events), len(backend.sni)
            _, result = load("tls-system-trust", HTTPS_DOMAIN, "/untrusted-fixture")
            check("production trust rejects the uninstalled fixture CA",
                  result["status"] == "failed" and used_tls_route(HTTPS_DOMAIN, start, sni_start)
                  and not backend.requests, result)

            probe.create("tls-fixture-trust", proxy, credentials=proxy.credentials, fixture_ca=True)
            start, sni_start = len(proxy.events), len(backend.sni)
            _, result = load("tls-fixture-trust", WRONG_CERT_DOMAIN, "/mismatched-cert")
            check("anchored certificate with wrong hostname is still rejected",
                  result["status"] == "failed" and used_tls_route(WRONG_CERT_DOMAIN, start, sni_start)
                  and {"host": WRONG_CERT_DOMAIN, "accepted": False} in result.get("trust", [])
                  and not backend.requests, result)

            start, sni_start = len(proxy.events), len(backend.sni)
            url, result = load("tls-fixture-trust", HTTPS_DOMAIN, "/secure-page")
            check("HTTPS preserves original URL, SOCKS5 hostname, SNI and HTTP Host",
                  result.get("url") == url and result.get("get") == 1
                  and used_tls_route(HTTPS_DOMAIN, start, sni_start)
                  and {"host": HTTPS_DOMAIN, "accepted": True} in result.get("trust", [])
                  and ("/secure-page", f"{HTTPS_DOMAIN}:{port}") in backend.requests,
                  {"navigation": result, "sni": backend.sni[sni_start:]})

            def websocket_page(host, path):
                return f"""<!doctype html><script>
const socket = new WebSocket("wss://{host}:{port}{path}");
socket.onmessage = (event) => {{ if (event.data === "ok") document.title = "secure-websocket-received"; }};
socket.onerror = () => {{ document.title = "secure-websocket-failed"; }};
</script>""".encode()

            backend.pages["/websocket-page"] = websocket_page(WSS_DOMAIN, "/secure-websocket")
            start, sni_start = len(proxy.events), len(backend.sni)
            _, result = load("tls-fixture-trust", HTTPS_DOMAIN, "/websocket-page", "secure-websocket-received")
            check("WSS delivers a message via authenticated SOCKS5 with its own hostname and SNI",
                  result["status"] == "loaded"
                  and used_tls_route(WSS_DOMAIN, start, sni_start)
                  and {"host": WSS_DOMAIN, "accepted": True} in result.get("trust", [])
                  and ("/secure-websocket", f"{WSS_DOMAIN}:{port}") in backend.requests
                  and backend.websocket_origins == [f"https://{HTTPS_DOMAIN}:{port}"],
                  {"navigation": result, "events": proxy.events[start:], "sni": backend.sni[sni_start:],
                   "requests": backend.requests, "origins": backend.websocket_origins})

            bad_socket = "/secure-websocket-wrong-host"
            backend.pages["/websocket-error-page"] = websocket_page(WRONG_CERT_DOMAIN, bad_socket)
            start, sni_start = len(proxy.events), len(backend.sni)
            _, result = load("tls-fixture-trust", HTTPS_DOMAIN, "/websocket-error-page", "secure-websocket-failed")
            check("WSS rejects the wrong hostname before WebSocket upgrade",
                  result["status"] == "loaded" and used_tls_route(WRONG_CERT_DOMAIN, start, sni_start)
                  and {"host": WRONG_CERT_DOMAIN, "accepted": False} in result.get("trust", [])
                  and all(path != bad_socket for path, _ in backend.requests),
                  {"navigation": result, "sni": backend.sni[sni_start:]})

    print(f"{sum(checks)}/{len(checks)} WebKit HTTPS/WSS checks passed", flush=True)
    return all(checks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interactions-only", action="store_true", help="Run dialog, request-method and HTTP-auth regressions only")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    subprocess.run(["sw_vers"], check=True)
    sdk = subprocess.check_output(["xcrun", "--show-sdk-version"], text=True).strip()
    print(f"macOS SDK {sdk}", flush=True)
    with tempfile.TemporaryDirectory(prefix="zerowork-web-proxy-") as directory:
        work = Path(directory)
        binary = work / "web-proxy-probe"
        anchor, certificate, key = tls_credentials(work)
        subprocess.run([
            "xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
            "-mmacosx-version-min=13.0", "-DZW_WEB_SURFACE_HEADLESS=1",
            "-framework", "AppKit", "-framework", "WebKit", "-framework", "Network",
            "-framework", "QuartzCore", "-framework", "Security", str(root / "e2e" / "web_proxy_probe.m"),
            str(root / "src" / "platform" / "macos_web_surface.m"), "-o", str(binary),
        ], check=True)
        target_ip = fixture_target_ip()
        with (
            running(Origin("direct origin")) as direct,
            running(IPv6Origin("IPv6 direct origin", ("::1", direct.port))) as direct_v6,
            running(Origin("direct target-IP origin", (target_ip, direct.port))) as direct_target,
            running(Origin("proxy origin")) as backend,
            subprocess.Popen([str(binary), str(anchor)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as process,
        ):
            try:
                probe = Probe(process)
                proxy_passed = args.interactions_only or run(probe, direct, direct_v6, direct_target, backend)
                interactions_passed = run_interactions(probe, backend)
                tls_passed = args.interactions_only or run_tls(probe, TLSOrigin(certificate, key))
            finally:
                process.stdin.close()
                try:
                    exit_code = process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.kill()
                    exit_code = process.wait(timeout=8)
            return 0 if proxy_passed and interactions_passed and tls_passed and exit_code == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
