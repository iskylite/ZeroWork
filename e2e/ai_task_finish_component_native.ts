/** Production native cleanup View. Real Local settlement is application_host's test. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdtemp,mkdir,writeFile,open,readFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';

const binary=resolve(process.argv[2]??'/tmp/zw-task-finish-build/out/bin/task-finish-preview');
const out=resolve(process.argv[3]??'dist/ui-acceptance/task-finish');
await mkdir(out,{recursive:true});
const shown=(n:any)=>n&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>n.text??(n.children??[]).map(text).join('');
const visible=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const report:any={status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],limitations:['The isolated fixture renders the production native View with representative immutable resources. Actual Local lifecycle, recording, retention and cancellation are tested through ApplicationHost.','No browser surface is enabled in this session; layout values come from the editable cleanup-row HTML/CSS, and native rectangles/screenshots verify their mapping.']};
const fixtures=[];
for(const theme of ['dark','light','sauber'])for(const width of [600,360])fixtures.push({name:`${theme}-${width}`,theme,width,state:'choice',decision:width===600?'keep':'close',long:false});
fixtures.push({name:'long-compact',theme:'dark',width:360,state:'choice',decision:'keep',long:true});
for(const theme of ['dark','light','sauber'])for(const control of ['stop','takeover'])fixtures.push({name:`working-${theme}-${control}`,theme,width:360,state:'working',decision:null,control,long:false});
for(const theme of ['dark','light','sauber'])fixtures.push({name:`working-${theme}-multi`,theme,width:600,state:'working',decision:null,control:'takeover',long:false,multi:true});
for(const theme of ['dark','light','sauber'])fixtures.push({name:`working-${theme}-multi-three`,theme,width:600,state:'working',decision:null,control:'takeover',long:false,multi:true,three:true});
fixtures.push({name:'unknown',theme:'sauber',width:360,state:'cleanup_pending',decision:null,long:false});

for(const fixture of fixtures.filter(f=>!process.env.TASK_FINISH_FIXTURE||f.name.includes(process.env.TASK_FINISH_FIXTURE))){
 const rpc=await mkdtemp('/tmp/zw-task-finish-rpc-');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,`${fixture.name}.log`),'w');
 const args=[`--theme=${fixture.theme}`,`--state=${fixture.state}`,...(fixture.long?['--long-target']:[]),...(fixture.multi?['--multi-target']:[]),...(fixture.three?['--three-targets']:[])];
 const child=spawn(binary,args,{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 try{
  await h.waitForServerReady(10000);await h.resizeWindow(fixture.width,240);
  const row=await visible('ai.task_finish'),title=await visible('ai.task_finish.title');
  assert.equal(text(title),fixture.state==='working'?'执行仍在进行':fixture.state==='cleanup_pending'?'清理待核实':'任务已结束');
  assert(row.rect.x>=0&&row.rect.y>=0&&row.rect.x+row.rect.w<=fixture.width+.5&&row.rect.y+row.rect.h<=240);
  const viewport=await visible('ai.task_finish.resources_viewport'),resources=await visible('ai.task_finish.resources');
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
   if(fixture.state==='working')for(const action of ['stop','takeover']){
    const button=await visible(`ai.task_finish.${action}`);assert.equal(button.rect.h,28);
    assert(button.rect.x>=row.rect.x&&button.rect.x+button.rect.w<=row.rect.x+row.rect.w+.5);
   }
  }
  await h.waitFor(async()=>(await h.stats()).frame_count>=2||null,10000);await h.mouseMove(1,239);
  assert((await h.screenshot(join(out,`${fixture.name}.png`))).ok);
  await writeFile(join(out,`${fixture.name}.json`),JSON.stringify(await h.query('task_finish.preview'),null,2));
  if(fixture.long&&resources.rect.h>viewport.rect.h){
   await h.scrollAt(viewport.rect.x+viewport.rect.w/2,viewport.rect.y+viewport.rect.h/2,0,-300);
   await h.waitFor(async()=>(await visible('ai.task_finish.resources')).rect.y<resources.rect.y-.5||null,5000);
   await h.mouseMove(1,239);assert((await h.screenshot(join(out,`${fixture.name}-scrolled.png`))).ok);
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
 }finally{
  const exited=new Promise<void>(done=>child.once('exit',()=>done()));
  await h.key('q',{cmd:true}).catch(()=>{});
  await Promise.race([exited,new Promise(done=>setTimeout(done,500))]);
  if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');
  await exited;await log.close();
 }
}
report.status='passed';await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
