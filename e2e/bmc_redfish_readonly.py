#!/usr/bin/env python3
"""Bounded Sugon Redfish evidence collector; connection JSON enters hidden TTY.

Only GETs, one selected Redfish/WEB-session POST, and that session's own DELETE exist.
No shell, PTY, listener, KVM session, management write, redirect, or write retry
is used. Reports contain sanitized GET bodies and status-only authentication.
Python cannot promise secure erasure of immutable strings; secrets stay in this
process's memory and are never accepted through argv, environment, or files.
"""
from __future__ import annotations

import argparse
import base64
from collections import deque
from dataclasses import dataclass
from datetime import datetime
import getpass
import hashlib
import hmac
import http.client
import json
import logging
import os
from pathlib import Path
import re
import socket
import ssl
import stat
import sys
import threading
import time
from urllib.parse import unquote, urlsplit
import warnings


SESSION_COLLECTION = "/redfish/v1/SessionService/Sessions"
PROFILE_ID = "sugon_1_80_oem_rfb"
PROFILE_HEADERS = {"From": "WebUI", "X-Requested-With": "XMLHttpRequest"}
PUBLIC_KEY_SHA256 = "3f3bd3f8a4837161f4dff9c6cce1110d38b2eb1d873d39c6c1d33173eccd71d6"
MAX_BODY = 1024 * 1024
MAX_TOTAL_BODY = 8 * 1024 * 1024
SAFE_CODE = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{0,127}\Z")
COMMON_ID = re.compile(r"(?:[0-9]{1,6}|system|bmc|self|primary|Boot[0-9A-Fa-f]{4})\Z", re.I)
SYSTEM_SELECT_QUERIES = (
    "$select=Id,UUID,Links,GraphicalConsole,Actions",
    "$select=Id,UUID,Links,PowerState,Actions,LastResetTime",
    "$select=Id,UUID,Links,Boot",
    "$select=PowerState",
    "$select=Boot",
)


def valid_rfc3339(value: str) -> bool:
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,9})?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])", value) is None:
        return False
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).tzinfo is not None
    except ValueError:
        return False


class SafeFailure(Exception):
    """Only fixed, locally defined codes may enter reports or the terminal."""


def require(condition: bool, code: str) -> None:
    if not condition:
        raise SafeFailure(code)


def remaining(deadline: float, maximum: float = 8.0) -> float:
    value = min(maximum, deadline - time.monotonic())
    require(value > 0, "deadline_reached")
    return value


def valid_text(value, limit: int, *, controls: bool = True) -> bool:
    return isinstance(value, str) and 0 < len(value.encode("utf-8")) <= limit and (
        not controls or not any(ord(c) < 32 or ord(c) == 127 for c in value))


def validate_input(value: object) -> dict:
    require(isinstance(value, dict), "invalid_connection_schema")
    allowed = {"bmc", "ssh_hops", "known_hosts_path", "approved_tls_leaf_sha256",
               "acceptance_mode", "observe_seconds", "can_autostop"}
    require(not (set(value) - allowed), "invalid_connection_schema")
    require(value.get("acceptance_mode", "read_only") == "read_only", "read_only_required")
    bmc, hops = value.get("bmc"), value.get("ssh_hops")
    require(isinstance(bmc, dict) and set(bmc) <= {"host", "https_port", "username", "password"}, "invalid_bmc_schema")
    require(isinstance(hops, list) and 1 <= len(hops) <= 8, "invalid_ssh_route")
    endpoints = set()
    for endpoint, port_key, default in [(bmc, "https_port", 443)] + [(h, "port", 22) for h in hops]:
        require(isinstance(endpoint, dict), "invalid_endpoint")
        require(set(endpoint) <= {"host", port_key, "username", "password"}, "invalid_endpoint")
        host = endpoint.get("host")
        require(valid_text(host, 253) and not any(c.isspace() or c in "/\\@?#%[]" for c in host), "invalid_host")
        port = endpoint.get(port_key, default)
        require(type(port) is int and 1 <= port <= 65535, "invalid_port")
        require(valid_text(endpoint.get("username"), 256), "invalid_username")
        password_limit = 245 if port_key == "https_port" else 8192
        require(valid_text(endpoint.get("password"), password_limit, controls=False) and "\x00" not in endpoint["password"], "invalid_password")
        if port_key == "port":
            key = (host.casefold(), port)
            require(key not in endpoints and host.casefold() != bmc["host"].casefold(), "invalid_ssh_route")
            endpoints.add(key)
    path = value.get("known_hosts_path")
    require(valid_text(path, 4096) and os.path.isabs(path), "invalid_known_hosts_path")
    try:
        require(stat.S_ISREG(os.stat(path).st_mode), "invalid_known_hosts_path")
    except OSError:
        raise SafeFailure("invalid_known_hosts_path") from None
    pin = value.get("approved_tls_leaf_sha256")
    require(isinstance(pin, str) and re.fullmatch(r"[0-9a-fA-F]{64}", pin) is not None and int(pin, 16) != 0, "invalid_approved_tls_pin")
    return value


class Origin:
    def __init__(self, host: str, port: int = 443):
        self.host, self.port = host, port

    def reference(self, value: str) -> str:
        require(valid_text(value, 2048) and all(32 < ord(c) < 127 for c in value), "unsafe_reference")
        require("\\" not in value and not value.startswith("//"), "unsafe_reference")
        try:
            parsed = urlsplit(value)
            if parsed.scheme or parsed.netloc:
                require(parsed.scheme.lower() == "https" and parsed.username is None and parsed.password is None,
                        "cross_origin_reference")
                require(parsed.hostname is not None and parsed.hostname.casefold() == self.host.casefold() and
                        (parsed.port or 443) == self.port, "cross_origin_reference")
        except ValueError:
            raise SafeFailure("unsafe_reference") from None
        require(not parsed.fragment and parsed.path.startswith("/redfish/v1/") or
                (not parsed.fragment and parsed.path == "/redfish/v1"), "unsafe_reference")
        decoded = unquote(parsed.path)
        require("\\" not in decoded and "//" not in decoded and all(ord(c) >= 32 and ord(c) != 127 for c in decoded), "unsafe_reference")
        require(not any(segment in (".", "..") for segment in decoded.split("/")), "unsafe_reference")
        require(not re.search(r"%(?:2f|5c)", parsed.path, re.I), "unsafe_reference")
        if parsed.query:
            require(parsed.query in SYSTEM_SELECT_QUERIES or
                    re.fullmatch(r"(?:\$(?:skip|top)=[0-9]{1,8}|\$skiptoken=[A-Za-z0-9_.~-]{1,256})(?:&(?:\$(?:skip|top)=[0-9]{1,8}|\$skiptoken=[A-Za-z0-9_.~-]{1,256}))*", parsed.query) is not None,
                    "unsafe_query")
        return parsed.path + ("?" + parsed.query if parsed.query else "")


class RequestGuard:
    """Every network request passes this single gate before any HTTP bytes."""
    def __init__(self, origin: Origin, *, standard_session=False):
        self.origin = origin
        self.standard_session = standard_session
        self.login_reserved = False
        self.logout_reserved = False
        self.own_location = None
        self.own_token = None

    def authorize(self, method: str, resource: str, body: bytes = b"", *, purpose: str = "read", token=None) -> str:
        path = self.origin.reference(resource)
        plain = unquote(urlsplit(path).path).rstrip("/")
        if method == "GET":
            require(not body and purpose == "read", "request_guard_blocked")
            require(not (plain == SESSION_COLLECTION or plain.startswith(SESSION_COLLECTION + "/")), "request_guard_blocked")
            require("/Actions/" not in plain or plain.endswith("ActionInfo"), "request_guard_blocked")
            return path
        if method == "POST":
            require(path == SESSION_COLLECTION and purpose == "web_login" and token is None and not self.login_reserved, "request_guard_blocked")
            try:
                payload = json.loads(body)
                require(isinstance(payload, dict) and set(payload) == {"UserName", "Password"} and
                        valid_text(payload.get("UserName"), 256), "request_guard_blocked")
                if self.standard_session:
                    require(valid_text(payload.get("Password"), 245, controls=False) and "\x00" not in payload["Password"],
                            "request_guard_blocked")
                else:
                    ciphertext = base64.b64decode(payload["Password"], validate=True)
                    require(len(ciphertext) == 256, "request_guard_blocked")
            except (ValueError, TypeError, KeyError):
                raise SafeFailure("request_guard_blocked") from None
            self.login_reserved = True  # Reservation precedes dispatch; a write is never retried.
            return path
        if method == "DELETE":
            require(not body and purpose == "web_logout" and self.own_location is not None and
                    path == self.own_location and token == self.own_token and not self.logout_reserved,
                    "request_guard_blocked")
            self.logout_reserved = True
            return path
        raise SafeFailure("request_guard_blocked")

    def remember_own_session(self, status: int, headers: list[tuple[str, str]]) -> None:
        if status != 201:
            return
        tokens = [v for k, v in headers if k.lower() == "x-auth-token"]
        locations = [v for k, v in headers if k.lower() == "location"]
        require(len(tokens) == len(locations) == 1 and valid_text(tokens[0], 4096), "invalid_web_session_headers")
        path = self.origin.reference(locations[0])
        identifier = path.removeprefix(SESSION_COLLECTION + "/")
        require(path.startswith(SESSION_COLLECTION + "/") and re.fullmatch(r"[A-Za-z0-9_.~-]{1,256}", identifier) is not None and
                identifier not in (".", ".."), "invalid_own_session_location")
        self.own_token, self.own_location = tokens[0], path


def known_host_algorithms(key_types, defaults) -> tuple[str, ...]:
    """Keep default algorithms for already trusted public-key families only.

    RSA/SHA2 host signatures use the same ssh-rsa public key in known_hosts;
    their algorithm aliases must survive filtering when SHA1 is not offered.
    No algorithm absent from Paramiko's existing defaults is introduced.
    """
    accepted = set(key_types)
    if "ssh-rsa" in accepted:
        accepted.update(("rsa-sha2-512", "rsa-sha2-256"))
    return tuple(algorithm for algorithm in defaults if algorithm in accepted)


class SshRoute:
    def __init__(self, config: dict, deadline: float):
        import paramiko
        # Paramiko logs remote banner/negotiation text on some failures. Keep
        # its complete logger subtree silent, including logging.lastResort.
        for name in ["paramiko"] + [name for name in logging.Logger.manager.loggerDict if name.startswith("paramiko.")]:
            logger = logging.getLogger(name)
            logger.handlers[:] = [logging.NullHandler()]
            logger.propagate = False
        self.paramiko, self.config, self.clients = paramiko, config, []
        self.stream_count = 0
        self.pin_checks = 0
        self.deadline = deadline
        self.diagnostics = {"stage": "route_not_started", "hop_number": None, "completed_hops": 0,
                            "known_hosts_entry_present": None, "known_hosts_key_types": [],
                            "host_key_algorithms": [],
                            "failure_category": None, "exception_type": None,
                            "paramiko_version": paramiko.__version__}

    def classify_failure(self, exc: Exception) -> tuple[str, str]:
        """Use exception types/phase only; never stringify remote error text."""
        errors = self.paramiko.ssh_exception
        cases = [
            (self.paramiko.hostkeys.InvalidHostKey, "ssh_known_hosts_format_invalid", "InvalidHostKey"),
            (errors.BadHostKeyException, "ssh_host_key_mismatch", "BadHostKeyException"),
            (errors.BadAuthenticationType, "ssh_auth_method_unsupported", "BadAuthenticationType"),
            (errors.PartialAuthentication, "ssh_authentication_partial", "PartialAuthentication"),
            (errors.AuthenticationException, "ssh_authentication_failed", "AuthenticationException"),
            (errors.IncompatiblePeer, "ssh_algorithm_incompatible", "IncompatiblePeer"),
            (errors.MessageOrderError, "ssh_message_order_invalid", "MessageOrderError"),
            (errors.ChannelException, "ssh_direct_tcpip_rejected", "ChannelException"),
            (errors.NoValidConnectionsError, "ssh_tcp_connect_failed", "NoValidConnectionsError"),
            (socket.gaierror, "ssh_dns_resolution_failed", "gaierror"),
        ]
        for kind, category, name in cases:
            if isinstance(exc, kind):
                return category, name
        if isinstance(exc, errors.SSHException):
            transport = self.clients[-1].get_transport() if self.clients else None
            banner_missing = transport is not None and not getattr(transport, "remote_version", "")
            cause = exc
            saw_timeout = False
            seen = set()
            while cause is not None and id(cause) not in seen:
                seen.add(id(cause))
                saw_timeout = saw_timeout or isinstance(cause, TimeoutError)
                cause = cause.__cause__ or cause.__context__
            if banner_missing:
                return ("ssh_banner_timeout" if saw_timeout else "ssh_banner_or_handshake_failed"), "SSHException"
            if self.diagnostics["known_hosts_entry_present"] is False:
                return "ssh_host_key_unknown", "SSHException"
            return "ssh_protocol_failure", "SSHException"
        if isinstance(exc, TimeoutError):
            return "ssh_timeout", "TimeoutError"
        if isinstance(exc, EOFError):
            return "ssh_peer_closed", "EOFError"
        if isinstance(exc, OSError):
            return ("ssh_known_hosts_read_failed" if self.diagnostics["stage"] == "known_hosts_load" else "ssh_socket_failure"), "OSError"
        for kind, name in [(TypeError, "TypeError"), (ValueError, "ValueError"), (AttributeError, "AttributeError")]:
            if isinstance(exc, kind):
                return "ssh_local_api_or_key_format_failure", name
        return "ssh_unclassified_local_failure", "other"

    def connect(self) -> None:
        previous = None
        try:
            for number, endpoint in enumerate(self.config["ssh_hops"], 1):
                self.diagnostics.update(stage="known_hosts_load", hop_number=number,
                                        known_hosts_entry_present=None, known_hosts_key_types=[], host_key_algorithms=[])
                client = self.paramiko.SSHClient()
                self.clients.append(client)
                client.load_host_keys(self.config["known_hosts_path"])
                client.set_missing_host_key_policy(self.paramiko.RejectPolicy())
                hostkey_name = endpoint["host"] if endpoint.get("port", 22) == 22 else "[{}]:{}".format(endpoint["host"], endpoint["port"])
                entry = client.get_host_keys().lookup(hostkey_name)
                self.diagnostics["known_hosts_entry_present"] = entry is not None
                default_algorithms = self.paramiko.Transport._preferred_keys
                supported = set(default_algorithms)
                self.diagnostics["known_hosts_key_types"] = sorted(key for key in entry if key in supported) if entry else []
                disabled_algorithms = {}
                if entry is not None:
                    allowed_algorithms = known_host_algorithms(entry.keys(), default_algorithms)
                    require(bool(allowed_algorithms), "ssh_known_host_algorithm_unavailable")
                    self.diagnostics["host_key_algorithms"] = list(allowed_algorithms)
                    disabled_algorithms["keys"] = [algorithm for algorithm in default_algorithms if algorithm not in allowed_algorithms]
                stream = None
                if previous is not None:
                    self.diagnostics["stage"] = "hop_direct_tcpip_open"
                    stream = previous.open_channel("direct-tcpip", (endpoint["host"], endpoint.get("port", 22)),
                                                   ("127.0.0.1", 0), timeout=remaining(self.deadline))
                timeout = remaining(self.deadline)
                self.diagnostics["stage"] = "ssh_connect_and_authenticate"
                client.connect(endpoint["host"], port=endpoint.get("port", 22), username=endpoint["username"],
                               password=endpoint["password"], sock=stream, allow_agent=False, look_for_keys=False,
                               timeout=timeout, banner_timeout=timeout, auth_timeout=timeout,
                               disabled_algorithms=disabled_algorithms)
                previous = client.get_transport()
                require(previous is not None and previous.is_authenticated(), "ssh_route_unavailable")
                self.diagnostics["completed_hops"] = number
            self.diagnostics["stage"] = "ssh_route_ready"
        except SafeFailure as exc:
            self.diagnostics["failure_category"] = str(exc)
            raise
        except Exception as exc:
            category, kind = self.classify_failure(exc)
            self.diagnostics.update(failure_category=category, exception_type=kind)
            raise SafeFailure(category) from None

    def open_stream(self, deadline: float):
        require(bool(self.clients), "ssh_route_unavailable")
        transport = self.clients[-1].get_transport()
        require(transport is not None and transport.is_active(), "ssh_route_unavailable")
        target = self.config["bmc"]
        self.stream_count += 1
        require(self.stream_count <= 52, "stream_budget_reached")
        return transport.open_channel("direct-tcpip", (target["host"], target.get("https_port", 443)),
                                      ("127.0.0.1", 0), timeout=remaining(deadline))

    def close(self) -> None:
        for client in reversed(self.clients):
            client.close()
        self.clients.clear()


class SocketBridge:
    """In-process AF_UNIX socketpair; never binds or listens on a TCP port."""
    def __init__(self, channel, deadline: float):
        self.channel = channel
        self.local, self.bridge = socket.socketpair()
        timeout = remaining(deadline)
        self.local.settimeout(timeout)
        self.bridge.settimeout(timeout)
        self.channel.settimeout(timeout)
        self.stopped = threading.Event()
        self.tls_socket = None
        self.timer = threading.Timer(remaining(deadline, 60), self.close)
        self.timer.daemon = True
        self.threads = [threading.Thread(target=self.pump, args=(self.bridge, channel), daemon=True),
                        threading.Thread(target=self.pump, args=(channel, self.bridge), daemon=True)]
        for thread in self.threads:
            thread.start()
        self.timer.start()

    def pump(self, source, destination):
        try:
            while not self.stopped.is_set():
                data = source.recv(65536)
                if not data:
                    # Preserve already-forwarded TLS bytes on a peer's normal
                    # Connection: close instead of closing both endpoints.
                    try:
                        destination.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    return
                destination.sendall(data)
        except (OSError, EOFError):
            self.close()

    def close(self):
        if self.stopped.is_set():
            return
        self.stopped.set()
        self.timer.cancel()
        for stream in (self.channel, self.bridge, self.tls_socket, self.local):
            if stream is None:
                continue
            try:
                stream.shutdown(socket.SHUT_RDWR)
            except (OSError, TypeError):
                pass
            try:
                stream.close()
            except OSError:
                pass


class PinnedConnection(http.client.HTTPConnection):
    def __init__(self, route: SshRoute, deadline: float):
        self.route, self.deadline, self.bridge = route, deadline, None
        bmc = route.config["bmc"]
        super().__init__(bmc["host"], bmc.get("https_port", 443), timeout=remaining(deadline))

    def connect(self):
        bridge = SocketBridge(self.route.open_stream(self.deadline), self.deadline)
        self.bridge = bridge
        try:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE  # Exact approved leaf pin is the trust authority.
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            secured = context.wrap_socket(bridge.local, server_hostname=self.host)
            bridge.tls_socket = secured
            require(not bridge.stopped.is_set(), "tls_stream_closed")
            actual = hashlib.sha256(secured.getpeercert(binary_form=True)).hexdigest()
            require(hmac.compare_digest(actual, self.route.config["approved_tls_leaf_sha256"].lower()), "tls_leaf_pin_mismatch")
            self.route.pin_checks += 1
            self.sock = secured
        except BaseException:
            bridge.close()
            raise

    def close(self):
        super().close()
        if self.bridge is not None:
            self.bridge.close()
            self.bridge = None


@dataclass
class Response:
    status: int
    headers: list[tuple[str, str]]
    body: object
    byte_count: int


class HttpClient:
    def __init__(self, route: SshRoute, guard: RequestGuard, deadline: float):
        self.route, self.guard, self.deadline = route, guard, deadline
        self.connection = PinnedConnection(route, deadline)
        self.total_body_bytes = 0
        self.last_status = None
        self.last_dispatched = False

    def request(self, method: str, resource: str, body: bytes = b"", *, purpose="read", standard=False) -> Response:
        token = self.guard.own_token if purpose != "web_login" else None
        path = self.guard.authorize(method, resource, body, purpose=purpose, token=token)
        remaining(self.deadline)
        headers = {"Accept": "application/json", "Accept-Encoding": "identity"}
        if not standard:
            headers.update(PROFILE_HEADERS)
        if token is not None:
            headers["X-Auth-Token"] = token
        if body:
            headers["Content-Type"] = "application/json"
        self.last_status, self.last_dispatched = None, False
        try:
            if self.connection.sock is None:
                self.connection.connect()  # The pin must pass before credential-bearing bytes.
            self.last_dispatched = True
            self.connection.request(method, path, body=body or None, headers=headers)
            response = self.connection.getresponse()
            self.last_status = response.status
            response_headers = response.getheaders()
            if purpose == "web_login":
                # Capture own Location before body parsing, so malformed/oversized
                # auth bodies still get a bounded, independent cleanup attempt.
                self.guard.remember_own_session(response.status, response_headers)
            length = response.getheader("Content-Length")
            if length is not None:
                require(length.isdecimal() and int(length) <= MAX_BODY, "response_body_limit")
            content = bytearray()
            while True:
                remaining(self.deadline)
                chunk = response.read(min(65536, MAX_BODY + 1 - len(content)))
                if not chunk:
                    break
                content.extend(chunk)
                require(len(content) <= MAX_BODY, "response_body_limit")
            self.total_body_bytes += len(content)
            require(self.total_body_bytes <= MAX_TOTAL_BODY, "response_total_limit")
            try:
                document = json.loads(content) if content else None
            except (ValueError, UnicodeError, RecursionError):
                document = {"_non_json_body": True, "_byte_count": len(content)}
            count = len(content)
            content[:] = b"\0" * count
            return Response(response.status, response_headers, document, count)
        except BaseException:
            self.close()
            raise

    def close(self):
        self.connection.close()


def login_body(config: dict, *, standard_session=False) -> bytes:
    if standard_session:
        return json.dumps({"UserName": config["bmc"]["username"], "Password": config["bmc"]["password"]},
                          separators=(",", ":")).encode()
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import padding, rsa
    key_path = Path(__file__).resolve().parents[1] / "src/plugins/bmc_ikvm/protocol/profile_fixtures/sugon_1_80_rsa2048.pem"
    pem = key_path.read_bytes()
    require(hashlib.sha256(pem).hexdigest() == PUBLIC_KEY_SHA256, "reviewed_public_key_mismatch")
    key = serialization.load_pem_public_key(pem)
    require(isinstance(key, rsa.RSAPublicKey) and key.key_size == 2048, "reviewed_public_key_invalid")
    encrypted = key.encrypt(config["bmc"]["password"].encode("utf-8"), padding.PKCS1v15())
    return json.dumps({"UserName": config["bmc"]["username"], "Password": base64.b64encode(encrypted).decode("ascii")}, separators=(",", ":")).encode()


def evidence(document: object) -> list[dict]:
    result = []
    def visit(value, depth=0):
        if depth > 64 or len(result) >= 128:
            return
        if isinstance(value, dict):
            item = {key: text if isinstance(text, str) and SAFE_CODE.fullmatch(text) else "<redacted>"
                    for key, text in value.items() if key in ("MessageId", "Severity", "MessageSeverity", "code")}
            if item:
                result.append(item)
            for child in value.values():
                visit(child, depth + 1)
        elif isinstance(value, list):
            for child in value:
                visit(child, depth + 1)
    visit(document)
    return result


def has_failure_messages(document: object) -> bool:
    """Interpret failure evidence without promoting an error/Success wrapper."""
    for item in evidence(document):
        if any(str(item.get(key, "")).lower() in ("critical", "warning") for key in ("Severity", "MessageSeverity")):
            return True
        message = item.get("MessageId", "")
        if isinstance(message, str) and re.search(r"(?:Error|Failed|Failure|Denied|Unauthorized|Invalid|Insufficient|NotAllowed|Unavailable|NotFound|Unsupported)", message, re.I):
            return True
        code = item.get("code")
        if code is not None and code != "Base.1.19.Success":
            return True
    return False


class Redactor:
    """Conservative string allowlist; unknown strings become stable placeholders."""
    sensitive = re.compile(r"password|passwd|passphrase|token|secret|authkey|session|serial|uuid|guid|macaddress|hostname|fqdn|dnsname|ipaddress|ipv[46]|username|userid|accountname|email|asset[tag]*", re.I)
    public_keys = {"manufacturer", "model", "productname", "platform", "bmcchipmodel", "firmwareversion", "biosversion", "redfishversion"}
    enum_keys = {"powerstate", "state", "health", "healthrollup", "resettype", "bootsourceoverrideenabled",
                 "bootsourceoverridetarget", "bootsourceoverridemode", "bootmode", "boottype", "bootorder",
                 "aliasbootorder", "bootoptionreference", "bootoptiontype", "bootoptionenabled", "bootprogresstype",
                 "connecttypessupported", "currentbootsource", "currentboottype"}

    def __init__(self, origin: Origin):
        self.origin = origin
        self.key = os.urandom(32)
        self.secrets = set()

    def placeholder(self, value) -> str:
        encoded = str(value).encode("utf-8", errors="replace")
        return "<redacted:" + hmac.new(self.key, encoded, hashlib.sha256).hexdigest()[:12] + ">"

    @staticmethod
    def normalized(key):
        return re.sub(r"[^a-z0-9]", "", key.lower())

    def learn(self, value, key="", depth=0):
        if depth > 64:
            return
        if isinstance(value, dict):
            for name, child in value.items():
                self.learn(child, name, depth + 1)
        elif isinstance(value, list):
            for child in value:
                self.learn(child, key, depth + 1)
        elif isinstance(value, str) and self.sensitive.search(self.normalized(key)):
            if len(value) >= 3:
                self.secrets.add(value)

    def text(self, value: str) -> str:
        for secret in sorted(self.secrets, key=len, reverse=True):
            value = value.replace(secret, self.placeholder(secret))
        value = re.sub(r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", lambda m: self.placeholder(m[0]), value)
        value = re.sub(r"(?i)\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b", lambda m: self.placeholder(m[0]), value)
        value = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", lambda m: self.placeholder(m[0]), value)
        return value

    def resource(self, value: str) -> str:
        try:
            path = self.origin.reference(value)
        except SafeFailure:
            return "<reference-redacted>"
        plain = urlsplit(path).path
        if plain == SESSION_COLLECTION or plain.startswith(SESSION_COLLECTION + "/"):
            return "<session-resource-redacted>"
        # Standard collection/action names and generic aliases remain useful;
        # unknown resource identifiers receive the same placeholder everywhere.
        segments = plain.split("/")
        names = {"", "redfish", "v1", "Systems", "Managers", "Chassis", "BootOptions", "Actions", "ActionInfo",
                 "Settings", "SettingsObject", "SecurityService", "KvmService", "SessionService", "Oem", "Public", "$metadata"}
        cleaned = [segment if segment in names or COMMON_ID.fullmatch(segment) or segment.endswith("ActionInfo")
                   else self.placeholder(unquote(segment)) for segment in segments]
        query = urlsplit(path).query
        suffix = "?" + query if query in SYSTEM_SELECT_QUERIES else ("?<query-redacted>" if query else "")
        return self.text("/".join(cleaned)) + suffix

    def clean(self, value, key="", depth=0):
        if depth > 64:
            return "<depth-limit>"
        if isinstance(value, dict):
            return {name: self.clean(child, name, depth + 1) for name, child in value.items()}
        if isinstance(value, list):
            return [self.clean(child, key, depth + 1) for child in value]
        normalized = self.normalized(key)
        if normalized == "maxconcurrentsessions" and type(value) is int and 0 <= value <= 1000000:
            return value
        if self.sensitive.search(normalized) and isinstance(value, (str, int, float)) and not isinstance(value, bool):
            return self.placeholder(value)
        if not isinstance(value, str):
            return value
        if key == "@odata.id" or key in ("target", "@Redfish.ActionInfo", "Members@odata.nextLink") or value.startswith(("/redfish/v1", "https://")):
            return self.resource(value)
        if key in ("MessageId", "Severity", "MessageSeverity", "code") and SAFE_CODE.fullmatch(value):
            return self.text(value)
        if key in ("@odata.type", "@odata.context") and re.fullmatch(r"[#/A-Za-z0-9_.$~()-]{1,512}", value):
            return self.text(value)
        if normalized in ("id", "systemid", "managerid", "chassisid"):
            return self.text(value) if COMMON_ID.fullmatch(value) else self.placeholder(value)
        if normalized == "lastresettime" and valid_rfc3339(value):
            return value
        if normalized in self.public_keys and len(value) <= 256:
            return self.text(value)
        if (normalized in self.enum_keys or normalized.endswith("allowablevalues")) and SAFE_CODE.fullmatch(value):
            return self.text(value)
        return self.placeholder(value)

    def safe_headers(self, headers):
        result = {}
        for key, value in headers:
            key = key.lower()
            if key == "content-type":
                result[key] = value if re.fullmatch(r"application/(?:json|problem\+json)(?:;\s*charset=[A-Za-z0-9_-]+)?", value, re.I) else "<header-redacted>"
            elif key == "odata-version":
                result[key] = value if re.fullmatch(r"[0-9.]{1,16}", value) else "<header-redacted>"
            elif key == "etag":
                result[key] = self.placeholder(value)
        return result


def related_resources(document: object):
    """Follow only the management resources requested by this collector."""
    follow_keys = {"Systems", "Managers", "Chassis", "Members", "ManagerForServers", "ManagedBy", "SettingsObject",
                   "BootOptions", "SecurityService", "KvmService", "@Redfish.ActionInfo", "ActionInfo"}
    found = []
    def references(value):
        if isinstance(value, str):
            found.append(value)
        elif isinstance(value, dict):
            if isinstance(value.get("@odata.id"), str):
                found.append(value["@odata.id"])
        elif isinstance(value, list):
            for child in value:
                references(child)
    def visit(value, depth=0):
        if depth > 64:
            return
        if isinstance(value, dict):
            for key, child in value.items():
                if key in follow_keys or key in ("Members@odata.nextLink", "@odata.nextLink"):
                    references(child)
                if isinstance(child, (dict, list)):
                    visit(child, depth + 1)
        elif isinstance(value, list):
            for child in value:
                visit(child, depth + 1)
    if isinstance(document, dict):
        references(document)  # A returned @odata.id can reveal a resource alias.
    visit(document)
    return found


def cleanup_confirmed(response: Response) -> bool:
    if response.status == 204:
        return True
    if response.status != 200:
        return False
    if has_failure_messages(response.body):
        return False
    if not isinstance(response.body, dict) or "error" not in response.body:
        return True
    failure = response.body["error"]
    if not isinstance(failure, dict) or failure.get("code") != "Base.1.19.Success":
        return False
    messages = failure.get("@Message.ExtendedInfo")
    return isinstance(messages, list) and 0 < len(messages) <= 64 and all(
        isinstance(m, dict) and m.get("MessageId") == "Base.1.19.Success" and m.get("Severity") == "OK" for m in messages)


def collect(config: dict, *, max_gets=48, seconds=60, compare_standard=False, select_critical_fields=False,
            standard_session=False) -> dict:
    origin = Origin(config["bmc"]["host"], config["bmc"].get("https_port", 443))
    guard, redactor = RequestGuard(origin, standard_session=standard_session), Redactor(origin)
    redactor.secrets.update([config["bmc"]["host"], config["bmc"]["username"], config["bmc"]["password"]])
    for hop in config["ssh_hops"]:
        redactor.secrets.update([hop["host"], hop["username"], hop["password"]])
    deadline = time.monotonic() + seconds
    route, client = None, None
    records = []
    report = {"schema": 1, "collector": "bmc_redfish_readonly", "profile_id": PROFILE_ID,
              "limits": {"get_count": max_gets, "seconds": seconds, "cleanup_seconds": 8, "per_response_bytes": MAX_BODY,
                         "total_response_bytes": MAX_TOTAL_BODY},
              "authentication": {"method": "POST", "resource": SESSION_COLLECTION, "status": None,
                                 "session_mode": "standard_redfish" if standard_session else "web_profile",
                                 "session_type": None,
                                 "body_recorded": False, "token_recorded": False, "dispatched": False},
              "cleanup": {"attempted": False, "dispatched": False, "status": None, "result": "not_created"},
              "select_critical_fields": {"requested": select_critical_fields, "advertised_supported": False, "performed_count": 0},
              "outcome": "failed", "failure_code": None, "failure_stage": None, "responses": [], "skipped_references": 0}
    get_count = 0
    stage = "dependency_and_route_setup"
    def read(path, phase="authenticated", standard=None):
        nonlocal get_count
        standard = standard_session if standard is None else standard
        require(get_count < max_gets, "get_budget_reached")
        get_count += 1
        response = client.request("GET", path, standard=standard)
        redactor.learn(response.body)
        records.append((path, phase, standard, response))
        return response
    try:
        route = SshRoute(config, deadline)
        stage = "ssh_route_connect"
        route.connect()
        client = HttpClient(route, guard, deadline)
        stage = "service_root_anonymous"
        root = read("/redfish/v1/", "anonymous")
        require(root.status == 200 and isinstance(root.body, dict), "service_root_unavailable")
        public_root_body = root.body
        stage = "web_login_encoding"
        body = login_body(config, standard_session=standard_session)
        try:
            stage = "web_login_request"
            login = client.request("POST", SESSION_COLLECTION, body, purpose="web_login", standard=standard_session)
            report["authentication"]["status"] = login.status
        finally:
            body = b""
            report["authentication"]["dispatched"] = client.last_dispatched
            report["authentication"]["status"] = client.last_status
            if client.last_dispatched:
                report["cleanup"]["result"] = "unknown"
        stage = "web_login_validation"
        require(login.status == 201 and guard.own_location is not None, "web_authentication_failed")
        redactor.secrets.update([guard.own_token, guard.own_location, guard.own_location.rsplit("/", 1)[-1]])
        require(isinstance(login.body, dict) and "error" not in login.body and not has_failure_messages(login.body),
                "web_authentication_response_rejected")
        if login.body.get("SessionType") in ("Redfish", "WebUI", "WEB", "Web"):
            report["authentication"]["session_type"] = login.body["SessionType"]
        if isinstance(login.body, dict) and "Id" in login.body:
            require(login.body["Id"] == guard.own_location.rsplit("/", 1)[-1], "web_session_identity_mismatch")
        else:
            raise SafeFailure("web_session_id_missing")
        login = None  # Authentication body is never retained in evidence.
        stage = "service_root_authenticated"
        root = read("/redfish/v1/")
        for source in (public_root_body, root.body):
            if isinstance(source, dict) and isinstance(source.get("ProtocolFeaturesSupported"), dict) and source["ProtocolFeaturesSupported"].get("SelectQuery") is True:
                report["select_critical_fields"]["advertised_supported"] = True
        pending = deque()
        system_collections, system_members = set(), set()
        for collection in ("Systems", "Managers"):
            declared = root.body.get(collection) if isinstance(root.body, dict) else None
            if not isinstance(declared, dict) or not isinstance(declared.get("@odata.id"), str):
                declared = public_root_body.get(collection)
            reference = declared["@odata.id"] if isinstance(declared, dict) and isinstance(declared.get("@odata.id"), str) else "/redfish/v1/" + collection
            pending.append(reference)
            if collection == "Systems":
                try:
                    system_collections.add(urlsplit(origin.reference(reference)).path.rstrip("/"))
                except SafeFailure:
                    pass
        pending.extend(related_resources(public_root_body))
        pending.extend(related_resources(root.body))
        seen = {"/redfish/v1/", "/redfish/v1"}
        compared = {"Systems": False, "Managers": False}
        while pending:
            remaining(deadline)
            path = pending.popleft()
            try:
                path = origin.reference(path)
                # Preflight GETs here without reserving any write authority.
                guard.authorize("GET", path, token=guard.own_token)
            except SafeFailure:
                report["skipped_references"] += 1
                continue
            if path in seen:
                continue
            if get_count >= max_gets:
                raise SafeFailure("get_budget_reached")
            seen.add(path)
            stage = "resource_get"
            response = read(path)
            pending.extend(related_resources(response.body))
            plain = urlsplit(path).path.rstrip("/")
            if plain in system_collections and isinstance(response.body, dict) and isinstance(response.body.get("Members"), list):
                for member in response.body["Members"]:
                    if isinstance(member, dict) and isinstance(member.get("@odata.id"), str):
                        try:
                            member_path = origin.reference(member["@odata.id"])
                            if not urlsplit(member_path).query:
                                system_members.add(member_path.rstrip("/"))
                        except SafeFailure:
                            pass
            if (select_critical_fields and report["select_critical_fields"]["advertised_supported"] and
                    report["select_critical_fields"]["performed_count"] == 0 and plain in system_members and response.status == 200):
                for query in SYSTEM_SELECT_QUERIES:
                    stage = "selected_system_fields_get"
                    selected = read(plain + "?" + query, phase="selected_system_fields")
                    report["select_critical_fields"]["performed_count"] += 1
                    pending.extend(related_resources(selected.body))
            for collection in compared:
                prefix = "/redfish/v1/" + collection + "/"
                if compare_standard and not compared[collection] and plain.startswith(prefix) and "/" not in plain[len(prefix):] and response.status == 200:
                    compared[collection] = True
                    stage = "standard_header_comparison_get"
                    read(path, standard=True)
        report["outcome"] = "complete"
    except SafeFailure as exc:
        report["failure_code"] = str(exc)
        if str(exc) in ("deadline_reached", "get_budget_reached", "response_total_limit"):
            report["outcome"] = "bounded_partial"
    except (KeyboardInterrupt, SystemExit):
        report["failure_code"] = "interrupted"
    except ImportError:
        report["failure_code"] = "dependency_unavailable"
    except Exception:
        report["failure_code"] = "transport_or_protocol_failure"
    finally:
        if report["failure_code"] is not None:
            report["failure_stage"] = stage
        if client is not None:
            client.close()
        if route is not None and guard.own_location is not None:
            report["cleanup"]["attempted"] = True
            cleaner = None
            try:
                # New stream, exact same approved leaf, independent bounded
                # deadline; never reuse a possibly incomplete HTTP stream.
                cleaner = HttpClient(route, guard, time.monotonic() + 8)
                response = cleaner.request("DELETE", guard.own_location, purpose="web_logout", standard=standard_session)
                report["cleanup"].update(status=response.status, result="confirmed" if cleanup_confirmed(response) else "unknown",
                                         message_evidence=redactor.clean(evidence(response.body)))
            except SafeFailure as exc:
                report["cleanup"]["failure_code"] = str(exc)
            except BaseException:
                report["cleanup"]["failure_code"] = "cleanup_transport_or_protocol_failure"
            finally:
                if cleaner is not None:
                    report["cleanup"]["dispatched"] = cleaner.last_dispatched
                    report["cleanup"]["status"] = cleaner.last_status
                    cleaner.close()
        if route is not None:
            report["transport"] = {"ssh_hop_count": len(config["ssh_hops"]), "ssh_host_key_policy": "RejectPolicy",
                                   "stream_kind": "direct-tcpip", "streams_opened": route.stream_count,
                                   "tls_pin_checks": route.pin_checks, "tls_trust_persisted": False,
                                   "ssh_diagnostics": getattr(route, "diagnostics", None)}
            route.close()
        guard.own_token, guard.own_location = None, None
    for path, phase, standard, response in records:
        report["responses"].append({"method": "GET", "resource": redactor.resource(path), "phase": phase,
                                    "header_mode": "standard_token" if standard else "profile", "status": response.status,
                                    "headers": redactor.safe_headers(response.headers), "body": redactor.clean(response.body),
                                    "error_evidence": redactor.clean(evidence(response.body)), "response_bytes": response.byte_count})
    report["get_count"] = get_count
    report["recorded_get_count"] = len(records)
    report["unreadable_get_count"] = sum(not 200 <= response.status < 300 for _, _, _, response in records)
    report["failure_message_get_count"] = sum(has_failure_messages(response.body) for _, _, _, response in records)
    report["error_envelope_get_count"] = sum(isinstance(response.body, dict) and "error" in response.body for _, _, _, response in records)
    if report["outcome"] == "complete" and (report["unreadable_get_count"] or report["failure_message_get_count"]):
        report["outcome"] = "complete_with_read_errors"
    if report["cleanup"]["result"] == "unknown" and report["outcome"] == "complete":
        report["outcome"] = "cleanup_unconfirmed"
    return report


def hidden_input() -> dict:
    require(sys.stdin.isatty(), "interactive_tty_required")
    with warnings.catch_warnings():
        warnings.simplefilter("error", getpass.GetPassWarning)
        text = getpass.getpass("Connection JSON (hidden; memory only): ")
    try:
        require(len(text.encode("utf-8")) <= 65536, "connection_input_limit")
        return validate_input(json.loads(text))
    finally:
        text = ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="New private 0600 JSON report; existing files are refused")
    parser.add_argument("--validate-stdin", action="store_true", help="Validate hidden connection input without network use")
    parser.add_argument("--compare-standard-headers", action="store_true", help="Repeat the first System and Manager GET using only standard token headers")
    parser.add_argument("--select-critical-fields", action="store_true", help="Read five fixed field projections of the first discovered System member when SelectQuery is advertised")
    parser.add_argument("--standard-redfish-session", action="store_true", help="Use the documented standard UserName/Password Session login and standard headers over pinned TLS")
    parser.add_argument("--max-gets", type=int, default=48, choices=range(3, 49), metavar="3..48")
    parser.add_argument("--seconds", type=int, default=60, choices=range(1, 61), metavar="1..60")
    options = parser.parse_args()
    if not options.validate_stdin and options.output is None:
        parser.error("--output is required for collection")
    config = None
    report_file = None
    try:
        config = hidden_input()
        if options.validate_stdin:
            print("REDFISH_READONLY input_validated network_used=false")
            return 0
        descriptor = os.open(options.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        os.fchmod(descriptor, 0o600)
        report_file = os.fdopen(descriptor, "w", encoding="utf-8")
        report = collect(config, max_gets=options.max_gets, seconds=options.seconds,
                         compare_standard=options.compare_standard_headers, select_critical_fields=options.select_critical_fields,
                         standard_session=options.standard_redfish_session)
        json.dump(report, report_file, ensure_ascii=True, indent=2)
        report_file.write("\n")
        report_file.flush()
        print("REDFISH_READONLY outcome=" + report["outcome"] + " gets=" + str(report["get_count"]) +
              " recorded=" + str(report["recorded_get_count"]) + " cleanup=" + report["cleanup"]["result"])
        return 0 if report["outcome"] == "complete" else 1
    except SafeFailure as exc:
        print("REDFISH_READONLY failure=" + str(exc), file=sys.stderr)
        return 2
    except (KeyboardInterrupt, EOFError):
        print("REDFISH_READONLY failure=input_cancelled", file=sys.stderr)
        return 130
    except Exception:
        print("REDFISH_READONLY failure=local_input_or_output_failure", file=sys.stderr)
        return 2
    finally:
        if report_file is not None:
            report_file.close()
        if config is not None:
            config["bmc"]["password"] = ""
            for hop in config["ssh_hops"]:
                hop["password"] = ""
        config = None


if __name__ == "__main__":
    raise SystemExit(main())
