/** Direct @up/@dl native pickers against an owned SSH shell.
 * A CUA driver operates AppKit panels, then writes continue-N in the output directory.
 * Pass --complete-transfers as the fourth argument to verify a writable SFTP round trip.
 * Without it, the fixture checks picker -> queue handoff only.
 */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdir,mkdtemp,realpath,copyFile,readFile,writeFile,open,readdir,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep,scrollAt,mouseDown,mouseMove,mouseUp} from '../zig-out/share/zenit/harness/client.ts';
const {cleanupOwnedBridgeDirectories}=await import('./native_owned_cleanup.ts');
const complete=process.argv[4]==='--complete-transfers';
const out=resolve(process.argv[2]),source=resolve(process.argv[3]);await mkdir(out,{recursive:false});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-builtin-records-'))),rpc=join(iso,'rpc'),data=join(iso,'data'),shell=join(iso,'shell');await Promise.all([mkdir(rpc),mkdir(data),mkdir(shell)]);
await writeFile(join(shell,'.zshrc'),"bindkey -e\nPS1='records%# '\n");
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
const bundle=join(out,'Transfer-Picker-Check.app'),mac=join(bundle,'Contents','MacOS');await mkdir(mac,{recursive:true});
await writeFile(join(bundle,'Contents','Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>local.zerowork.transferpicker.check</string><key>CFBundleName</key><string>Transfer Picker Check</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
await copyFile(source,join(mac,'zerowork'));await copyFile(join(source,'..','zw_ipc.so'),join(mac,'zw_ipc.so'));
const fixture=join(out,'upload-fixture');await mkdir(fixture);await writeFile(join(fixture,'first.txt'),'first picker fixture');await writeFile(join(fixture,'second.txt'),'second picker fixture');
await mkdir(join(out,'download-target'));
const remoteRoot=join(out,'remote-root');
if(complete){await writeFile(join(fixture,'first.txt'),Buffer.from(Array.from({length:300123},(_,i)=>i%251)));await writeFile(join(fixture,'second.txt'),'第二个上传文件\n'.repeat(8192))}
const peerLog=await open(join(out,'peer.log'),'w');const peerOut=join(out,'peer');const peer=spawn('python3',['e2e/builtin_records_ssh_peer.py','--out',peerOut,...(complete?['--sftp-root',remoteRoot]:[])],{stdio:['ignore',peerLog.fd,peerLog.fd]});const peerEnded=new Promise(r=>peer.once('close',r));
const ready=await waitFor(async()=>{try{return JSON.parse(await readFile(join(peerOut,'ready.json'),'utf8'))}catch{return null}},15000);
await writeFile(join(data,'known_hosts'),ready.known_host);
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Owned records SSH"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');const app=spawn(join(mac,'zerowork'),[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const report:any={status:'running',pid:app.pid,isolated:iso,sha256:createHash('sha256').update(await readFile(source)).digest('hex'),checks:[],captures:[],limits:['Harness drives terminal commands; an external CUA driver operates the real AppKit panels. IME and VoiceOver are outside this check.','The owned loopback peer provides an actual ZSH PTY but no SFTP subsystem: this checks cancellation and queue handoff, not completed file transfer. No external host is accessed.']};
const flat=(n:any):any[]=>[n,...(n.children??[]).flatMap(flat)];
const content=(n:any):string=>!shown(n)?'':(n.text??'')+(n.children??[]).map(content).join('');
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const vis=(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,12000),hidden=(id:string)=>waitFor(async()=>!(await query(id)).some(shown)||null,12000);
async function click(id:string){const n=await vis(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)}
async function press(name:string,mods?:any){assert((await key(name,mods)).ok)}
async function type(text:string){assert((await type_(text)).ok)}
async function capture(name:string){await sleep(180);assert((await screenshot(join(out,name+'.png'))).ok);const nodes:any={};for(const id of ['terminal.surface','terminal.commands','terminal.command.input','workspace.pane','terminal.command.record','terminal.command.output','terminal.search.count','terminal.search.query','tabs.strip'])nodes[id]=await query(id);await writeFile(join(out,name+'.json'),JSON.stringify(nodes,null,2));report.captures.push(name)}
async function palette(){await type('@');await vis('terminal.commands')}
async function command(value:string){await palette();await type(value);await press('right');await hidden('terminal.commands');await press('return');await sleep(350)}
async function outputs(){return (await query('terminal.command.output')).filter(shown).map(content).join('\n')}
async function records(){return (await query('terminal.command.record')).filter(shown).map(content)}
try{
 await waitForServerReady();await resizeWindow(1200,800);
 const host=await vis('sidebar.host');assert((await clickAt(host.rect.x+host.rect.w/2,host.rect.y+host.rect.h/2,2)).ok);
 await waitFor(async()=>content(await vis('workspace.pane')).includes('sshrecords')||null,30000);
 await sleep(600);await type('cd '+(complete?remoteRoot:'/tmp'));await press('return');await sleep(400);
 async function drive(stage:string,cmd:string){
   await writeFile(join(out,'stage.txt'),stage);await command(cmd);
   await waitFor(async()=>{try{await readFile(join(out,'continue-'+stage));return true}catch{return null}},180000);
   await hidden('transfer.confirmation');
 }
 await drive('1-up-cancel','up');
 await waitFor(async()=>(await outputs()).includes('已取消选择，未添加传输任务')||null);
 assert(!(await readFile(join(out,'app.log'),'utf8')).includes('FILE_SESSION_TRANSFER_ENQUEUED'));
 report.checks.push('@up opens native picker; cancelling creates no task and no confirmation');
 await drive('2-up-select','up '+fixture);
 await waitFor(async()=>(await outputs()).includes('已加入上传队列')||null);
 assert((await readFile(join(out,'app.log'),'utf8')).includes('FILE_SESSION_TRANSFER_ENQUEUED'));
 await capture('upload-queued');
 report.checks.push('@up selection immediately enqueues upload without a second confirmation');
 const hash=(bytes:Buffer)=>createHash('sha256').update(bytes).digest('hex');
 if(complete){
   report.files=[];
   for(const name of ['first.txt','second.txt']){
     const original=await readFile(join(fixture,name));
     const uploaded=await waitFor(async()=>{try{const bytes=await readFile(join(remoteRoot,name));return hash(bytes)===hash(original)?bytes:null}catch{return null}},30000);
     assert.deepEqual(uploaded,original);
     report.files.push({name,size:original.length,source_sha256:hash(original),uploaded_sha256:hash(uploaded)});
   }
   await capture('upload-completed');
   report.checks.push('Both selected files completed actual SFTP uploads to the captured shell directory; bytes and SHA-256 match');
 }
 const downloadSource=complete?remoteRoot+'/first.txt':'/tmp/picker-download.txt';
 const countBefore=((await readFile(join(out,'app.log'),'utf8')).match(/FILE_SESSION_TRANSFER_ENQUEUED/g)||[]).length;
 await drive('3-dl-cancel','dl '+downloadSource);
 assert.equal(((await readFile(join(out,'app.log'),'utf8')).match(/FILE_SESSION_TRANSFER_ENQUEUED/g)||[]).length,countBefore);
 await drive('4-dl-select','dl '+downloadSource);
 await waitFor(async()=>(await outputs()).includes('已加入下载队列')||null);
 assert.equal(((await readFile(join(out,'app.log'),'utf8')).match(/FILE_SESSION_TRANSFER_ENQUEUED/g)||[]).length,countBefore+1);
 await capture('download-queued');
 report.checks.push('@dl cancellation creates no task; directory selection immediately enqueues download');
 if(complete){
   const original=await readFile(join(fixture,'first.txt'));
   const downloaded=await waitFor(async()=>{try{const bytes=await readFile(join(out,'download-target','first.txt'));return hash(bytes)===hash(original)?bytes:null}catch{return null}},30000);
   assert.deepEqual(downloaded,original);
   report.files[0].downloaded_sha256=hash(downloaded);
   await click('toolbar.transfers');
   await waitFor(async()=>{const statuses=(await query('transfer.task.status')).filter(shown).map(content);return statuses.filter(value=>value.includes('已完成')).length===2||null},15000);
   report.checks.push('Native transfer manager shows both upload and download jobs completed');
   await capture('download-completed');
   await writeFile(join(out,'completed-task-statuses.json'),JSON.stringify(await query('transfer.task.status'),null,2));
   report.checks.push('The uploaded file completed an actual SFTP download to the native-selected directory; round-trip bytes and SHA-256 match');
   report.limits=['Actual SSH shell plus writable SFTP on 127.0.0.1, restricted to this run-owned root; no external host or user data accessed.','Harness drives commands, CUA operates AppKit selectors; IME and VoiceOver are outside this check.'];
 }
 const received=Buffer.concat(await Promise.all((await readdir(peerOut)).filter(n=>n.startsWith('received-')).map(n=>readFile(join(peerOut,n)))));assert(received.includes(Buffer.from('file://localhost')));assert(!received.includes(Buffer.from('@up')));assert(!received.includes(Buffer.from('@dl')));
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});process.exitCode=1}
finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}peer.kill('SIGTERM');await Promise.race([peerEnded,sleep(3500)]);await peerLog.close();await log.close();await cleanupOwnedBridgeDirectories(app.pid!);await rm(iso,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}))}
