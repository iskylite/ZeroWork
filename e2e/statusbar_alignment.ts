/** Native production statusbar, isolated loopback SSH, no user data. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,open,rm} from 'node:fs/promises';
import {join,resolve,basename} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {waitForServerReady,waitFor,query,clickTestId,clickAt,key,type_,screenshot,resizeWindow,sleep} from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'dist/ui-acceptance/statusbar-r21');await mkdir(out,{recursive:true});
const isolated=await mkdtemp(join(tmpdir(),'zw-statusbar-'));const rpc=join(isolated,'rpc'),data=join(isolated,'data'),peerDir=join(isolated,'peer');await Promise.all([mkdir(rpc),mkdir(data)]);
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
peer.main()
`;
const peerLog=await open(join(out,'peer.log'),'w');const peer=spawn('python3',['-c',peerCode,'--out',peerDir],{stdio:['ignore',peerLog.fd,peerLog.fd]});
const peerEnded=new Promise<void>(done=>peer.once('close',()=>done()));
let app:any,appEnded:Promise<void>|undefined;const report:any={checks:[],isolated,binary:resolve(process.argv[3]??'zig-out/bin/zerowork')};const shown=(n:any)=>n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,15000);
async function click(id:string){await visible(id);assert((await clickTestId(id)).ok);await sleep(150);}
async function capture(name:string){await sleep(300);assert((await screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(Object.fromEntries(await Promise.all(['workspace.statusbar','status.transfer','status.connection','connection.details','socks.info','status.theme','transfer.session','settings.footer.state','settings.appearance.font.header'].map(async id=>[id,await query(id)]))),null,2));}
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
 await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
 app=spawn(report.binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_FILE_TRACE:'1',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 appEnded=new Promise<void>(done=>app.once('close',()=>done()));
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);report.sha256=createHash('sha256').update(await readFile(report.binary)).digest('hex');await resizeWindow(1440,900);await connectHost('Statusbar Loopback');
 for(let i=0;i<150;i++){
  const trust=(await query('auth.challenge.trust_once')).find(shown);
  if(trust){const modal=JSON.stringify(await query('auth.challenge.modal'));assert(modal.includes(ready.fingerprint));await click('auth.challenge.trust_once');}
  const answer=(await query('auth.challenge.answer.0')).find(shown);if(answer){await click('auth.challenge.answer.0');await type_(ready.password);await click('auth.challenge.submit');}
  const identity=(await query('status.connection.identity')).find(shown);if(identity&&JSON.stringify(identity).includes('已连接'))break;
  await sleep(100);
 }
 const identity=await visible('status.connection.identity'),bar=await visible('workspace.statusbar'),side=await visible('workspace.sidebar');assert.equal(identity.rect.w,side.rect.w);
 for(const id of ['rtt','encoding','grid']){const n=await visible('status.connection.'+id);assert(!n.focusable,id+' is static');await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);assert(!(await query('status.ssh.detail')).some(shown));}
 assert(!(await query('status.connection.more')).some(shown));report.checks.push('sidebar width matches','metrics are static','More removed');await capture('01-statusbar');
 await click('status.connection.identity');await visible('status.connection');await capture('02-connection');await key('escape');
 await click('status.connection.chain');await visible('connection.details');await capture('03-chain');await key('escape');
 await click('status.connection.forward');await visible('socks.info');await capture('04-forward');await click('socks.info.close');
 await click('status.connection.theme');await visible('status.theme');await capture('05-theme');await key('escape');
 await click('status.transfer');const panel=await visible('transfer.session');assert.equal(panel.rect.w,620);assert.equal(panel.rect.h,330);assert(Math.abs(panel.rect.y+panel.rect.h-(bar.rect.y-6))<1);assert(JSON.stringify(panel).includes('本会话暂无传输任务'));await capture('06-session-transfers');await key('escape');assert(!(await query('transfer.session')).some(shown));report.checks.push('session list empty state and 620x330 geometry','session list 6px above bar','Escape closes');
 await resizeWindow(1024,700);await sleep(500);const collapsed=await visible('status.connection.identity');assert.equal(collapsed.rect.w,48);await capture('07-collapsed');report.checks.push('collapsed state width 48');
 await click('status.transfer');await visible('transfer.session');await capture('08-collapsed-transfers');await key('escape');
 await resizeWindow(1440,900);
 const sshTab=(await tabs())[0].test_id;
 await connectHost('Statusbar Files');await authenticate(async()=>(await query('files.workspace')).some(shown));
 const fileTab=(await tabs()).find(n=>n.test_id!==sshTab).test_id;report.file_tab=fileTab;
 const local=join(isolated,'downloads');await mkdir(local);const path=inside(await visible('files.local'),'files.path');await clickNode(path);await key('a',{cmd:true});await type_(local);await key('return');await sleep(400);
 async function download(name:string){
  const row=flatten(await visible('files.remote')).find(n=>n.test_id==='files.row'&&inside(n,'files.row.name')?.text===name);assert(row);await clickNode(row);
  await clickNode(inside(await visible('files.remote'),'files.transfer'));const confirm=await visible('files.copy.confirmation');assert(content(confirm).includes('源 /fixture'));assert(content(confirm).includes('下载 1 项'));assert(content(confirm).includes(local));await click('files.copy.submit');
 }
 await download('ticker-one.bin');await download('ticker-two.bin');
 const rotations:any[]=[];const transitions:any[]=[];const seen=new Set<string>();const started=Date.now();
 await waitFor(async()=>{const n=await visible('status.transfer.name');const sample={at:Date.now()-started,name:n.text};seen.add(basename(n.text));rotations.push(sample);if(transitions.at(-1)?.name!==sample.name)transitions.push(sample);return seen.has('ticker-one.bin')&&seen.has('ticker-two.bin')&&transitions.length>=4?true:null},13000);report.rotations=rotations;report.rotation_transitions=transitions;
 // The first interval may straddle the already-running clock; the next two
 // complete periods prove actual three-second rotation through real jobs.
 for(let i=2;i<4;i++)assert(transitions[i].at-transitions[i-1].at>=2400&&transitions[i].at-transitions[i-1].at<=3900,JSON.stringify(transitions));
 await capture('11-real-two-job-ticker');
 await click('status.transfer');const scoped=await visible('transfer.session');assert(content(scoped).includes('ticker-one.bin')&&content(scoped).includes('ticker-two.bin'));await capture('12-two-job-session-list');
 await click(sshTab);await waitFor(async()=>!(await query('transfer.session')).some(shown)||null,5000);assert.equal((await visible('status.transfer.name')).text,'暂无传输');await click('status.transfer');assert(content(await visible('transfer.session')).includes('本会话暂无传输任务'));await capture('13-owner-switch-isolation');await key('escape');
 await click(fileTab);await waitFor(async()=>['ticker-one.bin','ticker-two.bin'].includes(basename((await visible('status.transfer.name')).text))||null,5000);
 await waitFor(async()=>{try{return (await Promise.all(['ticker-one.bin','ticker-two.bin'].map(async n=>createHash('sha256').update(await readFile(join(local,n))).digest('hex')))).every(h=>h===ready.source_sha256)||null}catch{return null}},120000);
 report.actual_downloads=await Promise.all(['ticker-one.bin','ticker-two.bin'].map(async name=>({name,bytes:(await readFile(join(local,name))).length,sha256:createHash('sha256').update(await readFile(join(local,name))).digest('hex')})));
 report.checks.push('two actual SFTP jobs rotate after 3 seconds','owner switch dismisses popup and excludes other session jobs','actual two downloaded files match peer SHA256');await capture('14-transfers-complete');
 await click('toolbar.transfers');const global=await visible('transfer.manager');assert(content(global).includes('ticker-one.bin')&&content(global).includes('ticker-two.bin'));await capture('15-global-list-retained');report.checks.push('global toolbar list retains both original-owner completed jobs');await key('escape');
 await click(fileTab.replace('tabs.tab.','tabs.close.'));await waitFor(async()=>!(await query('files.workspace')).some(shown)||null,15000);report.checks.push('completed file owner closes through application coordinator');
 await click('toolbar.settings');await click('settings.nav.appearance');await capture('09-settings');await click('settings.appearance.font.header');
 const font=(await query('settings.field.font_size')).find(shown);if(font){await clickAt(font.rect.x+font.rect.w/2,font.rect.y+font.rect.h/2);await capture('10-settings-input');}
 report.checks.push('settings surface and focused field inspected');report.status='passed';report.evidence={synthetic_public_harness:true,real_sftp_io:true,physical_pointer_verified:false,generation_collision:'covered by targeted transfer projection test; this native run switches distinct full SessionHandles'};
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});throw e}
finally{
 if(app&&app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([appEnded,sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await appEnded;}}
 if(peer.exitCode===null&&peer.signalCode===null){peer.kill('SIGTERM');await Promise.race([peerEnded,sleep(3000)]);if(peer.exitCode===null&&peer.signalCode===null){peer.kill('SIGKILL');await peerEnded;}}
 await log.close();await peerLog.close();
 try{report.peer_final=JSON.parse(await readFile(join(peerDir,'report.json'),'utf8'));await writeFile(join(out,'peer-report.json'),JSON.stringify(report.peer_final,null,2));await writeFile(join(out,'peer-protocol.jsonl'),await readFile(join(peerDir,'protocol.jsonl')));assert.equal(report.peer_final.forbidden_operations.length,0);assert.equal(report.peer_final.errors.length,0);assert.deepEqual([...report.peer_final.read_handles_opened].sort(),[...report.peer_final.read_handles_closed].sort());}catch(e){report.status='failed';report.cleanup_error=String(e);process.exitCode=1;}
 await rm(isolated,{recursive:true,force:true});report.cleanup={app_exited:app?.exitCode!==null||app?.signalCode!==null,peer_exited:peer.exitCode!==null||peer.signalCode!==null,isolated_removed:true,shutdown_kind:'runner_SIGTERM_after_normal_file_tab_close'};await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(`${report.status}: ${join(out,'report.json')}`);

