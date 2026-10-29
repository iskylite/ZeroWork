/** Main App acceptance for exact, Task-local execution route grants.
 * Only the provider is deterministic: Local tools, approval, lifecycle, PTY,
 * saved intervals and normal Quit all use the production application.
 * Run only in an allocated native slot, against the delivered candidate:
 * ZW_AI_TEST_PREFIX=/tmp/zw-patch-main-native ZW_AI_TEST_EXPECTED_SHA256=<sha>
 *   node e2e/ai_execution_route_native.ts /tmp/zw-ai-execution-route-evidence
 */
import assert from 'node:assert/strict';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash,randomBytes} from 'node:crypto';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,readdir,open,realpath,access} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-patch-main-native');
const binary=resolve(process.env.ZW_AI_TEST_BINARY??join(prefix,'bin/zerowork'));
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-ai-execution-route-evidence');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-route-'));
const data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
await Promise.all([mkdir(data),mkdir(rpc),mkdir(zdot)]);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='route-test%# '\n");
const nonce=randomBytes(8).toString('hex'),key='route-'+nonce;
const stages=['CURRENT','BATCH','INTENT','NEW'] as const;
type Stage=typeof stages[number];
const cases=Object.fromEntries([...stages,'EXTRA'].map(stage=>{
 const marker='ZW_ROUTE_'+nonce+'_'+stage,file=join(iso,stage.toLowerCase());
 return[stage,{marker,file,command:`printf '%s\\n' '${marker}' >> '${file}'; printf '%s\\n' '${marker}'`}];
})) as Record<string,{marker:string,file:string,command:string}>;
const exists=async(path:string)=>{try{await access(path);return true}catch{return false}};
const wireName=(id:string)=>['run_command','read_terminal'].includes(id)?id:id.replaceAll('_','_u').replaceAll('.','__');
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const emitted=new Map<string,any>(),observations=new Map<string,any>(),requests:any[]=[],facts:any={};
let fixtureFailure:string|null=null,activeCall:any=null,finalEmitted=false;
const payload=(envelope:any)=>{
 for(const block of envelope.content??[])if(block.type==='structured'||block.type==='text')try{return JSON.parse(block.text)}catch{}
 return envelope;
};
const target=(envelope:any)=>{if(envelope.targets){assert.equal(envelope.targets.length,1);return envelope.targets[0]}return envelope};
const result=(results:Map<string,any>,id:string,success=true)=>{
 const envelope=results.get(id);if(!envelope)return null;
 const item=target(envelope),body=payload(item);observations.set(id,{envelope,body,at:new Date().toISOString()});
 if(success)assert.equal(item.status,'succeeded',`${id}: ${JSON.stringify(envelope)}`);
 return body;
};
const validateWire=(body:any)=>{
 const pending=new Map<string,any>();
 for(const message of body.messages){
  if(message.role==='assistant')for(const call of message.tool_calls??[]){assert(!pending.has(call.id),'duplicate unresolved call');pending.set(call.id,call)}
  if(message.role==='tool'){
   const call=pending.get(message.tool_call_id);assert(call,`orphan result ${message.tool_call_id}`);
   if(emitted.has(call.id)){const expected=emitted.get(call.id);assert.equal(call.function.name,expected.wire);assert.deepEqual(JSON.parse(call.function.arguments),expected.arguments,'original wire arguments changed')}
   JSON.parse(message.content);pending.delete(message.tool_call_id);
  }
 }
 assert.equal(pending.size,0,'every original call must have a production result before the next provider round');
};
const emitMany=(body:any,res:any,calls:any[])=>{
 const tool_calls=calls.map(({id,name,arguments:args},index)=>{
  const wire=wireName(name);assert(body.tools?.some((tool:any)=>tool.function.name===wire),`production catalog lacks ${wire}`);
  const call={id,name,wire,arguments:args};assert(!emitted.has(id),`fixture must never replay ${id}`);emitted.set(id,call);activeCall=call;
  return{index,id,type:'function',function:{name:wire,arguments:JSON.stringify(args)}};
 });res.end(frame({tool_calls})+'data: [DONE]\n\n');
};
const emit=(body:any,res:any,id:string,name:string,args:any)=>emitMany(body,res,[{id,name,arguments:args}]);
const finish=(res:any,stage:string)=>{activeCall=null;finalEmitted=true;res.end(frame({content:`[R-${stage}] 已核验本次实际执行方式、精确授权与一次执行。`})+'data: [DONE]\n\n')};
const traceEvents=async()=>{
 const events:any[]=[];for(const line of(await readFile(join(out,'app.log'),'utf8')).split('\n')){const index=line.indexOf('AI_TOOL_TRACE ');if(index>=0)try{events.push(JSON.parse(line.slice(index+14)))}catch{}}
 return events;
};
const assertPlan=async(results:Map<string,any>,id:string,stage:Stage,selected:string,creation=false)=>{
 const body=result(results,id,false);if(!body)return null;
 const envelope=target(results.get(id));assert.equal(envelope.status,'cancelled_unsent');assert.equal(body.error_code,'requires_plan_change');assert.equal(body.state,'cancelled_unsent');assert.equal(body.selected_route,selected);assert.equal(body.requires_new_session,creation);assert.equal(body.side_effect_started,false);
 if(facts[stage].plan_change)return body;
 assert.equal(await exists(cases[stage].file),false,'the old-route tool must produce zero writes');
 const events=await traceEvents();assert.equal(events.filter(event=>event.call_id===id&&['dynamic_dispatch','exec_started','host_received','group_host_received'].includes(event.event)).length,0,'old-route call must never reach a real adapter');
 facts[stage].plan_change={id,envelope:results.get(id),body,zero_writes:true,zero_adapter_dispatch:true};return body;
};
const assertInterval=(value:any,stage:Stage)=>{
 const s=value.snapshot;assert.equal(value.state,'interval_recorded');assert.equal(s.state,'interval_recorded');assert.equal(s.interval_saved,true);assert.equal(s.output_scope,'session_interval');assert.equal(s.command_accepted,true);assert.equal(s.submit_sent,true);assert(s.submit_native_bytes>0);assert.equal(s.native_wake_written,true);assert(s.start&&s.end&&s.end.sequence>s.start.sequence);assert.equal(s.process.foreground_finished,true);assert.equal(s.process.exit_code,0);assert.equal(s.recording_settled,true);assert.equal(s.recording_failed,false);assert.equal(s.local_released,true);assert.equal(s.remote_effect_unknown,false);assert.equal(s.grant,null);assert(value.output.includes(cases[stage].marker));
 const hash=typeof s.command_hash==='string'?[...Buffer.from(s.command_hash,'utf8')]:s.command_hash;assert.deepEqual(hash,[...createHash('sha256').update(cases[stage].command).digest()]);
};
const server=createServer(async(req,res)=>{
 try{
  if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'execution-route-fixture'}]}));return}
  let raw='';for await(const chunk of req)raw+=chunk;const body=JSON.parse(raw);validateWire(body);
  const userIndex=body.messages.findLastIndex((m:any)=>m.role==='user'&&/\[R-(CURRENT|BATCH|INTENT|NEW)\]/.test(String(m.content)));
  const stage=/\[R-(CURRENT|BATCH|INTENT|NEW)\]/.exec(String(body.messages[userIndex]?.content))?.[1] as Stage;assert(stages.includes(stage),'fixture stage must come from the actual submitted composer text');
  const current=body.messages.slice(userIndex+1),results=new Map<string,any>(current.filter((m:any)=>m.role==='tool').map((m:any)=>[m.tool_call_id,JSON.parse(m.content)]));
  requests.push({at:new Date().toISOString(),stage,wire:body.messages,results:[...results].map(([id,envelope])=>({id,envelope}))});
  res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
  const stem=stage.toLowerCase(),context=result(results,stem+'-context'),inventory=result(results,stem+'-sessions');
  if(!context||!inventory)return emitMany(body,res,[{id:stem+'-context',name:'host.get_current_context',arguments:{}},{id:stem+'-sessions',name:'host.list_sessions',arguments:{limit:16}}]);
  assert.equal(context.execution_mode,'ask');assert.equal(inventory.sessions.length,1);const source=inventory.sessions[0];assert.equal(source.ready,true);assert.equal(source.task_owned,false);assert.equal(context.binding_ref,source.session_ref);
  facts[stage]??={};Object.assign(facts[stage],{context,source});
  const wrongId=stem+'-wrong',wrongName=stage==='BATCH'?'host.run_in_terminal':'run_command';
  if(!results.has(wrongId))return emit(body,res,wrongId,wrongName,wrongName==='run_command'?{session_ids:[source.session_id],command:cases[stage].command}:{session_ref:source.session_ref,command:cases[stage].command,request_key:key+'-'+wrongId});
  await assertPlan(results,wrongId,stage,stage==='BATCH'?'batch':stage==='NEW'?'new_terminal':'current_terminal',stage==='NEW');
  let destination=source;
  if(stage==='NEW'){
   const group=result(results,'new-group');if(!group)return emit(body,res,'new-group','host.create_group',{initial_session_ref:source.session_ref,name:'Exact route acceptance',request_key:key+'-group'});
   assert.equal(group.state,'committed');assert.equal(group.same_conversation_id,context.conversation_id);assert.equal(group.initial_member,source.session_id);
   const next=result(results,'new-group-context');if(!next)return emit(body,res,'new-group-context','host.get_current_context',{});
   assert.equal(next.binding_ref,group.group_ref);assert.equal(next.conversation_id,context.conversation_id);assert.equal(next.task_id,context.task_id);assert(next.binding_revision>context.binding_revision);
   const opened=result(results,'new-open');if(!opened)return emit(body,res,'new-open','host.open_session',{group_ref:group.group_ref,source_ref:source.session_ref,connection_policy:'new_only',retention:'ask',request_key:key+'-open'});
   assert.equal(opened.ownership,'created_task');assert.equal(opened.retention,'ask');assert.notEqual(opened.session_ref,source.session_ref);
   let ready=result(results,'new-ready');if(!ready)return emit(body,res,'new-ready','host.wait_session_ready',{operation_ref:opened.operation_ref,after_revision:opened.source_revision,wait_ms:30000});
   for(let i=1;ready.state!=='ready'&&i<5;i++){const value=result(results,'new-ready-'+i);if(!value)return emit(body,res,'new-ready-'+i,'host.wait_session_ready',{operation_ref:opened.operation_ref,after_revision:ready.source_revision,wait_ms:30000});ready=value}
   assert.equal(ready.state,'ready');assert.equal(ready.membership_committed,true);assert.equal(ready.ownership,'created_task');assert.equal(ready.session_ref,opened.session_ref);destination=ready;Object.assign(facts.NEW,{group,next,opened,ready});
  }
  const actualId=stem+'-actual',actualName=stage==='BATCH'?'run_command':'host.run_in_terminal';
  const actual=result(results,actualId);if(!actual)return emit(body,res,actualId,actualName,actualName==='run_command'?{session_ids:[destination.session_id],command:cases[stage].command}:{session_ref:destination.session_ref,command:cases[stage].command,request_key:key+'-'+actualId});
  if(stage==='BATCH'){assert.equal(actual.status,'succeeded');assert.equal(actual.exit,0);assert(actual.stdout.includes(cases.BATCH.marker));facts.BATCH.actual=actual}
  else{
   assert(actual.execution_ref?.startsWith('x1:'));let value=result(results,stem+'-wait');if(!value)return emit(body,res,stem+'-wait','host.wait_execution',{execution_ref:actual.execution_ref,after_revision:actual.source_revision,wait_ms:30000,max_bytes:8192});
   for(let i=1;value.state!=='interval_recorded'&&i<6;i++){assert(!['cancelled_unsent','outcome_unknown','handed_off','recording_degraded'].includes(value.state),JSON.stringify(value));const next=result(results,stem+'-wait-'+i);if(!next)return emit(body,res,stem+'-wait-'+i,'host.wait_execution',{execution_ref:actual.execution_ref,after_revision:value.source_revision,wait_ms:30000,max_bytes:8192});value=next}
   assertInterval(value,stage);facts[stage].actual=value;
  }
  assert.equal(await readFile(cases[stage].file,'utf8'),cases[stage].marker+'\n','the fixed diagnostic command must execute exactly once');
  if(stage==='INTENT'){
   const extra=result(results,'intent-extra',false);if(!extra)return emit(body,res,'intent-extra','host.run_in_terminal',{session_ref:source.session_ref,command:cases.EXTRA.command,request_key:key+'-extra'});
   assert.equal(target(results.get('intent-extra')).status,'rejected');assert.equal(extra.side_effect_started,false);assert.equal(await exists(cases.EXTRA.file),false);facts.INTENT.extra_denied=results.get('intent-extra');
  }
  return finish(res,stage);
 }catch(error){fixtureFailure??=String(error);await writeFile(join(out,'fixture-failure.txt'),fixtureFailure);if(!res.headersSent)res.writeHead(500);res.end()}
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="execution-route-fixture"\npermission_mode="confirm"\nexecution_mode="ask"\nsession_retention="ask"\n[[ai.providers]]\nid="execution-route-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="execution-route-fixture"\ncontext_window=200000\ndefault=true\n[log]\nring_mb=1\ncheckpoint_sec=1\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const binarySha256=createHash('sha256').update(await readFile(binary)).digest('hex');
if(process.env.ZW_AI_TEST_EXPECTED_SHA256)assert.equal(binarySha256,process.env.ZW_AI_TEST_EXPECTED_SHA256,'binary differs from the explicitly delivered candidate');
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1',ZDOTDIR:zdot,OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join('');
const visible=(id:string)=>h.waitFor(async()=>{assert.equal(fixtureFailure,null);return(await h.query(id)).find(shown)??null},20000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,15000);
const report:any={status:'running',binary,binary_sha256:binarySha256,started_at:new Date().toISOString(),checks:[],scenarios:{},approvals:[],route_selections:[],limits:['The provider emits deterministic tool calls; every tool result, Local dispatch, approval, owned session, PTY interval and recording comes from the production App.','Only nonsecret random printf diagnostics in a private /tmp directory execute. SSH, physical keyboard, IME and VoiceOver are outside this case.','This is execution-route acceptance, not a claim that all application features are verified.']};
const click=async(id:string)=>{report.last_action=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
const capture=async(name:string)=>{await h.mouseMove(1,1);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify({panel:await h.query('ai.panel'),group:await h.query('groups.workspace'),tabs:await h.query('tabs.strip')},null,2))};
const send=async(stage:Stage)=>{activeCall=null;finalEmitted=false;await click('ai.prompt');await h.key('a',{cmd:true});const prompt=stage==='INTENT'?`这次在当前终端执行 \`${cases.INTENT.command}\` [R-INTENT]`:`[R-${stage}] 验收此条精确命令的真实运行方式，仅按实际审批执行。`;facts[stage]={submitted:prompt};await h.type_(prompt);await click('ai.send')};
async function normalQuit(){
 if(app.exitCode!==null||app.signalCode!==null)return;
 if((await h.query('ai.collapse')).some(shown))await click('ai.collapse');
 const at=performance.now();assert((await h.request('POST','/quit')).ok);report.close_confirmations=[];let unbound=false;
 while(app.exitCode===null&&app.signalCode===null&&performance.now()-at<15000){
  if(unbound){await Promise.race([ended,h.sleep(80)]);continue}
  try{for(const id of['groups.close.accept','local.close.accept','session.close.accept']){if(app.exitCode!==null||app.signalCode!==null)break;const nodes=await h.query(id);if(!Array.isArray(nodes)){unbound=true;break}if(nodes.some(shown)){report.close_confirmations.push(id);await click(id)}}}catch(error){report.close_rpc_after_unbind=String(error);unbound=true}
  if(app.exitCode===null&&app.signalCode===null)await h.sleep(80);
 }
 await Promise.race([ended,h.sleep(500)]);assert.equal(app.exitCode,0,'normal Quit must drain the App and exit zero');assert.equal(app.signalCode,null);report.normal_quit={route:'POST /quit',exit_code:app.exitCode,signal:app.signalCode,elapsed_ms:performance.now()-at};
}
try{
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.maximize');
 for(const stage of stages){
  report.active_stage=stage;await send(stage);const approved=new Set<string>(),start=performance.now();
  while(!finalEmitted&&performance.now()-start<100000){
   assert.equal(fixtureFailure,null);const recovery=(await h.query('ai.recovery')).find(shown);assert(!recovery,`provider recovery: ${text(recovery)}`);
   if((await h.query('ai.host_approval')).some(shown)){
    assert(activeCall,'every pending card belongs to the current original provider call');const call=activeCall,id=call.id;
    if(approved.has(id)){await h.sleep(80);continue}
    assert.equal(await exists(cases.EXTRA.file),false);
    const lifecycle=['new-group','new-open'].includes(id),extra=id==='intent-extra',trusted=stage==='INTENT'&&!extra;
    report.pending_approval={stage,id,tool:call.name,arguments:call.arguments,native:await h.query('ai.host_approval')};
    if(!lifecycle&&!extra&&id===stage.toLowerCase()+'-actual'&&!trusted)report.primary_failure={category:'product',phase:'exact-route-grant-reuse',reason:`The selected exact command requested an unexpected second approval at ${id}`,evidence:report.pending_approval};
    assert(lifecycle||extra||id===stage.toLowerCase()+'-wrong'||trusted&&id==='intent-actual',`unexpected new approval ${id}; exact route grant was not reused`);
    const card=await visible('ai.host_approval'),summary=text(await visible('ai.host_approval.summary')),targetText=text(await visible('ai.host_approval.target'));
    if(!lifecycle){
     const expected=extra?cases.EXTRA.command:cases[stage].command;assert.equal(summary,Buffer.from(expected).subarray(0,200).toString('utf8'));
     await click('ai.host_approval.copy');const complete=(await promisify(execFile)('/usr/bin/pbpaste',[],{encoding:'utf8'})).stdout;assert.equal(complete,expected,'native copy preserves the full exact pending command');
     assert.equal(await exists((extra?cases.EXTRA:cases[stage]).file),false,'no command write before permission');
     if(trusted){assert.equal((await h.query('ai.host_approval.route.batch')).filter(shown).length,0,'actual submitted intent fixes only this command route')}
     else{
      for(const option of['batch','current','new'])await visible('ai.host_approval.route.'+option);
      const order=stage==='CURRENT'?['batch','current','new','current']:[stage==='BATCH'?'batch':stage==='NEW'?'new':'current'];
      const beforeRequests=requests.length;
      for(const option of order){
       await click('ai.host_approval.route.'+option);const same=await visible('ai.host_approval');assert.equal(same.id,card.id);assert.equal(text(await visible('ai.host_approval.summary')),summary);assert.equal(text(await visible('ai.host_approval.target')),targetText);assert.equal(requests.length,beforeRequests,'selection alone must not advance provider or execute');assert.equal(await exists((extra?cases.EXTRA:cases[stage]).file),false);
       report.route_selections.push({stage,id,option,card_id:same.id,summary,target:targetText,provider_requests:requests.length,zero_writes:true});await capture(stage.toLowerCase()+'-pending-'+option);
      }
     }
    }
    await capture(stage.toLowerCase()+'-'+id+'-before-'+(extra?'reject':'approve'));
    approved.add(id);report.approvals.push({stage,id,kind:lifecycle?'lifecycle':'command',decision:extra?'reject':'approve',summary,target:targetText});await click(extra?'ai.host_approval.reject':'ai.host_approval.accept');
   }
   if(!finalEmitted)await h.sleep(80);
  }
  assert.equal(fixtureFailure,null);assert(finalEmitted,`${stage} timed out`);await absent('ai.stop');await visible('ai.turn.complete');
  assert.deepEqual([...approved],stage==='NEW'?['new-wrong','new-group','new-open']:stage==='INTENT'?['intent-actual','intent-extra']:[stage.toLowerCase()+'-wrong']);
  assert.equal(await readFile(cases[stage].file,'utf8'),cases[stage].marker+'\n');facts[stage].ui_decisions=[...approved];report.scenarios[stage]={status:'passed',ui_decisions:[...approved],one_write:true,plan_change:facts[stage].plan_change,execution_ref:facts[stage].actual?.execution_ref??null};report.pending_approval=null;await capture(stage.toLowerCase()+'-completed');
 }
 report.phase='aggregate-verification';const events=await traceEvents();
 for(const call of emitted.values()){
  // A later turn projects the original transcript again for UI feedback.
  // Count settlement in the first/original turn, and retain identical facts
  // when that settled result appears in a later turn's history projection.
  const feedback=events.filter(event=>event.event==='tool_feedback'&&event.call_id===call.id),first=feedback[0];assert(first,`${call.id} has production feedback`);
  assert.equal(feedback.filter(event=>event.turn_id===first.turn_id).length,1,`${call.id} settles once in its original turn`);
  for(const later of feedback)assert.deepEqual(JSON.parse(later.content),JSON.parse(first.content),`${call.id} historical feedback retains the original result`);
 }
 const wrongIds=stages.map(stage=>stage.toLowerCase()+'-wrong');for(const id of wrongIds)assert.equal(events.filter(event=>event.call_id===id&&['dynamic_dispatch','exec_started','host_received','group_host_received'].includes(event.event)).length,0);
 const batchDispatch=events.filter(event=>event.event==='exec_started');assert.equal(batchDispatch.length,1);assert.equal(batchDispatch[0].call_id,'batch-actual');
 const journal=JSON.parse(await readFile(join(data,'ai/lifecycle.json'),'utf8'));const runs=journal.records.filter((record:any)=>record.tool_id==='host.run_in_terminal'&&record.execution);assert.deepEqual(runs.map((run:any)=>run.original_call).sort(),['current-actual','intent-actual','new-actual']);
 for(const run of runs){assert.equal(run.stage,'succeeded');assert.equal(run.execution_receipt.interval_saved,true);assert.equal(run.execution_receipt.output_scope,'session_interval');assert.equal(run.execution_receipt.local_released,true)}
 const manifests:any[]=[];for(const path of await readdir(data,{recursive:true}))if(String(path).endsWith('.json'))try{const document=JSON.parse(await readFile(join(data,String(path)),'utf8'));if(document.execution_ranges?.length)manifests.push({path:String(path),document})}catch{}
 for(const stage of['CURRENT','INTENT','NEW'])assert.equal(manifests.flatMap(item=>item.document.execution_ranges).filter((range:any)=>range.execution_id===facts[stage].actual.snapshot.execution_id&&range.interval_saved).length,1);
 await writeFile(join(out,'lifecycle-journal.json'),JSON.stringify(journal,null,2));await writeFile(join(out,'recording-manifests.json'),JSON.stringify(manifests,null,2));
 report.checks.push('One actual ask card offers batch/current/new, keeps exact original command and target through selection, and advances only after one approve action','run_command → current PTY and PTY → batch return structured cancelled_unsent/requires_plan_change with zero adapter dispatch and zero writes before a later provider round emits the selected real tool','Each route executes its fixed unpredictable printf diagnostic once; batch has one real exec_started and the three PTY runs have real durably saved intervals','The actual composer submitted current-terminal instruction fixes the first route while exact command approval remains required; a different successor command gets a new selectable approval and rejection causes zero writes','New-work-terminal selection keeps exact same-Task source through explicit group/open approvals, one proved task-owned new_only Local identity and the chosen command on that real new PTY','Every original provider call retains its wire arguments, has one production feedback result, and normal Quit exits without a signal');
 await normalQuit();report.status='passed';
}catch(error){report.status='failed';report.error=String(error);report.fixture_failure=fixtureFailure;if(report.phase==='aggregate-verification')report.aggregate_failure=String(error);else report.scenarios[report.active_stage]={status:'failed',error:String(error)};process.exitCode=1;await capture('failure').catch(()=>{});await writeFile(join(out,'failure-tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{});try{await normalQuit()}catch(closeError){report.normal_quit_error=String(closeError)}}
finally{
 report.facts=facts;report.requests=requests;report.emitted=[...emitted.values()];report.observations=Object.fromEntries(observations);report.files={};for(const[name,value]of Object.entries(cases))try{report.files[name]={path:value.file,content:await readFile(value.file,'utf8')}}catch{report.files[name]={path:value.file,content:null}}
 const raw=await readFile(join(out,'app.log'),'utf8');report.native_errors=raw.split('\n').filter(line=>line.includes('ai worker turn failed:'));report.events=await traceEvents();
 await writeFile(join(out,'provider-wire.json'),JSON.stringify(requests,null,2));await writeFile(join(out,'raw-tool-results.json'),JSON.stringify(Object.fromEntries(observations),null,2));
 await writeFile(join(out,'tool-feedback.json'),JSON.stringify(report.events.filter((event:any)=>event.event==='tool_feedback').map((event:any)=>({...event,envelope:JSON.parse(event.content)})),null,2));
 try{await writeFile(join(out,'final-lifecycle-journal.json'),await readFile(join(data,'ai/lifecycle.json')))}catch{}
 const preservedManifests:any[]=[];for(const path of await readdir(data,{recursive:true}))if(String(path).endsWith('.json'))try{const document=JSON.parse(await readFile(join(data,String(path)),'utf8'));if(document.execution_ranges?.length)preservedManifests.push({path:String(path),document})}catch{}await writeFile(join(out,'final-recording-manifests.json'),JSON.stringify(preservedManifests,null,2));
 let forced=false;if(app.exitCode===null&&app.signalCode===null){forced=true;app.kill('SIGTERM')}await Promise.race([ended,h.sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}report.cleanup={forced,exit_code:app.exitCode,signal:app.signalCode};if(forced&&report.status==='passed'){report.status='failed';report.error='normal Quit was not achieved';process.exitCode=1}
 server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();report.isolation={directory:iso,preserved:true,data,rpc,zdot};await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(JSON.stringify({status:report.status,error:report.error,report:join(out,'report.json')}));
