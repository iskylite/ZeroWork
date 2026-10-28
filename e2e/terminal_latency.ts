/** Owned native input pipeline benchmark. Frame-return is not key-to-photon.
 * A trace's first output is only called echo after this fixture verifies text.
 * Usage: node e2e/terminal_latency.ts BINARY OUTPUT [local|ssh]
 */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,realpath,mkdir,readFile,writeFile,open,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {createHash} from 'node:crypto';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
import {waitForServerReady,waitFor,query,clickTestId,type_,key,resizeWindow,screenshot,stats,resetTiming} from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]),mode=process.argv[4]??'local';
assert(['local','ssh'].includes(mode));await mkdir(out,{recursive:false});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-input-latency-'))),data=join(iso,'data'),rpc=join(iso,'rpc');
await mkdir(data);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const sleep=(ms:number)=>new Promise(r=>setTimeout(r,ms));
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any):string=>flat(n).map(x=>x.text??'').join('');
const visible=async(id:string)=>(await query(id)).find(shown);
const report:any={mode,binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),limits:['Synthetic native Harness input; UI dispatch to frame-return, not physical key-to-photon.','First returned output is a candidate; sequential isolated input is separately verified in visible text.','Concurrent/overlapping inputs are excluded by the diagnostic; no input contents are logged.','Test build and loopback peer; no private network or user credentials.'],phases:{}};
const appLog=await open(join(out,'app.log'),'w');let app:any,peer:any;let peerEnd:Promise<any>|undefined,appEnd:Promise<any>|undefined;
function samples(log:string){return log.split('\n').filter(x=>x.startsWith('[terminal-latency]')).map(line=>Object.fromEntries([...line.matchAll(/(\w+)=(\d+)/g)].map(m=>[m[1],Number(m[2])])));}
function summary(values:number[]){const s=[...values].sort((a,b)=>a-b);return {n:s.length,p50:s[Math.floor(s.length*.5)]??null,p95:s[Math.min(s.length-1,Math.ceil(s.length*.95)-1)]??null,max:s.at(-1)??null};}
async function traces(){return samples(await readFile(join(out,'app.log'),'utf8'));}
async function rows(){return (await query('terminal.surface')).filter(shown).flatMap(flat).filter(n=>n.test_id?.startsWith('terminal.surface.row.')&&shown(n));}
async function screen(){return (await rows()).map(text).join('');}
async function command(command:string){await type_(command);await key('enter');}
async function typing(label:string){
 await sleep(250);const start=(await traces()).length;let typed='';const observations:number[]=[];
 for(const c of 'abcdefghijklmnopqrstuvwxyz012345'){
  typed+=c;const before=(await traces()).length,at=performance.now();await type_(c);
  // Observe the log first: dumping a large CJK node tree inside the measured
  // frame would charge the Harness query itself to frame_return_us.
  for(let retry=0;retry<20;retry++){await sleep(5);if((await traces()).length>before)break;}
  await waitFor(async()=>(await screen()).includes(typed)||null,5000,5);
  observations.push(performance.now()-at);await sleep(35);
 }
 await sleep(100);const values=(await traces()).slice(start);
 assert(values.length>=26,`${label}: insufficient complete segmented samples ${values.length}`);
 for(const v of values)for(const k of ['queue_us','write_us','first_output_us','publish_us','apply_us','frame_return_us','total_us'])assert(Number.isFinite(v[k]));
 report.phases[label]={confirmed_characters:typed.length,rpc_visible_ms:summary(observations),samples:values,timing_us:Object.fromEntries(['queue_us','write_us','first_output_us','publish_us','apply_us','frame_return_us','total_us'].map(k=>[k,summary(values.map(v=>v[k]))]))};
 if(mode==='local')await key('u',{ctrl:true});else await key('enter');await sleep(150);
}
try{
 let ready:any;
 if(mode==='ssh'){
  const code=`import paramiko,socket,threading,time,json,hashlib,base64,sys,signal
from pathlib import Path
key=paramiko.RSAKey.generate(2048);server=socket.socket();server.bind(('127.0.0.1',0));server.listen();stop=threading.Event()
class Auth(paramiko.ServerInterface):
 def check_auth_password(self,u,p):return paramiko.AUTH_SUCCESSFUL if (u,p)==('fixture','fixture-secret') else paramiko.AUTH_FAILED
 def get_allowed_auths(self,u):return 'password'
 def check_channel_request(self,k,i):return paramiko.OPEN_SUCCEEDED if k=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
 def check_channel_pty_request(self,*a):return True
 def check_channel_window_change_request(self,*a):return True
 def check_channel_exec_request(self,*a):return False
 def check_channel_shell_request(self,c):threading.Thread(target=echo,args=(c,),daemon=True).start();return True
def echo(c):
 buf=b''
 try:
  c.sendall(b'BENCH_READY\\r\\n')
  while not stop.is_set():
   b=c.recv(4096)
   if not b:break
   c.sendall(b.replace(b'\\r',b'\\r\\n'));buf+=b
   if b'\\r' in buf or b'\\n' in buf:
    if b'ZW_ASCII' in buf or b'ZW_CJK' in buf:
     line=('中文终端输出性能测试'*3 if b'ZW_CJK' in buf else 'abcdefghijklmnopqrstuvwxyz012345678901234567890123456789').encode()
     for i in range(200):c.sendall(line+b'\\r\\n');time.sleep(.01)
     c.sendall(b'BENCH_STREAM_DONE\\r\\n')
    buf=b''
 except (EOFError,OSError):pass
Path(sys.argv[1]).write_text(json.dumps({'port':server.getsockname()[1],'fingerprint':'SHA256:'+base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip('=')}))
signal.signal(signal.SIGTERM,lambda *_:stop.set());server.settimeout(.1);transports=[]
try:
 while not stop.is_set():
  try:s,_=server.accept()
  except socket.timeout:continue
  t=paramiko.Transport(s);transports.append(t);t.add_server_key(key);t.start_server(server=Auth())
  def accept(t):
   channels=[]
   while t.is_active() and not stop.is_set():
    c=t.accept(.1)
    if c is not None:channels.append(c)
  threading.Thread(target=accept,args=(t,),daemon=True).start()
finally:
 for t in transports:t.close()
 server.close()
`;
  peer=spawn('python3',['-u','-c',code,join(iso,'peer.json')],{stdio:'ignore'});peerEnd=new Promise(r=>peer.once('close',r));
  ready=await waitFor(async()=>{try{return JSON.parse(await readFile(join(iso,'peer.json'),'utf8'))}catch{return null}},10000);
  await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Latency owned peer"\nhost="127.0.0.1"\nport=${ready.port}\nuser="fixture"\n`);
 }
 await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[log]\nring_mb=8\ncheckpoint_sec=1\n');
 app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_INPUT_TIMING:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',appLog.fd,appLog.fd]});appEnd=new Promise(r=>app.once('close',r));report.pid=app.pid;
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1200,800);
 if(mode==='ssh'){await clickTestId('sidebar.host');await sleep(200);}
 assert((await clickTestId(mode==='local'?'workspace.empty.local':'sidebar.host.connect')).ok);
 if(mode==='ssh')await waitFor(async()=>{
  const modal=await visible('plugin.challenge.modal');
  if(modal){
   const nodes=flat(modal),trust=nodes.find(n=>n.test_id==='plugin.challenge.choice.0'&&shown(n));
   if(trust){assert(text(modal).includes(ready.fingerprint));await clickTestId('plugin.challenge.choice.0');await sleep(150);return null;}
   const input=nodes.find(n=>n.test_id==='plugin.challenge.answer.0'&&shown(n))??nodes.find(n=>n.test_id==='plugin.challenge.secret'&&shown(n));
   if(input){await clickTestId(input.test_id);await key('a',{cmd:true});await type_('fixture-secret');await clickTestId('plugin.challenge.submit');await sleep(150);return null;}
  }
  return text(await visible('status.connection.identity')).includes('已连接')||null;
 },30000);
 const surface=await waitFor(async()=>{const n=await visible('terminal.surface');return flat(n).some(x=>x.test_id?.startsWith('terminal.surface.row.'))?n:null},15000);
 await clickTestId('terminal.surface');await sleep(500);
 await typing('idle_typing');
 for(const [label,line] of [['ascii','abcdefghijklmnopqrstuvwxyz012345678901234567890123456789'],['cjk','中文终端输出性能测试中文终端输出性能测试中文终端输出性能测试']]){
  await command(mode==='ssh'?'ZW_'+label.toUpperCase():`/usr/bin/perl -e '$|=1;for(1..200){print "${line}\\n";select undef,undef,undef,0.01}print "BENCH_STREAM_","DONE\\n"'`);
  await sleep(450);await resetTiming();await sleep(1900);const frameStats=await stats();await waitFor(async()=>(await screen()).includes('BENCH_STREAM_DONE')||null,10000);
  report.phases[label]={frames:frameStats,row_nodes:(await rows()).reduce((s,n)=>s+flat(n).length,0)};
  await screenshot(join(out,label+'.png'));
 }
 await typing('after_output_typing');
 await sleep(500);const frames=(await stats()).frame_count;
 const cpu=()=>{const p=execFileSync('/bin/ps',['-p',String(app.pid),'-o','time='],{encoding:'utf8'}).trim().split(':').map(Number);return p.reduce((s,x)=>s*60+x,0);};
 const a=cpu(),at=performance.now();await sleep(3000);const b=cpu();report.idle={cpu_percent:(b-a)*100000/(performance.now()-at),frames:(await stats()).frame_count-frames};
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;await writeFile(join(out,'failure-ui.json'),JSON.stringify(await query('plugin.challenge.modal'))).catch(()=>{});await screenshot(join(out,'failure.png')).catch(()=>{});}
finally{
 if(app&&app.exitCode===null){app.kill('SIGTERM');await Promise.race([appEnd,sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await appEnd;}}
 if(peer&&peer.exitCode===null){peer.kill('SIGTERM');await Promise.race([peerEnd,sleep(2000)]);if(peer.exitCode===null&&peer.signalCode===null){peer.kill('SIGKILL');await peerEnd;}}
 if(app?.pid)await cleanupOwnedBridgeDirectories(app.pid);
 await appLog.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(iso,{recursive:true,force:true});console.log(JSON.stringify({status:report.status,mode,out,error:report.error}));
}
