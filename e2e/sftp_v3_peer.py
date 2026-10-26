#!/usr/bin/env python3
"""Disposable in-memory SFTP peer for native V3 file/transfer acceptance."""
import argparse, hashlib, json, os, signal, socket, stat, threading, time
from pathlib import Path
import paramiko
p=argparse.ArgumentParser();p.add_argument('--out',required=True);args=p.parse_args()
out=Path(args.out);out.mkdir(parents=True,exist_ok=True)
key=paramiko.RSAKey.generate(2048)
files={'/fixture/README.md':b'# remote markdown\n', '/fixture/config.json':b'{"native":true}\n', '/fixture/export.yaml':b'real: downloaded\n', '/fixture/export.log':b'actual remote log\n'}
lock=threading.Lock();calls=[];running=True;transports=[]
def record(op,path,**extra):
 with lock:
  calls.append({'op':op,'path':path,**extra})
  (out/'state.json').write_text(json.dumps({'calls':calls,'files':{k:{'bytes':len(v),'sha256':hashlib.sha256(v).hexdigest()} for k,v in files.items()}}))
def attr(path):
 a=paramiko.SFTPAttributes();a.st_mtime=a.st_atime=1700000000
 if path in ['/','/fixture']:a.st_mode=stat.S_IFDIR|0o755;a.st_size=0
 elif path in files:a.st_mode=stat.S_IFREG|0o600;a.st_size=len(files[path])
 else:return paramiko.SFTP_NO_SUCH_FILE
 return a
class Handle(paramiko.SFTPHandle):
 def __init__(self,path,flags):super().__init__(flags);self.path=path
 def stat(self):return attr(self.path)
 def chattr(self,attributes):
  if attributes.st_size is not None:
   size=attributes.st_size
   if size<0 or size>8*1024*1024:return paramiko.SFTP_PERMISSION_DENIED
   current=files[self.path];files[self.path]=current[:size]+b'\0'*max(0,size-len(current));record('TRUNCATE',self.path,bytes=size)
  return paramiko.SFTP_OK
 def read(self,offset,length):
  try:control=json.loads((out/'control.json').read_text())
  except (OSError,ValueError):control={}
  if self.path in control.get('fail_read',[]):record('READ_DENIED',self.path);return paramiko.SFTP_PERMISSION_DENIED
  delay=min(3,max(0,control.get('read_delay_ms',{}).get(self.path,0)/1000));time.sleep(delay)
  data=files[self.path][offset:offset+length];record('READ',self.path,offset=offset,bytes=len(data));return data
 def write(self,offset,data):
  # Keep the real in-flight task visible for native pause/notification checks.
  time.sleep(.4)
  old=files[self.path];files[self.path]=old[:offset]+data+old[offset+len(data):];record('WRITE',self.path,offset=offset,bytes=len(data));return paramiko.SFTP_OK
class Sftp(paramiko.SFTPServerInterface):
 def canonicalize(self,path):return '/fixture' if path in ['.',''] else path.rstrip('/') or '/'
 def stat(self,path):return attr(self.canonicalize(path))
 lstat=stat
 def list_folder(self,path):
  path=self.canonicalize(path);record('LIST',path)
  if path not in ['/','/fixture']:return paramiko.SFTP_NO_SUCH_FILE
  result=[]
  for name in list(files):
   if name.startswith(path.rstrip('/')+'/') and '/' not in name[len(path.rstrip('/'))+1:]:
    a=attr(name);a.filename=name.rsplit('/',1)[-1];result.append(a)
  return result
 def open(self,path,flags,attr_):
  path=self.canonicalize(path)
  if not path.startswith('/fixture/') or '/' in path[len('/fixture/'):]:return paramiko.SFTP_PERMISSION_DENIED
  if flags & (os.O_WRONLY|os.O_RDWR):
   if path.endswith('denied.bin'):return paramiko.SFTP_PERMISSION_DENIED
   if flags & os.O_TRUNC or path not in files:files[path]=b''
  elif path not in files:return paramiko.SFTP_NO_SUCH_FILE
  record('OPEN',path,flags=flags);return Handle(path,flags)
 def remove(self,path):
  if path not in files:return paramiko.SFTP_NO_SUCH_FILE
  del files[path];record('REMOVE',path);return paramiko.SFTP_OK
 def rename(self,old,new):
  if old not in files or new in files:return paramiko.SFTP_FAILURE
  files[new]=files.pop(old);record('RENAME',old,target=new);return paramiko.SFTP_OK
class Server(paramiko.ServerInterface):
 def check_auth_password(self,u,p):return paramiko.AUTH_SUCCESSFUL if (u,p)==('fixture','fixture-only') else paramiko.AUTH_FAILED
 def get_allowed_auths(self,u):return 'password'
 def check_channel_request(self,k,i):return paramiko.OPEN_SUCCEEDED if k=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
 def check_channel_exec_request(self,channel,command):
  # Only the production full-file MD5 verification protocol is supported.
  try:
   text=command.decode();path=next(path for path in files if path in text)
   response=hashlib.md5(files[path]).hexdigest()+'  '+path+'\n'
  except Exception:return False
  def finish():channel.send(response);channel.send_exit_status(0);channel.close()
  threading.Thread(target=finish,daemon=True).start();return True
listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();listener.settimeout(.2)
fp='SHA256:'+__import__('base64').b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip('=')
(out/'ready.json').write_text(json.dumps({'host':'127.0.0.1','port':listener.getsockname()[1],'user':'fixture','password':'fixture-only','fingerprint':fp}))
record('READY','/fixture')
def connect(sock):
 t=paramiko.Transport(sock);transports.append(t);t.add_server_key(key);t.set_subsystem_handler('sftp',paramiko.SFTPServer,Sftp)
 try:t.start_server(server=Server());
 except Exception:return
 while running and t.is_active():time.sleep(.05)
 t.close()
def stop(*_):
 global running;running=False
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
while running:
 try:
  try:control=json.loads((out/'control.json').read_text())
  except (OSError,ValueError):control={}
  if control.get('disconnect_all',False):
   for t in transports:t.close()
   record('DISCONNECT_ALL','/fixture');(out/'control.json').write_text('{}')
  if control.get('tamper_prefix',False):
   path='/fixture/upload-main.txt'
   if len(files.get(path,b''))>32:files[path]=files[path][:25]+b'TAMPER'+files[path][31:];record('TAMPER_PREFIX',path)
   (out/'control.json').write_text('{}')
  client,_=listener.accept();threading.Thread(target=connect,args=(client,),daemon=True).start()
 except socket.timeout:pass
for t in transports:t.close()
listener.close()
