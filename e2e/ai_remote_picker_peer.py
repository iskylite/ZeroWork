#!/usr/bin/env python3
"""Owned memory-only SSH/SFTP peer for AI selection; never executes shell input."""
import argparse, base64, hashlib, io, json, logging, signal, socket, stat, threading, time
from pathlib import Path
import paramiko
logging.getLogger('paramiko').setLevel(logging.CRITICAL)
p=argparse.ArgumentParser();p.add_argument('--out',required=True);o=Path(p.parse_args().out);o.mkdir(parents=True,exist_ok=True)
stop=threading.Event();signal.signal(signal.SIGTERM,lambda *_:stop.set())
key=paramiko.RSAKey.generate(2048)
entries={'/fixture/a.txt':b'first captured source\n','/fixture/b.log':b'second captured source\n'}
class Server(paramiko.ServerInterface):
 def check_auth_password(self,u,p):return paramiko.AUTH_SUCCESSFUL if (u,p)==('fixture','ai-readonly') else paramiko.AUTH_FAILED
 def get_allowed_auths(self,u):return 'password'
 def check_channel_request(self,k,i):return paramiko.OPEN_SUCCEEDED if k=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
 def check_channel_pty_request(self,*a):return True
 def check_channel_shell_request(self,ch):
  def prompt():
   time.sleep(.1);ch.send(b'\x1b]7;file://localhost/fixture\x07fixture$ ')
  threading.Thread(target=prompt,daemon=True).start();return True
class Files(paramiko.SFTPServerInterface):
 def canonicalize(self,path):return '/fixture' if path=='.' else path
 def stat(self,path):
  a=paramiko.SFTPAttributes();a.st_mode=(stat.S_IFDIR|0o755) if path in ('/','/fixture','.') else (stat.S_IFREG|0o644);a.st_size=len(entries.get(path,b''));a.st_mtime=1700000000;a.st_atime=1700000000;return a if path in ('/','/fixture','.') or path in entries else paramiko.SFTP_NO_SUCH_FILE
 lstat=stat
 def list_folder(self,path):
  if path not in ('/fixture','.'):return paramiko.SFTP_NO_SUCH_FILE
  result=[]
  for name in entries:
   a=self.stat(name);a.filename=name.rsplit('/',1)[-1];result.append(a)
  return result
 def open(self,path,flags,attr):
  if path not in entries:return paramiko.SFTP_NO_SUCH_FILE
  h=paramiko.SFTPHandle(flags);h.readfile=io.BytesIO(entries[path]);h.stat=lambda:self.stat(path);return h
sock=socket.socket();sock.bind(('127.0.0.1',0));sock.listen(8);sock.settimeout(.2)
(o/'ready.json').write_text(json.dumps({'port':sock.getsockname()[1],'known_host':f'[127.0.0.1]:{sock.getsockname()[1]} {key.get_name()} {key.get_base64()}\n'}))
transports=[]
def serve(c):
 t=paramiko.Transport(c);transports.append(t);t.add_server_key(key);t.set_subsystem_handler('sftp',paramiko.SFTPServer,Files)
 try:
  t.start_server(server=Server())
  while t.is_active() and not stop.is_set():time.sleep(.1)
 except Exception:pass
 finally:t.close()
while not stop.is_set():
 try:c,_=sock.accept();threading.Thread(target=serve,args=(c,),daemon=True).start()
 except socket.timeout:pass
for t in transports:t.close()
sock.close()
