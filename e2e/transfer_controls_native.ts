/** Real production transfer controls in isolated process; optional main-app close check. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,open,readFile,writeFile,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {waitForServerReady,waitFor,query,clickAt,resizeWindow,screenshot,sleep} from '../zig-out/share/zenit/harness/client.ts';
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
 if(mode!=='main'){const rows=(await query('transfer.task')).filter(shown);assert(rows.length>0);for(const row of rows)assert.equal(row.rect.h,40);const actions=(await query('transfer.task.actions')).filter(shown);for(const action of actions){const row=rows.find((r:any)=>action.rect.y>=r.rect.y&&action.rect.y+action.rect.h<=r.rect.y+r.rect.h);assert(row,'Actions stay within the compact single row');assert(action.rect.x+action.rect.w<=row.rect.x+row.rect.w+0.5);}}}
 if(mode!=='main'){await click('transfer.task.primary');await click('transfer.task.cancel');await sleep(80);const actionLog=await readFile(join(out,'app.log'),'utf8');assert(actionLog.includes('TRANSFER_CONTROLS_FIXTURE action='));assert(actionLog.includes('action=cancel'));report.checks.push('Actual primary and cancel clicks reach the production action callback');}
 if(mode!=='tray'){await click('transfer.window.close');await waitFor(async()=>!(await query('transfer.manager')).some(shown)||null,10000);assert.equal(app.exitCode,null);report.checks.push('Actual X click hides production panel while owning process remains alive');assert((await screenshot(join(out,'closed.png'))).ok);
 const reopen=mode==='main'?'toolbar.transfers':'transfer.preview.reopen';await click(reopen);await visible('transfer.manager');await click('transfer.window.close');await waitFor(async()=>!(await query('transfer.manager')).some(shown)||null,10000);report.checks.push('Reopen and second X also hide panel');}
 report.status='passed';
} catch(e){report.status='failed';report.error=String(e);process.exitCode=1;} finally {if(app.exitCode===null)app.kill('SIGTERM');await end;await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,mode,error:report.error}));}
