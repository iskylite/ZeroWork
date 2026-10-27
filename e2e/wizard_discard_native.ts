/** Whole production wizard flow, isolated config and own delayed SSH handshake peer. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {createServer} from 'node:net';
import {mkdir,mkdtemp,realpath,open,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,screenPos,sleep,scrollAt} from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]),theme=process.argv[4]??'dark';
assert(['dark','light','sauber'].includes(theme));
await mkdir(out,{recursive:true});
const isolated=await realpath(await mkdtemp(join(tmpdir(),'zw-wizard-discard-'))),data=join(isolated,'data'),rpc=join(isolated,'rpc');
await mkdir(data);await mkdir(rpc);
await writeFile(join(data,'hosts.toml'),'');
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
let connected=0,disconnected=0;const sockets=new Set<any>();
const peer=createServer(s=>{connected++;sockets.add(s);s.on('data',()=>{});s.on('error',()=>{});s.on('close',()=>{disconnected++;sockets.delete(s)});});
await new Promise<void>(r=>peer.listen(0,'127.0.0.1',r));const port=(peer.address() as any).port;
const log=await open(join(out,'app.log'),'w');
const child=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(r=>child.once('close',()=>r()));
const report:any={status:'running',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),theme,checks:[],stages:[],limits:['Synthetic Harness input, not physical keyboard/IME verification','Own loopback server holds SSH handshake; no external host, credentials or remote commands']};
const shown=(n:any)=>n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flatten=(n:any):any[]=>[n,...(n.children??[]).flatMap(flatten)];
const text=(n:any)=>flatten(n).map(x=>x.text??'').join(' ');
async function current(id:string){
 if(id==='wizard.dialog'){
  if(!(await query('wizard.close')).some(shown))return null;
  return {rect:await screenPos(id)};
 }
 return (await query(id)).find(shown)??null;
}
async function visible(id:string){return waitFor(()=>current(id));}
async function click(id:string){let prior='';let repeats=0;const n=await waitFor(async()=>{const n=await current(id);if(!n)return null;const at=JSON.stringify(n.rect);repeats=at===prior?repeats+1:0;prior=at;await sleep(80);return repeats>=2?n:null;});assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);}
async function fill(id:string,value:string){await click(id);await key('a',{cmd:true});await type_(value);await waitFor(async()=>{const n=await current(id);return n&&text(n).includes(value)?true:null});}
async function closed(){await waitFor(async()=>!(await query('wizard.close')).some(shown)||null);}
async function capture(name:string){await sleep(200);const dialog=await visible('wizard.dialog');await writeFile(join(out,name+'.json'),JSON.stringify(dialog,null,2));assert((await screenshot(join(out,name+'.png'))).ok);report.stages.push({name,rect:dialog.rect});}
try{
 await waitForServerReady(30000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),child.pid);
 await resizeWindow(1440,900);await click('sidebar.empty.new');
 await fill('wizard.name','DB-Master');await fill('wizard.host','127.0.0.1');await fill('wizard.port',String(port));await fill('wizard.user','fixture');
 await capture('01-identity');await click('wizard.cancel');await closed();
 assert(!(await query('wizard.discard.confirm')).some(shown));assert.equal(connected,0);
 assert.equal((await readFile(join(data,'hosts.toml'),'utf8')).trim(),'');
 await click('sidebar.empty.new');assert(!text(await visible('wizard.name')).includes('DB-Master'));
 await fill('wizard.name','DB-Master');await fill('wizard.host','127.0.0.1');await fill('wizard.port',String(port));await fill('wizard.user','fixture');
 await click('wizard.next.identity');await capture('03-route');assert.match(text(await visible('wizard.access.direct')),/从本机直接连接/);
 await click('wizard.next.route');await capture('04-review');assert.match(text(await visible('wizard.review.name')),/DB-Master/);await click('wizard.review.modify');await visible('wizard.name');await click('wizard.next.identity');await click('wizard.next.route');
 await resizeWindow(860,480);await capture('07-review-compact');await resizeWindow(1440,900);
 await click('wizard.test');await waitFor(async()=>connected===1||null,15000);
 await capture('08a-test-progress-visible');const stage=await visible('wizard.test.stage.0');assert(Math.abs(stage.rect.h-Number(process.argv[5]??54.6))<0.1);assert.match(text(stage),/DB-Master/);assert.match(text(stage),/127\.0\.0\.1/);assert(!(await current('wizard.test.hop.9')));await click('wizard.test.toggle');await visible('wizard.test.hop.9');await sleep(700);await capture('08b-test-details-expanded');const detailsArea=await visible('wizard.scroll.review');await scrollAt(detailsArea.rect.x+detailsArea.rect.w-20,detailsArea.rect.y+detailsArea.rect.h/2,0,-1400);await sleep(300);await capture('08b2-test-details-logs');const logs=await visible('wizard.test.logs.viewport');assert(logs.rect.y+logs.rect.h<=(await visible('wizard.footer')).rect.y+1);await scrollAt(detailsArea.rect.x+detailsArea.rect.w-20,detailsArea.rect.y+detailsArea.rect.h/2,0,1400);await sleep(300);await click('wizard.test.toggle');assert(!(await current('wizard.test.hop.9')));await visible('wizard.test.stage.0');await capture('08c-test-details-collapsed');report.checks.push('Real per-hop stage summary keeps endpoint and state; details expand and collapse during the same live probe');const probe=await visible('wizard.test.card'),actions=await visible('wizard.footer'),steps=await visible('wizard.steps');assert(probe.rect.y>=steps.rect.y+steps.rect.h-0.5&&probe.rect.y<actions.rect.y);

 await click('wizard.close');await closed();
 assert(!(await query('wizard.discard.confirm')).some(shown));
 assert((await screenshot(join(out,'09-closed-after-test.png'))).ok);
 await waitFor(async()=>disconnected===1||null,15000);
 assert.equal((await readFile(join(data,'hosts.toml'),'utf8')).trim(),'');
 await click('sidebar.empty.new');assert(!text(await visible('wizard.name')).includes('DB-Master'));
 await click('wizard.close');await closed();
 await click('sidebar.empty.new');await fill('wizard.name','unfinished');await key('escape');await closed();
 assert(!(await query('wizard.discard.confirm')).some(shown));
 assert((await screenshot(join(out,'10-closed-after-escape.png'))).ok);
 assert.equal(connected,1);
 report.checks=[...report.checks,'Cancel closes a populated draft directly','Close cancels exact pending probe and waits for disconnect','No host persisted by cancellation','Reopen has no cancelled draft','Empty draft closes directly','Escape closes partial input directly','No discard confirmation shown'];report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await screenshot(join(out,'failure.png')).catch(()=>{});throw e;}
finally{report.peer={connected,disconnected};await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));child.kill('SIGTERM');await ended;for(const s of sockets)s.destroy();await new Promise<void>(r=>peer.close(()=>r()));await log.close();}
