/** Production on-demand inventory approval; fabricated requests, no host IO. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,open} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]??'/tmp/zw-inventory-ondemand-ui/build/bin/inventory-grant-preview');
const out=resolve(process.argv[3]??'/tmp/zw-inventory-ondemand-ui/native');await mkdir(out,{recursive:true});
const report:any={status:'running',binary,checks:[],measurements:[],shutdown:[],limitations:['Isolated production view and approval broker, fabricated requests only. Workspace/provider integration is validated separately.']};
const shown=(n:any)=>n&&n.visible!==false&&n.hidden!==true&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>n.text??(n.children??[]).map(text).join('');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
const result=async()=>text(await visible('inventory_grant.preview.result'));
const click=async(id:string)=>assert((await h.clickTestId(id)).ok);
const save=()=>writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
try{
for(const [theme,transparency] of [['dark',0],['light',75],['sauber',100]] as const){
 for(const width of [600,320]){
  const name=`${theme}-${width}`,iso=await mkdtemp('/tmp/zw-inventory-ondemand-'),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(data);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
  const log=await open(join(out,`${name}.log`),'w');
  const child=spawn(binary,[`--theme=${theme}`,`--transparency=${transparency}`],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
  const ended=new Promise<any>(done=>child.once('exit',(code,signal)=>done({code,signal})));
  try{
   await h.waitForServerReady(10000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),child.pid);
   await h.resizeWindow(width,420);await absent('ai.inventory_grant');assert.equal(await result(),'尚无读取请求');
   assert((await h.screenshot(join(out,`${name}-idle.png`))).ok);
   await click('inventory_grant.preview.request');
   const card=await visible('ai.inventory_grant'),title=await visible('ai.inventory_grant.title'),icon=await visible('ai.inventory_grant.icon'),copy=await visible('ai.inventory_grant.explanation'),target=await visible('ai.inventory_grant.target'),hint=await visible('ai.inventory_grant.hint');
   assert(Math.abs(icon.rect.y+icon.rect.h/2-title.rect.y-title.rect.h/2)<.5);assert.equal(icon.rect.w,16);assert.equal(icon.rect.h,16);
   assert.equal(text(title),'查看其他会话');assert(text(copy).includes('名称、连接状态与分组'));assert(text(copy).includes('不会读取终端内容或执行命令'));assert(text(hint).includes('持续允许仅当前对话'));
   const buttons=[];
   for(const id of ['deny','allow_once','allow_conversation']){
    const node=await visible(`ai.inventory_grant.${id}`);assert.equal(node.rect.h,26.5);assert(node.rect.w>=76);assert(node.rect.x>=card.rect.x&&node.rect.x+node.rect.w<=card.rect.x+card.rect.w+.5);assert(node.rect.y>=hint.rect.y+hint.rect.h);assert(node.rect.y+node.rect.h<=card.rect.y+card.rect.h+.5);assert.equal(node.effective_opacity??1,1);buttons.push({id,rect:node.rect});
   }
   assert(buttons[0].rect.x+buttons[0].rect.w+5.9<=buttons[1].rect.x);assert(buttons[1].rect.x+buttons[1].rect.w+5.9<=buttons[2].rect.x);assert(Math.abs(buttons[2].rect.x+buttons[2].rect.w-(card.rect.x+card.rect.w-11))<.5);
   for(const node of [title,icon,copy,target,hint])assert.equal(node.effective_opacity??1,1);
   await h.mouseMove(1,1);assert((await h.screenshot(join(out,`${name}-pending.png`))).ok);
   await writeFile(join(out,`${name}-pending.json`),JSON.stringify(await h.query('inventory_grant.preview'),null,2));
   await click('ai.inventory_grant.deny');await absent('ai.inventory_grant');assert((await result()).includes('deny · decisions 1'));assert((await result()).includes('stopped false'));
   await click('inventory_grant.preview.request');await visible('ai.inventory_grant');await click('ai.inventory_grant.allow_once');await absent('ai.inventory_grant');assert((await result()).includes('allow_once · decisions 2'));
   await click('inventory_grant.preview.request');await visible('ai.inventory_grant');await click('ai.inventory_grant.allow_conversation');await absent('ai.inventory_grant');assert((await result()).includes('allow_conversation · decisions 3'));
   await click('inventory_grant.preview.request');await absent('ai.inventory_grant');assert((await result()).includes('当前对话已持续允许，无需再次审批'));
   await click('ai.composer.permission');const revoke=await visible('ai.permission.revoke_inventory'),menu=await visible('ai.permission.menu');assert.equal(text(revoke),'撤销会话列表授权');assert(revoke.rect.y>=menu.rect.y&&revoke.rect.y+revoke.rect.h<=menu.rect.y+menu.rect.h+.5);assert.equal(menu.rect.h,232);
   const confirm=await visible('ai.permission.confirm'),automatic=await visible('ai.permission.auto');assert.equal(confirm.focusable??false,false);assert.equal(automatic.focusable??false,false);
   await h.mouseMove(1,1);assert((await h.screenshot(join(out,`${name}-revoke-menu.png`))).ok);await writeFile(join(out,`${name}-revoke-menu.json`),JSON.stringify(await h.query('ai.permission.menu'),null,2));
   await click('ai.permission.revoke_inventory');await absent('ai.permission.menu');assert.equal(await result(),'已撤销当前对话的持续允许');
   await click('inventory_grant.preview.request');await visible('ai.inventory_grant');
   await click('inventory_grant.preview.disable');const before=await result();const disabled=await visible('ai.inventory_grant.allow_once');await h.mouseDown(disabled.rect.x+disabled.rect.w/2,disabled.rect.y+disabled.rect.h/2);await h.mouseUp(disabled.rect.x+disabled.rect.w/2,disabled.rect.y+disabled.rect.h/2);assert.equal(await result(),before);assert.equal(text(await visible('ai.inventory_grant.feedback')),'请求暂时不可用');
   await h.mouseMove(1,1);await h.sleep(180);assert((await h.screenshot(join(out,`${name}-disabled.png`))).ok);
   await click('inventory_grant.preview.disable');await click('inventory_grant.preview.expire');await click('ai.inventory_grant.allow_once');assert.equal(text(await visible('ai.inventory_grant.feedback')),'请求已失效，请等待新的请求');assert.equal(await result(),'本次请求已失效');
   await h.mouseMove(1,1);await h.sleep(180);assert((await h.screenshot(join(out,`${name}-expired.png`))).ok);
   report.measurements.push({width,theme,transparency,card:card.rect,title:title.rect,icon:icon.rect,target:target.rect,copy:copy.rect,hint:hint.rect,buttons});
   report.checks.push(`${name}: absent before request; deny/once/current-conversation; repeat request skips approval only after continuous choice; revoke; disabled no dispatch; stale safe feedback; inline icon/title; foreground opacity 1`);
  }finally{
   let method='POST /quit';try{await h.request('POST','/quit');await h.waitFor(async()=>child.exitCode!==null||child.signalCode!==null||null,10000)}catch{method='SIGTERM fallback';child.kill('SIGTERM')}
   const status=await ended;report.shutdown.push({name,method,...status});await log.close();await save();assert.equal(method,'POST /quit');assert.equal(status.code,0);assert.equal(status.signal,null);
  }
 }
}
report.status='passed';await save();console.log(`PASS ${report.checks.length} on-demand inventory fixtures: ${out}`);
}catch(e){report.status='failed';report.error=String(e);await save();throw e}
