/** Real welcome component, fabricated titles, isolated file RPC, no application data. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]??'/private/tmp/zw-ai-recent-build/bin/ai-empty-recent-preview');
const out=resolve(process.argv[3]??'/private/tmp/zerowork-ai-recent-evidence/native');
await mkdir(out,{recursive:true});
const report:any={status:'running',binary,measurements:[],checks:[],shutdown:[]};
const shown=(n:any)=>n&&n.visible!==false&&(n.effective_opacity??1)>0.99&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const near=(a:number,b:number)=>assert(Math.abs(a-b)<0.15,`${a} != ${b}`);
const text=(n:any):string=>n.text??(n.children??[]).map(text).join('');
const save=()=>writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
try{
 for(const fixture of ['mixed','wide','unbroken']){
  const iso=await mkdtemp('/private/tmp/zw-recent-'),rpc=join(iso,'rpc');await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
  const log=await open(join(out,`${fixture}.log`),'w');
  const child=spawn(binary,[`--fixture=${fixture}`],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
  const ended=new Promise<any>(done=>child.once('exit',(code,signal)=>done({code,signal})));
  try{
   await h.waitForServerReady(10000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),child.pid);
   for(const theme of ['dark','light','sauber']){
    for(const width of [600,360,480]){
     await h.resizeWindow(width,400);await h.mouseMove(1,1);await h.sleep(300);
     const content=await visible('ai.empty.preview.content'),group=await visible('ai.empty.recent'),row=await visible('ai.empty.recent.link'),icon=await visible('ai.empty.recent.icon'),title=await visible('ai.empty.recent.title'),arrow=await visible('ai.empty.recent.arrow');
     near(row.rect.w,Math.min(width-28,440));near(row.rect.w,group.rect.w);near(row.rect.h,30);near(icon.rect.w,16);near(arrow.rect.w,16);near(title.rect.x,icon.rect.x+24);near(title.rect.x+title.rect.w+8,arrow.rect.x);near(row.rect.x+row.rect.w,arrow.rect.x+16);assert(row.rect.x>=content.rect.x+13.9&&row.rect.x+row.rect.w<=content.rect.x+content.rect.w-13.9);assert(Buffer.byteLength(text(title))>120);near(title.rect.h,16);
     report.measurements.push({fixture,theme,width,row:row.rect,icon:icon.rect,title:title.rect,arrow:arrow.rect});
     if(theme==='dark'&&width!==480){assert((await h.screenshot(join(out,`${fixture}-${theme}-${width}.png`))).ok);await writeFile(join(out,`${fixture}-${width}-tree.json`),JSON.stringify(await h.query('ai.empty.configured'),null,2));}
     await h.mouseMove(title.rect.x+20,title.rect.y+8);
     await h.sleep(1000);const tip=await visible('ai.empty.recent.tooltip');assert.equal(text(tip),text(title));assert(tip.rect.x>=0&&tip.rect.x+tip.rect.w<=width+0.2);assert(tip.rect.h>20);
     if(theme==='dark'&&width===360)assert((await h.screenshot(join(out,`${fixture}-tooltip-360.png`))).ok);
     for(const x of [row.rect.x+2,row.rect.x+row.rect.w/2,row.rect.x+row.rect.w-2]){await h.clickAt(x,row.rect.y+15);assert.equal(text(await visible('ai.empty.preview.result')),'selected 17');}
     await h.key('return');assert.equal(text(await visible('ai.empty.preview.result')),'selected 17');
    }
    assert((await h.clickTestId('ai.empty.preview.replay')).ok);
   }
   report.checks.push(`${fixture}: 360/480/600 native row and icons bounded; dark/light/sauber replay; full original title tooltip; row left/center/right and Enter select conversation 17`);
  }finally{
   let method='POST /quit';try{await h.request('POST','/quit');await h.waitFor(async()=>child.exitCode!==null||child.signalCode!==null||null,10000)}catch{method='SIGTERM fallback';child.kill('SIGTERM')}
   const status=await ended;report.shutdown.push({fixture,method,...status});await log.close();await save();assert.equal(method,'POST /quit');assert.equal(status.code,0);assert.equal(status.signal,null);
  }
 }
 report.status='passed';await save();console.log(`PASS ${report.measurements.length} recent title native layouts: ${out}`);
}catch(error){report.status='failed';report.error=String(error);await save();throw error}
