/** Owned SSH burst-output probe. No real remote host or terminal payload is logged.
 * Usage: node e2e/terminal_output.ts BINARY OUTPUT_DIRECTORY
 * Optional: ZEROWORK_OUTPUT_TIMING=1 enables read/wait diagnostics in test builds.
 * Requires Python paramiko; all fixture processes and data are cleaned up.
 */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,realpath,mkdir,readFile,writeFile,open,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {createHash} from 'node:crypto';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
import {waitForServerReady,waitFor,query,clickTestId,type_,key,resizeWindow,screenshot,stats,resetTiming} from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]),mode='ssh';
await mkdir(out,{recursive:false});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-output-burst-'))),data=join(iso,'data'),rpc=join(iso,'rpc');
await mkdir(data);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const sleep=(ms:number)=>new Promise(r=>setTimeout(r,ms));
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any):string=>flat(n).map(x=>x.text??'').join('');
const visible=async(id:string)=>(await query(id)).find(shown);
const report:any={mode,binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),limits:['Output-only synthetic dmesg-like numbered ASCII lines; not a real kernel dmesg capture.','Bounded last-five-row query every 250ms; observed gaps include Harness overhead.','Source completion is write/sendall completion, not proof of receipt by the application.'],phases:{}};
const appLog=await open(join(out,'app.log'),'w');let app:any,peer:any;let peerEnd:Promise<any>|undefined,appEnd:Promise<any>|undefined;
async function command(command:string){await type_(command);await key('enter');}
function outputDiagnostics(log:string){
 const records=log.split('\n').filter(x=>x.startsWith('[terminal-output-')).map(line=>Object.fromEntries([...line.matchAll(/(\w+)=([^ ]+)/g)].map(m=>[m[1],/^\d+$/.test(m[2])?Number(m[2]):m[2]]))) as any[];
 const first=records.findIndex(x=>x.bytes>=83),last=records.findLastIndex(x=>x.bytes>0);
 if(first<0)return null;
 const burst=records.slice(first,last+1),reads=burst.filter(x=>x.bytes!==undefined),waits=burst.filter(x=>x.wait_us!==undefined);
 const delayed=burst.filter((x,i)=>x.events===0&&x.wait_us>1000&&burst[i-1]?.reason==='full'&&burst[i+1]?.bytes>0);
 const sum=(xs:any[],key:string)=>xs.reduce((n,x)=>n+x[key],0);
 return {bytes:sum(reads,'bytes'),reads:reads.length,full_reads:reads.filter(x=>x.reason==='full').length,read_ms:sum(reads,'read_us')/1000,feed_ms:sum(reads,'feed_us')/1000,wait_ms:sum(waits,'wait_us')/1000,full_then_timeout_then_data:delayed.length,full_then_timeout_ms:sum(delayed,'wait_us')/1000,burst_ms:(burst.at(-1).at_us-burst[0].at_us+burst.at(-1).read_us+burst.at(-1).feed_us)/1000};
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
    for phase,batch,rounds,delay in [('flood',4096,64,0)]:
     if ('ZW_'+phase.upper()).encode() not in buf:continue
     with open(sys.argv[2],'a') as progress:
      seq=0;started=time.time_ns()/1e6
      for j in range(rounds):
       payload=b''.join(('[12345.678901] seq=%08d eth0: link state changed to UP, mtu=1500 flags=0x1043\\r\\n'%(seq+i)).encode() for i in range(batch))
       c.sendall(payload);seq+=batch
       progress.write(json.dumps({'phase':phase,'seq':seq-1,'at_ms':time.time_ns()/1e6,'started_ms':started})+'\\n');progress.flush()
       if delay:time.sleep(delay)
      c.sendall(('STREAM_'+phase.upper()+'_DONE\\r\\n').encode())
      progress.write(json.dumps({'phase':phase,'seq':seq-1,'at_ms':time.time_ns()/1e6,'started_ms':started,'done':True})+'\\n');progress.flush()
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
  peer=spawn('python3',['-u','-c',code,join(iso,'peer.json'),join(out,'source-progress.jsonl')],{stdio:'ignore'});peerEnd=new Promise(r=>peer.once('close',r));
  ready=await waitFor(async()=>{try{return JSON.parse(await readFile(join(iso,'peer.json'),'utf8'))}catch{return null}},10000);
  await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Burst output owned peer"\nhost="127.0.0.1"\nport=${ready.port}\nuser="fixture"\n`);
 }
 await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[log]\nring_mb=8\ncheckpoint_sec=1\n');
 app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',appLog.fd,appLog.fd]});appEnd=new Promise(r=>app.once('close',r));report.pid=app.pid;
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1200,800);
 if(mode==='ssh'){await clickTestId('sidebar.host');await sleep(200);}
 assert((await clickTestId('sidebar.host.connect')).ok);
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
 await sleep(1000);
 const rowIds=flat(await visible('terminal.surface')).filter(n=>n.test_id?.startsWith('terminal.surface.row.')&&shown(n)).sort((a,b)=>a.rect.y-b.rect.y).slice(-5).map(n=>n.test_id);
 const tail=async()=>(await Promise.all(rowIds.map(id=>query(id)))).flat().filter(shown).map(text).join('');
 const cpu=()=>{const v=execFileSync('/bin/ps',['-p',String(app.pid),'-o','time=,rss='],{encoding:'utf8'}).trim().split(/\s+/);return {seconds:v[0].split(':').map(Number).reduce((s,x)=>s*60+x,0),rss_kib:Number(v[1])}};
 for(const [label,batch,rounds,delay] of [['flood',4096,64,0]] as const){
  await resetTiming();const before=cpu(),at=Date.now(),frameStart=(await stats()).frame_count;
  await command('ZW_'+label.toUpperCase());
  const observations:any[]=[];let done=false;
  while(Date.now()-at<45000){
   const queryAt=Date.now();const value=await tail();const visibleSeq=Math.max(-1,...[...value.matchAll(/seq=(\d+)/g)].map(x=>Number(x[1])));
   const progress=(await readFile(join(out,'source-progress.jsonl'),'utf8').catch(()=>'')).trim().split('\n').filter(Boolean).map(x=>{try{return JSON.parse(x)}catch{return null}}).filter(x=>x?.phase===label).at(-1);
   observations.push({at_ms:Date.now(),query_ms:Date.now()-queryAt,visible_seq:visibleSeq,source:progress,frames:await stats()});
   if(value.includes('STREAM_'+label.toUpperCase()+'_DONE')){assert.equal(visibleSeq,batch*rounds-1);done=true;break;}
   await sleep(250);
  }
  const after=cpu(),last=observations.at(-1),latest=last?.source;
  report.phases[label]={done,lines:batch*rounds,target_lines_per_second:delay?batch/delay:null,observations,wall_ms:Date.now()-at,cpu_seconds:after.seconds-before.seconds,rss_kib:after.rss_kib,frame_delta:last.frames.frame_count-frameStart,completion_after_source_ms:latest?.done?last.at_ms-latest.at_ms:null};
  await screenshot(join(out,label+'.png'));
  assert(done,label+' output tail did not arrive');await sleep(500);
 }
 report.diagnostics=outputDiagnostics(await readFile(join(out,'app.log'),'utf8'));
 if(report.diagnostics){
  const expected=83*262144+'STREAM_FLOOD_DONE\r\n'.length;
  // The command echo may share the first data read; it is ten bytes at most.
  assert(report.diagnostics.bytes>=expected&&report.diagnostics.bytes<=expected+10);
 }
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;await writeFile(join(out,'failure-ui.json'),JSON.stringify(await query('plugin.challenge.modal'))).catch(()=>{});await screenshot(join(out,'failure.png')).catch(()=>{});}
finally{
 if(app&&app.exitCode===null){app.kill('SIGTERM');await Promise.race([appEnd,sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await appEnd;}}
 if(peer&&peer.exitCode===null){peer.kill('SIGTERM');await Promise.race([peerEnd,sleep(2000)]);if(peer.exitCode===null&&peer.signalCode===null){peer.kill('SIGKILL');await peerEnd;}}
 if(app?.pid)await cleanupOwnedBridgeDirectories(app.pid);
 await appLog.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(iso,{recursive:true,force:true});console.log(JSON.stringify({status:report.status,mode,out,error:report.error}));
}
