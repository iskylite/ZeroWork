/** Real production widgets with explicit local journal facts; no SSH is opened. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'artifacts/connection-progress-20261028/native');
await mkdir(out,{recursive:true});
const checks:string[]=[];
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
for(const scene of (process.argv.slice(3).length?process.argv.slice(3):['direct','failed','releasing','long'])){
 const rpc=await mkdtemp('/tmp/zw-progress-layout-');
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,scene+'.log'),'w');
 const app=spawn(resolve('zig-out/bin/connection-progress-preview'),[scene],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 const ended=new Promise(r=>app.once('close',r));
 try{
  await h.waitForServerReady();
  await h.resizeWindow(1280,720);
  const panel=await visible('connection.progress');
  assert.equal(panel.rect.w,640);
  const name=scene==='long'?'ScaleX40-AI01 · production-east-primary-cluster':'ScaleX40-AI01';
  const address=scene==='long'?'operations-administrator@[2001:db8:1234:5678:abcd:ef01:2345:6789]:2222':'root@10.2.209.201:22';
  assert.equal(text(await visible('connection.progress.target')),name);
  const title=await visible('connection.progress.target'),endpoint=await visible('connection.progress.endpoint');
  assert.equal(text(endpoint),address);
  assert(endpoint.rect.y>title.rect.y+4&&endpoint.rect.y+endpoint.rect.h<=title.rect.y+title.rect.h+1,'small endpoint sits low beside the larger title');
  assert(Math.abs(endpoint.rect.x-title.rect.x-title.rect.w-8)<.5,'endpoint follows name with an 8-point gap');
  assert.equal(text(panel).split(address).length-1,1);
  const close=await visible('connection.progress.close');
  assert.equal(close.rect.w,28);assert.equal(close.rect.h,28);
  const summary=await visible('connection.progress.summary.title');
  const chain=await visible('connection.progress.chain');
  assert(summary.rect.y<chain.rect.y,'current phase precedes connection path');
  await h.mouseMove(20,80);
  await h.sleep(250);
  await h.screenshot(join(out,scene+'.png'));
  await writeFile(join(out,scene+'.json'),JSON.stringify(await h.query('connection.progress'),null,2));
  if(scene==='long'){
   await h.mouseMove(endpoint.rect.x+endpoint.rect.w/2,endpoint.rect.y+endpoint.rect.h/2);
   const tip=await visible('connection.progress.identity.tooltip');
   assert.equal(text(tip),name+'\n'+address);
   assert(tip.rect.w<=420&&tip.rect.x>=0&&tip.rect.x+tip.rect.w<=1280);
   await h.sleep(250);
   await h.screenshot(join(out,'long-header-tooltip.png'));
   await h.mouseMove(20,80);
   await absent('connection.progress.identity.tooltip');
   for(let i=0;i<12&&(await h.focused()).test_id!=='connection.progress.hop.1';i++)await h.key('tab');
   assert.equal((await h.focused()).test_id,'connection.progress.hop.1');
   assert.equal(text(await visible('connection.progress.hop.tooltip.1')),name+'\n'+address);
   await h.sleep(250);
   await h.screenshot(join(out,'long-keyboard-tooltip.png'));
   await h.key('return');
   await visible('connection.progress.logs');
   await h.key('escape');
   await h.waitFor(async()=>text(await visible('connection.progress.state'))==='已取消'||null);
   await h.key('escape');
   await absent('connection.progress');
   await absent('connection.progress.hop.tooltip.1');
   checks.push('long name and bracketed IPv6: full header tooltip on hover, full row tooltip on Tab focus, Enter opens logs, Escape cancels then closes released result and tooltip');
  }else if(scene==='direct'){
   assert.equal(text(summary),'正在准备终端');
   const toggle=await visible('connection.progress.logs.toggle');
   await h.mouseMove(toggle.rect.x+20,toggle.rect.y+14);await h.sleep(200);
   await h.screenshot(join(out,'direct-log-hover.png'));
   const cancel=await visible('connection.progress.cancel');
   assert.equal(cancel.rect.w,96);assert.equal(cancel.rect.h,32);
   await h.mouseMove(cancel.rect.x+30,cancel.rect.y+16);await h.sleep(200);
   await h.screenshot(join(out,'direct-cancel-hover.png'));
   await h.mouseMove(20,80);await h.sleep(200);
   await h.clickTestId('connection.progress.hop.1');
   await visible('connection.progress.logs');
   await h.clickTestId('connection.progress.logs.copy');
   assert(text(await visible('fixture.result')).includes('已收到本次连接日志'));
   assert(text(await visible('connection.progress')).includes('已复制阶段日志'));
   await h.resizeWindow(860,480);
   const compact=await visible('connection.progress');
   const footer=await visible('connection.progress.actions');
   assert(compact.rect.y>=0&&compact.rect.y+compact.rect.h<=480.5);
   assert(footer.rect.y+footer.rect.h<=compact.rect.y+compact.rect.h+.5);
   assert.equal(footer.rect.h,54);
   await h.screenshot(join(out,'direct-logs-860.png'));
   await h.clickTestId('connection.progress.cancel');
   await h.waitFor(async()=>text(await visible('connection.progress.state'))==='已取消'||null);
   await h.clickTestId('connection.progress.dismiss');
   await absent('connection.progress');
   checks.push('direct target, phase hierarchy, one endpoint, node opens filtered logs, copy callback, compact footer, cancel and close');
  }else if(scene==='failed'){
   assert.equal(text(summary),'SSH 认证失败');
   assert(text(await visible('connection.progress.summary.detail')).includes('服务器未接受认证信息'));
   const retry=await visible('connection.progress.retry');
   const rx=retry.rect.x+retry.rect.w/2,ry=retry.rect.y+retry.rect.h/2;
   await h.mouseMove(rx,ry);await h.sleep(200);
   await h.screenshot(join(out,'failed-retry-hover.png'));
   await h.mouseDown(rx,ry);await h.sleep(200);
   await h.screenshot(join(out,'failed-retry-pressed.png'));
   await h.mouseMove(20,80);await h.mouseUp(20,80);await h.sleep(200);
   assert.equal(text(await visible('connection.progress.attempt')),'第 1 次尝试');
   await h.clickTestId('connection.progress.retry');
   await h.waitFor(async()=>text(await visible('connection.progress.attempt'))==='第 2 次尝试'||null);
   assert(text(await visible('fixture.result')).includes('已调用原连接的重试操作'));
   await h.screenshot(join(out,'retry.png'));
   checks.push('failed hop and reason remain visible with logs folded; released resources permit original retry callback');
  }else{
   await h.clickTestId('connection.progress.retry');
   assert.equal(text(await visible('connection.progress.attempt')),'第 1 次尝试');
   assert.equal(text(await visible('connection.progress.state')),'连接失败');
   assert(text(await visible('connection.progress')).includes('等待连接结束'));
   checks.push('unreleased resources keep retry disabled and explain why');
  }
 }finally{
  app.kill('SIGTERM');
  await Promise.race([ended,new Promise(r=>setTimeout(r,2000))]);
  if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}
  await log.close();await rm(rpc,{recursive:true,force:true});
 }
}
await writeFile(join(out,'report.json'),JSON.stringify({status:'passed',scope:'production view with local fixture facts, no networking',checks},null,2));
console.log(JSON.stringify({status:'passed',checks,out}));
