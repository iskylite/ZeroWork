/** V3 forwarding controls over the production native app and owned SSH peers. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash,randomBytes} from 'node:crypto';
import {mkdtemp,realpath,mkdir,readFile,writeFile,copyFile,open,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,dirname} from 'node:path';
import net from 'node:net';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep,scrollAt,mouseMove} from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]),theme=process.argv[3]??'dark';assert(['dark','light'].includes(theme));await mkdir(out,{recursive:false});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-v3-forward-'))),data=join(iso,'data'),rpc=join(iso,'rpc'),peerDir=join(iso,'peer');
// Always remove this run's sandbox, including setup and reporting failures.
try {
await Promise.all([mkdir(data),mkdir(rpc),mkdir(peerDir)]);
const peerCode=`import sys,time,json,signal,threading,hashlib,base64
sys.path.insert(0,'e2e')
from pathlib import Path
from fixed_forward import Peer,Echo
from shared_forward import Connection
# The app opens a read-only OS-identification channel beside its PTY.
# Record only this exact production probe; every other exec remains forbidden.
def identify_os(self,channel,command):
 expected=b'sh -c "uname -s; cat /etc/os-release" || cmd /c ver'
 if command==expected:
  self.calls.append({'os_probe':command.decode('utf-8')})
  return False  # Fixture rejects exec: no shell command is actually run.
 self.calls.append({'UNEXPECTED_EXEC':command.decode('utf-8','replace')})
 return False
Connection.check_channel_exec_request=identify_os
out=Path(sys.argv[1]);peer=Peer();peer.deny_remote=False;peer.remote_cancelled=threading.Event();echo=Echo();peer.thread.start();stop=threading.Event()
signal.signal(signal.SIGTERM,lambda *_:stop.set())
signal.signal(signal.SIGINT,lambda *_:stop.set())
ready={'port':peer.port,'user':'shared-fixture','password':'shared-secret','echo_port':echo.port,'fingerprint':'SHA256:'+base64.b64encode(hashlib.sha256(peer.key.asbytes()).digest()).decode().rstrip('=')}
(out/'ready.json').write_text(json.dumps(ready))
def report():
 return {'calls':[c.calls for c in peer.connections],'shell_bytes':[len(c.shell) for c in peer.connections],'forward_bytes':[len(c.forward) for c in peer.connections],'echo_bytes':echo.bytes}
try:
 while not stop.wait(.05):(out/'live.json').write_text(json.dumps(report()))
finally:
 peer.stop();echo.close();(out/'report.json').write_text(json.dumps(report()))
`;
const peerLog=await open(join(out,'peer.log'),'w'),peer=spawn('python3',['-u','-c',peerCode,peerDir],{stdio:['ignore',peerLog.fd,peerLog.fd]}),peerEnd=new Promise(r=>peer.once('close',r));
let app:any,appEnd:any;const log=await open(join(out,'app.log'),'w');const report:any={status:'running',theme,checks:[],captures:[],limits:['Owned loopback SSH traffic; not evidence of user private-network multihop access.','Native Metal window with synthetic public Harness input.']};
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(x=>x.text??'').join(' ');
const vis=(id:string)=>waitFor(async()=>{const nodes=await query(id);assert(Array.isArray(nodes),JSON.stringify(nodes));return nodes.find(shown)??null},12000);
const hidden=(id:string)=>waitFor(async()=>!(await query(id)).some(shown)||null,12000);
async function click(id:string){const n=await vis(id);await mouseMove(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)}
async function edit(id:string,value:string){await click(id);await key('a',{cmd:true});await type_(value)}
async function cap(name:string){await mouseMove(20,80);await sleep(180);assert((await screenshot(join(out,name+'.png'))).ok);const ids=['socks.info','socks.info.rule','socks.info.empty','socks.info.status','socks.config.card','socks.config.error','forward.mode.local','forward.mode.remote','forward.mode.socks5','forward.exposure.card'];await writeFile(join(out,name+'.json'),JSON.stringify(Object.fromEntries(await Promise.all(ids.map(async id=>[id,await query(id)]))),null,2));report.captures.push(name)}
async function freePort(){const s=net.createServer();await new Promise<void>((r,j)=>{s.once('error',j);s.listen(0,'127.0.0.1',r)});const port=(s.address() as net.AddressInfo).port;await new Promise<void>(r=>s.close(()=>r()));return port}
async function dial(port:number){const socket=net.createConnection({host:'127.0.0.1',port});socket.setTimeout(5000,()=>socket.destroy(new Error('owned socket timeout')));await new Promise<void>((r,j)=>{socket.once('connect',r);socket.once('error',j)});return socket}
async function exchange(port:number,socks:boolean){const socket=await dial(port);let data=Buffer.alloc(0),failure:any;socket.on('data',x=>data=Buffer.concat([data,x]));socket.on('error',e=>failure=e);const take=async(n:number)=>{await waitFor(()=>{if(failure)throw failure;return data.length>=n?true:null},6000);const result=data.subarray(0,n);data=data.subarray(n);return result};try{if(socks){socket.write(Buffer.from([5,1,0]));assert.deepEqual(await take(2),Buffer.from([5,0]));const host=Buffer.from('shared.fixture');socket.write(Buffer.concat([Buffer.from([5,1,0,3,host.length]),host,Buffer.from([16,146])]));const reply=await take(10);assert.equal(reply[1],0)}const payload=randomBytes(8192);socket.write(payload);assert.deepEqual(await take(payload.length),payload);await sleep(100);assert.equal(data.length,0);return payload.length}finally{socket.destroy()}}
let ready:any;
try{
 ready=await waitFor(async()=>{try{return JSON.parse(await readFile(join(peerDir,'ready.json'),'utf8'))}catch{return null}},12000);
 await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`);
 await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Forwarding owned peer"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\n`);
 const sourceEvidence=process.argv[4]?JSON.parse(await readFile(process.argv[4],'utf8')):null;const sourceBinary=sourceEvidence?join(sourceEvidence.isolated,'zerowork'):resolve('zig-out/bin/zerowork');await copyFile(sourceBinary,join(iso,'zerowork'));await copyFile(join(dirname(sourceBinary),'zw_ipc.so'),join(iso,'zw_ipc.so'));report.sha256=createHash('sha256').update(await readFile(join(iso,'zerowork'))).digest('hex');
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;app=spawn(join(iso,'zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});appEnd=new Promise(r=>app.once('close',r));report.pid=app.pid;
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1440,900);
 await click('sidebar.host');
 await waitFor(async()=>{const title=(await query('plugin.challenge.title')).find(shown);if(title){const source=text((await query('plugin.challenge.source')).find(shown));assert(source.includes('127.0.0.1'));const trust=(await query('plugin.challenge.choice.0')).find(n=>shown(n)&&text(n).includes('仅本次信任'));if(trust){assert(text((await query('plugin.challenge.material')).find(shown)).includes(ready.fingerprint));await click('plugin.challenge.choice.0');return null}const answer=[...(await query('plugin.challenge.secret')),...(await query('plugin.challenge.answer.0'))].find(n=>shown(n)&&n.focusable);if(answer){await edit(answer.test_id,ready.password);await click('plugin.challenge.submit');return null}}return text((await query('status.connection.identity')).find(shown)).includes('已连接')&&(await query('workspace.pane')).some(shown)?true:null},45000);
 await click('status.connection.forward');const empty=await vis('socks.info.empty');assert(text(empty).includes('没有转发规则'));assert.equal((await vis('socks.info')).rect.w,344);await cap('01-forward-empty');
 const ports:any={};
 for(const mode of ['local','remote','socks5']){
  await click('socks.info.config');await vis('socks.config.card');assert(!(await query('socks.info')).some(shown));await click('socks.config.exit');await key('escape');await vis('socks.config.card');await click('forward.mode.'+mode);await sleep(120);const configText=text(await vis('socks.config.card'));assert(configText.includes(mode==='remote'?'SSH端监听 → 本机目标':mode==='local'?'本机监听 → SSH端目标':'本机监听 · 动态目标'));const port=await freePort();ports[mode]=port;await edit('socks.config.port',String(port));await edit('socks.config.bind','127.0.0.1');
  if(mode!=='socks5'){await edit('forward.target.host',mode==='local'?'shared.fixture':'127.0.0.1');await edit('forward.target.port',mode==='local'?'4242':String(ready.echo_port))}
  if(mode==='local'){await edit('socks.config.port','0');await click('socks.config.save');assert(text(await vis('socks.config.error')).includes('不能为空'));await edit('socks.config.port',String(port));
   await edit('socks.config.bind','0.0.0.0');await click('socks.config.save');await vis('forward.exposure.card');await key('return');assert((await query('forward.exposure.card')).some(shown));await assert.rejects(()=>dial(port));await cap('02-exposure-confirmation-only');await click('forward.exposure.cancel');await hidden('forward.exposure');await vis('socks.config.card');await edit('socks.config.bind','127.0.0.1');
  }
  await resizeWindow(860,480);await sleep(150);const card=await vis('socks.config.card');assert.equal(card.rect.w,480);assert.equal((await vis('socks.config.owner')).rect.x-card.rect.x,22);assert.equal((await vis('socks.config.save')).rect.x+(await vis('socks.config.save')).rect.w,card.rect.x+card.rect.w-22);assert(card.rect.x>=16&&card.rect.y>=16&&card.rect.x+card.rect.w<=844&&card.rect.y+card.rect.h<=464.5);await cap('02-config-'+mode+'-minimum');
  if(mode==='socks5'){
   const saveBefore=(await vis('socks.config.save')).rect,persistBefore=(await vis('socks.config.persist')).rect;
   assert((await scrollAt(card.rect.x+40,card.rect.y+card.rect.h/2,0,-500)).ok);await sleep(200);const persistAfter=(await vis('socks.config.persist')).rect;
   assert.deepEqual((await vis('socks.config.save')).rect,saveBefore);assert(persistAfter.y<persistBefore.y&&persistAfter.y+persistAfter.h<saveBefore.y);await click('socks.config.persist');await cap('02b-config-advanced-scrolled');
  }
  await click('socks.config.save');await hidden('socks.config');await click('status.connection.forward');await vis('socks.info.rule');await click('socks.info.control');await waitFor(async()=>text(await vis('socks.info.status')).includes('正在监听')||null,15000);
  const bytes=await exchange(port,mode==='socks5');report.checks.push({mode,bytes,roundtrip:'exact 8192 random bytes'});await sleep(250);await cap('03-running-'+mode);
  const info=await vis('socks.info'),anchor=await vis('status.connection.forward');assert(info.rect.x>=8&&info.rect.y>=8&&info.rect.x+info.rect.w<=852&&info.rect.y+info.rect.h<=anchor.rect.y);
  await click('socks.info.control');await waitFor(async()=>text(await vis('socks.info.status')).includes('未开启')||null,15000);await assert.rejects(()=>dial(port));await cap('04-stopped-'+mode);
 }
 report.ports=ports;report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await cap('failure').catch(()=>{});process.exitCode=1}
finally{if(app&&app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([appEnd,sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await appEnd}}if(peer.exitCode===null&&peer.signalCode===null){peer.kill('SIGTERM');await Promise.race([peerEnd,sleep(3000)]);if(peer.exitCode===null&&peer.signalCode===null){peer.kill('SIGKILL');await peerEnd}}await log.close();await peerLog.close();try{const final=JSON.parse(await readFile(join(peerDir,'report.json'),'utf8'));report.peer=final;assert(!JSON.stringify(final.calls).includes('UNEXPECTED_EXEC'),'Only the exact read-only OS probe may use exec');if(report.status==='passed'){assert.equal(final.calls.length,1,'One host activation must create exactly one SSH transport');assert.equal(final.calls[0].filter((x:any)=>x==='auth').length,1);assert.equal(final.calls[0].filter((x:any)=>x==='pty').length,1);assert.equal(final.calls[0].filter((x:any)=>x==='shell').length,1);assert.equal(final.calls[0].filter((x:any)=>x==='session').length,2,'One PTY channel plus one OS-identification channel');assert.equal(final.calls[0].filter((x:any)=>x&&typeof x==='object'&&x.os_probe).length,1);assert.equal(final.forward_bytes[0],16384);assert.equal(final.echo_bytes,8192)} }catch(e){report.cleanup_error=String(e);report.status='failed';process.exitCode=1}report.isolated=iso;await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}))}
} finally {
 await rm(iso,{recursive:true,force:true});
}
