/** Production native cleanup View. Real Local settlement is application_host's test. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdtemp,mkdir,writeFile,open,readFile,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';

const binary=resolve(process.argv[2]??'/tmp/zw-task-finish-build/out/bin/task-finish-preview');
const out=resolve(process.argv[3]??'dist/ui-acceptance/task-finish');
await mkdir(out,{recursive:true});
const shown=(n:any)=>n&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>n.text??(n.children??[]).map(text).join('');
const visible=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const report:any={status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],limitations:['The isolated fixture renders the production native View with representative immutable resources. Actual Local lifecycle, recording, retention and cancellation are tested through ApplicationHost.'],working_design:'design/ai-task-finish/running.svg'};
const fixtures=[];
for(const theme of ['dark','light','sauber'])for(const width of [600,360])fixtures.push({name:`${theme}-${width}`,theme,width,state:'choice',decision:width===600?'keep':'close',long:false});
fixtures.push({name:'long-compact',theme:'dark',width:360,state:'choice',decision:'keep',long:true});
for(const theme of ['dark','light','sauber'])for(const control of ['stop','takeover'])fixtures.push({name:`working-${theme}-${control}`,theme,width:360,state:'working',decision:null,control,long:false});
fixtures.push({name:'working-dark-long',theme:'dark',width:280,state:'working',decision:null,control:'stop',long:true});
for(const theme of ['dark','light','sauber'])fixtures.push({name:`working-${theme}-multi`,theme,width:600,state:'working',decision:null,control:'takeover',long:false,multi:true});
for(const theme of ['dark','light','sauber'])fixtures.push({name:`working-${theme}-multi-three`,theme,width:600,state:'working',decision:null,control:'takeover',long:false,multi:true,three:true});
fixtures.push({name:'unknown',theme:'sauber',width:360,state:'cleanup_pending',decision:null,long:false});

const selectedFixtures=fixtures.filter(f=>!process.env.TASK_FINISH_FIXTURE||f.name.includes(process.env.TASK_FINISH_FIXTURE));
assert(selectedFixtures.length,'No task-finish fixture matched TASK_FINISH_FIXTURE');
for(const fixture of selectedFixtures){
 const rpc=await mkdtemp('/tmp/zw-task-finish-rpc-');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,`${fixture.name}.log`),'w');
 const args=[`--theme=${fixture.theme}`,`--state=${fixture.state}`,...(fixture.long?['--long-target']:[]),...(fixture.multi?['--multi-target']:[]),...(fixture.three?['--three-targets']:[])];
 const child=spawn(binary,args,{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 const exited=new Promise<void>(done=>child.once('close',()=>done()));
 let spawnError:Error|undefined;
 child.once('error',error=>{spawnError=error});
 try{
  await h.waitForServerReady(10000);await h.resizeWindow(fixture.width,240);
  const row=await visible('ai.task_finish'),title=await visible('ai.task_finish.title');
  assert.equal(text(title),fixture.state==='working'?'执行仍在进行':fixture.state==='cleanup_pending'?'清理待核实':'任务已结束');
  assert(row.rect.x>=0&&row.rect.y>=0&&row.rect.x+row.rect.w<=fixture.width+.5&&row.rect.y+row.rect.h<=240);
  const working=fixture.state==='working';
  const viewport=await visible(working?'ai.task_finish.session_tag':'ai.task_finish.resources_viewport');
  const resources=await visible(working?'ai.task_finish.session_tag.label':'ai.task_finish.resources');
  assert(text(resources).includes(fixture.long?'production-session':'Local Terminal'));
  assert(viewport.rect.w>100&&viewport.rect.h>=16);
  if(fixture.decision){
   const keep=await visible('ai.task_finish.keep'),close=await visible('ai.task_finish.close');
   for(const button of [keep,close]){
    assert.equal(button.rect.h,28);
    assert(button.rect.x>=row.rect.x&&button.rect.x+button.rect.w<=row.rect.x+row.rect.w+.5);
    assert(button.rect.y>=row.rect.y&&button.rect.y+button.rect.h<=row.rect.y+row.rect.h+.5);
   }
   assert(close.rect.x>=keep.rect.x+keep.rect.w);
  }else {
   assert(!(await h.query('ai.task_finish.keep')).some(shown)&&!(await h.query('ai.task_finish.close')).some(shown));
   if(working){
    assert(!(await h.query('ai.task_finish.detail')).some(shown));
    assert(viewport.rect.x+viewport.rect.w<=row.rect.x+row.rect.w-10.5);
    if(fixture.width===600||fixture.long){
     assert(viewport.rect.x>=title.rect.x+title.rect.w);
     assert(Math.abs(viewport.rect.y-title.rect.y)<=1);
     assert.equal(row.rect.h,fixture.long?71:46);
    }else{
     assert(viewport.rect.y>=title.rect.y+title.rect.h);
     assert(Math.abs(viewport.rect.x-title.rect.x)<=.5,JSON.stringify({viewport:viewport.rect,title:title.rect,row:row.rect}));
     assert.equal(row.rect.h,66);
    }
   }
   if(working)for(const action of ['stop','takeover']){
    const button=await visible(`ai.task_finish.${action}`);assert.equal(button.rect.h,28);
    assert(button.rect.x>=row.rect.x&&button.rect.x+button.rect.w<=row.rect.x+row.rect.w+.5);
    if(fixture.long)assert(button.rect.y>=title.rect.y+title.rect.h);
    else assert(button.rect.y<=title.rect.y&&button.rect.y+button.rect.h>=title.rect.y+title.rect.h);
   }
  }
  await h.waitFor(async()=>(await h.stats()).frame_count>=2||null,10000);await h.mouseMove(1,239);
  assert((await h.screenshot(join(out,`${fixture.name}.png`))).ok);
  await writeFile(join(out,`${fixture.name}.json`),JSON.stringify(await h.query('task_finish.preview'),null,2));
  if(working&&fixture.long){
   await h.mouseMove(viewport.rect.x+viewport.rect.w/2,viewport.rect.y+viewport.rect.h/2);
   assert(text(await visible('ai.task_finish.session_tag.tooltip')).includes('production-session-with-a-long-visible-target-name'));
   await h.mouseMove(1,239);
  }
  if(!working&&fixture.long&&resources.rect.h>viewport.rect.h){
   await h.scrollAt(viewport.rect.x+viewport.rect.w/2,viewport.rect.y+viewport.rect.h/2,0,-300);
   await h.waitFor(async()=>(await visible('ai.task_finish.resources')).rect.y<resources.rect.y-.5||null,5000);
   await h.mouseMove(1,239);assert((await h.screenshot(join(out,`${fixture.name}-scrolled.png`))).ok);
  }
  if(working&&fixture.name==='working-dark-stop'){
   await h.resizeWindow(600,240);
   await h.waitFor(async()=>(await visible('ai.task_finish')).rect.h===46||null,10000);
   await h.resizeWindow(fixture.width,240);
   await h.waitFor(async()=>(await visible('ai.task_finish')).rect.h===66||null,10000);
  }
  if(fixture.decision){
   assert((await h.clickTestId(`ai.task_finish.${fixture.decision}`)).ok);
   await h.waitFor(async()=>text(await visible('ai.task_finish.title'))===(fixture.decision==='keep'?'已保留任务会话':'已清理任务会话')||null,10000);
   assert(!(await h.query('ai.task_finish.keep')).some(shown));
   assert(text(await visible('task_finish.preview.result')).includes(fixture.decision==='keep'?'保留选择':'关闭选择'));
   await h.mouseMove(1,239);assert((await h.screenshot(join(out,`${fixture.name}-result.png`))).ok);
  }
  if(fixture.control){
   assert((await h.clickTestId(`ai.task_finish.${fixture.control}`)).ok);
   if(fixture.multi){
    await visible('ai.task_finish.takeover.target.6');await visible('ai.task_finish.takeover.target.7');
    if(fixture.three)await visible('ai.task_finish.takeover.target.8');
    await h.mouseMove(1,239);assert((await h.screenshot(join(out,`${fixture.name}-menu.png`))).ok);
    assert((await h.clickTestId('ai.task_finish.takeover.target.6')).ok);
    await h.waitFor(async()=>text(await visible('task_finish.preview.result')).includes('精确接管 session-6')||null,10000);
   }
   await h.waitFor(async()=>text(await visible('ai.task_finish.detail')).includes(fixture.control==='stop'?'停止选择已交付':'接管选择已交付')||null,10000);
   assert(!(await h.query('ai.task_finish.stop')).some(shown));
   await h.mouseMove(1,239);assert((await h.screenshot(join(out,`${fixture.name}-result.png`))).ok);
  }
  report.checks.push({fixture:fixture.name,width:fixture.width,row:row.rect,resource_viewport:viewport.rect,decision:fixture.control??fixture.decision??'no action while unsettled'});
 }catch(error){
  report.status='failed';report.error=String(spawnError??error);report.failed_fixture=fixture.name;
  await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
  throw spawnError??error;
 }finally{
  if(child.exitCode===null&&child.signalCode===null&&!spawnError){
   await Promise.race([h.key('q',{cmd:true}).catch(()=>{}),exited]);
   await Promise.race([exited,h.sleep(500)]);
  }
  if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');
  await Promise.race([exited,h.sleep(2000)]);
  if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');
  await exited;await log.close();await rm(rpc,{recursive:true,force:true});
 }
}
report.status='passed';await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
