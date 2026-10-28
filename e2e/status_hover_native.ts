/** Statusbar hover previews and click pinning against an isolated SSH + Local session. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,realpath,copyFile,readFile,writeFile,open,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep,scrollAt,mouseDown,mouseMove,mouseUp} from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]),source=resolve(process.argv[3]);await mkdir(out,{recursive:false});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-builtin-records-'))),rpc=join(iso,'rpc'),data=join(iso,'data'),shell=join(iso,'shell');
// Always remove this run's sandbox, including setup and reporting failures.
try {
await Promise.all([mkdir(rpc),mkdir(data),mkdir(shell)]);
await writeFile(join(shell,'.zshrc'),"bindkey -e\nPS1='records%# '\n");
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
await copyFile(source,join(iso,'zerowork'));await copyFile(join(source,'..','zw_ipc.so'),join(iso,'zw_ipc.so'));
const peerLog=await open(join(out,'peer.log'),'w');const peerOut=join(out,'peer');const peer=spawn('python3',['e2e/builtin_records_ssh_peer.py','--out',peerOut],{stdio:['ignore',peerLog.fd,peerLog.fd]});const peerEnded=new Promise(r=>peer.once('close',r));
const ready=await waitFor(async()=>{try{return JSON.parse(await readFile(join(peerOut,'ready.json'),'utf8'))}catch{return null}},15000);
await writeFile(join(data,'known_hosts'),ready.known_host);
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Owned records SSH"\ngroup="QA hosts"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');const app=spawn(join(iso,'zerowork'),[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const report:any={status:'running',pid:app.pid,isolated:iso,sha256:createHash('sha256').update(await readFile(source)).digest('hex'),checks:[],captures:[],limits:['Public synthetic Harness on actual Metal window; no physical CUA/IME/VoiceOver acceptance.','The owned loopback SSH peer runs an actual ZSH PTY; no external host is accessed. Physical CUA/IME/VoiceOver remain separate.']};
const content=(n:any):string=>!shown(n)?'':(n.text??'')+(n.children??[]).map(content).join('');
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const vis=(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,12000),hidden=(id:string)=>waitFor(async()=>!(await query(id)).some(shown)||null,12000);
async function click(id:string){const n=await vis(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await sleep(160)}
async function press(name:string,mods?:any){assert((await key(name,mods)).ok)}
async function type(text:string){assert((await type_(text)).ok)}
async function capture(name:string){await sleep(180);assert((await screenshot(join(out,name+'.png'))).ok);report.captures.push(name)}
try{
 await waitForServerReady(60000);await resizeWindow(1440,900);const host=await vis('sidebar.host');assert((await clickAt(host.rect.x+host.rect.w/2,host.rect.y+host.rect.h/2,2)).ok);await waitFor(async()=>content(await vis('workspace.pane')).includes('sshrecords')||null,30000);await sleep(450);
 await mouseMove(700,300);await sleep(200);
 const cases=[['status.connection.identity','status.connection','status.connection.close'],['status.connection.chain','connection.details','connection.details.close'],['status.connection.forward','socks.info','socks.info.close'],['status.connection.theme','status.theme','status.theme.close']];
 async function checkEntries(cases:string[][]){
 for(const [triggerId,panelId] of cases){
  const t=await vis(triggerId);const x=t.rect.x+t.rect.w/2,y=t.rect.y+t.rect.h/2;
  await mouseMove(x,y);let panel=await vis(panelId);await sleep(200);
  await capture(triggerId.replaceAll('.','-')+'-hover');
  await mouseMove(panel.rect.x+panel.rect.w/2,panel.rect.y+25);await sleep(250);await vis(panelId);
  await mouseMove(700,300);await hidden(panelId);
  await mouseMove(x,y);await vis(panelId);await click(triggerId);await mouseMove(700,300);await sleep(350);await vis(panelId);
  const other=await vis(triggerId.startsWith('local.')?(triggerId==='local.status.theme'?'local.status.identity':'local.status.theme'):(triggerId==='status.connection.theme'?'status.connection.identity':'status.connection.theme'));await mouseMove(other.rect.x+other.rect.w/2,other.rect.y+other.rect.h/2);await sleep(250);await vis(panelId);
  await press('escape');await hidden(panelId);await mouseMove(700,300);
  report.checks.push(triggerId+': hover opens, panel stays interactive, leave closes, click pins and other hover preserves pinned panel, Escape closes');
 }
 }
 await checkEntries(cases);
 await click('toolbar.new_session');await click('session.menu.local');await vis('local.status.identity');await mouseMove(700,300);
 await checkEntries([['local.status.identity','status.detail',''],['local.status.theme','status.theme','']]);
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});process.exitCode=1}
finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}peer.kill('SIGTERM');await Promise.race([peerEnded,sleep(3500)]);await peerLog.close();await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
console.log(JSON.stringify({status:report.status,checks:report.checks,error:report.error,out}));
} finally {
 await rm(iso,{recursive:true,force:true});
}
