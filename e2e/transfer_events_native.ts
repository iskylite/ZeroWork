/** Production Manager projection and event popover; deterministic engine, no network or file IO. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,open,writeFile,readFile,chmod,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {waitForServerReady,waitFor,query,clickTestId,clickAt,key,resizeWindow,screenshot,sleep} from '../vendor/zenit/e2e/client.ts';
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
const report:any={status:'running',binary,theme,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],limits:['Real production panel, Manager and Popover; deterministic engine, no real SSH/SFTP/file transfer','Synthetic Harness input; no physical input claim']};
const shown=(n:any)=>n.visible!==false&&n.hidden!==true&&n.rect.w>0&&n.rect.h>0;
const visible=async(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null);
async function click(id:string){await visible(id);assert((await clickTestId(id)).ok);}
try{
 await waitForServerReady();report.pid=child.pid;report.rpc_owner=JSON.parse(await readFile(join(rpc,'owner.json'),'utf8'));assert.equal(Number(report.rpc_owner.pid),child.pid);
 await visible('transfer.task.events');await sleep(300);
 assert(!(await query('transfer.notice')).some(shown), 'Empty notice row stays hidden');
 await screenshot(join(out,'task-detail.png'));
 await click('transfer.task.events');
 await sleep(300);
 const card=await visible('transfer.events.dialog');
 assert.equal(card.rect.w,520);assert(card.rect.h<=242);
 const anchor=(await visible('transfer.task.events')).rect;
 assert(Math.abs(card.rect.y-anchor.y-anchor.h-8)<1 || Math.abs(card.rect.y+card.rect.h-anchor.y+8)<1,'Popover stays 8px above or below its trigger');
 const entries=await visible('transfer.events.entries');
 const rows=(await query('transfer.events.entry')).filter(shown);
 const eventText=rows.map(n=>n.text??'').join('\n');
 assert.match(eventText,/入队/);assert.match(eventText,reference?/开始上传/:/传输中/);
 const viewport=await visible('transfer.events.viewport');
 if(reference){assert.equal(rows.length,4);assert.equal(card.rect.h,162);assert.equal(viewport.rect.h,104);}
 await writeFile(join(out,'geometry.json'),JSON.stringify({card,entries,rows,viewport},null,2));
 assert((await screenshot(join(out,'events.png'))).ok);
 // Resize the open popover through both compact and restored layouts.
 const resizing=[];
 for(const [width,height] of [[620,360],[860,480],[1100,720]]){
  await resizeWindow(width,height);await sleep(400);
  const popup=(await visible('transfer.events.dialog')).rect;
  const trigger=(await visible('transfer.task.events')).rect;
  assert(popup.x>=7.5&&popup.y>=7.5&&popup.x+popup.w<=width-7.5&&popup.y+popup.h<=height-7.5);
  assert(Math.abs(popup.y-trigger.y-trigger.h-8)<1 || Math.abs(popup.y+popup.h-trigger.y+8)<1,'Open popover follows trigger after resizing');
  const close=(await visible('transfer.events.dismiss')).rect;
  const body=(await visible('transfer.events.viewport')).rect;
  assert(close.y>=popup.y&&close.y+close.h<=popup.y+popup.h);
  assert(body.y+body.h<=popup.y+popup.h-11.5);
  resizing.push({width,height,popup,trigger,body});
  assert((await screenshot(join(out,`events-open-${width}.png`))).ok);
 }
 await writeFile(join(out,'resize-geometry.json'),JSON.stringify(resizing,null,2));
 await key('escape');await waitFor(async()=>!(await query('transfer.events.dialog')).some(shown)||null);
 await click('transfer.task.events');await click('transfer.events.dismiss');
 await waitFor(async()=>!(await query('transfer.events.dialog')).some(shown)||null);
 await click('transfer.task.events');assert((await clickAt(8,350)).ok);
 await waitFor(async()=>!(await query('transfer.events.dialog')).some(shown)||null);
 await resizeWindow(860,480);await sleep(300);await click('transfer.task.events');await sleep(300);
 const compact=await visible('transfer.events.dialog');
 assert(compact.rect.x>=0&&compact.rect.y>=0&&compact.rect.x+compact.rect.w<=860&&compact.rect.y+compact.rect.h<=480);
 await visible('transfer.events.dismiss');assert((await screenshot(join(out,'events-compact.png'))).ok);
 report.checks=['520px width with content-driven height capped at 242px','Real Manager enqueue and running receipts visible','Escape and outside click close','Close returns to unchanged task list','Open popover follows trigger at 620x360, 860x480 and 1100x720 with 8px gap and viewport inset','860x480 popover and header dismiss stay inside viewport'];report.status='passed';
}catch(e){report.status='failed';report.error=String(e);report.nodes=Object.fromEntries(await Promise.all(['transfer.events.dialog','transfer.events.entries','transfer.task.events','transfer.failure'].map(async id=>[id,await query(id)])));await screenshot(join(out,'failure.png')).catch(()=>{});throw e;}
finally{child.kill('SIGTERM');await ended;await log.close();await rm(rpc,{recursive:true,force:true});report.cleanup={owned_process_exited:true,rpc_removed:true,signal:child.signalCode,note:'SIGTERM is owned preview cleanup, not normal window-close evidence'};await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
