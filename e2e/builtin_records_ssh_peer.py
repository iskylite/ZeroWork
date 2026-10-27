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
parser.add_argument("--sftp-root", type=Path, help="Allow SFTP reads/writes only inside this disposable test directory")
args = parser.parse_args()
out = Path(args.out); out.mkdir(parents=True)
root = args.sftp_root.resolve() if args.sftp_root else None
if root: root.mkdir(parents=True, exist_ok=False)
stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())
key = paramiko.RSAKey.generate(2048)
listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen(4); listener.settimeout(.1)
port = listener.getsockname()[1]
(out / ".zshrc").write_text("bindkey -e\nPS1=$'%{\\e]133;A\\a%}sshrecords%# %{\\e]133;B\\a%}'\npreexec() { printf '\\033]133;C\\007'; }\nprecmd() { printf '\\033]133;D;0\\007'; }\n")
(out / "ready.json").write_text(json.dumps(dict(port=port, user="records-fixture", password="records-secret", known_host=f"[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n")))

class Server(paramiko.ServerInterface):
    def __init__(self): self.shell = threading.Event(); self.size = (100, 30); self.master = None; self.term = ""
    def get_allowed_auths(self, _): return "password"
    def check_auth_password(self, user, password): return paramiko.AUTH_SUCCESSFUL if (user,password)==("records-fixture","records-secret") else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, _): return paramiko.OPEN_SUCCEEDED if kind=="session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_pty_request(self, channel, term, width, height, *rest):
        self.size=(width,height); self.term=term.decode("ascii")
        (out / "pty-request.json").write_text(json.dumps(dict(term=self.term,cols=width,rows=height)))
        return True
    def check_channel_window_change_request(self, channel, width, height, *rest):
        self.size=(width,height)
        if self.master is not None:
            try: fcntl.ioctl(self.master,termios.TIOCSWINSZ,struct.pack("HHHH",height,width,0,0))
            except OSError: pass
        return True
    def check_channel_shell_request(self, _): self.shell.set(); return True

class Handle(paramiko.SFTPHandle):
    def stat(self):
        try:
            stream = getattr(self, "writefile", None) or self.readfile
            return paramiko.SFTPAttributes.from_stat(os.fstat(stream.fileno()))
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno or 13)
    def chattr(self, attrs):
        try:
            stream = getattr(self, "writefile", None) or self.readfile
            if attrs.st_size is not None: os.ftruncate(stream.fileno(), attrs.st_size)
            if attrs.st_mode is not None: os.fchmod(stream.fileno(), attrs.st_mode)
            return paramiko.SFTP_OK
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno or 13)

class Files(paramiko.SFTPServerInterface):
    """Real files, bounded to the run-owned test root, including symlink targets."""
    def path(self, value):
        candidate = (root / value if not os.path.isabs(value) else Path(value)).resolve()
        if not candidate.is_relative_to(root): raise PermissionError(value)
        return candidate
    def canonicalize(self, path):
        try: return str(self.path(path))
        except OSError: return str(root)
    def stat(self, path):
        try: return paramiko.SFTPAttributes.from_stat(self.path(path).stat())
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno or 13)
    lstat = stat
    def list_folder(self, path):
        try:
            result = []
            for child in self.path(path).iterdir():
                item = paramiko.SFTPAttributes.from_stat(child.stat()); item.filename = child.name; result.append(item)
            return result
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno or 13)
    def open(self, path, flags, attrs):
        try:
            fd = os.open(self.path(path), flags, 0o600)
            mode = "r+b" if flags & os.O_RDWR else "wb" if flags & os.O_WRONLY else "rb"
            stream = os.fdopen(fd, mode, buffering=0)
            handle = Handle(flags)
            if flags & (os.O_WRONLY | os.O_RDWR): handle.writefile = stream
            if not flags & os.O_WRONLY: handle.readfile = stream
            return handle
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno or 13)
    def rename(self, old, new):
        try: self.path(old).rename(self.path(new)); return paramiko.SFTP_OK
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno or 13)
    posix_rename = rename
    def remove(self, path):
        try: self.path(path).unlink(); return paramiko.SFTP_OK
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno or 13)
    def mkdir(self, path, attrs):
        try: self.path(path).mkdir(); return paramiko.SFTP_OK
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno or 13)
    def chattr(self, path, attrs):
        try: paramiko.SFTPServer.set_file_attr(str(self.path(path)), attrs); return paramiko.SFTP_OK
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno or 13)

connections = []
def serve(connection, index):
    transport = paramiko.Transport(connection); transport.add_server_key(key)
    server=Server(); process=None; master=None
    try:
        if root: transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files)
        transport.start_server(server=server); channel=transport.accept(10)
        if channel is None: return
        if not server.shell.wait(1 if root else 10):
            while transport.is_active() and not stop.wait(.1): pass
            return
        master, slave = os.openpty(); server.master=master
        fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack("HHHH",server.size[1],server.size[0],0,0))
        def own_tty():
            os.setsid()
            fcntl.ioctl(slave,termios.TIOCSCTTY,0)
        process=subprocess.Popen(["/bin/zsh","-i"],stdin=slave,stdout=slave,stderr=slave,preexec_fn=own_tty,cwd=root,env={**os.environ,"HOME":str(out),"ZDOTDIR":str(out),"TERM":server.term})
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
