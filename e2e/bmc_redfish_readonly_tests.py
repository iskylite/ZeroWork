#!/usr/bin/env python3
"""Offline request-guard, pin-before-credentials, graph, and redaction checks."""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import logging
from pathlib import Path
import socket
import ssl
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import bmc_redfish_readonly as collector


def connection_input(known_hosts):
    return {"bmc": {"host": "bmc.invalid", "username": "operator-sensitive", "password": "bmc-password-sensitive"},
            "ssh_hops": [{"host": "hop.invalid", "username": "hop-operator-sensitive", "password": "hop-password-sensitive"}],
            "known_hosts_path": str(known_hosts), "approved_tls_leaf_sha256": "a" * 64}


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.origin = collector.Origin("bmc.invalid")
        self.guard = collector.RequestGuard(self.origin)
        self.login = json.dumps({"UserName": "operator", "Password": base64.b64encode(bytes(256)).decode()}).encode()

    def test_only_reviewed_web_post_once(self):
        self.guard.authorize("POST", collector.SESSION_COLLECTION, self.login, purpose="web_login")
        with self.assertRaises(collector.SafeFailure):
            self.guard.authorize("POST", collector.SESSION_COLLECTION, self.login, purpose="web_login")

    def test_all_management_writes_and_kvm_creation_blocked(self):
        for method, path, body, purpose in [
            ("PATCH", "/redfish/v1/Systems/system", b"{}", "read"),
            ("PUT", "/redfish/v1/Systems/system", b"{}", "read"),
            ("POST", "/redfish/v1/Systems/system/Actions/ComputerSystem.Reset", b"{}", "read"),
            ("POST", "/redfish/v1/Systems/system/BootOptions", b"{}", "read"),
            ("POST", collector.SESSION_COLLECTION + "/Oem/Public/KvmSessions", self.login, "web_login"),
            ("DELETE", collector.SESSION_COLLECTION + "/somebody-else", b"", "web_logout"),
            ("GET", collector.SESSION_COLLECTION, b"", "read"),
        ]:
            with self.subTest(method=method, path=path), self.assertRaises(collector.SafeFailure):
                self.guard.authorize(method, path, body, purpose=purpose)

    def test_plaintext_login_is_blocked(self):
        with self.assertRaises(collector.SafeFailure):
            self.guard.authorize("POST", collector.SESSION_COLLECTION,
                                 b'{"UserName":"operator","Password":"plaintext"}', purpose="web_login")

    def test_standard_session_is_explicit_once_and_cannot_enable_other_posts(self):
        guard = collector.RequestGuard(self.origin, standard_session=True)
        body = b'{"UserName":"operator","Password":"tls-protected-password"}'
        guard.authorize("POST", collector.SESSION_COLLECTION, body, purpose="web_login")
        with self.assertRaises(collector.SafeFailure):
            guard.authorize("POST", collector.SESSION_COLLECTION, body, purpose="web_login")
        guard = collector.RequestGuard(self.origin, standard_session=True)
        for path in ("/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
                     collector.SESSION_COLLECTION + "/Oem/Public/KvmSessions"):
            with self.assertRaises(collector.SafeFailure):
                guard.authorize("POST", path, body, purpose="web_login")
        for password in ("", "bad\x00password", 1):
            with self.assertRaises(collector.SafeFailure):
                guard.authorize("POST", collector.SESSION_COLLECTION,
                                json.dumps({"UserName": "operator", "Password": password}).encode(), purpose="web_login")

    def test_only_owned_location_can_be_deleted_once(self):
        location = collector.SESSION_COLLECTION + "/owned-session"
        self.guard.remember_own_session(201, [("X-Auth-Token", "owned-token"), ("Location", location)])
        with self.assertRaises(collector.SafeFailure):
            self.guard.authorize("DELETE", collector.SESSION_COLLECTION + "/another", purpose="web_logout", token="owned-token")
        with self.assertRaises(collector.SafeFailure):
            self.guard.authorize("DELETE", location, purpose="web_logout", token="wrong-token")
        self.guard.authorize("DELETE", location, purpose="web_logout", token="owned-token")
        with self.assertRaises(collector.SafeFailure):
            self.guard.authorize("DELETE", location, purpose="web_logout", token="owned-token")

    def test_same_origin_and_path_confusion_rejected(self):
        for path in ["https://other.invalid/redfish/v1/Systems", "http://bmc.invalid/redfish/v1/Systems",
                     "//other.invalid/redfish/v1/Systems", "https://user@bmc.invalid/redfish/v1/Systems",
                     "/redfish/v1/../foo", "/redfish/v1/%2e%2e/foo", "/redfish/v1/%2fSystems",
                     "/redfish/v1/Systems?token=sensitive", "/redfish/v1/Systems#fragment"]:
            with self.subTest(path=path), self.assertRaises(collector.SafeFailure):
                self.origin.reference(path)
        self.assertEqual(self.origin.reference("https://bmc.invalid/redfish/v1/Systems"), "/redfish/v1/Systems")

    def test_select_query_allowlist_remains_get_only(self):
        for query in collector.SYSTEM_SELECT_QUERIES:
            path = "/redfish/v1/Systems/1?" + query
            self.assertEqual(self.guard.authorize("GET", path), path)
            for method in ("PATCH", "PUT", "POST", "DELETE"):
                with self.subTest(method=method, query=query), self.assertRaises(collector.SafeFailure):
                    self.guard.authorize(method, path)
        for query in ("$select=Password", "$select=PowerState,Password", "$select=Id,*", "$select=Boot&$expand=*",
                      "$select=Boot&$filter=Id%20eq%201", "$select=PowerState&$skip=1", "$select=Boot/Password",
                      "$select=Boot&$select=PowerState", "%24select=Boot", "$select=Boot%2cPassword"):
            with self.subTest(query=query), self.assertRaises(collector.SafeFailure):
                self.origin.reference("/redfish/v1/Systems/1?" + query)

    def test_graphical_console_boot_enums_and_message_severity_are_public(self):
        redactor = collector.Redactor(self.origin)
        body = {"GraphicalConsole": {"ConnectTypesSupported": ["KVMIP", "Oem"], "MaxConcurrentSessions": 4},
                "Boot": {"CurrentBootSource": "Pxe", "CurrentBootType": "UEFI"},
                "error": {"code": "Base.1.19.InternalError", "@Message.ExtendedInfo": [{"MessageId": "Base.1.19.InternalError", "MessageSeverity": "Critical", "Message": "private-message"}]},
                "SessionId": 4}
        redactor.learn(body)
        cleaned = redactor.clean(body)
        self.assertEqual(cleaned["GraphicalConsole"], body["GraphicalConsole"])
        self.assertEqual(cleaned["Boot"], body["Boot"])
        self.assertNotEqual(cleaned["SessionId"], 4)
        self.assertEqual(cleaned["error"]["@Message.ExtendedInfo"][0]["MessageSeverity"], "Critical")
        self.assertTrue(collector.has_failure_messages(body))
        self.assertIn({"MessageId": "Base.1.19.InternalError", "MessageSeverity": "Critical"}, collector.evidence(body))
        self.assertNotIn("private-message", json.dumps(cleaned))
        for query in collector.SYSTEM_SELECT_QUERIES:
            self.assertEqual(redactor.resource("/redfish/v1/Systems/1?" + query), "/redfish/v1/Systems/1?" + query)

    def test_oem_resource_ids_use_same_rule_as_id_without_session_exceptions(self):
        redactor = collector.Redactor(self.origin)
        for identifier in ("1", "system", "bmc", "private-resource-id"):
            body = {"Id": identifier, "Oem": {"Public": {"SystemId": identifier, "ManagerId": identifier, "ChassisId": identifier}},
                    "SessionId": "private-session-" + identifier, "UserId": "private-account-" + identifier}
            redactor.learn(body)
            clean = redactor.clean(body)
            for field in ("SystemId", "ManagerId", "ChassisId"):
                self.assertEqual(clean["Oem"]["Public"][field], clean["Id"])
            if collector.COMMON_ID.fullmatch(identifier):
                self.assertEqual(clean["Id"], identifier)
            else:
                self.assertNotEqual(clean["Id"], identifier)
            self.assertNotEqual(clean["SessionId"], body["SessionId"])
            self.assertNotEqual(clean["UserId"], body["UserId"])

    def test_last_reset_time_preserves_only_valid_rfc3339(self):
        redactor = collector.Redactor(self.origin)
        for value in ("2026-11-01T12:34:56Z", "2026-11-01T12:34:56.123456789+08:00", "2024-02-29T00:00:00-05:30"):
            self.assertTrue(collector.valid_rfc3339(value))
            self.assertEqual(redactor.clean({"LastResetTime": value})["LastResetTime"], value)
        for value in ("private-host.invalid", "2026-11-01", "2026-11-01T12:34:56", "2026-02-30T00:00:00Z",
                      "2026-11-01T24:00:00Z", "2026-11-01T12:34:56+25:00", "2026-11-01T12:34:56+08:60",
                      "2026-11-01T12:34:56-00:60", "2026-11-01T12:34:56+24:00", "2026-11-01T12:34:56Z private-id"):
            self.assertFalse(collector.valid_rfc3339(value))
            self.assertNotEqual(redactor.clean({"LastResetTime": value})["LastResetTime"], value)

    def test_ambiguous_or_non_owned_auth_headers_are_rejected(self):
        for headers in [
            [("X-Auth-Token", "one"), ("X-Auth-Token", "two"), ("Location", collector.SESSION_COLLECTION + "/own")],
            [("X-Auth-Token", "one"), ("Location", "https://other.invalid" + collector.SESSION_COLLECTION + "/own")],
            [("X-Auth-Token", "one"), ("Location", collector.SESSION_COLLECTION + "/Oem/Public/KvmSessions/own")],
            [("X-Auth-Token", "one"), ("Location", collector.SESSION_COLLECTION + "/own?token=other")],
        ]:
            with self.subTest(headers=headers), self.assertRaises(collector.SafeFailure):
                self.guard.remember_own_session(201, headers)
            self.assertIsNone(self.guard.own_location)

    def test_cleanup_success_requires_no_conflicting_failure(self):
        body = {"error": {"code": "Base.1.19.Success", "@Message.ExtendedInfo": [{"MessageId": "Base.1.19.Success", "Severity": "OK"}]}}
        self.assertTrue(collector.cleanup_confirmed(collector.Response(200, [], body, 0)))
        body["error"]["@Message.ExtendedInfo"].append({"MessageId": "Base.1.19.InternalError", "Severity": "Critical"})
        self.assertFalse(collector.cleanup_confirmed(collector.Response(200, [], body, 0)))
        self.assertFalse(collector.cleanup_confirmed(collector.Response(202, [], None, 0)))

    def test_redaction_preserves_identity_and_protocol_values(self):
        redactor = collector.Redactor(self.origin)
        body = {"SerialNumber": "serial-sensitive", "HostName": "host-sensitive.invalid", "UUID": "01234567-0123-0123-0123-0123456789ab",
                "MACAddress": "00:11:22:33:44:55", "X-Auth-Token": "token-sensitive", "Password": "password-sensitive",
                "Name": "host-sensitive.invalid serial-sensitive", "Links": {"@odata.id": "/redfish/v1/Systems/serial-sensitive"},
                "PowerState": "On", "Boot": {"BootSourceOverrideEnabled": "Once", "BootOrder": ["Boot0001"]},
                "error": {"code": "Base.1.19.Success", "@Message.ExtendedInfo": [{"MessageId": "Base.1.19.Success", "Severity": "OK", "Message": "serial-sensitive"}]}}
        redactor.learn(body)
        cleaned = redactor.clean(body)
        text = json.dumps(cleaned)
        for private in ("serial-sensitive", "host-sensitive.invalid", "01234567-0123-0123-0123-0123456789ab", "00:11:22:33:44:55", "token-sensitive", "password-sensitive"):
            self.assertNotIn(private, text)
        self.assertEqual(cleaned["PowerState"], "On")
        self.assertEqual(cleaned["Boot"]["BootOrder"], ["Boot0001"])
        self.assertEqual(cleaned["error"]["code"], "Base.1.19.Success")
        self.assertIn(cleaned["SerialNumber"], cleaned["Links"]["@odata.id"])

    def test_schema_rejects_control_modes_and_non_tty_input(self):
        with tempfile.TemporaryDirectory() as directory:
            known_hosts = Path(directory) / "known_hosts"
            known_hosts.write_text("")
            good = connection_input(known_hosts)
            self.assertEqual(collector.validate_input(good)["bmc"]["host"], "bmc.invalid")
            for extra in ({"acceptance_mode": "native_interactive"}, {"operator_approval": "anything"}, {"interactive_seconds": 60}):
                with self.assertRaises(collector.SafeFailure):
                    collector.validate_input({**good, **extra})
        with patch("sys.stdin.isatty", return_value=False), self.assertRaises(collector.SafeFailure):
            collector.hidden_input()


class SshDiagnosticsTests(unittest.TestCase):
    def test_known_rsa_key_keeps_sha2_aliases_and_does_not_add_algorithms(self):
        defaults = ("ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa")
        self.assertEqual(collector.known_host_algorithms(["ssh-rsa"], defaults),
                         ("rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"))
        self.assertEqual(collector.known_host_algorithms(["ssh-rsa"], ("ssh-ed25519", "rsa-sha2-256")), ("rsa-sha2-256",))
        self.assertEqual(collector.known_host_algorithms(["ssh-ed25519"], defaults), ("ssh-ed25519",))
        self.assertEqual(collector.known_host_algorithms(["ssh-dss"], defaults), ())
        self.assertEqual(collector.known_host_algorithms(["ssh-rsa", "ssh-ed25519"], defaults),
                         ("ssh-ed25519", "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"))

    def test_route_passes_known_key_filter_and_retains_exact_key_policy(self):
        import paramiko
        with tempfile.TemporaryDirectory() as directory:
            key = paramiko.RSAKey.generate(2048)
            known_hosts = Path(directory) / "known_hosts"
            known_hosts.write_text("hop.invalid ssh-rsa " + key.get_base64() + "\n")
            config = connection_input(known_hosts)
            client = paramiko.SSHClient()
            with patch.object(paramiko, "SSHClient", return_value=client), patch.object(
                    client, "connect", side_effect=paramiko.AuthenticationException("offline-stop-before-any-network")) as connect:
                report = collector.collect(config)
            disabled = connect.call_args.kwargs["disabled_algorithms"]["keys"]
            self.assertIn("ssh-ed25519", disabled)
            self.assertNotIn("rsa-sha2-512", disabled)
            self.assertNotIn("rsa-sha2-256", disabled)
            self.assertNotIn("ssh-rsa", disabled)
            self.assertIsInstance(client._policy, paramiko.RejectPolicy)
            self.assertEqual(client.get_host_keys().lookup("hop.invalid")["ssh-rsa"], key)
            self.assertEqual(report["transport"]["ssh_diagnostics"]["host_key_algorithms"],
                             [algorithm for algorithm in paramiko.Transport._preferred_keys if algorithm in ("rsa-sha2-512", "rsa-sha2-256", "ssh-rsa")])
            self.assertEqual(report["failure_code"], "ssh_authentication_failed")
            self.assertEqual(known_hosts.read_text(), "hop.invalid ssh-rsa " + key.get_base64() + "\n")

    def test_exception_categories_never_stringify_remote_text(self):
        import paramiko
        route = collector.SshRoute(connection_input("/unused"), time.monotonic() + 5)
        route.clients = [SimpleNamespace(get_transport=lambda: SimpleNamespace(remote_version="SSH-2.0-offline"))]
        route.diagnostics.update(stage="ssh_connect_and_authenticate", known_hosts_entry_present=True)
        errors = paramiko.ssh_exception
        examples = [
            (errors.BadHostKeyException("private-host", None, None), "ssh_host_key_mismatch"),
            (errors.BadAuthenticationType("private-message", ["private-method"]), "ssh_auth_method_unsupported"),
            (errors.AuthenticationException("private-message"), "ssh_authentication_failed"),
            (errors.IncompatiblePeer("private-message"), "ssh_algorithm_incompatible"),
            (errors.ChannelException(1, "private-message"), "ssh_direct_tcpip_rejected"),
            (errors.NoValidConnectionsError({("127.0.0.1", 22): ConnectionRefusedError()}), "ssh_tcp_connect_failed"),
            (socket.gaierror("private-message"), "ssh_dns_resolution_failed"),
            (TypeError("private-message"), "ssh_local_api_or_key_format_failure"),
        ]
        class NeverStringify(errors.SSHException):
            def __str__(self):
                raise AssertionError("Remote text must not be stringified")
        examples.append((NeverStringify(), "ssh_protocol_failure"))
        for exc, expected in examples:
            with self.subTest(expected=expected):
                self.assertEqual(route.classify_failure(exc)[0], expected)
        route.clients = [SimpleNamespace(get_transport=lambda: SimpleNamespace(remote_version=""))]
        timeout = NeverStringify()
        timeout.__cause__ = TimeoutError("private-timeout-message")
        self.assertEqual(route.classify_failure(timeout)[0], "ssh_banner_timeout")
        self.assertEqual(route.classify_failure(NeverStringify())[0], "ssh_banner_or_handshake_failed")
        route.clients = [SimpleNamespace(get_transport=lambda: SimpleNamespace(remote_version="SSH-2.0-offline"))]
        route.diagnostics["known_hosts_entry_present"] = False
        self.assertEqual(route.classify_failure(NeverStringify())[0], "ssh_host_key_unknown")

    def test_ssh_failure_report_has_safe_stage_and_no_credentials_or_remote_text(self):
        import paramiko
        with tempfile.TemporaryDirectory() as directory:
            known_hosts = Path(directory) / "known_hosts"
            known_hosts.write_text("")
            config = connection_input(known_hosts)
            client = paramiko.SSHClient()
            with patch.object(paramiko, "SSHClient", return_value=client), patch.object(
                    client, "connect", side_effect=paramiko.AuthenticationException("remote-sensitive-diagnostic")) as connect:
                report = collector.collect(config)
            self.assertEqual(report["failure_code"], "ssh_authentication_failed")
            self.assertEqual(report["failure_stage"], "ssh_route_connect")
            diagnostics = report["transport"]["ssh_diagnostics"]
            self.assertEqual(diagnostics["exception_type"], "AuthenticationException")
            self.assertEqual(diagnostics["hop_number"], 1)
            self.assertEqual(diagnostics["stage"], "ssh_connect_and_authenticate")
            self.assertEqual(diagnostics["completed_hops"], 0)
            self.assertFalse(diagnostics["known_hosts_entry_present"])
            self.assertIsInstance(client._policy, paramiko.RejectPolicy)
            self.assertFalse(connect.call_args.kwargs["allow_agent"])
            self.assertFalse(connect.call_args.kwargs["look_for_keys"])
            self.assertFalse(report["authentication"]["dispatched"])
            self.assertEqual(report["cleanup"]["result"], "not_created")
            self.assertEqual(report["get_count"], 0)
            text = json.dumps(report)
            for private in ("remote-sensitive-diagnostic", "hop.invalid", "hop-operator-sensitive", "hop-password-sensitive"):
                self.assertNotIn(private, text)

    def test_paramiko_error_logs_are_silent(self):
        collector.SshRoute(connection_input("/unused"), time.monotonic() + 5)
        output = io.StringIO()
        with patch("sys.stderr", output):
            logging.getLogger("paramiko.transport").error("remote-sensitive-existing-logger")
            logging.getLogger("paramiko.new_offline_logger").error("remote-sensitive-new-logger")
        self.assertEqual(output.getvalue(), "")


class OfflineTlsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID
        cls.directory = tempfile.TemporaryDirectory()
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "offline-test.invalid")])
        now = datetime.now(timezone.utc)
        certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
                       .serial_number(1).not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=1)).sign(key, hashes.SHA256()))
        cert_path, key_path = Path(cls.directory.name) / "cert.pem", Path(cls.directory.name) / "key.pem"
        cert_path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
        key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        cls.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        cls.context.load_cert_chain(cert_path, key_path)
        cls.pin = hashlib.sha256(certificate.public_bytes(serialization.Encoding.DER)).hexdigest()

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def route(self, config, handler):
        context = self.context
        class OfflineRoute:
            def __init__(self, config, deadline=None):
                self.config, self.pin_checks, self.stream_count = config, 0, 0
                self.captured, self.threads = [], []
            def connect(self):
                pass
            def open_stream(self, deadline):
                client, peer = socket.socketpair()
                self.stream_count += 1
                def serve():
                    try:
                        with context.wrap_socket(peer, server_side=True) as secured:
                            secured.settimeout(5)
                            pending = b""
                            while True:
                                while b"\r\n\r\n" not in pending:
                                    chunk = secured.recv(65536)
                                    if not chunk:
                                        return
                                    pending += chunk
                                head, pending = pending.split(b"\r\n\r\n", 1)
                                lines = head.decode().split("\r\n")
                                method, path, _ = lines[0].split(" ")
                                headers = dict(line.split(": ", 1) for line in lines[1:])
                                count = int(headers.get("Content-Length", "0"))
                                while len(pending) < count:
                                    pending += secured.recv(65536)
                                body, pending = pending[:count], pending[count:]
                                self.captured.append((method, path, headers, body))
                                status, extra, document = handler(method, path, headers, body)
                                payload = json.dumps(document).encode()
                                response = f"HTTP/1.1 {status} Offline\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\n"
                                for name, value in extra.items():
                                    response += name + ": " + value + "\r\n"
                                secured.sendall(response.encode() + b"\r\n" + payload)
                    except (OSError, ValueError):
                        pass
                thread = threading.Thread(target=serve, daemon=True)
                self.threads.append(thread)
                thread.start()
                return client
            def close(self):
                for thread in self.threads:
                    thread.join(timeout=0.5)
        return OfflineRoute(config)

    def test_pin_mismatch_sends_no_http_or_credentials(self):
        config = connection_input("/unused")
        for standard_session in (False, True):
            with self.subTest(standard_session=standard_session):
                route = self.route(config, lambda *args: (200, {}, {}))
                guard = collector.RequestGuard(collector.Origin("bmc.invalid"), standard_session=standard_session)
                client = collector.HttpClient(route, guard, time.monotonic() + 5)
                with self.assertRaisesRegex(collector.SafeFailure, "tls_leaf_pin_mismatch"):
                    client.request("POST", collector.SESSION_COLLECTION,
                                   collector.login_body(config, standard_session=standard_session),
                                   purpose="web_login", standard=standard_session)
                client.close()
                route.close()
                self.assertEqual(route.captured, [])
                self.assertEqual(route.pin_checks, 0)

    def test_standard_redfish_session_has_no_web_headers_and_secret_free_report(self):
        config = connection_input("/unused")
        config["approved_tls_leaf_sha256"] = self.pin
        location = collector.SESSION_COLLECTION + "/redfish-session-sensitive"
        def handler(method, path, headers, body):
            self.assertNotIn("From", headers)
            self.assertNotIn("X-Requested-With", headers)
            if method == "POST":
                self.assertEqual(path, collector.SESSION_COLLECTION)
                self.assertNotIn("X-Auth-Token", headers)
                self.assertEqual(json.loads(body), {"UserName": config["bmc"]["username"], "Password": config["bmc"]["password"]})
                return 201, {"X-Auth-Token": "redfish-token-sensitive", "Location": location}, {"Id": "redfish-session-sensitive", "SessionType": "Redfish"}
            if method == "DELETE":
                self.assertEqual(path, location)
                self.assertEqual(headers.get("X-Auth-Token"), "redfish-token-sensitive")
                return 200, {}, {"error": {"code": "Base.1.19.Success", "@Message.ExtendedInfo": [{"MessageId": "Base.1.19.Success", "Severity": "OK"}]}}
            self.assertEqual(method, "GET")
            if path == "/redfish/v1/":
                return 200, {}, {"Systems": {"@odata.id": "/redfish/v1/Systems"}, "Managers": {"@odata.id": "/redfish/v1/Managers"}}
            self.assertEqual(headers.get("X-Auth-Token"), "redfish-token-sensitive")
            return 200, {}, {"Members": [], "Members@odata.count": 0}
        route = self.route(config, handler)
        with patch.object(collector, "SshRoute", return_value=route):
            report = collector.collect(config, seconds=15, standard_session=True)
        self.assertEqual(report["outcome"], "complete", report)
        self.assertEqual(report["authentication"]["session_mode"], "standard_redfish")
        self.assertEqual(report["authentication"]["session_type"], "Redfish")
        self.assertEqual(report["cleanup"]["result"], "confirmed")
        self.assertEqual(sum(method == "POST" for method, *_ in route.captured), 1)
        self.assertEqual(sum(method == "DELETE" for method, *_ in route.captured), 1)
        self.assertTrue(all(row["header_mode"] == "standard_token" for row in report["responses"]))
        saved = json.dumps(report)
        for secret in (config["bmc"]["username"], config["bmc"]["password"], "redfish-token-sensitive", "redfish-session-sensitive"):
            self.assertNotIn(secret, saved)

    def test_full_graph_comparison_and_independent_logout(self):
        config = connection_input("/unused")
        config["approved_tls_leaf_sha256"] = self.pin
        root = {"@odata.id": "/redfish/v1/", "Systems": {"@odata.id": "/redfish/v1/Systems"}, "Managers": {"@odata.id": "/redfish/v1/Managers"}}
        documents = {
            "/redfish/v1/": root,
            "/redfish/v1/Systems": {"Members": [{"@odata.id": "/redfish/v1/Systems/system"}]},
            "/redfish/v1/Managers": {"Members": [{"@odata.id": "/redfish/v1/Managers/bmc"}]},
            "/redfish/v1/Systems/system": {"Id": "system", "PowerState": "On", "SerialNumber": "serial-sensitive", "HostName": "host-sensitive.invalid",
                "Links": {"ManagedBy": [{"@odata.id": "/redfish/v1/Managers/bmc"}]},
                "BootOptions": {"@odata.id": "/redfish/v1/Systems/system/BootOptions"},
                "@Redfish.Settings": {"SettingsObject": {"@odata.id": "/redfish/v1/Systems/system/Settings"}},
                "Actions": {"#ComputerSystem.Reset": {"target": "/redfish/v1/Systems/system/Actions/ComputerSystem.Reset", "@Redfish.ActionInfo": "/redfish/v1/Systems/system/ResetActionInfo"}}},
            "/redfish/v1/Managers/bmc": {"Id": "bmc", "FirmwareVersion": "1.80", "Links": {"ManagerForServers": [{"@odata.id": "/redfish/v1/Systems/system"}]}, "SecurityService": {"@odata.id": "/redfish/v1/Managers/bmc/SecurityService"}},
            "/redfish/v1/Systems/system/BootOptions": {"Members": [{"@odata.id": "/redfish/v1/Systems/system/BootOptions/Boot0001"}]},
            "/redfish/v1/Systems/system/BootOptions/Boot0001": {"BootOptionReference": "Boot0001", "DisplayName": "host-sensitive.invalid"},
            "/redfish/v1/Systems/system/Settings": {"Boot": {"BootSourceOverrideTarget": "Pxe"}},
            "/redfish/v1/Systems/system/ResetActionInfo": {"Parameters": [{"Name": "ResetType", "AllowableValues": ["On", "ForceOff"]}]},
            "/redfish/v1/Managers/bmc/SecurityService": {"SecurityMode": "Normal"},
        }
        def handler(method, path, headers, body):
            if method == "POST":
                self.assertEqual(path, collector.SESSION_COLLECTION)
                self.assertEqual(headers.get("From"), "WebUI")
                payload = json.loads(body)
                self.assertEqual(set(payload), {"UserName", "Password"})
                self.assertNotEqual(payload["Password"], config["bmc"]["password"])
                self.assertEqual(len(base64.b64decode(payload["Password"])), 256)
                return 201, {"X-Auth-Token": "session-token-sensitive", "Location": collector.SESSION_COLLECTION + "/session-id-sensitive"}, {"Id": "session-id-sensitive", "AuthMessage": "auth-body-sensitive"}
            if method == "DELETE":
                self.assertEqual(path, collector.SESSION_COLLECTION + "/session-id-sensitive")
                return 200, {}, {"error": {"code": "Base.1.19.Success", "@Message.ExtendedInfo": [{"MessageId": "Base.1.19.Success", "Severity": "OK", "Message": "logout-body-sensitive"}]}}
            return 200, {"Set-Cookie": "cookie-sensitive", "X-Auth-Token": "header-token-sensitive"}, documents[path]
        route = self.route(config, handler)
        with patch.object(collector, "SshRoute", return_value=route):
            report = collector.collect(config, seconds=15, compare_standard=True)
        self.assertEqual(report["outcome"], "complete", report)
        self.assertEqual(report["cleanup"]["result"], "confirmed")
        self.assertEqual(route.stream_count, 2)
        self.assertEqual(route.pin_checks, 2)
        self.assertEqual(sum(method == "POST" for method, *_ in route.captured), 1)
        self.assertEqual(sum(method == "DELETE" for method, *_ in route.captured), 1)
        self.assertEqual({method for method, *_ in route.captured}, {"GET", "POST", "DELETE"})
        self.assertEqual(sum(item["header_mode"] == "standard_token" for item in report["responses"]), 2)
        for method, _, headers, _ in route.captured:
            if method == "GET" and "X-Auth-Token" in headers and "From" not in headers:
                self.assertNotIn("X-Requested-With", headers)
        text = json.dumps(report)
        for private in ("serial-sensitive", "host-sensitive.invalid", "session-token-sensitive", "session-id-sensitive", "auth-body-sensitive", "logout-body-sensitive", "cookie-sensitive", "header-token-sensitive", "bmc.invalid"):
            self.assertNotIn(private, text)
        resources = [item["resource"] for item in report["responses"]]
        self.assertIn("/redfish/v1/Systems/system/BootOptions/Boot0001", resources)
        self.assertIn("/redfish/v1/Managers/bmc/SecurityService", resources)

    def test_fixed_system_projections_preserve_critical_and_follow_chassis_kvm_links(self):
        for advertised, budget in ((True, 48), (False, 48), (True, 8)):
            with self.subTest(advertised=advertised, budget=budget):
                config = connection_input("/unused")
                config["approved_tls_leaf_sha256"] = self.pin
                failure = {"code": "Base.1.19.InternalError", "@Message.ExtendedInfo": [{"MessageId": "Base.1.19.InternalError", "MessageSeverity": "Critical", "Message": "private-critical-message"}]}
                root = {"ProtocolFeaturesSupported": {"SelectQuery": advertised},
                        "Systems": {"@odata.id": "/redfish/v1/Systems"}, "Managers": {"@odata.id": "/redfish/v1/Managers"},
                        "Chassis": {"@odata.id": "/redfish/v1/Chassis"}}
                system = {"Id": "1", "PowerState": "On", "UUID": "01234567-0123-0123-0123-0123456789ab",
                          "GraphicalConsole": {"ConnectTypesSupported": ["KVMIP"], "MaxConcurrentSessions": 4},
                          "Boot": {"CurrentBootSource": "Pxe", "CurrentBootType": "UEFI"}, "error": failure}
                documents = {
                    "/redfish/v1/": root,
                    "/redfish/v1/Systems": {"Members": [{"@odata.id": "/redfish/v1/Systems/1"}, {"@odata.id": "/redfish/v1/Systems/2"}]},
                    "/redfish/v1/Managers": {"Members": [{"@odata.id": "/redfish/v1/Managers/bmc"}]},
                    "/redfish/v1/Chassis": {"Members": [{"@odata.id": "/redfish/v1/Chassis/1"}]},
                    "/redfish/v1/Systems/1": system, "/redfish/v1/Systems/2": {"Id": "2", "PowerState": "Off"},
                    "/redfish/v1/Chassis/1": {"Id": "1"},
                    "/redfish/v1/Managers/bmc": {"Oem": {"Public": {"KvmService": {"@odata.id": "/redfish/v1/Managers/bmc/Oem/Public/KvmService"}}}},
                    "/redfish/v1/Managers/bmc/Oem/Public/KvmService": {"ServiceEnabled": True},
                }
                def handler(method, path, headers, body):
                    if method == "POST":
                        return 201, {"X-Auth-Token": "private-session-token", "Location": collector.SESSION_COLLECTION + "/private-session-id"}, {"Id": "private-session-id"}
                    if method == "DELETE":
                        return 200, {}, {"error": {"code": "Base.1.19.Success", "@Message.ExtendedInfo": [{"MessageId": "Base.1.19.Success", "Severity": "OK"}]}}
                    if "?" in path:
                        plain, query = path.split("?", 1)
                        self.assertEqual(plain, "/redfish/v1/Systems/1")
                        self.assertIn(query, collector.SYSTEM_SELECT_QUERIES)
                        fields = query.removeprefix("$select=").split(",")
                        selected = {key: value for key, value in system.items() if key in fields}
                        if "Boot" in fields:
                            selected["error"] = failure
                        return 200, {}, selected
                    return 200, {}, documents[path]
                route = self.route(config, handler)
                with patch.object(collector, "SshRoute", return_value=route):
                    report = collector.collect(config, max_gets=budget, seconds=15, select_critical_fields=True)
                selected_requests = [path for method, path, *_ in route.captured if method == "GET" and "?" in path]
                if advertised and budget == 48:
                    self.assertEqual(selected_requests, ["/redfish/v1/Systems/1?" + query for query in collector.SYSTEM_SELECT_QUERIES])
                    self.assertEqual(report["select_critical_fields"]["performed_count"], 5)
                    self.assertEqual(report["failure_message_get_count"], 3)
                    self.assertEqual(report["outcome"], "complete_with_read_errors")
                    resources = [item["resource"] for item in report["responses"]]
                    self.assertIn("/redfish/v1/Chassis/1", resources)
                    self.assertIn("/redfish/v1/Managers/bmc/Oem/Public/KvmService", resources)
                elif not advertised:
                    self.assertEqual(selected_requests, [])
                    self.assertEqual(report["select_critical_fields"]["performed_count"], 0)
                else:
                    self.assertEqual(report["outcome"], "bounded_partial")
                    self.assertLess(len(selected_requests), 5)
                self.assertLessEqual(report["get_count"], budget)
                self.assertEqual(report["cleanup"]["result"], "confirmed")
                self.assertEqual(sum(method == "POST" for method, *_ in route.captured), 1)
                self.assertEqual(sum(method == "DELETE" for method, *_ in route.captured), 1)
                self.assertNotIn("private-critical-message", json.dumps(report))
                normal = next(item for item in report["responses"] if item["resource"] == "/redfish/v1/Systems/1")
                self.assertEqual(normal["body"]["error"]["@Message.ExtendedInfo"][0]["MessageSeverity"], "Critical")

    def run_failure_fixture(self, *, login_document=None, denied_get=False, broken_get=False, oversized_login=False):
        config = connection_input("/unused")
        config["approved_tls_leaf_sha256"] = self.pin
        root = {"Systems": {"@odata.id": "/redfish/v1/Systems"}, "Managers": {"@odata.id": "/redfish/v1/Managers"}}
        def handler(method, path, headers, body):
            if method == "POST":
                document = login_document or {"Id": "session-id-sensitive"}
                if oversized_login:
                    document = {"Id": "session-id-sensitive", "SecretBlob": "x" * (collector.MAX_BODY + 1)}
                return 201, {"X-Auth-Token": "session-token-sensitive", "Location": collector.SESSION_COLLECTION + "/session-id-sensitive"}, document
            if method == "DELETE":
                return 200, {}, {"error": {"code": "Base.1.19.Success", "@Message.ExtendedInfo": [{"MessageId": "Base.1.19.Success", "Severity": "OK"}]}}
            if path == "/redfish/v1/":
                return 200, {}, root
            if broken_get:
                raise OSError("synthetic transport failure must not enter report")
            if denied_get:
                return 401, {}, {"error": {"code": "Base.1.19.InsufficientPrivilege", "@Message.ExtendedInfo": [{"MessageId": "Base.1.19.InsufficientPrivilege", "Severity": "Critical", "Message": "remote-sensitive-message"}]}}
            return 200, {}, {"Members": []}
        route = self.route(config, handler)
        with patch.object(collector, "SshRoute", return_value=route):
            report = collector.collect(config, seconds=15)
        self.assertEqual(report["cleanup"]["result"], "confirmed", report)
        self.assertEqual(route.stream_count, 2)
        self.assertEqual(route.pin_checks, 2)
        self.assertEqual(sum(method == "POST" for method, *_ in route.captured), 1)
        self.assertEqual(sum(method == "DELETE" for method, *_ in route.captured), 1)
        text = json.dumps(report)
        for secret in ("session-token-sensitive", "session-id-sensitive", "remote-sensitive-message", "synthetic transport failure"):
            self.assertNotIn(secret, text)
        return report

    def test_critical_auth_body_is_rejected_and_own_session_cleaned(self):
        report = self.run_failure_fixture(login_document={"Id": "session-id-sensitive", "@Message.ExtendedInfo": [{"MessageId": "Base.1.19.GeneralError", "Severity": "Critical"}]})
        self.assertEqual(report["outcome"], "failed")
        self.assertEqual(report["failure_code"], "web_authentication_response_rejected")
        self.assertEqual(report["authentication"]["status"], 201)

    def test_401_gets_are_not_reported_as_complete(self):
        report = self.run_failure_fixture(denied_get=True)
        self.assertEqual(report["outcome"], "complete_with_read_errors")
        self.assertEqual(report["unreadable_get_count"], 2)
        self.assertEqual(report["failure_message_get_count"], 2)

    def test_broken_get_uses_independent_cleanup(self):
        report = self.run_failure_fixture(broken_get=True)
        self.assertEqual(report["outcome"], "failed")
        self.assertEqual(report["failure_code"], "transport_or_protocol_failure")

    def test_oversized_auth_body_still_cleans_captured_owned_location(self):
        report = self.run_failure_fixture(oversized_login=True)
        self.assertEqual(report["outcome"], "failed")
        self.assertEqual(report["failure_code"], "response_body_limit")
        self.assertEqual(report["authentication"]["status"], 201)


if __name__ == "__main__":
    unittest.main(verbosity=2)
