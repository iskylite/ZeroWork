/** Shared-task native acceptance helpers. Import into the process-owning
 * multiwindow runner after its two windows and real SFTP workspace are ready.
 * Every mutation below is a production control; /zerowork/windows is read-only
 * for task state and only selects/closes captured native window identities.
 */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { request, query, clickAt, mouseMove, key, type_, sleep, waitFor, screenshot } from '../zig-out/share/zenit/harness/client.ts';
const shown = (n:any):boolean => !!n?.rect && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? n.opacity ?? 1)>0 && n.rect.w>0 && n.rect.h>0;
const flat = (n:any):any[] => shown(n) ? [n,...(n.children??[]).flatMap(flat)] : [];
const text = (n:any):string => flat(n).filter(v=>typeof v.text==='string'&&v.text.length>0).map(v=>v.text).join(' ');
const within = (n:any,id:string):any => flat(n).find(v=>v.test_id===id);
async function visible(id:string):Promise<any>{return waitFor(async()=>(await query(id)).find(shown)??null,20000)}
async function clickNode(n:any){assert(shown(n));assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)}
async function click(id:string){await clickNode(await visible(id))}
export async function resourceSnapshot():Promise<any>{const result=await request('POST','/zerowork/windows',{action:'snapshot'});assert(result.ok);return result}
export async function selectResourceWindow(window:number){assert((await request('POST','/zerowork/windows',{action:'select',window})).ok);await sleep(100)}
async function approveClose(){
 for(const id of ['groups.close.accept','local.close.accept','session.close.accept']){const values=await query(id);const node=Array.isArray(values)?values.find(shown):null;if(node){await clickNode(node);return}}
 // The existing ordinary-session card predates test IDs. Read its real
 // workspace subtree and activate the actual displayed confirmation label.
 for(const pane of (await query('workspace.pane') instanceof Array ? await query('workspace.pane') : [])){const force=flat(pane).find(n=>n.text==='仍然关闭');if(force){await clickNode(force);return}}
}
export type RetainedOptions = {
 firstWindow:number; secondWindow:number; sourceName:string; targetDirectory:string;
 expectedSha256:string; output:string;
 // Used only by a controlled loopback peer to make the first real IO slice
 // available. No synthetic progress, state injection or fabricated checkpoint.
 releasePeer?:()=>Promise<void>;
 authenticate?:()=>Promise<void>;
};
export async function exerciseRetainedTransfer(options:RetainedOptions):Promise<any>{
 const {firstWindow,secondWindow,sourceName,targetDirectory,output}=options;
 const stages:any[]=[];
 const capture=async(name:string)=>{await sleep(150);const snapshot=await resourceSnapshot();await writeFile(join(output,name+'.json'),JSON.stringify(snapshot,null,2));assert((await screenshot(join(output,name+'.png'))).ok);stages.push({name,snapshot});return snapshot};
 const taskLabel=async(phase:string)=>waitFor(async()=>(await query('transfer.task')).find((n:any)=>shown(n)&&text(n).includes(sourceName)&&text(n).includes(phase))??null,15000);
 await selectResourceWindow(firstWindow);
 const initial=await resourceSnapshot();assert(initial.windows.some((w:any)=>w.window===firstWindow)&&initial.windows.some((w:any)=>w.window===secondWindow));
 const originalJobs=new Set(initial.tasks.map((t:any)=>t.job));
 const local=await visible('files.local'),path=within(local,'files.path');assert(path);
 await clickNode(path);await key('a',{cmd:true});await type_(targetDirectory);await key('return');
 await waitFor(async()=>text(within(await visible('files.local'),'files.path'))===targetDirectory?true:null,15000);
 const row=flat(await visible('files.remote')).find(n=>n.test_id==='files.row'&&within(n,'files.row.name')?.text===sourceName);assert(row,'Owned immutable peer source is present');
 await clickNode(row);await clickNode(within(await visible('files.remote'),'files.transfer'));await visible('files.copy.confirmation');await click('files.copy.submit');
 const created=await waitFor(async()=>{const s=await resourceSnapshot();return s.tasks.find((t:any)=>!originalJobs.has(t.job))??null},15000);
 assert(created.session>0);const job=created.job,originalSession=created.session;
 if(options.releasePeer)await options.releasePeer();
 await waitFor(async()=>{const current=(await resourceSnapshot()).tasks.find((t:any)=>t.job===job);return current?.state==='running'&&current.done_bytes>0?current:null},45000);
 if(!(await query('transfer.manager')).some(shown))await click('toolbar.transfers');
 const task=await waitFor(async()=>{const rows=(await query('transfer.task')).filter(shown);return rows.find((r:any)=>text(r).includes(sourceName))??null},15000);
 await clickNode(within(task,'transfer.task.primary'));
 await waitFor(async()=>{const current=(await resourceSnapshot()).tasks.find((t:any)=>t.job===job);return current?.state==='paused'&&current.cleanup==='released'?current:null},30000);
 await taskLabel('已暂停');
 await capture('tasks-01-real-paused-checkpoint');
 // The ordinary close transaction must export the original native checkpoint.
 assert((await request('POST','/zerowork/windows',{action:'close',window:firstWindow})).ok);
 await waitFor(async()=>{await approveClose();const s=await resourceSnapshot();return !s.windows.some((w:any)=>w.window===firstWindow)?s:null},60000);
 await selectResourceWindow(secondWindow);
 if(!(await query('transfer.manager')).some(shown))await click('toolbar.transfers');
 await taskLabel('已暂停');
 const retained=await capture('tasks-02-origin-window-closed-retained-in-second');
 const retainedJob=retained.tasks.find((t:any)=>t.job===job);assert(retainedJob);assert.equal(retainedJob.state,'paused');assert(retainedJob.retained_owner>0);assert.equal(retainedJob.original_session,originalSession);
 assert((await request('POST','/zerowork/windows',{action:'select',window:secondWindow})).ok);
 if(!(await query('transfer.manager')).some(shown))await click('toolbar.transfers');
 const secondRow=await waitFor(async()=>(await query('transfer.task')).find((n:any)=>shown(n)&&text(n).includes(sourceName))??null,15000);
 assert(text(secondRow).includes(`#${originalSession}`),'Second manager displays the original source');
 await clickNode(within(secondRow,'transfer.task.primary'));
 await waitFor(async()=>{if(options.authenticate)await options.authenticate();const current=(await resourceSnapshot()).tasks.find((t:any)=>t.job===job);if(current?.state==='failed')throw Error('Original retained job failed: '+JSON.stringify(current));return current?.state==='succeeded'&&current.cleanup==='released'?current:null},90000);
 await taskLabel('已完成');
 const bytes=await readFile(join(targetDirectory,sourceName));assert.equal(createHash('sha256').update(bytes).digest('hex'),options.expectedSha256);
 const finished=await capture('tasks-03-same-job-resumed-from-second-hash-verified');
 assert.equal(finished.tasks.find((t:any)=>t.job===job).original_session,originalSession);
 return {job,originalSession,bytes:bytes.length,sha256:options.expectedSha256,stages};
}

export type BackgroundOptions={firstWindow:number;secondWindow:number;asset:number;output:string;authenticate?:()=>Promise<void>;closeFirst?:boolean};
export async function exerciseSharedBackground(options:BackgroundOptions):Promise<any>{
 await selectResourceWindow(options.firstWindow);
 // Open the saved-host production menu. The caller's fixture has one direct
 // SSH asset; the normal action freezes its saved source and allocates owner.
 const host=await visible('sidebar.host');await mouseMove(host.rect.x+host.rect.w/2,host.rect.y+host.rect.h/2);await sleep(120);
 await click('sidebar.host.more');await click('context.menu.start_background_socks');
 const owner=await waitFor(async()=>{if(options.authenticate)await options.authenticate();const s=await resourceSnapshot();return s.backgrounds.find((b:any)=>b.asset===options.asset&&b.phase==='listening'&&b.local_port>0)??null},90000);
 const before=await resourceSnapshot();
 if(options.closeFirst){assert((await request('POST','/zerowork/windows',{action:'close',window:options.firstWindow})).ok);await waitFor(async()=>{await approveClose();return !(await resourceSnapshot()).windows.some((w:any)=>w.window===options.firstWindow)||null},60000)}
 await selectResourceWindow(options.secondWindow);
 const after=await resourceSnapshot();const shared=after.backgrounds.find((b:any)=>b.session===owner.session);assert(shared);assert.equal(shared.generation,owner.generation);assert.equal(shared.asset,options.asset);assert.equal(shared.local_port,owner.local_port);assert.equal(shared.phase,'listening');
 const entry=(await query('status.background.forward')).find(shown)??(await query('local.status.background.forward')).find(shown);await clickNode(entry);
 const row=await waitFor(async()=>(await query('socks.background.row')).find((n:any)=>shown(n)&&text(n).includes(owner.name))??null,15000);
 await clickNode(within(row,'socks.background.stop'));
 await waitFor(async()=>!(await resourceSnapshot()).backgrounds.some((b:any)=>b.session===owner.session)||null,60000);
 await writeFile(join(options.output,'background-shared-owner.json'),JSON.stringify({before,after,owner,stopped:await resourceSnapshot()},null,2));
 return {owner,before,after};
}
