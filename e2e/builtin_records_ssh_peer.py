#!/usr/bin/env python3
"""Disposable loopback SSH server forwarding one actual local ZSH PTY.
No fake command output is produced by this fixture. All shell-channel input is
retained solely to assert app commands never reached the SSH transport.
"""
import argparse
import fcntl
import json
import logging
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import termios
import threading
import time
import paramiko
logging.getLogger("paramiko").setLevel(logging.CRITICAL)
parser = argparse.ArgumentParser()
parser.add_argument("--out", required=True)
args = parser.parse_args()
out = Path(args.out); out.mkdir(parents=True)
stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())
key = paramiko.RSAKey.generate(2048)
listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen(4); listener.settimeout(.1)
port = listener.getsockname()[1]
(out / ".zshrc").write_text("bindkey -e\nPS1=$'%{\\e]133;A\\a%}sshrecords%# %{\\e]133;B\\a%}'\npreexec() { printf '\\033]133;C\\007'; }\nprecmd() { printf '\\033]133;D;0\\007'; }\n")
(out / "ready.json").write_text(json.dumps(dict(port=port, user="records-fixture", password="records-secret", known_host=f"[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n")))

class Server(paramiko.ServerInterface):
    def __init__(self): self.shell = threading.Event(); self.size = (100, 30); self.master = None
    def get_allowed_auths(self, _): return "password"
    def check_auth_password(self, user, password): return paramiko.AUTH_SUCCESSFUL if (user,password)==("records-fixture","records-secret") else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, _): return paramiko.OPEN_SUCCEEDED if kind=="session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_pty_request(self, channel, term, width, height, *rest): self.size=(width,height); return True
    def check_channel_window_change_request(self, channel, width, height, *rest):
        self.size=(width,height)
        if self.master is not None:
            try: fcntl.ioctl(self.master,termios.TIOCSWINSZ,struct.pack("HHHH",height,width,0,0))
            except OSError: pass
        return True
    def check_channel_shell_request(self, _): self.shell.set(); return True

connections = []
def serve(connection, index):
    transport = paramiko.Transport(connection); transport.add_server_key(key)
    server=Server(); process=None; master=None
    try:
        transport.start_server(server=server); channel=transport.accept(10)
        if channel is None or not server.shell.wait(10): return
        master, slave = os.openpty(); server.master=master
        fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack("HHHH",server.size[1],server.size[0],0,0))
        process=subprocess.Popen(["/bin/zsh","-i"],stdin=slave,stdout=slave,stderr=slave,start_new_session=True,env={**os.environ,"HOME":str(out),"ZDOTDIR":str(out),"TERM":"xterm-256color"})
        os.close(slave)
        received=bytearray()
        with (out / f"received-{index}.bin").open("wb") as audit:
            while not stop.is_set() and transport.is_active() and process.poll() is None:
                readable,_,_=select.select([master,channel],[],[],.1)
                if master in readable:
                    try: block=os.read(master,65536)
                    except OSError: break
                    if not block: break
                    channel.sendall(block)
                if channel in readable:
                    block=channel.recv(65536)
                    if not block: break
                    received.extend(block); audit.write(block); audit.flush(); os.write(master,block)
                    if len(received)>1024*1024: raise ValueError("FixtureInputLimit")
            if process.poll() is not None: channel.send_exit_status(process.returncode)
        channel.close()
    except (OSError,EOFError,paramiko.SSHException): pass
    finally:
        transport.close()
        if process is not None and process.poll() is None:
            process.terminate()
            try: process.wait(2)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        if master is not None: os.close(master)
        if process is not None: (out / f"closed-{index}.json").write_text(json.dumps(dict(pid=process.pid,exit_code=process.returncode,transport_active=transport.is_active())))

try:
    while not stop.is_set():
        try: connection,_=listener.accept()
        except socket.timeout: continue
        thread=threading.Thread(target=serve,args=(connection,len(connections)+1),daemon=True); connections.append(thread); thread.start()
finally:
    listener.close()
    for thread in connections: thread.join(3)
