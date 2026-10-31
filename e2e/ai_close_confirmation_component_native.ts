/** Isolated production Popover/Button; fixture state only, no provider or app data. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]??'/private/tmp/zw-close-confirmation-build/bin/close-confirmation-preview');
const out=resolve(process.argv[3]??'/private/tmp/zerowork-close-confirmation-evidence/native');
await mkdir(out,{recursive:true});
const report:any={status:'running',binary,checks:[],measurements:[],shutdown:[],limitations:['Isolated production close component; main app validates stop/history retention separately.']};
const shown=(n:any)=>n&&n.visible!==false&&n.hidden!==true&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
const click=async(id:string)=>assert((await h.clickTestId(id)).ok);
const text=(n:any):string=>n.text??(n.children??[]).map(text).join('');
const result=async()=>text(await visible('ai.close.preview.result'));
const save=()=>writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
try{
 for(const theme of ['dark','light','sauber']){
  const iso=await mkdtemp('/private/tmp/zw-close-popover-'),rpc=join(iso,'rpc');await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
  const log=await open(join(out,`${theme}.log`),'w');
  const child=spawn(binary,[`--theme=${theme}`],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
  const ended=new Promise<any>(done=>child.once('exit',(code,signal)=>done({code,signal})));
  try{
   await h.waitForServerReady(10000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),child.pid);
   await h.resizeWindow(320,360);await absent('ai.close.confirmation');
   await click('ai.close');
   const panel=await visible('ai.close.confirmation'),title=await visible('ai.close.confirmation.title'),detail=await visible('ai.close.confirmation.detail'),confirm=await visible('ai.close.confirmation.confirm'),cancel=await visible('ai.close.confirmation.cancel');
   assert.equal(text(title),'停止本轮并关闭？');assert.equal(text(detail),'对话和历史会保留');assert.equal(text(confirm),'停止并关闭');
   assert.equal(panel.rect.w,288);assert.equal(panel.rect.h,106);assert(panel.rect.x>=8&&panel.rect.x+panel.rect.w<=312);
   assert.equal(title.rect.y,panel.rect.y+12);assert.equal(detail.rect.y,title.rect.y+24);
   for(const node of [confirm,cancel]){assert.equal(node.rect.h,28);assert(node.rect.w<100);assert(node.rect.x>=panel.rect.x+12&&node.rect.x+node.rect.w<=panel.rect.x+panel.rect.w-11.9);assert.equal(node.rect.y+node.rect.h,panel.rect.y+panel.rect.h-12)}
   assert(cancel.rect.w<confirm.rect.w);assert.equal((await h.focused()).test_id,'ai.close.confirmation.cancel');
   await h.mouseMove(1,1);assert((await h.screenshot(join(out,`${theme}-320-running.png`))).ok);
   await writeFile(join(out,`${theme}-320-running.json`),JSON.stringify(await h.query('ai.close.confirmation'),null,2));
   await h.key('escape');await absent('ai.close.confirmation');assert((await result()).includes('confirm 0 · cancel 1'));assert((await result()).includes('running true'));
   await click('ai.close');await visible('ai.close.confirmation');await click('ai.close.confirmation.cancel');await absent('ai.close.confirmation');assert((await result()).includes('confirm 0 · cancel 2'));assert((await result()).includes('running true'));
   await click('ai.close');await visible('ai.close.confirmation');await click('ai.close.preview.toggle');await absent('ai.close.confirmation');assert((await result()).includes('confirm 0 · cancel 3'));assert((await result()).includes('running true'));
   await click('ai.minimize');assert((await result()).includes('minimize 1 · running true'));
   await click('ai.close');await visible('ai.close.confirmation');await click('ai.close.confirmation.confirm');await absent('ai.close.confirmation');assert((await result()).includes('confirm 1 · cancel 3'));assert((await result()).includes('running false'));
   await click('ai.close');await visible('ai.close.confirmation');assert.equal(text(await visible('ai.close.confirmation.title')),'关闭助手？');assert.equal(text(await visible('ai.close.confirmation.confirm')),'关闭窗口');
   await h.mouseMove(1,1);assert((await h.screenshot(join(out,`${theme}-320-idle.png`))).ok);
   await click('ai.close.confirmation.cancel');await absent('ai.close.confirmation');await click('ai.close.preview.replace');assert((await result()).includes('旧确认已撤销'));
   await click('ai.close');await visible('ai.close.confirmation');await h.key('tab');assert.equal((await h.focused()).test_id,'ai.close.confirmation.confirm');await h.key('return');await absent('ai.close.confirmation');assert((await result()).includes('confirm 2'));
   report.measurements.push({theme,width:320,panel:panel.rect,title:title.rect,detail:detail.rect,confirm:confirm.rect,cancel:cancel.rect});
   report.checks.push(`${theme}: 320px native geometry; running/idle copy; cancel autofocus; Escape/cancel/outside preserve running; outside press consumed; minimize retains running; confirm once; Tab/Return confirm; changed conversation remains usable`);
  }finally{
   let method='POST /quit';try{await h.request('POST','/quit');await h.waitFor(async()=>child.exitCode!==null||child.signalCode!==null||null,10000)}catch{method='SIGTERM fallback';child.kill('SIGTERM')}
   const status=await ended;report.shutdown.push({theme,method,...status});await log.close();await save();assert.equal(method,'POST /quit');assert.equal(status.code,0);assert.equal(status.signal,null);
  }
 }
 report.status='passed';await save();console.log(`PASS ${report.checks.length} native close confirmation fixtures: ${out}`);
}catch(error){report.status='failed';report.error=String(error);await save();throw error}
