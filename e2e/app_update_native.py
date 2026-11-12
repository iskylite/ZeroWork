#!/usr/bin/env python3
"""Run the real helper against disposable signed apps; never touch installed app/data.
Build first: zig build build-update-tools -Dtest-mode=true -Doptimize=ReleaseFast -j2
"""
import argparse, base64, hashlib, json, os, pathlib, plistlib, shutil, signal, subprocess, tempfile, time, uuid, zipfile
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
ROOT=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bin-dir',type=pathlib.Path,default=ROOT/'zig-out/bin')
parser.add_argument('--output',type=pathlib.Path,default=ROOT/'dist/update-validation')
args=parser.parse_args()
OUT=args.output;OUT.mkdir(parents=True,exist_ok=True)
FIXTURE=(args.bin_dir/'update-fixture').resolve();HELPER=(args.bin_dir/'ZeroWorkUpdater').resolve()
IDENTITY=subprocess.check_output(['python3','scripts/macos_signing.py','identity'],cwd=ROOT,text=True).strip()
TRUST=json.loads((ROOT/'src/update/trust.json').read_bytes())
KEY=Ed25519PrivateKey.from_private_bytes((pathlib.Path.home()/'Library/Application Support/com.zerowork.signing/update-ed25519.key').read_bytes())
checks=[]
def run(args,**kw): return subprocess.run([str(x) for x in args],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kw)
def write(path,value):
 temp=path.with_name(path.name+'.tmp');temp.write_text(json.dumps(value));temp.chmod(0o600);os.replace(temp,path)
def wait(fn, timeout=20):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  result=fn()
  if result:return result
  time.sleep(.035)
 raise AssertionError('timed out: '+str(fn))
def record(path):
 try:return json.loads((path/'record.json').read_bytes())
 except (FileNotFoundError,json.JSONDecodeError):return {}
def app(path,version):
 (path/'Contents/MacOS').mkdir(parents=True);shutil.copy2(FIXTURE,path/'Contents/MacOS/ZeroWork')
 (path/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.zerowork.app','CFBundleExecutable':'ZeroWork','CFBundlePackageType':'APPL','CFBundleName':'ZeroWork update fixture','ZeroWorkReleaseVersion':version,'CFBundleVersion':version,'CFBundleShortVersionString':version.split('-')[0]}))
 run(['codesign','--force','--sign',IDENTITY,'--identifier','com.zerowork.app',path])
def version(path):return plistlib.loads((path/'Contents/Info.plist').read_bytes())['ZeroWorkReleaseVersion']
def seal(payload):
 raw=json.dumps(payload,separators=(',',':'),sort_keys=True).encode()
 return {'key_id':TRUST['key_id'],'payload_base64':base64.b64encode(raw).decode(),'signature_base64':base64.b64encode(KEY.sign(raw)).decode()}
class Case:
 def __init__(self,name,mode='healthy',crash=None):
  self.base=pathlib.Path(tempfile.mkdtemp(prefix='zw-update-'+name+'-')).resolve();self.target=self.base/'ZeroWork.app';self.data=self.base/'data';self.data.mkdir();self.stop=self.base/'stop';self.newstop=self.base/'new-stop';self.processes=[]
  app(self.target,'0.3.0-rc1');candidate=self.base/'candidate/ZeroWork.app';app(candidate,'0.3.1')
  digest=hashlib.sha256((str(self.target)+'\n'+str(self.data)).encode()).hexdigest()[:32]
  self.root=pathlib.Path.home()/'Library/Application Support/com.zerowork.updater'/digest;self.root.mkdir(mode=0o700,parents=True)
  self.txn=self.root/('txn-'+str(uuid.uuid4()));self.txn.mkdir(mode=0o700)
  archive=self.txn/'update.zip';run(['ditto','-c','-k','--keepParent','--norsrc','--noextattr',candidate,archive])
  with zipfile.ZipFile(archive) as z: expanded=sum(x.file_size for x in z.infolist())
  payload={'schema':1,'version':'0.3.1','minimum_os':'14.0','arch':'arm64','url':'https://github.com/iskylite/ZeroWork/releases/download/v0.3.1/ZeroWork-0.3.1-arm64.zip','release_url':'https://github.com/iskylite/ZeroWork/releases/tag/v0.3.1','bytes':archive.stat().st_size,'expanded_bytes':expanded,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'notes':'Isolated signed fixture'}
  write(self.txn/'envelope.json',seal(payload));write(self.txn/'workspace.json',{'phase':'before-close','windows':[{'tabs':['fixture-local']}],'replay_tasks':False})
  helper=self.txn/'ZeroWorkUpdater';shutil.copy2(HELPER,helper);helper.chmod(0o700);run(['codesign','--force','--sign',IDENTITY,'--identifier','com.zerowork.updater',helper])
  parent=subprocess.Popen([str(self.target/'Contents/MacOS/ZeroWork'),'--parent',str(self.stop)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);self.processes.append(parent)
  pid,birth=map(int,parent.stdout.readline().split());self.parent=parent
  self.initial={'stage':'preparing','decision':'undecided','target':str(self.target),'data':str(self.data),'version':'0.3.1','old_version':'0.3.0-rc1','parent_pid':pid,'parent_birth':birth,'nonce':str(uuid.uuid4()),'helper_pid':0,'helper_birth':0,'data_state':'unchanged','theme':[.1,.1,.1,1,.9,.9,.9,1,.6,.6,.6,1,.2,.5,.8,1]}
  write(self.txn/'record.json',self.initial);write(self.root/'active.json',{'transaction':str(self.txn)})
  self.env=os.environ|{'ZW_UPDATE_HEADLESS':'1','ZW_UPDATE_FIXTURE_MODE':mode,'ZW_UPDATE_FIXTURE_DATA':str(self.data),'ZW_UPDATE_FIXTURE_NEW_STOP':str(self.newstop)}
  if crash:self.env['ZW_UPDATE_CRASH_AT_STAGE']=crash
 def start(self):
  log=(self.base/'helper.log').open('ab');p=subprocess.Popen([str(self.txn/'ZeroWorkUpdater'),str(self.txn)],env=self.env,stdout=log,stderr=log);self.processes.append(p);return p
 def stage(self,*names,timeout=20):return wait(lambda: (r if (r:=record(self.txn)).get('stage') in names else None),timeout)
 def request(self,kind):write(self.txn/(kind+'.request'),{'nonce':record(self.txn)['nonce']})
 def prepare(self):self.start();return self.stage('prepared')
 def commit(self):self.request('commit');r=self.stage('waiting_parent');assert r['decision']=='committed';return r
 def exit_parent(self):self.stop.touch();self.parent.wait(timeout=8)
 def done(self,name):
  r=record(self.txn);shutil.copy2(self.txn/'record.json',OUT/(name+'.json'));assert (self.txn/'workspace.json').exists();checks.append({'name':name,'stage':r.get('stage'),'decision':r.get('decision')})
 def close(self):
  self.stop.touch();self.newstop.touch()
  r=record(self.txn)
  # Only processes created by this fixture, with matching birth identity.
  pid=r.get('new_pid',0)
  if pid:
   try:
    birth=int(subprocess.check_output([str(FIXTURE),'--birth',str(pid)],text=True).strip())
    if birth==r.get('new_birth') and birth:os.kill(pid,signal.SIGTERM)
   except (ProcessLookupError,subprocess.CalledProcessError):pass
  for p in self.processes:
   if p.poll() is None:p.terminate()
   try:p.wait(timeout=5)
   except subprocess.TimeoutExpired:p.kill();p.wait()
  shutil.rmtree(self.base);shutil.rmtree(self.root)
def case(name,fn,**kwargs):
 c=Case(name,**kwargs)
 try:fn(c);c.done(name)
 except Exception:
  print('FAILED',name,record(c.txn),(c.base/'helper.log').read_text(errors='replace') if (c.base/'helper.log').exists() else '')
  raise
 finally:c.close()
def cancelled(c):
 c.prepare();c.request('cancel');c.stage('cancelled');c.request('commit');c.exit_parent();time.sleep(.2);assert version(c.target)=='0.3.0-rc1';assert record(c.txn)['decision']=='cancelled'
case('cancel-before-commit',cancelled)
def vanished(c):
 c.prepare();c.exit_parent();c.stage('cancelled');assert version(c.target)=='0.3.0-rc1'
case('prepare-is-not-install-permission',vanished)
def committed(c):
 c.prepare();c.commit();c.request('cancel');assert c.parent.poll() is None;c.exit_parent();r=c.stage('healthy');assert version(c.target)=='0.3.1';assert pathlib.Path(r['backup']).exists();assert r['decision']=='committed'
case('commit-wins-late-cancel-and-healthy-start',committed)
def delayed_healthy(c,restart=False):
 c.env['ZW_UPDATE_TEST_READINESS_SECONDS']='.2'
 c.prepare();c.commit();c.exit_parent();r=c.stage('readiness_unknown')
 assert r['data_state']=='potentially_changed' and (c.txn/'data-may-change.json').exists()
 if restart:
  helper=c.processes[-1];helper.terminate();helper.wait(timeout=5);c.start()
 for field,value in [('nonce','stale-nonce'),('pid',r['new_pid']+1),('birth',r['new_birth']+1)]:
  receipt={'nonce':r['nonce'],'pid':r['new_pid'],'birth':r['new_birth'],'version':r['version']};receipt[field]=value
  write(c.txn/'healthy.request',receipt);time.sleep(.15);assert record(c.txn)['stage']=='readiness_unknown'
 (c.txn/'healthy.request').unlink()
 c.newstop.touch();r=c.stage('healthy');assert version(c.target)=='0.3.1'
 healthy=json.loads((c.txn/'healthy.request').read_bytes())
 assert healthy['pid']==r['new_pid'] and healthy['birth']==r['new_birth'] and healthy['nonce']==r['nonce']
case('late-authentication-can-complete-update',delayed_healthy,mode='delayed-healthy')
case('restarted-helper-accepts-late-health-for-same-process',lambda c:delayed_healthy(c,True),mode='delayed-healthy')
def delayed_gate(c):
 c.env['ZW_UPDATE_TEST_STARTUP_SECONDS']='.2'
 c.prepare();c.commit();c.exit_parent();r=c.stage('readiness_unknown')
 assert r['data_state']=='unchanged' and not (c.txn/'data-may-change.json').exists()
 c.newstop.touch();r=c.stage('healthy');assert r['data_state']=='potentially_changed'
 assert version(c.target)=='0.3.1'
case('late-startup-handshake-can-complete-update',delayed_gate,mode='delayed-gate')
def restored(c):
 c.prepare();c.commit();c.exit_parent();r=c.stage('old_restored_verified');assert version(c.target)=='0.3.0-rc1';assert r['data_state']=='unchanged'
case('launch-failure-restores-verified-old-app',restored,mode='early-crash')
def changed(c):
 c.prepare();c.commit();c.exit_parent();r=c.stage('incompatible_data');assert version(c.target)=='0.3.1';assert pathlib.Path(r['backup']).exists();assert (c.txn/'data-may-change.json').exists()
 # Explicit repair may launch the same or a newer signed compatible app, never old.
 c.env['ZW_UPDATE_FIXTURE_MODE']='healthy';c.request('repair');c.start();c.stage('healthy');assert version(c.target)=='0.3.1'
case('data-access-prevents-old-launch-and-compatible-repair-works',changed,mode='changed-crash')
def crash(c):
 c.prepare();c.commit();c.exit_parent();c.stage('backup_verified');wait(lambda:c.processes[-1].poll() is not None);assert not c.target.exists();c.env.pop('ZW_UPDATE_CRASH_AT_STAGE');c.start();c.stage('healthy');assert version(c.target)=='0.3.1'
case('crash-after-backup-reconciles-same-transaction',crash,crash='backup_verified')
def missing_backup(c):
 c.prepare();c.commit();c.exit_parent();r=c.stage('new_started');shutil.rmtree(r['backup']);c.newstop.touch();r=c.stage('restore_failed');assert version(c.target)=='0.3.1';assert (c.root/'active.json').exists()
case('restore-failure-preserves-recovery-gate',missing_backup,mode='before-gate-wait')
def timeout(c):
 c.prepare();c.commit();c.stage('aborted_before_replace',timeout=35);assert c.parent.poll() is None;assert record(c.txn)['decision']=='committed';c.exit_parent();time.sleep(.2);assert version(c.target)=='0.3.0-rc1'
case('parent-exit-timeout-revokes-replacement-without-kill',timeout)
# Real verifier rejects signature mutation, payload overflow, and unsafe archives.
with tempfile.TemporaryDirectory(prefix='zw-update-validation-') as temp:
 base=pathlib.Path(temp)
 with zipfile.ZipFile(base/'traversal.zip','w') as z:z.writestr('ZeroWork.app/../../escaped','x')
 p=subprocess.run([str(FIXTURE),'--extract',str(base/'traversal.zip'),str(base/'extract'), '100'],capture_output=True)
 assert p.returncode!=0 and not (base/'escaped').exists();checks.append({'name':'zip-traversal-rejected'})
 for name in ('symlink','absolute','duplicate','size-limit'):
  archive=base/(name+'.zip')
  with zipfile.ZipFile(archive,'w') as z:
   if name=='symlink':
    entry=zipfile.ZipInfo('ZeroWork.app/escape');entry.create_system=3;entry.external_attr=(0o120777<<16);z.writestr(entry,'../../outside')
   elif name=='absolute':z.writestr('/tmp/ZeroWork.app/escape','x')
   elif name=='duplicate':z.writestr('ZeroWork.app/file','x');z.writestr('ZeroWork.app/file','y')
   else:z.writestr('ZeroWork.app/large',b'x'*70000)
  p=subprocess.run([str(FIXTURE),'--extract',str(archive),str(base/name),'1'],capture_output=True)
  assert p.returncode!=0,name;checks.append({'name':'zip-'+name+'-rejected'})
report={'checks':checks,'status':'passed','scope':'disposable signed fixtures only; no installed app/data replaced'}
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
