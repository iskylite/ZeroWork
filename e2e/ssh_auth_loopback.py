#!/usr/bin/env python3
"""Real SSH authentication packets over loopback; no shell/channel/remote IO.

Run after building src/ssh_auth_loopback_runner.zig against the vendored SSH
library: python3 e2e/ssh_auth_loopback.py --runner /tmp/zerowork-auth-loopback-runner
Only test method names/counts and outcomes are written to the report.
"""
import argparse
import base64
import hashlib
import json
import logging
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time

from cryptography.hazmat.primitives import padding, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
import paramiko
from paramiko.common import cMSG_USERAUTH_FAILURE
from paramiko.message import Message

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


def cbc_padding_collision_fixture(key):
    """Choose a wrong password with valid CBC padding and invalid inner DER.

    The envelope uses explicit supported PBES2/PBKDF2-SHA256/AES256-CBC.
    This tests the inner ASN.1 failure, rather than relying on random padding.
    """
    def der(tag, value):
        size = len(value).to_bytes((len(value).bit_length() + 7) // 8 or 1, "big")
        return bytes([tag]) + (bytes([len(value)]) if len(value) < 128 else bytes([128 + len(size)]) + size) + value
    def sequence(*values): return der(0x30, b"".join(values))
    def oid(value): return der(6, bytes.fromhex(value))
    salt, iv, rounds = os.urandom(16), os.urandom(16), 2048
    clear = key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    padder = padding.PKCS7(128).padder()
    encryptor = Cipher(algorithms.AES(hashlib.pbkdf2_hmac("sha256", b"fixture-key-passphrase", salt, rounds, 32)), modes.CBC(iv)).encryptor()
    ciphertext = encryptor.update(padder.update(clear) + padder.finalize()) + encryptor.finalize()
    prf = sequence(oid("2a864886f70d0209"), der(5, b""))
    def kdf(iterations=rounds, algorithm=prf):
        return sequence(oid("2a864886f70d01050c"), sequence(der(4, salt), der(2, iterations.to_bytes(2, "big")), algorithm))
    def encryption(vector=iv, algorithm="60864801650304012a"): return sequence(oid(algorithm), der(4, vector))
    def envelope(derivation=None, cipher=None, data=ciphertext):
        return sequence(sequence(oid("2a864886f70d01050d"), sequence(derivation or kdf(), cipher or encryption())), der(4, data))
    def find_wrong(data, derive):
        for index in range(16384):
            wrong = f"owned-padding-collision-{index}"
            decryptor = Cipher(algorithms.AES(derive(wrong.encode())), modes.CBC(iv)).decryptor()
            candidate = decryptor.update(data) + decryptor.finalize()
            amount = candidate[-1]
            if candidate[0] != 0x30 and 1 <= amount <= 16 and candidate[-amount:] == bytes([amount]) * amount:
                return wrong
        raise AssertionError("Could not construct CBC padding collision")
    wrong = find_wrong(ciphertext, lambda value: hashlib.pbkdf2_hmac("sha256", value, salt, rounds, 32))
    def legacy_derive(password):
        derived, previous = b"", b""
        while len(derived) < 32:
            previous = hashlib.md5(previous + password + iv[:8]).digest()
            derived += previous
        return derived[:32]
    legacy_clear = key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption())
    padder = padding.PKCS7(128).padder()
    encryptor = Cipher(algorithms.AES(legacy_derive(b"fixture-key-passphrase")), modes.CBC(iv)).encryptor()
    legacy_ciphertext = encryptor.update(padder.update(legacy_clear) + padder.finalize()) + encryptor.finalize()
    def legacy_pem(data):
        encoded = base64.b64encode(data)
        return b"-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC," + iv.hex().upper().encode() + b"\n\n" + b"\n".join(encoded[index:index + 64] for index in range(0, len(encoded), 64)) + b"\n-----END RSA PRIVATE KEY-----\n"
    legacy = legacy_pem(legacy_ciphertext)
    legacy_wrong = find_wrong(legacy_ciphertext, legacy_derive)
    invalid = {
        "key-envelope-truncated": envelope(data=ciphertext[:-1]),
        "key-envelope-trailing": envelope() + b"\0",
        "key-envelope-cipher-unsupported": envelope(cipher=encryption(algorithm="60864801650304017f")),
        "key-envelope-prf-unsupported": envelope(derivation=kdf(algorithm=sequence(oid("2a864886f70d027f"), der(5, b"")))),
        "key-envelope-iv-invalid": envelope(cipher=encryption(vector=iv[:-1])),
        "key-envelope-iterations-invalid": envelope(derivation=kdf(iterations=0)),
    }
    invalid_legacy = {
        "key-envelope-legacy-truncated": legacy_pem(legacy_ciphertext[:-1]),
        "key-envelope-legacy-cipher-unsupported": legacy.replace(b"AES-256-CBC", b"BAD-256-CBC"),
        "key-envelope-legacy-iv-invalid": legacy.replace(iv.hex().upper().encode(), iv[:-1].hex().upper().encode()),
    }
    return envelope(), wrong, invalid, legacy, legacy_wrong, invalid_legacy


class Server(paramiko.ServerInterface):
    def __init__(self, mode, fixture_key):
        self.mode = mode
        self.fixture_key = fixture_key
        self.first_accepted = False
        self.password_refused = False
        self.methods = []
        self.transport = None

    def get_allowed_auths(self, username):
        if self.mode.startswith("key-"):
            return "publickey"
        if self.mode == "cache":
            return "password"
        if self.mode in ("key", "agent") and not self.first_accepted:
            return "publickey"
        if self.first_accepted or self.password_refused or self.mode == "cancel":
            return "keyboard-interactive"
        return "password,keyboard-interactive"

    def check_auth_none(self, username):
        self.methods.append("none")
        return paramiko.AUTH_FAILED

    def check_auth_password(self, username, password):
        self.methods.append("password")
        if self.mode == "cache":
            return paramiko.AUTH_PARTIALLY_SUCCESSFUL if password == "stage-one" else paramiko.AUTH_SUCCESSFUL if password == "stage-two" else paramiko.AUTH_FAILED
        if self.mode == "malformed":
            packet = Message()
            packet.add_byte(cMSG_USERAUTH_FAILURE)
            packet.add_string("keyboard-interactive")
            packet.add_boolean(True)
            packet.add_byte(b"x")  # Invalid trailing byte: cannot count as PARTIAL.
            self.transport._send_message(packet)
            return paramiko.AUTH_FAILED
        if self.mode == "no-partial":
            self.password_refused = True
            return paramiko.AUTH_FAILED
        if password == "fixture-password":
            self.first_accepted = True
            return paramiko.AUTH_PARTIALLY_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        self.methods.append("publickey")
        if self.mode.startswith("key-"):
            return paramiko.AUTH_SUCCESSFUL if self.mode != "key-rejected" and key == self.fixture_key else paramiko.AUTH_FAILED
        if key == self.fixture_key:
            self.first_accepted = True
            return paramiko.AUTH_PARTIALLY_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_auth_interactive(self, username, submethods):
        self.methods.append("keyboard-interactive")
        return paramiko.InteractiveQuery("Loopback", "Two distinct prompts", ("Account:", True), ("Recovery phrase:", False))

    def check_auth_interactive_response(self, responses):
        self.methods.append("interactive-response")
        return paramiko.AUTH_SUCCESSFUL if responses == ["operator", "arbitrary-length-response"] else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        self.methods.append("UNEXPECTED_CHANNEL")
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


def run_case(runner, mode, host_key, fixture_key, key_file, env):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(8)
    port = listener.getsockname()[1]
    server = Server(mode, fixture_key)
    errors = []
    finished = threading.Event()

    def serve():
        transport = None
        try:
            connection, _ = listener.accept()
            transport = paramiko.Transport(connection)
            transport.add_server_key(host_key)
            server.transport = transport
            transport.start_server(server=server)
            while transport.is_active() and not finished.wait(0.01):
                pass
        except (EOFError, ConnectionResetError, BrokenPipeError, paramiko.SSHException):
            pass  # Expected after a cancelled or deliberately malformed exchange.
        except Exception as exc:
            errors.append(type(exc).__name__)
        finally:
            if transport:
                transport.close()
            listener.close()

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    started = time.monotonic()
    try:
        result = subprocess.run([str(runner), str(port), mode, str(key_file)], env=env, capture_output=True, text=True, timeout=12)
    finally:
        finished.set()
        worker.join(timeout=2)
        listener.close()
    output = (result.stdout + result.stderr).strip()
    passed = result.returncode == 0 and "PASS " in output and not errors and not worker.is_alive() and "UNEXPECTED_CHANNEL" not in server.methods
    record = {"case": mode, "passed": passed, "exit_code": result.returncode, "elapsed_ms": round((time.monotonic() - started) * 1000), "methods": server.methods, "output": output, "server_errors": errors, "no_shell_or_channel": "UNEXPECTED_CHANNEL" not in server.methods}
    if mode in ("password", "no-partial"):
        record["one_password_attempt"] = server.methods.count("password") == 1
        record["passed"] &= record["one_password_attempt"]
    return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("dist/ssh-acceptance/20261018/auth-loopback/report.json"))
    args = parser.parse_args()
    host_key = paramiko.RSAKey.generate(2048)
    fixture_key = paramiko.RSAKey.generate(2048)
    records = []
    with tempfile.TemporaryDirectory(prefix="zerowork-auth-loopback-") as directory:
        key_file = Path(directory) / "encrypted-fixture.pem"
        fixture_key.write_private_key_file(str(key_file), password="fixture-key-passphrase")
        os.chmod(key_file, 0o600)
        openssh_clear = Path(directory) / "clear-openssh"
        openssh_encrypted = Path(directory) / "encrypted-openssh"
        for path, encryption in ((openssh_clear, serialization.NoEncryption()), (openssh_encrypted, serialization.BestAvailableEncryption(b"fixture-key-passphrase"))):
            path.write_bytes(fixture_key.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH, encryption))
            path.chmod(0o600)
        der_clear = Path(directory) / "clear.der"
        der_clear.write_bytes(fixture_key.key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption())); der_clear.chmod(0o600)
        der_encrypted = Path(directory) / "encrypted.der"
        der_encrypted.write_bytes(fixture_key.key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.BestAvailableEncryption(b"fixture-key-passphrase"))); der_encrypted.chmod(0o600)
        collision_der, collision_wrong, invalid_envelopes, legacy_collision, legacy_wrong, invalid_legacy = cbc_padding_collision_fixture(fixture_key.key)
        collision_path = Path(directory) / "padding-collision.der"
        collision_path.write_bytes(collision_der); collision_path.chmod(0o600)
        collision_pem = Path(directory) / "padding-collision.pem"
        encoded_collision = base64.b64encode(collision_der)
        collision_pem.write_bytes(b"-----BEGIN ENCRYPTED PRIVATE KEY-----\n" + b"\n".join(encoded_collision[index:index + 64] for index in range(0, len(encoded_collision), 64)) + b"\n-----END ENCRYPTED PRIVATE KEY-----\n"); collision_pem.chmod(0o600)
        envelope_cases = []
        legacy_collision_path = Path(directory) / "legacy-padding-collision.pem"
        legacy_collision_path.write_bytes(legacy_collision); legacy_collision_path.chmod(0o600)
        for name, blob in invalid_legacy.items():
            path = Path(directory) / name
            path.write_bytes(blob); path.chmod(0o600)
            envelope_cases.append((name, path))
        for name, blob in invalid_envelopes.items():
            path = Path(directory) / name
            path.write_bytes(blob); path.chmod(0o600)
            envelope_cases.append((name, path))
            pem_path = Path(directory) / (name + "-pem")
            encoded = base64.b64encode(blob)
            pem_path.write_bytes(b"-----BEGIN ENCRYPTED PRIVATE KEY-----\n" + b"\n".join(encoded[index:index + 64] for index in range(0, len(encoded), 64)) + b"\n-----END ENCRYPTED PRIVATE KEY-----\n"); pem_path.chmod(0o600)
            envelope_cases.append((name + "-pem", pem_path))
            if name == "key-envelope-trailing":
                envelope_cases.extend(((name + "-unlocked", path), (name + "-pem-unlocked", pem_path)))
        fifo = Path(directory) / "key-fifo"
        os.mkfifo(fifo, 0o600)
        unsupported_key = ec.generate_private_key(ec.SECP256R1())
        unsupported_types = []
        for name, encoding, key_format in (("key-type-pem", serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL), ("key-type-der", serialization.Encoding.DER, serialization.PrivateFormat.PKCS8), ("key-type-openssh", serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH)):
            path = Path(directory) / name
            path.write_bytes(unsupported_key.private_bytes(encoding, key_format, serialization.NoEncryption())); path.chmod(0o600)
            unsupported_types.append((name, path))
        pem_clear = Path(directory) / "clear.pem"
        fixture_key.write_private_key_file(str(pem_clear)); pem_clear.chmod(0o600)
        invalid = Path(directory) / "invalid"
        invalid.write_text("not a private key\n"); invalid.chmod(0o600)
        unsupported = Path(directory) / "unsupported"
        unsupported.write_bytes(openssh_clear.read_bytes().replace(b"OPENSSH PRIVATE KEY", b"UNKNOWN PRIVATE KEY")); unsupported.chmod(0o600)
        corrupt = Path(directory) / "corrupt"
        corrupt.write_bytes(b"-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"); corrupt.chmod(0o600)
        cipher_unsupported = Path(directory) / "unsupported-cipher"
        encrypted_blob = base64.b64decode(b"".join(openssh_encrypted.read_bytes().splitlines()[1:-1]))
        binary = encrypted_blob.replace(b"aes256-ctr", b"bad256-ctr", 1)
        cipher_unsupported.write_bytes(b"-----BEGIN OPENSSH PRIVATE KEY-----\n" + base64.b64encode(binary) + b"\n-----END OPENSSH PRIVATE KEY-----\n"); cipher_unsupported.chmod(0o600)
        oversize = Path(directory) / "oversize"
        oversize.write_bytes(b"x" * (1024 * 1024 + 1)); oversize.chmod(0o600)
        def read_string(blob, offset):
            length = struct.unpack_from(">I", blob, offset)[0]
            return blob[offset + 4:offset + 4 + length], offset + 4 + length
        def ssh_string(value):
            return struct.pack(">I", len(value)) + value
        encrypted_offset = len(b"openssh-key-v1\0")
        for _ in range(3): _, encrypted_offset = read_string(encrypted_blob, encrypted_offset)
        encrypted_offset += 4
        _, encrypted_offset = read_string(encrypted_blob, encrypted_offset)
        encrypted_private, _ = read_string(encrypted_blob, encrypted_offset)
        damaged_encrypted = []
        for name, private_blob in (("key-encrypted-truncated", encrypted_private[:-1]), ("key-encrypted-short", b"x"), ("key-encrypted-short-aligned", b"x" * 16)):
            path = Path(directory) / name
            encoded = base64.b64encode(encrypted_blob[:encrypted_offset] + ssh_string(private_blob))
            path.write_bytes(b"-----BEGIN OPENSSH PRIVATE KEY-----\n" + b"\n".join(encoded[index:index + 70] for index in range(0, len(encoded), 70)) + b"\n-----END OPENSSH PRIVATE KEY-----\n"); path.chmod(0o600)
            damaged_encrypted.append((name, path))
        clear_blob = base64.b64decode(b"".join(openssh_clear.read_bytes().splitlines()[1:-1]))
        offset = len(b"openssh-key-v1\0")
        for _ in range(3): _, offset = read_string(clear_blob, offset)
        offset += 4
        _, offset = read_string(clear_blob, offset)
        private, _ = read_string(clear_blob, offset)
        cursor = 8
        fields = []
        for _ in range(8):
            field, cursor = read_string(private, cursor); fields.append(field)
        def write_variant(name, private_blob):
            path = Path(directory) / name
            blob = clear_blob[:offset] + ssh_string(private_blob)
            encoded = base64.b64encode(blob)
            path.write_bytes(b"-----BEGIN OPENSSH PRIVATE KEY-----\n" + b"\n".join(encoded[index:index + 70] for index in range(0, len(encoded), 70)) + b"\n-----END OPENSSH PRIVATE KEY-----\n"); path.chmod(0o600)
            return path
        # The OpenSSH writer permits no padding when the last field aligns.
        raw = private[:8] + b"".join(ssh_string(value) for value in fields[:7])
        comment = b"x" * ((-len(raw) - 4) % 8)
        zero_padding = write_variant("zero-padding", raw + ssh_string(comment))
        invalid_padding = write_variant("invalid-padding", private[:cursor] + b"\0" * (len(private) - cursor or 8))
        large_fields = list(fields); large_fields[1] = b"\1" * 2049
        raw = private[:8] + b"".join(ssh_string(value) for value in large_fields)
        rsa_oversize = write_variant("rsa-field-oversize", raw + bytes(range(1, 9 - len(raw) % 8)))
        for mode, path in (("key-openssh-zero-padding", zero_padding), ("key-padding-invalid", invalid_padding), ("key-rsa-field-oversize", rsa_oversize)):
            record = run_case(args.runner, mode, host_key, fixture_key, path, os.environ.copy())
            records.append(record)
            print(f"{mode}: {'PASS' if record['passed'] else 'FAIL'}")
        for mode, path, wrong in (("key-der-padding-wrong", collision_path, collision_wrong), ("key-pkcs8-pem-padding-wrong", collision_pem, collision_wrong), ("key-legacy-pem-padding-wrong", legacy_collision_path, legacy_wrong)):
            collision_env = {**os.environ, "ZW_SSH_FIXTURE_PADDING_WRONG": wrong}
            record = run_case(args.runner, mode, host_key, fixture_key, path, collision_env)
            record["wrong_password_has_valid_padding"] = True
            records.append(record)
            print(f"{mode}: {'PASS' if record['passed'] else 'FAIL'}")
        for mode, path in [("key-fifo", fifo), ("key-der-encrypted", der_encrypted), ("key-der-wrong", der_encrypted)] + damaged_encrypted + unsupported_types + envelope_cases:
            record = run_case(args.runner, mode, host_key, fixture_key, path, os.environ.copy())
            records.append(record)
            print(f"{mode}: {'PASS' if record['passed'] else 'FAIL'}")
        for mode, path in (("key-cipher-unsupported", cipher_unsupported), ("key-oversize", oversize), ("key-openssh-clear", openssh_clear), ("key-der-clear", der_clear), ("key-openssh-encrypted", openssh_encrypted), ("key-openssh-wrong", openssh_encrypted), ("key-pem-clear", pem_clear), ("key-pem-encrypted", key_file), ("key-rejected", openssh_clear), ("key-invalid", invalid), ("key-unsupported", unsupported), ("key-corrupt", corrupt), ("key-missing", Path(directory) / "missing")):
            record = run_case(args.runner, mode, host_key, fixture_key, path, os.environ.copy())
            records.append(record)
            print(f"{mode}: {'PASS' if record['passed'] else 'FAIL'}")
        for mode in ("password", "no-partial", "key", "cancel", "malformed", "cache"):
            record = run_case(args.runner, mode, host_key, fixture_key, key_file, os.environ.copy())
            if mode == "key":
                record["case"] = "key-high-bit"
                record["fixture_modulus_bits"] = fixture_key.get_bits()
            records.append(record)
            print(f"{mode}: {'PASS' if record['passed'] else 'FAIL'}")
        ordinary_key = paramiko.RSAKey.generate(2047)
        ordinary_path = Path(directory) / "ordinary-fixture.pem"
        ordinary_key.write_private_key_file(str(ordinary_path), password="fixture-key-passphrase")
        os.chmod(ordinary_path, 0o600)
        record = run_case(args.runner, "key", host_key, ordinary_key, ordinary_path, os.environ.copy())
        record["case"] = "key-ordinary"
        record["fixture_modulus_bits"] = ordinary_key.get_bits()
        records.append(record)
        print(f"key-ordinary: {'PASS' if record['passed'] else 'FAIL'}")
        # Own this agent and isolated socket. Rejected identities surround the
        # accepted one; a later identity must not overwrite its PARTIAL result.
        agent_socket = Path(directory) / "agent.sock"
        agent = subprocess.Popen(["/usr/bin/ssh-agent", "-D", "-a", str(agent_socket)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(100):
                if agent_socket.exists():
                    break
                time.sleep(0.01)
            env = os.environ.copy()
            env["SSH_AUTH_SOCK"] = str(agent_socket)
            for index, key in enumerate((paramiko.RSAKey.generate(2048), fixture_key, paramiko.RSAKey.generate(2048))):
                path = Path(directory) / f"agent-{index}.pem"
                key.write_private_key_file(str(path))
                os.chmod(path, 0o600)
                subprocess.run(["/usr/bin/ssh-add", str(path)], env=env, check=True, capture_output=True)
            record = run_case(args.runner, "agent", host_key, fixture_key, key_file, env)
            # Rejected probe + accepted probe + accepted signed request.
            record["stopped_after_accepted_identity"] = record["methods"].count("publickey") == 3
            record["passed"] &= record["stopped_after_accepted_identity"]
            records.append(record)
            print(f"agent: {'PASS' if record['passed'] else 'FAIL'}")
        finally:
            agent.terminate()
            agent.wait(timeout=2)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"transport": "127.0.0.1 ephemeral port; Paramiko SSH server", "scope": "real auth packets only; no PTY, shell, exec or remote endpoints", "cases": records, "passed": all(item["passed"] for item in records)}, ensure_ascii=False, indent=2) + "\n")
    raise SystemExit(0 if all(item["passed"] for item in records) else 1)


if __name__ == "__main__":
    main()
