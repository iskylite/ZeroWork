/** Real production transfer controls in isolated process; optional main-app close check. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,open,readFile,writeFile,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {waitForServerReady,waitFor,query,clickAt,mouseMove,resizeWindow,screenshot,sleep} from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]),mode=process.argv[4]??'fixture';await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-transfer-controls-')),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(data);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w'),app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const end=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n?.rect?.w>0&&n.rect.h>0&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0;
const visible=(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,10000);
const click=async(id:string)=>{const n=await visible(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);};
const report:any={mode,binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),pid:app.pid,isolated:iso,network:false,captures:[],checks:[]};
try {await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 if(mode==='main'){await click('toolbar.transfers');}
 for(const [w,h] of [[860,480],[1440,900]]) {await resizeWindow(w,h);const card=await visible('transfer.manager');await sleep(120);await writeFile(join(out,`${w}.json`),JSON.stringify(await query('transfer.manager'),null,2));assert((await screenshot(join(out,`${w}.png`))).ok);report.captures.push({w,h,card:card.rect});
 if(mode==='tray'){const card=(await visible('transfer.manager')).rect;const row=await visible('transfer.task');const progress=await visible('transfer.task.progress');assert(row.rect.y>=card.y&&row.rect.y+row.rect.h<=card.y+card.h,'First tray card fully fits');assert(progress.rect.y+progress.rect.h<=card.y+card.h,'Tray progress fully fits');}
 if(mode!=='main'){const rows=(await query('transfer.task')).filter(shown);assert(rows.length>0);for(const row of rows)assert.equal(row.rect.h,76);const actions=(await query('transfer.task.actions')).filter(shown);for(const action of actions){const row=rows.find((r:any)=>action.rect.y>=r.rect.y&&action.rect.y+action.rect.h<=r.rect.y+r.rect.h);assert(row,'Actions stay within the current card main row');assert(action.rect.x+action.rect.w<=row.rect.x+row.rect.w+0.5);}}}
 if(mode!=='main'){
 for(const column of ['transfer.task.owner','transfer.task.status','transfer.task.rate']){const cells=(await query(column)).filter(shown);if(cells.length>1){const right=cells[0].rect.x+cells[0].rect.w;for(const cell of cells)assert(Math.abs(cell.rect.x+cell.rect.w-right)<0.5,'Shared metadata column right edge: '+column);}}
 assert(!(await query('transfer.task.select')).some(shown));
 assert(!(await query('transfer.task.expand')).some(shown));
 assert(!(await query('transfer.task.more')).some(shown));
 assert((await query('transfer.task.progress')).filter(shown).length>0);
 const before=(await visible('transfer.manager')).rect;
 if(mode==='session')assert(!(await query('transfer.scope')).some(shown));
 await click('transfer.batch');await click('transfer.task.select');await sleep(100);
 assert((await screenshot(join(out,'selected.png'))).ok);
 await click('transfer.batch');assert(!(await query('transfer.task.select')).some(shown));
 const after=(await visible('transfer.manager')).rect;assert.equal(before.x,after.x);assert.equal(before.y,after.y);
 const row=await visible('transfer.task');await mouseMove(row.rect.x+100,row.rect.y+12);await sleep(650);
 const detail=await visible('transfer.task.hover_detail');
 assert(detail.rect.w<=420.5&&detail.rect.x>=0&&detail.rect.x+detail.rect.w<=1440.5);
 for(const id of ['transfer.detail.identity','transfer.detail.name','transfer.detail.local','transfer.detail.remote','transfer.detail.options'])assert((await query(id)).some(shown),'Structured hover field: '+id);
 const local=await visible('transfer.detail.local');await mouseMove(local.rect.x+20,local.rect.y+local.rect.h/2);await sleep(350);await visible('transfer.task.hover_detail');await click('transfer.detail.copy_local');await click('transfer.detail.copy_remote');
 assert((await screenshot(join(out,'hover-detail.png'))).ok);
 await mouseMove(5,5);
 await click('transfer.task.primary');await click('transfer.task.cancel');
 const actionLog=await readFile(join(out,'app.log'),'utf8');assert(actionLog.includes('action=cancel'));
 assert(!(await query('transfer.detail.status')).some(shown));
 report.checks.push('76px shallow cards, visible progress, direct actions, opt-in top management, unchanged scope and anchor');
 }
 if(mode!=='tray'){await click('transfer.window.close');await waitFor(async()=>!(await query('transfer.manager')).some(shown)||null,10000);assert.equal(app.exitCode,null);report.checks.push('Actual X click hides production panel while owning process remains alive');assert((await screenshot(join(out,'closed.png'))).ok);
 const reopen=mode==='main'?'toolbar.transfers':'transfer.preview.reopen';await click(reopen);await visible('transfer.manager');await click('transfer.window.close');await waitFor(async()=>!(await query('transfer.manager')).some(shown)||null,10000);report.checks.push('Reopen and second X also hide panel');}
 report.status='passed';
} catch(e){report.status='failed';report.error=String(e);process.exitCode=1;} finally {if(app.exitCode===null)app.kill('SIGTERM');await end;await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,mode,error:report.error}));}
