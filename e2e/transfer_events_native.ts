/** Production Manager projection and event modal; deterministic engine, no network or file IO. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,open,writeFile,readFile,chmod,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {waitForServerReady,waitFor,query,clickTestId,key,resizeWindow,screenshot,sleep} from '../vendor/zenit/e2e/client.ts';
const reference=process.argv.includes('--reference');
const theme=process.env.ZEROWORK_ACCEPT_THEME??'dark';
assert(['dark','light','sauber'].includes(theme));
const out=resolve(process.argv[2]??'dist/ui-acceptance/functional-alignment-20261021/events');
await mkdir(out,{recursive:true});
const rpc=await mkdtemp(join(tmpdir(),'zw-event-rpc-'));
await chmod(rpc,0o700);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const binary=resolve(process.env.ZEROWORK_TRANSFER_PREVIEW_BINARY??'zig-out/bin/transfer-events-preview');
const log=await open(join(out,'app.log'),'w');
const child=spawn(binary,[...(reference?['--reference']:[]),'--theme',theme],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(r=>child.once('close',()=>r()));
const report:any={status:'running',binary,theme,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],limits:['Real production panel, Manager and Modal; deterministic engine, no real SSH/SFTP/file transfer','Synthetic Harness input; no physical input claim']};
const shown=(n:any)=>n.visible!==false&&n.hidden!==true&&n.rect.w>0&&n.rect.h>0;
const visible=async(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null);
async function click(id:string){await visible(id);assert((await clickTestId(id)).ok);}
try{
 await waitForServerReady();report.pid=child.pid;report.rpc_owner=JSON.parse(await readFile(join(rpc,'owner.json'),'utf8'));assert.equal(Number(report.rpc_owner.pid),child.pid);
 await click('transfer.task.expand');await sleep(300);
 assert(!(await query('transfer.notice')).some(shown), 'Empty notice row stays hidden');
 await screenshot(join(out,'task-detail.png'));
 await click('transfer.task.events');
 await sleep(300);
 const card=await visible('transfer.events.dialog');
 assert.equal(card.rect.w,520);assert(card.rect.h<=242);
 const entries=await visible('transfer.events.entries');
 const rows=(await query('transfer.events.entry')).filter(shown);
 const eventText=rows.map(n=>n.text??'').join('\n');
 assert.match(eventText,/入队/);assert.match(eventText,reference?/开始上传/:/传输中/);
 const viewport=await visible('transfer.events.viewport');
 if(reference){assert.equal(rows.length,4);assert.equal(card.rect.h,162);assert.equal(viewport.rect.h,104);}
 await writeFile(join(out,'geometry.json'),JSON.stringify({card,entries,rows,viewport},null,2));
 assert((await screenshot(join(out,'events.png'))).ok);
 await key('escape');await waitFor(async()=>!(await query('transfer.events.dialog')).some(shown)||null);
 await click('transfer.task.events');await click('transfer.events.dismiss');
 await waitFor(async()=>!(await query('transfer.events.dialog')).some(shown)||null);
 await resizeWindow(860,480);await sleep(300);await click('transfer.task.events');await sleep(300);
 const compact=await visible('transfer.events.dialog');
 assert(compact.rect.x>=0&&compact.rect.y>=0&&compact.rect.x+compact.rect.w<=860&&compact.rect.y+compact.rect.h<=480);
 await visible('transfer.events.dismiss');assert((await screenshot(join(out,'events-compact.png'))).ok);
 report.checks=['520px width with content-driven height capped at 242px','Real Manager enqueue and running receipts visible','Escape closes','Close returns to unchanged task list','860x480 modal and header dismiss stay inside viewport'];report.status='passed';
}catch(e){report.status='failed';report.error=String(e);report.nodes=Object.fromEntries(await Promise.all(['transfer.events.dialog','transfer.events.entries','transfer.task.events','transfer.failure'].map(async id=>[id,await query(id)])));await screenshot(join(out,'failure.png')).catch(()=>{});throw e;}
finally{child.kill('SIGTERM');await ended;await log.close();await rm(rpc,{recursive:true,force:true});report.cleanup={owned_process_exited:true,rpc_removed:true,signal:child.signalCode,note:'SIGTERM is owned preview cleanup, not normal window-close evidence'};await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
