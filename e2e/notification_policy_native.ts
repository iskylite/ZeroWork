/** Structured global notification policy, through the production native views. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,writeFile,rm,realpath} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'/tmp/zw-notification-policy-native');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-notify-policy-')),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(data);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const binary=resolve('zig-out/bin/notification-preview'),log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n?.rect&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('\n');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
const click=async(id:string)=>{const n=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok,id);};
let stage='startup';
const report:any={status:'running',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),cases:[],limits:['Synthetic business events and Harness input; real source lifecycle is covered by controller tests. No remote action or OS notification permission change.']};
async function capture(name:string){await h.waitFor(async()=>{const n=(await h.query('notifications.history')).find(shown);return n&&(n.effective_opacity??1)===1&&(n.scale_x??1)===1&&(n.scale_y??1)===1?n:null},10000);await h.sleep(100);await writeFile(join(out,name+'.json'),JSON.stringify({history:await h.query('notifications.history'),presenter:await h.query('notifications.presenter')},null,2));assert((await h.screenshot(join(out,name+'.png'))).ok);}
try{
 await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 for(const theme of ['dark','light','sauber']){
  await click('fixture.theme.'+theme);await h.resizeWindow(1440,900);
  await click('fixture.error');await absent('notifications.toast.0');await absent('notifications.unread');
  await click('fixture.scenes');await visible('notifications.toast.0');await absent('notifications.toast.1');
  await click('notifications.dismiss.0');await visible('notifications.unread');
  await click('toolbar.notifications');await visible('notifications.history.record');await absent('notifications.toast.0');
  assert.equal(text(await visible('notifications.history.count')),'2');
  assert.equal((await h.query('notifications.history.record')).filter(shown).length,2);
  assert((await h.query('notifications.history.summary')).filter(shown).some((n:any)=>text(n).includes('3 个来源')));
  for(const row of (await h.query('notifications.history.record')).filter(shown))assert.equal(row.rect.h,68);
  await absent('notifications.history.clear');await capture(theme+'-standard');
  const summary=(await h.query('notifications.history.summary')).filter(shown).find((n:any)=>text(n).includes('3 个来源'));
  const expand=(await h.query('notifications.history.expand')).filter(shown).find((n:any)=>Math.abs(n.rect.y-summary.rect.y)<24);
  assert(expand,'shared incident has an expansion control');await h.clickAt(expand.rect.x+expand.rect.w/2,expand.rect.y+expand.rect.h/2);
  const details=await visible('notifications.history.details');assert.equal((text(details).match(/待处理/g)??[]).length,3);
  await capture(theme+'-expanded');
  stage=theme+' locate expanded source';const locate=(await h.query('notifications.history.action')).filter(shown).find((n:any)=>n.rect.y>details.rect.y);
  assert(locate);await h.clickAt(locate.rect.x+locate.rect.w/2,locate.rect.y+locate.rect.h/2);stage=theme+' history closes after locate';await absent('notifications.history');
  assert(text(await visible('fixture.result')).includes('已定位 SSH 连接'));await click('toolbar.notifications');
  assert.equal(text(await visible('notifications.history.count')),'2');
  const collapse=(await h.query('notifications.history.expand')).filter(shown).find((n:any)=>Math.abs(n.rect.y-summary.rect.y)<24);
  if((await h.query('notifications.history.details')).some(shown)&&collapse)await h.clickAt(collapse.rect.x+collapse.rect.w/2,collapse.rect.y+collapse.rect.h/2);
  stage=theme+' compact';await h.resizeWindow(860,480);await h.sleep(250);const panel=await visible('notifications.history');
  assert(panel.rect.x>=0&&panel.rect.y>=0&&panel.rect.x+panel.rect.w<=860.5&&panel.rect.y+panel.rect.h<=480.5);
  await capture(theme+'-compact');await click('notifications.history.close');await visible('notifications.unread');
  stage=theme+' outcomes';await click('fixture.outcomes');await absent('notifications.toast.0');
  await click('toolbar.notifications');await visible('notifications.history.empty');assert.equal(text(await visible('notifications.history.count')),'0');
  await click('notifications.history.recent');await visible('notifications.history.record');
  assert.equal((await h.query('notifications.history.record')).filter(shown).length,2);
  await capture(theme+'-resolved');await click('notifications.history.clear');await visible('notifications.history.empty');
  await click('notifications.history.pending');await click('notifications.history.close');await absent('notifications.unread');
  report.cases.push({theme,status:'passed',checks:['ordinary errors stay local','one banner','three shared sources form one incident','two pending incidents','dismiss and view preserve pending','clear excludes pending','source recovery updates in place','recent filter and clear resolved','68px rows and bounded minimum window']});
 }
 report.status='passed';
}catch(e){report.status='failed';report.error=stage+': '+String(e);await h.screenshot(join(out,'failure.png')).catch(()=>{});await writeFile(join(out,'failure-tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{});process.exitCode=1;}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;await log.close();await rm(iso,{recursive:true,force:true});}
console.log(JSON.stringify({status:report.status,out,error:report.error}));
