/** Production Manager + native panel: startup failure, explicit pause and retry.
 * node e2e/transfer_startup_failure_native.ts /absolute/evidence [fixture-binary]
 * Deterministic connector failure; no network or user transfer is touched.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,writeFile,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'/tmp/zw-transfer-startup-acceptance');await mkdir(out,{recursive:true});
const binary=resolve(process.argv[3]??'zig-out/bin/transfer-events-preview');
const rpc=await mkdtemp('/private/tmp/zw-transfer-startup-rpc-');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const child=spawn(binary,['--startup-failure'],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>child.once('close',r));
const report:any={status:'running',checks:[],limits:['Production UI and Manager with deterministic in-memory engine; no real SSH/SFTP transfer.']};
const shown=(n:any)=>n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');
const node=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null);
const row=async(name:string)=>h.waitFor(async()=>(await h.query('transfer.task')).find(n=>shown(n)&&text(n).includes(name))??null);
function descendant(n:any,id:string):any{if(n.test_id===id)return n;for(const c of n.children??[]){const found=descendant(c,id);if(found)return found;}return null;}
async function clickChild(name:string,id:string){const target=descendant(await row(name),id);assert(target,id);assert((await h.clickAt(target.rect.x+target.rect.w/2,target.rect.y+target.rect.h/2)).ok);}
async function capture(name:string){await h.mouseMove(3,3);await h.sleep(120);await h.screenshot(join(out,name+'.png'));}
try{
 await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),child.pid);
 await h.resizeWindow(926,594);
 const failed=await row('connection-failed.zip');assert.match(text(failed),/传输失败/);assert.match(text(failed),/SSH 认证失败/);assert(!text(failed).includes('已暂停'));
 assert.match(text(await row('manually-paused.zip')),/已暂停/);assert.match(text(await row('waiting-for-connection.zip')),/排队中/);assert.match(text(await row('waiting-for-connection.zip')),/正在建立传输连接/);
 await capture('startup-statuses');report.checks.push('Startup failure is failed with Chinese reason; manual pause and connection waiting have separate states.');
 await clickChild('connection-failed.zip','transfer.task.events');await node('transfer.events.dialog');const entries=text(await node('transfer.events.entries'));assert.match(entries,/传输失败/);assert.match(entries,/AuthFailed/);assert.match(entries,/阶段：SSH 连接与认证/);await capture('failure-events');
 assert((await h.clickTestId('transfer.events.dismiss')).ok);report.checks.push('Readonly task events retain the exact error code and failure stage.');
 await clickChild('connection-failed.zip','transfer.task.primary');await h.waitFor(async()=>text(await row('connection-failed.zip')).includes('传输中')?true:null);assert.match(text(await row('manually-paused.zip')),/已暂停/);
 await clickChild('connection-failed.zip','transfer.task.events');await node('transfer.events.dialog');assert.match(text(await node('transfer.events.entries')),/AuthFailed/);await h.clickTestId('transfer.events.dismiss');await capture('retry-running');report.checks.push('Retry starts a fresh binding while manual pause remains paused and historical failure diagnostics remain readable.');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});console.error(e);}
finally{if(child.exitCode===null){child.kill('SIGTERM');await ended;}await log.close();await rm(rpc,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
if(report.status!=='passed')process.exitCode=1;else console.log('PASS',report.checks.length,'transfer startup failure native checks');
