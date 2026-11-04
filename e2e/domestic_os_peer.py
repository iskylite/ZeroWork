#!/usr/bin/env python3
"""Owned loopback SSH peer for OS discovery; no commands run on this machine."""
import argparse
import json
import logging
from pathlib import Path
import signal
import socket
import threading

import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)
parser = argparse.ArgumentParser()
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=True)
stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
key = paramiko.RSAKey.generate(2048)
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(32)
listener.settimeout(.1)
port = listener.getsockname()[1]
(args.out / "ready.json").write_text(json.dumps({"port": port, "known_host": f"[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n"}))
ids = {"kylin", "neokylin", "openkylin", "ubuntukylin", "uos", "deepin", "openeuler", "euleros", "anolis", "opencloudos", "tencentos", "alinux", "loongnix", "aosc", "bclinux", "kylinsec", "nfs", "linx", "isoft", "redflag"}
international_ids = {"rhel": "rhel", "centos": "centos", "almalinux": "almalinux", "oraclelinux": "ol", "sles": "sles", "opensuse": "opensuse-leap", "amazonlinux": "amzn", "nixos": "nixos", "gentoo": "gentoo", "kali": "kali", "linuxmint": "linuxmint", "manjaro": "manjaro", "openbsd": None, "netbsd": None}
international_ids.update({"debian": "debian", "alpine": "alpine", "freebsd": None})
ids.update(international_ids)
os_probe_command = b'sh -c "uname -s || exit; if test -r /etc/os-release; then cat /etc/os-release; elif test -r /usr/lib/os-release; then cat /usr/lib/os-release; fi" || cmd /c ver'


class Server(paramiko.ServerInterface):
    def __init__(self):
        self.user = None
        self.shells = []

    def get_allowed_auths(self, _):
        return "password"

    def check_auth_password(self, user, password):
        self.user = user
        return paramiko.AUTH_SUCCESSFUL if user in ids and password == "fixture-only" else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, _):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, *_):
        return True

    def check_channel_shell_request(self, channel):
        while (args.out / f"hold-shell-{self.user}").exists() and not stop.is_set():
            (args.out / f"held-shell-{self.user}").touch()
            stop.wait(.05)
        if stop.is_set():
            return False
        self.shells.append(channel)
        channel.sendall(f"OS discovery fixture: {self.user}\r\nfixture# ".encode())
        return True

    def check_channel_exec_request(self, channel, command):
        if command != os_probe_command:
            (args.out / "unexpected-exec.txt").write_bytes(command)
            return False
        user = self.user

        def reply():
            output = f'Linux\nNAME="{user}"\nID="{user}"\nID_LIKE="debian rhel fedora"\n'
            if user in international_ids:
                release_id = international_ids[user]
                output = f'Linux\nID="{release_id}"\nID_LIKE="rhel debian arch"\n' if release_id else {"openbsd": "OpenBSD\n", "netbsd": "NetBSD\n", "freebsd": "FreeBSD\n"}[user]
            if user == "kylin":
                output = 'Linux\nNAME="Kylin Linux Advanced Server"\nVERSION="V11 (Swan25)"\nID="kylin"\nVERSION_ID="V11"\nPRETTY_NAME="Kylin Linux Advanced Server V11 (Swan25)"\n'
            try:
                channel.sendall(output.encode())
                channel.send_exit_status(0)
                channel.close()
                (args.out / f"probed-{user}").write_text(output)
            except (OSError, EOFError):
                pass

        threading.Thread(target=reply, daemon=True).start()
        return True


def serve(connection):
    transport = paramiko.Transport(connection)
    transport.add_server_key(key)
    channels = []
    try:
        server = Server()
        transport.start_server(server=server)
        while transport.is_active() and not stop.is_set():
            if (args.out / f"drop-{server.user}").exists():
                (args.out / f"dropped-{server.user}").touch()
                break
            output = args.out / f"output-{server.user}"
            if output.exists():
                data = output.read_bytes()
                output.unlink()
                for shell in server.shells:
                    if not shell.closed:
                        shell.sendall(data)
            exiting = args.out / f"exit-{server.user}"
            if exiting.exists():
                exiting.unlink()
                for shell in server.shells:
                    if not shell.closed:
                        shell.send_exit_status(0)
                        shell.close()
            channel = transport.accept(.1)
            if channel:
                channels.append(channel)
    except (OSError, EOFError, paramiko.SSHException):
        pass
    finally:
        transport.close()


workers = []
try:
    while not stop.is_set():
        try:
            connection, _ = listener.accept()
        except socket.timeout:
            continue
        worker = threading.Thread(target=serve, args=(connection,), daemon=True)
        workers.append(worker)
        worker.start()
finally:
    listener.close()
    for worker in workers:
        worker.join(2)
