/** Native production statusbar, isolated loopback SSH, no user data. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,open,rm,realpath,copyFile} from 'node:fs/promises';
import {join,resolve,basename} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {waitForServerReady,waitFor,query,clickTestId,clickAt,key,type_,screenshot,resizeWindow,sleep,screenPos} from '../zig-out/share/zenit/harness/client.ts';
const theme=process.argv[4]??'dark';assert(['dark','light'].includes(theme));
const out=resolve(process.argv[2]??'dist/ui-acceptance/statusbar-r21');await mkdir(out,{recursive:true});
const isolated=await realpath(await mkdtemp(join(tmpdir(),'zw-statusbar-')));const rpc=join(isolated,'rpc'),data=join(isolated,'data'),peerDir=join(isolated,'peer');await Promise.all([mkdir(rpc),mkdir(data)]);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const peerCode=`import sys,time,stat
sys.path.insert(0, 'e2e')
import ssh_aux_download_loopback as peer
f=peer.file_fixture
f.PAYLOAD=b'ZEROWORK_STATUSBAR_REAL_TICKER\\n'+bytes(range(256))*65536
peer.PAYLOAD=f.PAYLOAD
original=f.normalized
f.normalized=lambda path: f.REMOTE if path in ('/fixture/ticker-one.bin','/fixture/ticker-two.bin') else original(path)
read=f.Handle.read
def slow(self,offset,length):
 time.sleep(0.025)
 return read(self,offset,length)
f.Handle.read=slow
def listing(self,path):
 self.state.record(self.connection,'LIST',path=path)
 if f.normalized(path)!='/fixture': return peer.paramiko.SFTP_NO_SUCH_FILE
 result=[]
 for name in ('ticker-one.bin','ticker-two.bin'):
  a=f.attributes(f.REMOTE);a.filename=name;result.append(a)
 return result
f.Files.list_folder=listing
original_channel=peer.Server.check_channel_request
def delayed_channel(self,kind,channel_id):
 result=original_channel(self,kind,channel_id)
 if channel_id>0: time.sleep(0.8)
 return result
peer.Server.check_channel_request=delayed_channel
peer.main()
`;
const peerLog=await open(join(out,'peer.log'),'w');const peer=spawn('python3',['-c',peerCode,'--out',peerDir],{stdio:['ignore',peerLog.fd,peerLog.fd]});
const peerEnded=new Promise<void>(done=>peer.once('close',()=>done()));
let app:any,appEnded:Promise<void>|undefined;const report:any={checks:[],theme,isolated,binary:resolve(process.argv[3]??'zig-out/bin/zerowork')};const shown=(n:any)=>n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,15000);
async function click(id:string){await visible(id);assert((await clickTestId(id)).ok,id);await sleep(150);}
async function capture(name:string){await sleep(300);assert((await screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(Object.fromEntries(await Promise.all(['workspace.statusbar','status.transfer','status.connection','status.connection.footer','status.connection.viewport','connection.details','connection.details.footer','connection.details.body','connection.details.node-dialog','wizard.dialog','socks.info','status.theme','transfer.session','settings.footer.state','settings.appearance.font.header'].map(async id=>[id,id==='wizard.dialog'?await screenPos(id):await query(id)]))),null,2));}
const flatten=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flatten)]:[];
const content=(n:any)=>flatten(n).map(n=>n.text??'').join(' ');
const inside=(n:any,id:string)=>flatten(n).find(n=>n.test_id===id&&shown(n));
const clickNode=async(n:any)=>{assert(n&&shown(n));assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await sleep(150)};
const tabs=async()=>flatten(await visible('tabs.strip')).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??''));
async function connectHost(label:string){const row=(await query('sidebar.host')).find(n=>shown(n)&&content(n).includes(label));assert(row);assert((await clickAt(row.rect.x+Math.min(70,row.rect.w/2),row.rect.y+row.rect.h/2,2)).ok);await sleep(200);}
async function authenticate(done:()=>Promise<boolean>){await waitFor(async()=>{if(await done())return true;const modal=(await query('auth.challenge.modal')).find(shown);if(modal){assert(content(modal).includes('127.0.0.1'));const trust=inside(modal,'auth.challenge.trust_once');if(trust){assert(content(modal).includes(ready.fingerprint));await clickNode(trust);}const answer=inside(modal,'auth.challenge.answer.0');if(answer){await clickNode(answer);await key('a',{cmd:true});await type_(ready.password);await click('auth.challenge.submit');}}return null},75000)}
let ready:any;
const log=await open(join(out,'app.log'),'w');
try{
 ready=await waitFor(async()=>{try{return JSON.parse(await readFile(join(peerDir,'ready.json'),'utf8'))}catch{return null}},15000);
 await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=3\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Statusbar Loopback"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n[[hosts]]\nconnection_id=2\nrevision=1\nprotocol="sftp"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Statusbar Files"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
 await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`);
 await copyFile(report.binary,join(isolated,'zerowork'));await copyFile(join(resolve(report.binary,'..'),'zw_ipc.so'),join(isolated,'zw_ipc.so'));
 app=spawn(join(isolated,'zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_FILE_TRACE:'1',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 appEnded=new Promise<void>(done=>app.once('close',()=>done()));
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);report.sha256=createHash('sha256').update(await readFile(join(isolated,'zerowork'))).digest('hex');await resizeWindow(1440,900);await connectHost('Statusbar Loopback');
 await waitFor(async()=>{
  const generic=(await query('plugin.challenge.title')).find(shown);
  if(generic){
   const source=content((await query('plugin.challenge.source')).find(shown));assert(source.includes('127.0.0.1'));
   const trust=(await query('plugin.challenge.choice.0')).find(n=>shown(n)&&content(n).includes('仅本次信任'));
   if(trust){assert(content((await query('plugin.challenge.material')).find(shown)).includes(ready.fingerprint));await clickNode(trust);return null;}
   const answer=[...(await query('plugin.challenge.answer.0')),...(await query('plugin.challenge.secret'))].find(n=>shown(n)&&n.focusable);
   if(answer){await clickNode(answer);await key('a',{cmd:true});await type_(ready.password);await click('plugin.challenge.submit');return null;}
  }
  const old=(await query('auth.challenge.modal')).find(shown);
  if(old){const trust=inside(old,'auth.challenge.trust_once');if(trust){assert(content(old).includes(ready.fingerprint));await clickNode(trust);return null;}const answer=inside(old,'auth.challenge.answer.0');if(answer){await clickNode(answer);await type_(ready.password);await click('auth.challenge.submit');return null;}}
  const identity=(await query('status.connection.identity')).find(shown);
  return identity&&content(identity).includes('已连接')&&(await query('workspace.pane')).some(shown)?true:null;
 },45000);
 assert((await readFile(join(peerDir,'protocol.jsonl'),'utf8')).includes('SHELL'),'actual SSH shell acknowledgement');
 const identity=await visible('status.connection.identity');assert.equal(identity.rect.w,162);
 const latency=flatten(identity).find(n=>shown(n)&&n.text&&n.rect.x>=identity.rect.x+79);assert(latency);assert(latency.rect.x>=identity.rect.x&&latency.rect.x+latency.rect.w<=identity.rect.x+identity.rect.w);
 assert(!(await query('status.connection.rtt')).some(shown));assert(!(await query('status.connection.more')).some(shown));
 report.checks.push('Latency is inside the connection identity; redundant metric and More stay hidden.');await capture('01-statusbar');
 await click('status.connection.identity');let panel=await visible('status.connection');assert.equal(panel.rect.w,344);assert.equal(panel.rect.h,334);
 const facts=content(panel);assert(facts.includes('SSH · 交互式 Shell'));assert(facts.includes('Statusbar Loopback'));assert(facts.includes('127.0.0.1'));assert(!content(await visible('status.connection.cipher')).includes('未知'));
 await capture('02-v3-connection');await click('status.connection.copy');await waitFor(async()=>content(await visible('status.connection')).includes('已复制信息')||null);
 const copy=await visible('status.connection.copy');assert.equal(copy.rect.w,90);await capture('03-copy-acknowledged');await key('escape');await waitFor(async()=>!(await query('status.connection')).some(shown)||null);
 report.checks.push('V3 labeled facts use the real negotiated cipher; Copy information acknowledges the production clipboard callback.');
 await click('status.connection.identity');await resizeWindow(860,480);await sleep(250);panel=await visible('status.connection');const minAnchor=await visible('status.connection.identity');
 assert(panel.rect.x>=8&&panel.rect.y>=8&&panel.rect.x+panel.rect.w<=852&&panel.rect.y+panel.rect.h<=minAnchor.rect.y);
 const footer=await visible('status.connection.footer');assert(footer.rect.y+footer.rect.h<=panel.rect.y+panel.rect.h);await capture('04-minimum-anchored');
 for(let step=0;step<2;step++){
  const toggle=(await query('sidebar.collapse')).some(shown)?'sidebar.collapse':'sidebar.rail.expand';await click(toggle);
  await waitFor(async()=>!(await query('status.connection')).some(shown)||null);await click('status.connection.identity');panel=await visible('status.connection');
  assert(panel.rect.x>=8&&panel.rect.y>=8&&panel.rect.x+panel.rect.w<=852&&panel.rect.y+panel.rect.h<=480);await capture(`05-sidebar-toggle-${step}`);
 }
 await click('status.connection.close');await waitFor(async()=>!(await query('status.connection')).some(shown)||null);await click('status.connection.identity');await clickAt(600,150);await waitFor(async()=>!(await query('status.connection')).some(shown)||null);
 report.checks.push('Actual 860x480 resize, sidebar fold/reopen, close, Escape and outside click keep the card inside the window.');
 await resizeWindow(1440,900);await click('status.connection.chain');let chain=await visible('connection.details');assert.equal(chain.rect.w,344);assert.equal(chain.rect.h,318);
 assert(content(chain).includes('↓ SSH 隧道'));assert((await query('connection.details.node.0')).some(shown));assert((await query('connection.details.node.1')).some(shown));await capture('06-v3-chain');
 await click('connection.details.copy');await waitFor(async()=>content(await visible('connection.details.feedback')).includes('已复制链路')||null);
 await click('connection.details.node.1');let node=await visible('connection.details.node-dialog');assert(content(node).includes(ready.fingerprint));assert(content(node).includes('aes128-ctr'));await capture('07-target-node');
 await resizeWindow(860,480);await sleep(200);node=await visible('connection.details.node-dialog');assert(node.rect.x>=8&&node.rect.y>=8&&node.rect.x+node.rect.w<=852&&node.rect.y+node.rect.h<=472);await capture('08-target-node-minimum');
 await click('connection.details.node-done');await waitFor(async()=>!(await query('connection.details.node-dialog')).some(shown)||null);
 chain=await visible('connection.details');const chainAnchor=await visible('status.connection.chain');assert(chain.rect.x>=8&&chain.rect.y>=8&&chain.rect.x+chain.rect.w<=852&&chain.rect.y+chain.rect.h<=chainAnchor.rect.y);
 const protocolCalls=async()=> (await readFile(join(peerDir,'protocol.jsonl'),'utf8')).trim().split('\n').map(x=>JSON.parse(x));
 const channelCount=(await protocolCalls()).filter(x=>x.operation==='CHANNEL').length;
 await click('connection.details.sample');await waitFor(async()=>content((await query('connection.details')).find(shown)).includes('采样中')||null,10000);await waitFor(async()=> (await protocolCalls()).filter(x=>x.operation==='CHANNEL').length>channelCount||null,15000);
 await waitFor(async()=>/\b\d+ms\b/.test(content((await query('connection.details')).find(shown)))||null,15000);await capture('09-real-chain-sample');
 const chainFooter=await visible('connection.details.footer');chain=await visible('connection.details');assert(chainFooter.rect.y+chainFooter.rect.h<=chain.rect.y+chain.rect.h);
 await click('connection.details.edit');await visible('wizard.name');assert(content(await visible('wizard.title')).includes('编辑连接'));const wizardBounds=await screenPos('wizard.dialog');assert(wizardBounds.w>0&&wizardBounds.h>0);assert(content(await visible('wizard.name')).includes('Statusbar Loopback'));assert(!(await query('connection.details')).some(shown));await capture('10-chain-edit-captured-host');
 await click('wizard.cancel');if((await query('wizard.discard.confirm')).some(shown))await click('wizard.discard.confirm');await waitFor(async()=>!(await query('wizard.name')).some(shown)||null);
 report.checks.push('Chain node list, captured fingerprint/cipher detail, minimum layout, real SSH CHANNEL sampling and editing original connection all passed.');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});throw e}
finally{
 if(app&&app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([appEnded,sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await appEnded;}}
 if(peer.exitCode===null&&peer.signalCode===null){peer.kill('SIGTERM');await Promise.race([peerEnded,sleep(3000)]);if(peer.exitCode===null&&peer.signalCode===null){peer.kill('SIGKILL');await peerEnded;}}
 await log.close();await peerLog.close();
 try{report.peer_final=JSON.parse(await readFile(join(peerDir,'report.json'),'utf8'));await writeFile(join(out,'peer-report.json'),JSON.stringify(report.peer_final,null,2));await writeFile(join(out,'peer-protocol.jsonl'),await readFile(join(peerDir,'protocol.jsonl')));assert.equal(report.peer_final.forbidden_operations.length,0);assert.equal(report.peer_final.errors.length,0);assert.deepEqual([...report.peer_final.read_handles_opened].sort(),[...report.peer_final.read_handles_closed].sort());}catch(e){report.status='failed';report.cleanup_error=String(e);process.exitCode=1;}
 await rm(isolated,{recursive:true,force:true});report.cleanup={app_exited:app?.exitCode!==null||app?.signalCode!==null,peer_exited:peer.exitCode!==null||peer.signalCode!==null,isolated_removed:true,shutdown_kind:'runner_SIGTERM_after_normal_file_tab_close'};await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(`${report.status}: ${join(out,'report.json')}`);

