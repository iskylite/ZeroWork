/** Production Presenter/Coordinator in an isolated native Metal window.
 * Explicit fixture facts verify presentation, not SSH/LLM/OS delivery. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
const prefix=process.env.ZW_NOTIFICATION_PREFIX??'/private/tmp/zw-surfaces-prefix';
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const output=process.argv[2];assert(output);await mkdir(output,{recursive:true});
const base=await mkdtemp('/private/tmp/zw-feedback-'),rpc=join(base,'rpc');await mkdir(rpc);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const binary=join(prefix,'bin/notification-preview'),log=await open(join(output,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const end=new Promise(r=>app.once('close',r));
const report:any={status:'running',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],scope:'Production native feedback presentation using explicit local fixture facts. No network or OS notification delivery.',screenshots:[]};
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const vis=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,7000);
const hidden=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,7000);
async function click(id:string){await vis(id);assert((await h.clickTestId(id)).ok,id)}
async function capture(name:string){assert((await h.screenshot(join(output,name+'.png'))).ok);report.screenshots.push(name)}
try{
 await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1440,900);
 await click('fixture.local');await vis('notifications.local');await h.sleep(120);
 const local=(await h.query('notifications.local')).find(shown),anchor=(await h.query('fixture.local')).find(shown);
 assert(local.rect.x>=8&&local.rect.x+local.rect.w<=1432);assert(local.rect.y>=anchor.rect.y+anchor.rect.h+7||local.rect.y+local.rect.h<=anchor.rect.y-7);await capture('local-acknowledgment');await h.sleep(2300);await hidden('notifications.local');report.checks.push('local acknowledgment uses measured trigger, fits app and expires after 2 seconds');
 await click('fixture.local');await vis('notifications.local');await h.resizeWindow(860,480);await hidden('notifications.local');report.checks.push('local acknowledgment closes on resize');await h.resizeWindow(1440,900);
 await click('fixture.normal');await vis('notifications.toast.0');await h.sleep(180);
 const position=(await h.query('notifications.presenter')).find(shown).rect;assert.equal(position.x,1080);assert.equal(position.y,62);assert.equal(position.w,340);
 await capture('normal-standard');await h.sleep(3000);await vis('notifications.toast.0');await h.sleep(1300);await hidden('notifications.toast.0');report.checks.push('ordinary visible at 3 seconds; expires after 4 seconds');
 await click('fixture.action');await vis('notifications.toast.0');await h.sleep(4500);await vis('notifications.toast.0');await capture('action-after-four-seconds');await click('notifications.action');await hidden('notifications.toast.0');assert(JSON.stringify(await h.query('fixture.result')).includes('已打开结果'));report.checks.push('action lives beyond 4 seconds, opens actual result handler, dismisses');
 await click('fixture.normal');await vis('notifications.toast.0');await click('fixture.cover');await h.sleep(150);await hidden('notifications.toast.0');await capture('covered-paused');await h.sleep(4500);await click('fixture.cover');await vis('notifications.toast.0');await capture('resumed-after-four-seconds-hidden');await h.sleep(4500);await hidden('notifications.toast.0');report.checks.push('overlay hides ordinary feedback for >4 seconds, resumes and restarts visible timer');
 await click('fixture.action');await vis('notifications.toast.0');await h.sleep(8500);await hidden('notifications.toast.0');report.checks.push('action expires after 8 seconds when not invoked');
 for(let i=0;i<4;i++)await click('fixture.error');await h.sleep(180);
 for(let i=0;i<3;i++)await vis('notifications.toast.'+i);await capture('errors-three-visible-one-queued');await h.sleep(4500);for(let i=0;i<3;i++)await vis('notifications.toast.'+i);
 await click('notifications.dismiss.0');await h.sleep(180);for(let i=0;i<3;i++)await vis('notifications.toast.'+i);report.checks.push('four persistent errors: three slots then queued fourth appears after dismissal');
 await click('fixture.cover');await h.sleep(180);for(let i=0;i<3;i++)await vis('notifications.toast.'+i);await capture('errors-priority-over-obstacle');await click('fixture.cover');
 await h.resizeWindow(860,480);await h.sleep(250);const compact=(await h.query('notifications.presenter')).find(shown).rect;assert.equal(compact.x,500);assert.equal(compact.y,62);assert.equal(compact.w,340);await capture('errors-compact');
 for(let i=0;i<3;i++)await click('notifications.dismiss.0');await hidden('notifications.toast.0');report.checks.push('error priority, compact fixed origin and all errors explicitly dismissed');
 for(let i=0;i<3;i++)await click('fixture.long');await h.sleep(250);
 const longRoot=(await h.query('notifications.presenter')).find(shown), viewport=(await h.query('notifications.viewport')).find(shown);
 assert.equal(longRoot.rect.y,62);assert(longRoot.rect.y+longRoot.rect.h<=480.5);await capture('long-errors-compact-top');
 const allActions=(await h.query('notifications.action')).filter(shown);assert.equal(allActions.length,9);
 const last=allActions.at(-1), before=last.rect.y;
 assert((await h.scrollAt(viewport.rect.x+20,viewport.rect.y+100,0,-100000)).ok);await h.sleep(250);
 const bottom=(await h.query('notifications.action')).filter(shown).at(-1);
 assert(bottom.rect.y<before&&bottom.rect.y>=viewport.rect.y&&bottom.rect.y+bottom.rect.h<=viewport.rect.y+viewport.rect.h+.5);
 assert(bottom.rect.x>=viewport.rect.x&&bottom.rect.x+bottom.rect.w<=viewport.rect.x+viewport.rect.w+.5);await capture('long-errors-compact-bottom');await writeFile(join(output,'long-geometry.json'),JSON.stringify({root:longRoot.rect,viewport:viewport.rect,bottom:bottom.rect,actions:await h.query('notifications.action')},null,2));
 assert((await h.clickAt(bottom.rect.x+bottom.rect.w/2,bottom.rect.y+bottom.rect.h/2)).ok);await h.sleep(150);
 assert.equal((await h.query('notifications.toast.2')).filter(shown).length,0);
 report.checks.push('three long persistent facts retain all content in bounded scroll viewport; final wrapped action is reachable and dismisses original fact');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});process.exitCode=1}
finally{await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));app.kill('SIGTERM');await Promise.race([end,h.sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await end}await log.close();console.log(JSON.stringify({status:report.status,error:report.error,output}))}
