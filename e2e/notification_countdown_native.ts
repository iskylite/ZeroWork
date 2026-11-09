/** Native countdown presentation; isolated data and production card renderers.
 * node e2e/notification_countdown_native.ts BUILD_PREFIX OUTPUT_DIRECTORY
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,writeFile,rm} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {join,resolve} from 'node:path';
const prefix=resolve(process.argv[2]),out=resolve(process.argv[3]);
const h=await import('../vendor/zenit/e2e/client.ts');
await mkdir(out,{recursive:true});
const base=await mkdtemp('/private/tmp/zw-countdown-'),rpc=join(base,'rpc'),data=join(base,'data');
await mkdir(rpc);await mkdir(data);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const binary=join(prefix,'bin/notification-preview'),log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
const click=async(id:string)=>{const n=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok,id);};
const checks:string[]=[],shots:string[]=[];let stage='startup';
async function capture(name:string){const file=join(out,name+'.png');assert((await h.screenshot(file)).ok);shots.push(file);}
async function align(timerId:string,actionId:string){
 const timer=await visible(timerId),action=await visible(actionId);
 assert(timer.rect.x+timer.rect.w<=action.rect.x+0.5,'countdown precedes action without overlap');
 assert(Math.abs(timer.rect.y+timer.rect.h/2-action.rect.y-action.rect.h/2)<=1,'countdown vertically centered with action');
}
try{
 await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 for(const theme of ['light','dark','sauber']){
  stage=theme+' command';await click('fixture.theme.'+theme);await h.resizeWindow(1440,900);
  await click('fixture.command-error');await h.mouseMove(5,5);
  await visible('terminal.ai-error-hint');
  const initial=text(await visible('terminal.ai-error-hint.countdown'));assert.match(initial,/^[78] 秒后关闭$/);
  await align('terminal.ai-error-hint.countdown','terminal.ai-error-hint.open');await capture(theme+'-command');
  await h.sleep(1200);assert.notEqual(text(await visible('terminal.ai-error-hint.countdown')),initial);
  const card=await visible('terminal.ai-error-hint');await h.mouseMove(card.rect.x+20,card.rect.y+20);
  await absent('terminal.ai-error-hint.countdown');assert(!text(await visible('terminal.ai-error-hint')).includes('已暂停'));
  await capture(theme+'-command-interacting');
  if(theme==='light'){await h.sleep(8200);await visible('terminal.ai-error-hint');}
  await h.mouseMove(5,5);assert.match(text(await visible('terminal.ai-error-hint.countdown')),/^[78] 秒后关闭$/);
  if(theme==='light'){
   stage='command idle expiration';await h.sleep(8300);await absent('terminal.ai-error-hint');
  }else{
   await click('terminal.ai-error-hint.open');await absent('terminal.ai-error-hint');assert(text(await visible('fixture.result')).includes('已打开命令分析'));
  }
  checks.push(theme+': command decreases each second, hides countdown on hover, resumes, and closes or opens original analysis');
  stage=theme+' application risk';await click('fixture.application-risk');await h.mouseMove(5,5);
  await visible('notifications.toast.0');assert.match(text(await visible('notifications.countdown')),/^[78] 秒后关闭$/);
  await align('notifications.countdown','notifications.action');await capture(theme+'-risk');
  const toast=await visible('notifications.toast.0');await h.mouseMove(toast.rect.x+20,toast.rect.y+20);
  await absent('notifications.countdown');assert(!text(await visible('notifications.toast.0')).includes('已暂停'));
  await h.mouseMove(5,5);await visible('notifications.countdown');
  await click('notifications.expand');await visible('notifications.detail');await h.mouseMove(5,5);
  await absent('notifications.countdown');await capture(theme+'-risk-expanded');
  if(theme==='light'){await h.sleep(8200);await visible('notifications.toast.0');await absent('notifications.countdown');}
  await click('notifications.expand');await h.mouseMove(5,5);
  // Clicking an expanded card can retain keyboard focus: its timer must stay hidden.
  const focused=JSON.stringify(await h.focused());
  if(focused.includes('notifications.expand'))await absent('notifications.countdown');
  await click('notifications.dismiss.0');await absent('notifications.toast.0');
  checks.push(theme+': risk banner shows countdown, interaction hides it, expanded details retain notification');
 }
 stage='minimum window long content';await h.resizeWindow(860,480);await click('fixture.long');await h.mouseMove(5,5);
 await visible('notifications.toast.0');await visible('notifications.countdown');await align('notifications.countdown','notifications.action');
 let card=await visible('notifications.toast.0');
 assert(card.rect.x>=0&&card.rect.y>=0&&card.rect.x+card.rect.w<=860.5&&card.rect.y+card.rect.h<=480.5);
 for(const id of ['notifications.countdown','notifications.action','notifications.expand']){
  const n=await visible(id);assert(n.rect.x>=card.rect.x&&n.rect.x+n.rect.w<=card.rect.x+card.rect.w+0.5,id+' fits card');
 }
 await capture('minimum-long');await click('notifications.expand');await h.mouseMove(5,5);await absent('notifications.countdown');await capture('minimum-long-expanded');
 await click('notifications.dismiss.0');
 stage='risk expiration and history';await click('fixture.application-risk');await h.mouseMove(5,5);await visible('notifications.countdown');
 await h.sleep(8300);await absent('notifications.toast.0');await click('toolbar.notifications');await visible('notifications.history.record');
 await capture('retained-history');checks.push('minimum-width long content and all actions fit; expired risks remain in history');
 await writeFile(join(out,'report.json'),JSON.stringify({status:'passed',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks,screenshots:shots,scope:'Production native renderers with synthetic notification facts, isolated app/data and Harness input. No remote sessions or OS notification delivery.'},null,2));
 console.log(JSON.stringify({status:'passed',out,checks}));
}catch(error){
 await h.screenshot(join(out,'failure.png')).catch(()=>{});
 await writeFile(join(out,'failure-tree.json'),JSON.stringify(await h.tree().catch(()=>null),null,2));
 await writeFile(join(out,'report.json'),JSON.stringify({status:'failed',stage,error:String(error),checks,screenshots:shots},null,2));
 console.error(stage,error);process.exitCode=1;
}finally{
 if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;await log.close();await rm(base,{recursive:true,force:true});
}
