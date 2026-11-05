#!/usr/bin/env python3
"""Owned SSH peer running only the production file scripts in a disposable root.
The shell stays live, receives no file payload, and SFTP is explicitly denied.
"""
import argparse
import json
import logging
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import threading
import time
import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)
parser = argparse.ArgumentParser()
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--root", type=Path, required=True)
parser.add_argument("--fault", choices=("none", "post-commit-exit", "disconnect-after-commit", "cancel-before-commit", "cancel-after-commit"), default="none")
args = parser.parse_args()
out, root = args.out.resolve(), args.root.resolve()
out.mkdir(parents=True, exist_ok=True)
repo = Path(__file__).resolve().parents[1]
scripts = [(repo / f"src/host/terminal_file_{kind}.sh").read_text() for kind in ("read", "write")]
key = paramiko.RSAKey.generate(2048)
listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen(8); listener.settimeout(.1)
port = listener.getsockname()[1]
(out / "ready.json").write_text(json.dumps(dict(port=port, user="terminal-fixture", password="disposable-fixture", known_host=f"[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n")))
stop = threading.Event(); lock = threading.Lock(); transports = []; jobs = []
audit = dict(exec_reads=0, exec_writes=0, stdin_bytes=0, shell_input_bytes=0, sftp_requests=0, write_waiting=0, fault_commits=0, errors=[])
def record(**values):
    with lock:
        for name, value in values.items(): audit[name] += value
        (out / "audit.json").write_text(json.dumps(audit))

class Server(paramiko.ServerInterface):
    def get_allowed_auths(self, _): return "password"
    def check_auth_password(self, user, password):
        return paramiko.AUTH_SUCCESSFUL if (user,password)==("terminal-fixture","disposable-fixture") else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, _):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_pty_request(self, *args): return True
    def check_channel_shell_request(self, channel):
        channel.sendall(b"terminal-file-fixture ready\r\n")
        def drain():
            try:
                while not stop.is_set() and not channel.closed:
                    if channel.recv_ready(): record(shell_input_bytes=len(channel.recv(4096)))
                    time.sleep(.01)
            except (EOFError,OSError): pass
        thread=threading.Thread(target=drain,daemon=True);jobs.append(thread);thread.start();return True
    def check_channel_subsystem_request(self, channel, name):
        record(sftp_requests=1);return False
    def check_channel_exec_request(self, channel, command):
        text=command.decode();words=shlex.split(text)
        if words[:4]!=["/usr/bin/env","-i","PATH=/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL=C"]: return False
        words=words[4:]
        if len(words)<6 or words[:2]!=["/bin/sh","-c"] or words[2] not in scripts or words[3]!="zw-file": return False
        if not Path(words[4]).resolve().is_relative_to(root): return False
        write=words[2]==scripts[1];record(**{"exec_writes" if write else "exec_reads":1})
        fault=args.fault if write and audit["exec_writes"]==1 else "none"
        def run():
            try:
                time.sleep(.005)
                payload=bytearray()
                if write:
                    while True:
                        block=channel.recv(16384)
                        if not block: break
                        payload.extend(block)
                        if len(payload)>256*1024: raise ValueError("InputLimit")
                record(stdin_bytes=len(payload))
                if fault=="cancel-before-commit":
                    record(write_waiting=1)
                    while not stop.is_set() and not channel.closed: time.sleep(.01)
                    return
                process=subprocess.run(["/bin/sh","-c",text],input=payload,cwd=root,capture_output=True,timeout=20)
                if fault!="none":
                    assert process.returncode==0 and process.stdout==b"ZWCOMMIT1\n", process.stderr
                    record(fault_commits=1)
                    if fault=="disconnect-after-commit":
                        channel.get_transport().close();return
                    if fault=="post-commit-exit":
                        channel.send_exit_status(7);channel.close();return
                    if fault=="cancel-after-commit":
                        channel.sendall(process.stdout);record(write_waiting=1)
                        while not stop.is_set() and not channel.closed: time.sleep(.01)
                        return
                if process.stdout: channel.sendall(process.stdout)
                if process.stderr: channel.sendall_stderr(process.stderr)
                channel.send_exit_status(process.returncode);channel.close()
            except (EOFError,OSError,paramiko.SSHException): pass
            except Exception as error: record(errors=[str(error)])
        thread=threading.Thread(target=run,daemon=True);jobs.append(thread);thread.start();return True

def serve(connection):
    transport=paramiko.Transport(connection);transports.append(transport);transport.add_server_key(key)
    try:
        transport.start_server(server=Server())
        channels=[]
        while transport.is_active() and not stop.wait(.01):
            channel=transport.accept(.01)
            if channel is not None: channels.append(channel)
    except (EOFError,OSError,paramiko.SSHException): pass
    finally: transport.close()

signal.signal(signal.SIGTERM,lambda *_:stop.set())
signal.signal(signal.SIGINT,lambda *_:stop.set())
try:
    while not stop.is_set():
        try: connection,_=listener.accept()
        except socket.timeout: continue
        thread=threading.Thread(target=serve,args=(connection,),daemon=True);jobs.append(thread);thread.start()
finally:
    listener.close()
    for transport in transports: transport.close()
    for job in jobs: job.join(2)
    record()
