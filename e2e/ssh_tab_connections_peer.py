#!/usr/bin/env python3
"""Owned loopback fixture: independent real ZSH PTYs on each SSH channel."""
import argparse, fcntl, json, logging, os, select, signal, socket, struct, subprocess, termios, threading, time
from pathlib import Path
import paramiko
logging.getLogger('paramiko').setLevel(logging.CRITICAL)
p = argparse.ArgumentParser(); p.add_argument('--out', required=True); p.add_argument('--hold-request', choices=['open','pty','shell']); p.add_argument('--drop-after-eof', action='store_true'); args = p.parse_args()
out = Path(args.out); out.mkdir(parents=True)
(out / '.zshrc').write_text("bindkey -e\nPS1='sshrecords%# '\n")
stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
key = paramiko.RSAKey.generate(2048)
listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(8); listener.settimeout(.1)
port = listener.getsockname()[1]
(out / 'ready.json').write_text(json.dumps(dict(port=port, user='records-fixture', password='records-secret', known_host=f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n')))
class Server(paramiko.ServerInterface):
    def __init__(self): self.requests = {}; self.sizes = {}; self.armed = False; self.held = None; self.pty_ids = set(); self.pending_message = None
    def hold(self, phase, channel_id):
        if args.hold_request==phase and self.armed and self.held is None:
            self.held = (phase,channel_id)
            (out/'held-request.json').write_text(json.dumps(dict(phase=phase,channel=channel_id)))
    def get_allowed_auths(self, user): return 'password'
    def check_auth_password(self, user, password): return paramiko.AUTH_SUCCESSFUL if (user,password)==('records-fixture','records-secret') else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, channel_id):
        self.requests[channel_id] = threading.Event()
        self.hold('open',channel_id)
        return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_pty_request(self, channel, term, width, height, *rest):
        self.sizes[channel.get_id()] = (width,height); self.pty_ids.add(channel.remote_chanid)
        self.hold('pty',channel.remote_chanid)
        return True
    def check_channel_window_change_request(self, channel, width, height, *rest): return True
    def check_channel_shell_request(self, channel):
        self.hold('shell',channel.remote_chanid)
        self.requests[channel.get_id()].set()
        return True

def shell(transport, channel, server, index):
    process = None; master = None; cid = channel.get_id()
    try:
        while not server.requests[cid].wait(.05):
            if not transport.is_active() or stop.is_set() or channel.closed: return
        master, slave = os.openpty(); width,height = server.sizes.get(cid,(100,30))
        fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',height,width,0,0))
        def own_tty(): os.setsid(); fcntl.ioctl(slave,termios.TIOCSCTTY,0)
        process = subprocess.Popen(['/bin/zsh','-i'],stdin=slave,stdout=slave,stderr=slave,preexec_fn=own_tty,env={**os.environ,'HOME':str(out),'ZDOTDIR':str(out),'TERM':'xterm-256color'})
        os.close(slave)
        (out / f'shell-{index}-{cid}.json').write_text(json.dumps(dict(transport=index,channel=cid,pid=process.pid)))
        while transport.is_active() and not stop.is_set() and not channel.closed and process.poll() is None:
            readable,_,_ = select.select([master,channel],[],[],.1)
            if master in readable:
                data=os.read(master,65536)
                if not data: break
                channel.sendall(data)
            if channel in readable:
                data=channel.recv(65536)
                if not data: break
                if b'ZW_ARM_REUSE_HOLD' in data: server.armed = True
                os.write(master,data)
    except (OSError, EOFError, paramiko.SSHException): pass
    finally:
        channel.close()
        if process and process.poll() is None:
            process.terminate()
            try: process.wait(2)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        if master is not None: os.close(master)

def serve(connection,index):
    transport=paramiko.Transport(connection); transport.add_server_key(key); server=Server(); workers=[]
    original_send = transport._send_message
    def send_message(message):
        data=message.asbytes(); kind=data[0] if data else 0
        cid=int.from_bytes(data[1:5],'big') if len(data)>=5 else -1
        if server.held and cid==server.held[1] and kind==(91 if server.held[0]=='open' else 99):
            server.pending_message = message
            return
        if args.drop_after_eof and kind==97 and cid in server.pty_ids and len(server.pty_ids)>1:
            (out/'held-eof-close.json').write_text(json.dumps(dict(channel=cid)))
            threading.Timer(.05,transport.close).start()
            return
        original_send(message)
    transport._send_message=send_message
    (out / f'connection-{index}.json').write_text(json.dumps(dict(transport=index)))
    try:
        transport.start_server(server=server)
        while transport.is_active() and not stop.is_set():
            if server.pending_message is not None and (out/'release-held').exists():
                message, server.pending_message = server.pending_message, None
                original_send(message)
                (out/'released-request.json').write_text(json.dumps(dict(phase=server.held[0])))
            channel=transport.accept(.05)
            if channel is not None:
                worker=threading.Thread(target=shell,args=(transport,channel,server,index),daemon=True); workers.append(worker); worker.start()
    except (OSError,EOFError,paramiko.SSHException): pass
    finally:
        transport.close()
        for worker in workers: worker.join(3)
        (out / f'closed-{index}.json').write_text('{}')
workers=[]
try:
    while not stop.is_set():
        try: connection,_=listener.accept()
        except socket.timeout: continue
        worker=threading.Thread(target=serve,args=(connection,len(workers)+1),daemon=True); workers.append(worker); worker.start()
finally:
    listener.close()
    for worker in workers: worker.join(4)
