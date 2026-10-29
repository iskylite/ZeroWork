/** Dedicated production host execution card. Synthetic trusted receipts; no PTY/network. */
import assert from 'node:assert/strict';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,mkdir,writeFile,readFile,open} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]??'/tmp/zw-ui-final-candidate/out/bin/execution-result-preview');
const out=resolve(process.argv[3]??'/tmp/zw-execution-result-native');await mkdir(out,{recursive:true});
const shown=(n:any)=>n&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>n.text??(n.children??[]).map(text).join('');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const clipboard=async()=>(await promisify(execFile)('/usr/bin/pbpaste',[],{encoding:'utf8'})).stdout;
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const labels:any={running:'运行中',sealed:'已完成',failed:'执行失败',interval_recorded:'前台已结束 · 观测片段已保存',interval_unverified:'前台已结束 · 观测片段已保存',interval_concurrent:'前台已结束 · 观测片段已保存',interval_failed:'前台已结束 · 执行失败',recording_failed:'记录保存失败',unknown:'结果待核实',handed_off:'用户已接管',sealing:'正在保存观测片段',cancelled:'已取消',missing:'调用失败',refused:'已拒绝'};
const intervalOnly=process.argv[4]==='interval-only';
const report:any={status:'running',binary,matrix:{themes:intervalOnly?['dark']:['dark','light','sauber'],width:intervalOnly?[600]:[600,360],states:intervalOnly?['interval_recorded','interval_unverified','interval_concurrent','interval_failed','recording_failed','handed_off']:process.argv[4]==='refused-only'?['refused']:['running','sealed','failed','unknown','handed_off','sealing','cancelled','missing']},checks:[],shutdown:[],sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),limitations:['Uses production Snapshot JSON, Store.capture, typed projection and native view with synthetic immutable receipts.','Callback payloads are verified here; actual Driver stop/takeover and terminal navigation require application integration acceptance.','A saved session_interval is an observed same-PTY range, never proof of complete command output or exclusive writer attribution.','RecordingId is copied as a real stable ID; no unresolved history jump is presented.']};
try{
for(const theme of report.matrix.themes)for(const width of report.matrix.width)for(const state of report.matrix.states){
 const name=`${theme}-${width}-${state}`,rpc=await mkdtemp('/tmp/zw-execution-result-rpc-');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,`${name}.log`),'w');
 const long=state==='running'&&width===360;
 const child=spawn(binary,[`--theme=${theme}`,`--state=${state}`,`--transparency=${theme==='dark'?0:theme==='light'?75:100}`,...(long?['--long-output']:[])],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 const ended=new Promise<any>(done=>child.once('exit',(code,signal)=>done({code,signal})));
 try{
  await h.waitForServerReady(10000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),child.pid);await h.resizeWindow(width,358);await h.waitFor(async()=>Math.abs((await visible('execution_result.preview')).rect.w-width)<.1||null,10000);
  const card=await visible('execution_result.preview.card'),header=await visible('ai.execution.result.header'),title=await visible('ai.execution.result.title'),icon=await visible('ai.execution.result.icon');
  assert.equal(header.rect.h,32);assert(Math.abs(icon.rect.y+icon.rect.h/2-title.rect.y-title.rect.h/2)<.5);assert(icon.rect.x+icon.rect.w<title.rect.x);
  const summary=text(await visible('ai.execution.result.summary'));assert(summary.includes(labels[state]),summary);assert(summary.includes('最近观测'));
  const details=await visible('ai.execution.result.details');assert(details.rect.h<=150.1);
  if(state==='missing'||state==='refused'){
   assert(text(await visible('ai.execution.result.target')).includes('目标身份未返回'));
   assert.equal(text(await visible('ai.execution.result.failure')),state==='refused'?'当前终端的执行能力不可用。':'宿主执行服务当前不可用。');
   for(const id of ['ai.execution.result.process','ai.execution.result.execution_id','ai.execution.result.recording_id','ai.execution.result.view_terminal','ai.execution.result.stop','ai.execution.result.takeover'])assert(!(await h.query(id)).some(shown),id);
  }else{
   assert(text(await visible('ai.execution.result.target')).includes('deploy@app-prod-01.example.net:2222'));
   const footer=await visible('ai.execution.result.footer');assert(footer.rect.y>=details.rect.y+details.rect.h-.5);assert(footer.rect.y+footer.rect.h<=358);
   const savedInterval=state.startsWith('interval_');
   if(savedInterval||state==='recording_failed'){
    assert.equal(text(await visible('ai.execution.result.process')),`前台已结束 · 退出码 ${state==='interval_failed'||state==='recording_failed'?7:0}`);
    assert.equal(text(await visible('ai.execution.result.output_scope')),savedInterval?'同一终端观测片段 · 已保存':'同一终端观测片段 · 保存失败');
    const attribution=text(await visible('ai.execution.result.output_attribution'));
    assert.equal(attribution,state==='interval_concurrent'?'观察到并发写入 · 输出可能混有其他程序内容':state==='interval_recorded'||state==='interval_failed'?'未观察到并发写入 · 输出归属未确认':'输出归属未确认');
    assert(text(await visible('ai.execution.result.output_limit')).includes('后台输出可能在前台结束后继续'));
    assert(!summary.includes('封存'));
    assert.equal(text(await visible('ai.execution.result.output_label')),'同一终端观测片段');
    if(state==='interval_unverified')assert.equal(text(await visible('ai.execution.result.output_attribution_reason')),'并发观察未在时限内完成。');
    if(state==='interval_concurrent')assert.equal(text(await visible('ai.execution.result.output_attribution_reason')),'检测到后台任务。');
   }else if(state==='sealed'||state==='failed')assert.equal(text(await visible('ai.execution.result.process')),`退出码 ${state==='failed'?7:0}`);
   else assert(!(await h.query('ai.execution.result.process')).some(shown));
   if(state==='handed_off'){
    assert(summary.includes('命令继续运行'));
    assert.equal(text(await visible('ai.execution.result.output_scope')),'同一终端观测片段 · 保存待确认');
   }
   if(state==='running'){
    const before=await visible('ai.execution.result.terminal_output');
    if(long){assert(before.rect.h>150);await h.scrollAt(details.rect.x+details.rect.w/2,details.rect.y+details.rect.h/2,0,-100000);await h.waitFor(async()=>(await visible('ai.execution.result.recording_id')).rect.y<details.rect.y+details.rect.h||null,5000);assert((await visible('ai.execution.result.terminal_output')).rect.y<before.rect.y);assert.equal((await visible('ai.execution.result.footer')).rect.y,footer.rect.y)}
    const recording=await visible('ai.execution.result.recording_id');
    if(recording.rect.y+recording.rect.h>details.rect.y+details.rect.h){await h.scrollAt(details.rect.x+20,details.rect.y+details.rect.h/2,0,-100000)}
    await click('ai.execution.result.copy_recording');assert.equal((await clipboard()).trim(),text(recording).split('·').slice(1).join('·').trim());
    await click('ai.execution.result.copy_output');assert((await clipboard()).includes('ACTUAL_TERMINAL_OUTPUT'));
    const expected=text(await visible('execution_result.preview.execution_ref'));
    await click('ai.execution.result.view_terminal');let action=text(await visible('execution_result.preview.action'));assert(action.includes('view_terminal')&&action.includes(expected)&&action.includes('#101/g9'),action);
    const control=width===360?'takeover':'stop';await click(`ai.execution.result.${control}`);action=text(await visible('execution_result.preview.action'));assert(action.includes(control)&&action.includes(expected)&&action.includes('#101/g9')&&action.includes('request 2'),action);
    assert(text(await visible('ai.execution.result.summary')).includes('运行中'));assert(!(await h.query('ai.execution.result.action_feedback')).some(shown));
   }else{
    assert(!(await h.query('ai.execution.result.stop')).some(shown));assert(!(await h.query('ai.execution.result.takeover')).some(shown));
    if(intervalOnly){
     const expected=text(await visible('execution_result.preview.execution_ref'));
     await click('ai.execution.result.view_terminal');
     const action=text(await visible('execution_result.preview.action'));
     assert(action.includes('view_terminal')&&action.includes(expected)&&action.includes('#101/g9')&&action.includes('request 1'),action);
     await click('ai.execution.result.copy_output');assert((await clipboard()).includes('ACTUAL_TERMINAL_OUTPUT'));
     assert.equal(text(await visible('ai.execution.result.summary')),summary);
     assert(!(await h.query('ai.execution.result.action_feedback')).some(shown));
     (report.actions??=[]).push({state,view_terminal:action,copy_output:'ACTUAL_TERMINAL_OUTPUT',stop:0,takeover:0});
    }
   }
  }
  await h.mouseMove(1,357);assert((await h.screenshot(join(out,`${name}.png`))).ok);await writeFile(join(out,`${name}.json`),JSON.stringify(await h.query('execution_result.preview'),null,2));
  report.checks.push(`${name}: typed real target/state/output/RecordingId, header alignment and bounded body passed`);
 }catch(error){report.primaryError??=String(error);throw error}finally{
  const shutdown:any={name,method:'already_exited'};
  if(child.exitCode===null&&child.signalCode===null){try{await h.request('POST','/quit');shutdown.method='POST /quit';await h.waitFor(async()=>child.exitCode!==null||child.signalCode!==null||null,10000)}catch(error){shutdown.method='SIGTERM fallback';shutdown.error=String(error);child.kill('SIGTERM')}}
  Object.assign(shutdown,await ended);report.shutdown.push(shutdown);await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
  assert.equal(shutdown.method,'POST /quit');assert.equal(shutdown.code,0);assert.equal(shutdown.signal,null);
 }
}
}catch(error){report.status='failed';report.error=String(error);await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));throw error}
report.status='passed';await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,checks:report.checks.length,out},null,2));
