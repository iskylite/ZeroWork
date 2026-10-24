/** Actual main-app SSH password challenge against an owned loopback peer; no transfer. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,rm,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep} from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]),theme=process.argv[4]??'dark';
assert(['dark','light','sauber'].includes(theme));
await mkdir(out,{recursive:true});const isolated=await mkdtemp(join(tmpdir(),'zw-auth-align-')),data=join(isolated,'data'),rpc=join(isolated,'rpc');await mkdir(data);await mkdir(rpc);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w'),peerLog=await open(join(out,'peer.log'),'w'),peerOut=join(out,'peer');
const peer=spawn('python3',[resolve('e2e/sftp_upload_loopback.py'),'--out',peerOut],{stdio:['ignore',peerLog.fd,peerLog.fd]});
const peerEnded=new Promise<void>(r=>peer.once('close',()=>r()));let app:any,ended:any;
const report:any={status:'running',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),theme,stages:[],checks:[],limits:['Harness synthetic input, no physical keyboard/IME claim','Own loopback password challenge and read-only SFTP attach; no file transfer or external hosts']};
const shown=(n:any)=>n?.visible!==false&&n?.hidden!==true&&(n?.effective_opacity??1)>0&&n?.rect?.w>0&&n?.rect?.h>0;
const nodes=(n:any):any[]=>!shown(n)?[]:[n,...(n.children??[]).flatMap(nodes)];const text=(n:any)=>nodes(n).map(x=>x.text??'').join(' ');
async function modal(){return (await query('auth.challenge.modal')).find(shown);}
async function current(id:string){if(id.startsWith('auth.challenge.')&&id!=='auth.challenge.modal'){const m=await modal();return m?nodes(m).find(n=>n.test_id===id):null;}return (await query(id)).find(shown);}
async function visible(id:string){return waitFor(()=>current(id));}
async function click(id:string){let last='',count=0;const n=await waitFor(async()=>{const n=await current(id);if(!n)return null;const at=JSON.stringify(n.rect);count=at===last?count+1:0;last=at;await sleep(80);return count>=2?n:null;});assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);}
async function capture(name:string){await sleep(200);const m=await modal();assert(m);await writeFile(join(out,name+'.json'),JSON.stringify(m,null,2));assert((await screenshot(join(out,name+'.png'))).ok);report.stages.push({name,rect:m.rect});}
let ready:any,fixture='';
async function passwordPrompt(){
 let trusted=0;
 return waitFor(async()=>{
  const m=await modal();if(!m)return null;
  const trust=nodes(m).find(n=>n.test_id==='auth.challenge.trust_once'&&n.focusable);
  if(trust){assert(text(m).includes(ready.fingerprint));assert(text(m).includes(String(ready.port)));assert(++trusted<=4);await click('auth.challenge.trust_once');await sleep(100);return null;}
  return nodes(m).some(n=>n.test_id==='auth.challenge.answer.0'&&n.focusable)?m:null;
 },30000);
}
try{
 ready=await waitFor(async()=>{try{return JSON.parse(await readFile(join(peerOut,'ready.json'),'utf8'));}catch{return null;}},15000);
 fixture=`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="sftp"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Loopback Auth"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\n`;
 await writeFile(join(data,'hosts.toml'),fixture);await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`);
 app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});ended=new Promise<void>(r=>app.once('close',()=>r()));
 await waitForServerReady(30000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');
 await click('sidebar.host');await click('sidebar.host.connect');await passwordPrompt();await capture('01-password-empty');
 const first=await modal();assert.equal(first.rect.w,430);assert(first.rect.h<=380);assert(!text(first).includes('本次认证不保存凭据'));
 assert(text(first).includes('凭据仅用于当前认证'));await click('auth.challenge.answer.0');await type_(ready.password);assert(!text(await modal()).includes(ready.password));
 await capture('02-password-masked');await click('auth.challenge.reveal.0');await waitFor(async()=>text(await modal()).includes(ready.password)||null);await click('auth.challenge.reveal.0');
 await click('auth.challenge.cancel');await waitFor(async()=>!(await modal())||null);await waitFor(async()=>JSON.parse(await readFile(join(peerOut,'state.json'),'utf8')).active_connections===0||null,15000);
 await click('sidebar.host');await click('sidebar.host.connect');await passwordPrompt();await resizeWindow(860,480);await capture('03-password-compact');
 const compact=await modal();assert(compact.rect.y>=0&&compact.rect.y+compact.rect.h<=480);const actions=await visible('auth.challenge.actions');assert(actions.rect.y+actions.rect.h<=480);
 await click('auth.challenge.answer.0');await type_(ready.password);await click('auth.challenge.submit');
 let subsequent=0;
 await waitFor(async()=>{
  if((await query('files.workspace')).some(shown))return true;
  const m=await modal();if(!m)return null;
  if(nodes(m).some(n=>n.test_id==='auth.challenge.trust_once'&&n.focusable)){
   assert(text(m).includes(ready.fingerprint));assert(++subsequent<=6);await click('auth.challenge.trust_once');await sleep(100);return null;
  }
  if(nodes(m).some(n=>n.test_id==='auth.challenge.answer.0'&&n.focusable)){
   assert(++subsequent<=6);assert(text(m).includes(String(ready.port)));await click('auth.challenge.answer.0');await key('a',{cmd:true});await type_(ready.password);await click('auth.challenge.submit');await sleep(100);
  }
  return null;
 },45000);assert(!(await modal()));
 const tabs=nodes(await visible('tabs.strip')).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??''));const fileTab=tabs.at(-1).test_id;
 await click(fileTab.replace('tabs.tab.','tabs.close.'));await waitFor(async()=>JSON.parse(await readFile(join(peerOut,'state.json'),'utf8')).active_connections===0||null,15000);
 const state=JSON.parse(await readFile(join(peerOut,'state.json'),'utf8'));assert.equal(state.upload,null);assert.equal(state.forbidden_operations.length,0);assert(!state.calls.some(c=>c.operation==='WRITE'));
 assert.equal(await readFile(join(data,'hosts.toml'),'utf8'),fixture);report.peer={connections:state.connections.length,active_connections:state.active_connections,upload:state.upload};
 report.checks=['430px password form shrinks to content within 380px maximum','One credential safety notice retained','Password masked and explicit eye toggle works','Cancel closes original connection and releases peer','860x480 dialog and actions reachable','Explicit password submit attaches actual SFTP workspace','Close releases connection; no write or transfer; no password saved'];report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await screenshot(join(out,'failure.png')).catch(()=>{});throw e;}
finally{if(app){app.kill('SIGTERM');await ended;}peer.kill('SIGTERM');await peerEnded;await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await log.close();await peerLog.close();await rm(isolated,{recursive:true,force:true});}
