/** Main App acceptance: real Local lifecycle, approval, private PTY protocol,
 * durable recording, TaskFinish and old-task fences. Only model output is fake.
 * Run after a test-mode build, with one allocated native-app slot:
 * ZW_AI_TEST_PREFIX=/tmp/zw-patch-integrated node e2e/ai_execution_lifecycle_native.ts /tmp/zw-ai-execution-lifecycle-evidence
 * Add ZW_AI_TEST_CLOSE_ONLY=1 for the real Local + settled AI Task normal-close
 * acceptance; that mode does not invoke terminal command execution.
 * ZW_AI_TEST_NEGATIVE_ONLY=1 checks fixed new_pty legacy-batch denial and a
 * rejected unknown execution reference, then normal close, without dispatch.
 * ZW_AI_TEST_TAKEOVER_ONLY=1 checks one precise input handoff while the same
 * provider Task and a second real Local execution keep running.
 */
import assert from 'node:assert/strict';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash,randomBytes} from 'node:crypto';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,readdir,open,realpath,rm,access} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-patch-integrated');
const binary=resolve(process.env.ZW_AI_TEST_BINARY??join(prefix,'bin/zerowork'));
const closeOnly=process.env.ZW_AI_TEST_CLOSE_ONLY==='1';
const negativeOnly=process.env.ZW_AI_TEST_NEGATIVE_ONLY==='1';
const takeoverOnly=process.env.ZW_AI_TEST_TAKEOVER_ONLY==='1';assert([closeOnly,negativeOnly,takeoverOnly].filter(Boolean).length<=1,'choose one independent acceptance mode');
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-ai-execution-lifecycle-evidence');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-ai-execution-lifecycle-'));
const data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
await Promise.all([mkdir(data),mkdir(rpc),mkdir(zdot)]);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='execution-test%# '\n");
const marker='ZW_EXEC_'+randomBytes(16).toString('hex'),markerFile=join(iso,'executed-once'),stopFile=join(iso,'must-not-execute');
// CRLF tests the production normalized approval while preserving original wire.
const command=`printf '%s\\n' '${marker}' >> '${markerFile}'\r\nprintf '%s\\n' '${marker}'`;
const normalizedCommand=command.replaceAll('\r\n','\n');
const stopCommand=`printf forbidden > '${stopFile}'`;
const unknownExecutionRef='x1:'+randomBytes(16).toString('hex');
const takeoverFiles={readyA:join(iso,'read-a-ready'),doneA:join(iso,'read-a-result'),readyB:join(iso,'loop-b-ready'),releaseB:join(iso,'release-b'),freshA:join(iso,'fresh-a-result')};
const takeoverInput='ZW_USER_'+randomBytes(16).toString('hex'),takeoverMarkerA='ZW_READ_DONE_'+randomBytes(8).toString('hex'),takeoverMarkerB='ZW_LOOP_DONE_'+randomBytes(8).toString('hex'),takeoverFreshMarker='ZW_FRESH_'+randomBytes(8).toString('hex');
const takeoverCommands={
 a:`printf ready > '${takeoverFiles.readyA}'; IFS= read -r ZW_TAKEOVER_VALUE; printf '%s\\n' "$ZW_TAKEOVER_VALUE" > '${takeoverFiles.doneA}'; printf '%s\\n' '${takeoverMarkerA}'`,
 b:`zmodload zsh/zselect && { printf ready > '${takeoverFiles.readyB}'; while [[ ! -f '${takeoverFiles.releaseB}' ]]; do zselect -t 5; done; printf '%s\\n' '${takeoverMarkerB}'; }`,
 fresh:`printf '%s\\n' '${takeoverFreshMarker}' > '${takeoverFiles.freshA}'; printf '%s\\n' '${takeoverFreshMarker}'`,
};
let takeoverHeld:any=null,takeoverTeardown=false,takeoverUnexpectedProviderClose=false,takeoverHandoffObserved=false;
const takeoverState:any={held_stages:[],notices:[],user_input_sent:false,b_released:false};
type FailureCategory='product'|'fixture_contract'|'query_contract'|'verification';
const recordFailure=(category:FailureCategory,phase:string,reason:string,evidence:any=null)=>{
 const failure={category,phase,reason,evidence,at:new Date().toISOString()};takeoverState.primary_failure??=failure;return failure;
};
class AcceptanceFailure extends Error{category:FailureCategory;phase:string;evidence:any;constructor(category:FailureCategory,phase:string,reason:string,evidence:any=null){super(reason);this.name='AcceptanceFailure';this.category=category;this.phase=phase;this.evidence=evidence;recordFailure(category,phase,reason,evidence)}}
const key='native-execution-'+randomBytes(8).toString('hex');
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const wireName=(id:string)=>['run_command','read_terminal'].includes(id)?id:id.replaceAll('_','_u').replaceAll('.','__');
const emitted=new Map<string,any>(),observations=new Map<string,any>(),requests:any[]=[];
let fixtureFailure:string|null=null,activeCall:any=null,finalEmitted=false;
let initialContext:any,groupContext:any,initialSession:any,ownedSession:any,executionRef:string|null=null,recorded:any;
const exists=async(path:string)=>{try{await access(path);return true}catch{return false}};
const payload=(envelope:any)=>{
 for(const block of envelope.content??[])if(block.type==='structured'||block.type==='text'){
  try{return JSON.parse(block.text)}catch{}
 }
 return envelope;
};
const result=(results:Map<string,any>,id:string,success=true)=>{
 const envelope=results.get(id);if(!envelope)return null;
 const body=payload(envelope);observations.set(id,{envelope,body,at:new Date().toISOString()});
 if(takeoverOnly&&id.startsWith('takeover-')&&success){
  if(envelope.status!=='succeeded')recordFailure('product','tool-result',`${id} returned ${envelope.status}`,{id,envelope,body});
  else if(body.snapshot&&['cancelled_unsent','outcome_unknown','recording_degraded'].includes(body.state))recordFailure('product','execution-state',`${id} observed ${body.state}: ${body.snapshot.failure??'unknown reason'}`,{id,envelope,body});
 }
 if(success)assert.equal(envelope.status,'succeeded',`${id}: ${JSON.stringify(envelope)}`);
 return body;
};
const assertHostRejected=(envelope:any,code:string)=>{
 const body=payload(envelope);assert.equal(envelope.status,'rejected');assert.equal(body.error_code,code);
 assert.equal(body.side_effect_started,false);assert.equal(body.local_released,true);assert.equal(body.remote_effect_unknown,false);
 assert.equal(envelope.receipt.side_effect_started,false);assert.equal(envelope.receipt.local_released,true);assert.equal(envelope.receipt.remote_effect_unknown,false);
 return body;
};
const emitMany=(body:any,res:any,calls:any[])=>{
 const tool_calls=calls.map(({id,name,arguments:args},index)=>{
  const wire=wireName(name);assert(body.tools?.some((tool:any)=>tool.function.name===wire),`production catalog lacks ${wire}`);
  const call={id,name,wire,arguments:args};
  if(emitted.has(id))assert.deepEqual(emitted.get(id),call,'retry changed original fixture call');
  emitted.set(id,call);activeCall=call;
  return{index,id,type:'function',function:{name:wire,arguments:JSON.stringify(args)}};
 });
 res.end(frame({tool_calls})+'data: [DONE]\n\n');
};
const emit=(body:any,res:any,id:string,name:string,args:any)=>emitMany(body,res,[{id,name,arguments:args}]);
const holdTakeover=(body:any,res:any,kind:string)=>{
 assert.equal(takeoverHeld,null,'only one real provider response may be held');activeCall=null;
 takeoverHeld={body,res,kind,at:performance.now()};takeoverState.held_stages.push(kind);
 res.write(frame({content:'继续观察当前任务的真实终端状态。'}));
 res.once('close',()=>{if(!res.writableEnded&&!takeoverTeardown)takeoverUnexpectedProviderClose=true});
};
const releaseTakeover=(kind:string,calls:any[])=>{assert(takeoverHeld&&takeoverHeld.kind===kind);const held=takeoverHeld;takeoverHeld=null;emitMany(held.body,held.res,calls)};
const finish=(res:any,stage:string)=>{activeCall=null;finalEmitted=true;res.end(frame({content:`[E-${stage}] 已核验真实终端、执行回执与本次任务边界。`})+'data: [DONE]\n\n')};
const validateWire=(body:any)=>{
 const system=body.messages.find((m:any)=>m.role==='system')?.content??'';
 assert(!/assistant_session_id=|provider=.*session_id=/.test(system),'ambient identity must be discovered through tools');
 const pending=new Map<string,any>();
 for(const message of body.messages){
  if(message.role==='assistant')for(const call of message.tool_calls??[]){assert(!pending.has(call.id),'duplicate unresolved call');pending.set(call.id,call)}
  if(message.role==='tool'){
   const call=pending.get(message.tool_call_id);assert(call,`orphan tool result ${message.tool_call_id}`);
   if(emitted.has(call.id)){
    const expected=emitted.get(call.id);assert.equal(call.function.name,expected.wire);
    assert.deepEqual(JSON.parse(call.function.arguments),expected.arguments,'assistant wire changed original arguments');
   }
   JSON.parse(message.content);pending.delete(message.tool_call_id);
  }
 }
 assert.equal(pending.size,0,'provider followup must contain a result for every original call');
};
const assertIntervalRecorded=(body:any,expectedCommand=normalizedCommand,expectedMarker=marker)=>{
 const s=body.snapshot;assert.equal(body.state,'interval_recorded');assert.equal(s.state,'interval_recorded');assert.equal(s.output_scope,'session_interval');assert.equal(s.interval_saved,true);
 assert.equal(body.execution_ref,'x1:'+s.execution_id);
 assert.equal(s.command_accepted,true);assert.equal(s.submit_sent,true);assert(s.submit_native_bytes>0);assert.equal(s.native_wake_written,true);
 assert(s.accepted_sequence>0&&s.submit_sequence>0&&s.submit_ack_sequence>0);
 assert(s.start&&s.end&&s.end.sequence>s.start.sequence&&s.end.event_sequence>s.start.event_sequence);
 assert.equal(s.process.foreground_finished,true);assert.equal(s.process.exit_code,0);assert.equal(s.process.signal,null);
 assert(['unverified','no_concurrent_owner_observed','concurrent_observed'].includes(s.output_attribution),'observed attribution must use the public enum');
 assert(s.output_attribution_reason===null||typeof s.output_attribution_reason==='string');
 assert.equal(s.recording_settled,true);assert.equal(s.recording_failed,false);assert(s.recording_id&&s.recording_generation>0&&s.manifest_revision>0);
 assert.equal(s.local_released,true);assert.equal(s.remote_effect_unknown,false);assert.equal(s.grant,null);
 const hashBytes=typeof s.command_hash==='string'?[...Buffer.from(s.command_hash,'utf8')]:s.command_hash;
 assert.deepEqual(hashBytes,[...createHash('sha256').update(expectedCommand.replaceAll('\r\n','\n')).digest()]);
 assert(body.output.includes(expectedMarker),'saved PTY interval must expose the real unpredictable output');
};
const assertRunning=(body:any,label:string)=>{
 assert.equal(body.state,'running',`${label}: ${JSON.stringify(body)}`);assert.equal(body.snapshot.submit_sent,true);assert(body.snapshot.submit_native_bytes>0);assert.equal(body.snapshot.process?.foreground_finished??false,false);
};
const server=createServer(async(req,res)=>{
 try{
  if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'execution-lifecycle-fixture'}]}));return}
  let raw='';for await(const chunk of req)raw+=chunk;const body=JSON.parse(raw);validateWire(body);
  // A real single-to-group handoff adds a host-authored user notice. Keep the
  // fixture's explicit task marker as the boundary across that genuine notice.
  const userIndex=body.messages.findLastIndex((m:any)=>m.role==='user'&&/\[E-(LIFE|STOP|AFTER|CLOSE|NEGATIVE|TAKEOVER)\]/.test(String(m.content)));
  const user=String(body.messages[userIndex]?.content??'');
  const stage=/\[E-(LIFE|STOP|AFTER|CLOSE|NEGATIVE|TAKEOVER)\]/.exec(user)?.[1];if(!stage)throw new AcceptanceFailure('fixture_contract','stage-selection','expected explicit fixture stage');
  const current=body.messages.slice(userIndex+1);
  const results=new Map<string,any>(current.filter((m:any)=>m.role==='tool').map((m:any)=>[m.tool_call_id,JSON.parse(m.content)]));
  const notices=current.filter((m:any)=>m.role==='user').flatMap((m:any)=>{try{const notice=JSON.parse(m.content);return notice.input_handoffs??(notice.host_input_handoff?[notice]:[])}catch{return[]}});
  requests.push({at:new Date().toISOString(),stage,wire:body.messages,calls:current.flatMap((m:any)=>m.tool_calls??[]),results:[...results].map(([id,value])=>({id,envelope:value})),host_notices:notices});
  res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
  if(stage==='TAKEOVER'){
   const diagnostic=[...results].filter(([id])=>id.startsWith('takeover-diagnostic-'));
   if(diagnostic.length){
    takeoverState.failure_snapshots=diagnostic.map(([id,envelope])=>({id,envelope,body:payload(envelope)}));
    const failed=takeoverState.failure_snapshots.find((item:any)=>item.envelope.status!=='succeeded'||['cancelled_unsent','outcome_unknown','recording_degraded'].includes(item.body.state));
    if(failed)recordFailure('product','execution-state',`${failed.id} observed ${failed.body.state??failed.envelope.status}: ${failed.body.snapshot?.failure??failed.body.error_code??'unknown reason'}`,failed);
    else{const pending=takeoverState.pending_failure;recordFailure(pending.category,pending.phase,pending.reason,{...pending.evidence,snapshots:takeoverState.failure_snapshots})}
    return holdTakeover(body,res,'diagnostic_failure');
   }
   assert(takeoverOnly);assert.equal(takeoverUnexpectedProviderClose,false,'the existing provider response must survive handoff');
   initialContext=result(results,'takeover-context');if(!initialContext)return emitMany(body,res,[{id:'takeover-context',name:'host.get_current_context',arguments:{}},{id:'takeover-sessions',name:'host.list_sessions',arguments:{limit:16}}]);
   const initial=result(results,'takeover-sessions');assert(initial);assert.equal(initial.sessions.length,1);initialSession=initial.sessions[0];assert.equal(initialSession.ready,true);
   const group=result(results,'takeover-group');if(!group)return emit(body,res,'takeover-group','host.create_group',{initial_session_ref:initialSession.session_ref,name:'Precise takeover acceptance',request_key:key+'-takeover-group'});
   groupContext=result(results,'takeover-group-context');if(!groupContext)return emit(body,res,'takeover-group-context','host.get_current_context',{});
   assert.equal(groupContext.conversation_id,initialContext.conversation_id);assert.equal(groupContext.task_id,initialContext.task_id);assert.equal(groupContext.binding_ref,group.group_ref);
   const openedA=result(results,'takeover-open-a');if(!openedA)return emit(body,res,'takeover-open-a','host.open_session',{group_ref:groupContext.binding_ref,source_ref:initialSession.session_ref,connection_policy:'new_only',retention:'keep',request_key:key+'-takeover-open-a'});
   const openedB=result(results,'takeover-open-b');if(!openedB)return emit(body,res,'takeover-open-b','host.open_session',{group_ref:groupContext.binding_ref,source_ref:initialSession.session_ref,connection_policy:'new_only',retention:'keep',request_key:key+'-takeover-open-b'});
   let readyA=result(results,'takeover-ready-a'),readyB=result(results,'takeover-ready-b');
   if(!readyA||!readyB)return emitMany(body,res,[{id:'takeover-ready-a',name:'host.wait_session_ready',arguments:{operation_ref:openedA.operation_ref,after_revision:openedA.source_revision,wait_ms:30000}},{id:'takeover-ready-b',name:'host.wait_session_ready',arguments:{operation_ref:openedB.operation_ref,after_revision:openedB.source_revision,wait_ms:30000}}]);
   for(let i=1;(readyA.state!=='ready'||readyB.state!=='ready')&&i<=3;i++){
    for(const value of[readyA,readyB])assert(['queued','prepared','opening','ready'].includes(value.state),JSON.stringify(value));
    const nextA=result(results,'takeover-ready-a-'+i),nextB=result(results,'takeover-ready-b-'+i);
    if(!nextA||!nextB)return emitMany(body,res,[{id:'takeover-ready-a-'+i,name:'host.wait_session_ready',arguments:{operation_ref:openedA.operation_ref,after_revision:readyA.source_revision,wait_ms:30000}},{id:'takeover-ready-b-'+i,name:'host.wait_session_ready',arguments:{operation_ref:openedB.operation_ref,after_revision:readyB.source_revision,wait_ms:30000}}]);readyA=nextA;readyB=nextB;
   }
   for(const ready of[readyA,readyB]){assert.equal(ready.state,'ready');assert.equal(ready.ownership,'created_task');assert.equal(ready.membership_committed,true)}
   // Lifecycle attached/ready precedes the private shell hello and recording
   // barrier. Observe the real capability in a closed read-only batch before
   // sending either command; failed/unavailable never become execution retries.
   takeoverState.pty_observation_started_at??=performance.now();takeoverState.pty_observations??=[];
   let sessionA:any,sessionB:any;
   for(let attempt=0;attempt<3;attempt++){
    const suffix=attempt?'-'+attempt:'',idA='takeover-session-a'+suffix,idB='takeover-session-b'+suffix;
    const observationA=result(results,idA),observationB=result(results,idB);
    if(!observationA||!observationB){
     assert(performance.now()-takeoverState.pty_observation_started_at<6000,'private PTY readiness exceeded the bounded read-only deadline');
     if(attempt)await h.sleep(attempt===1?1500:3000);
     return emitMany(body,res,[{id:idA,name:'host.get_session',arguments:{session_ref:readyA.session_ref}},{id:idB,name:'host.get_session',arguments:{session_ref:readyB.session_ref}}]);
    }
    sessionA=observationA.session;sessionB=observationB.session;
    if(!takeoverState.pty_observations.some((item:any)=>item.attempt===attempt))takeoverState.pty_observations.push({attempt,elapsed_ms:performance.now()-takeoverState.pty_observation_started_at,a:observationA,b:observationB});
    assert.notEqual(sessionA.session_id,sessionB.session_id);
    for(const session of[sessionA,sessionB]){
     assert.equal(session.ready,true);assert.equal(session.task_owned,true);
     const caps=session.capabilities;
     assert(['ready','initializing','busy'].includes(caps.trusted_pty_state),`private PTY initialization failed: ${JSON.stringify({session_id:session.session_id,capabilities:caps})}`);
     assert(caps.trusted_pty_failure===null||(caps.trusted_pty_state==='busy'&&caps.trusted_pty_failure==='WorkerBusy'),`private PTY failure: ${JSON.stringify(caps)}`);
    }
    if([sessionA,sessionB].every(session=>session.capabilities.trusted_pty_execution===true))break;
    assert(attempt<2&&performance.now()-takeoverState.pty_observation_started_at<6000,'private PTY capability did not become ready within three read-only observations / six seconds');
   }
   for(const session of[sessionA,sessionB])assert.equal(session.capabilities.trusted_pty_execution,true);
   Object.assign(takeoverState,{session_a:sessionA,session_b:sessionB});
   const runA=result(results,'takeover-run-a');if(!runA)return emit(body,res,'takeover-run-a','host.run_in_terminal',{session_ref:readyA.session_ref,command:takeoverCommands.a,request_key:key+'-takeover-run-a'});
   const runB=result(results,'takeover-run-b');if(!runB)return emit(body,res,'takeover-run-b','host.run_in_terminal',{session_ref:readyB.session_ref,command:takeoverCommands.b,request_key:key+'-takeover-run-b'});
   Object.assign(takeoverState,{execution_a:runA.execution_ref,execution_b:runB.execution_ref});
   const activeA=result(results,'takeover-active-a'),activeB=result(results,'takeover-active-b');
   if(!activeA||!activeB)return holdTakeover(body,res,'before_handoff');
   takeoverState.active_snapshots={a:activeA,b:activeB};
   for(const[label,value]of[['A',activeA],['B',activeB]]as const){if(value.state!=='running')throw new AcceptanceFailure('product','active-executions',`${label} did not enter real running state`,value);assertRunning(value,label);assert.equal(value.snapshot.output_scope,'session_interval');assert.equal(value.snapshot.interval_saved,false);assert(value.snapshot.grant);assert.equal(value.snapshot.input_handed_off,false);assert.equal(value.snapshot.local_released,false)}
   const handedA=result(results,'takeover-handed-a'),untouchedB=result(results,'takeover-untouched-b');
   if(!handedA||!untouchedB)return holdTakeover(body,res,'active_confirmed');
   assertRunning(handedA,'handoff A keeps its foreground read');assert.equal(handedA.snapshot.input_handed_off,true);assert.equal(handedA.snapshot.grant,null);assert.equal(handedA.snapshot.input_ready,true);assert.equal(handedA.snapshot.local_released,true);assert.equal(handedA.snapshot.remote_effect_unknown,false);
   assertRunning(untouchedB,'unselected B keeps running');assert(untouchedB.snapshot.grant);assert.equal(untouchedB.snapshot.input_handed_off,false);assert.equal(untouchedB.snapshot.input_ready,false);assert.equal(untouchedB.snapshot.local_released,false);
   assert.equal(handedA.execution_ref,runA.execution_ref);assert.equal(handedA.snapshot.execution_id,runA.execution_ref.slice(3));assert.equal(handedA.snapshot.owner.session_id,sessionA.session_id);assert.equal(untouchedB.execution_ref,runB.execution_ref);assert.equal(untouchedB.snapshot.execution_id,runB.execution_ref.slice(3));assert.equal(untouchedB.snapshot.grant.execution_id,runB.execution_ref.slice(3));assert.equal(untouchedB.snapshot.owner.session_id,sessionB.session_id);assert.deepEqual(untouchedB.snapshot.grant,activeB.snapshot.grant,'B keeps the exact original grant');
   takeoverHandoffObserved=true;takeoverState.handoff_snapshot=handedA;takeoverState.untouched_snapshot=untouchedB;
   const notice=notices.find((item:any)=>item.text?.includes('你已接管终端')&&(item.conversation_id??item.context?.conversation_id)===initialContext.conversation_id);
   assert(notice,'the same provider Task must receive the real host handoff notice');assert.equal(notice.task_id??notice.context?.task_id,initialContext.task_id);assert(notice.revision??notice.notice_revision);assert(notice.text.includes(sessionA.title));takeoverState.notices=notices;
   let doneA=result(results,'takeover-finished-a');if(!doneA)return holdTakeover(body,res,'before_user_input');
   for(let i=1;doneA.state!=='interval_recorded'&&i<=3;i++){
    assert(!['cancelled_unsent','outcome_unknown','handed_off','recording_degraded'].includes(doneA.state),JSON.stringify(doneA));
    const id='takeover-finished-a-'+i,next=result(results,id);if(!next)return emit(body,res,id,'host.wait_execution',{execution_ref:runA.execution_ref,after_revision:doneA.source_revision,wait_ms:30000,max_bytes:8192});doneA=next;
   }
   assertIntervalRecorded(doneA,takeoverCommands.a,takeoverMarkerA);assert.equal(doneA.snapshot.input_handed_off,true);assert.equal(await readFile(takeoverFiles.doneA,'utf8'),takeoverInput+'\n');takeoverState.finished_original_a=doneA;
   const fresh=result(results,'takeover-fresh-a');if(!fresh)return emit(body,res,'takeover-fresh-a','host.run_in_terminal',{session_ref:readyA.session_ref,command:takeoverCommands.fresh,request_key:key+'-takeover-fresh-a'});
   assert.notEqual(fresh.execution_ref,runA.execution_ref);assert.equal(fresh.snapshot.owner.session_id,doneA.snapshot.owner.session_id);assert.equal(fresh.snapshot.input_handed_off,false);takeoverState.fresh_execution_a=fresh.execution_ref;
   let finalA=result(results,'takeover-final-a-0'),finalB=result(results,'takeover-final-b-0'),originalA=result(results,'takeover-original-a-again');
   if(!finalA||!finalB||!originalA)return holdTakeover(body,res,'fresh_output');
   assert.equal(originalA.execution_ref,runA.execution_ref);assert.equal(originalA.snapshot.execution_id,doneA.snapshot.execution_id);assert.equal(originalA.snapshot.input_handed_off,true);assert.equal(originalA.state,'interval_recorded');assert.deepEqual(originalA.snapshot.owner,doneA.snapshot.owner);assert.equal(originalA.snapshot.execution_fence,doneA.snapshot.execution_fence);assert.equal(originalA.snapshot.execution_input_epoch,doneA.snapshot.execution_input_epoch);assert.equal(originalA.snapshot.grant,null);assert.deepEqual(originalA.snapshot.start,doneA.snapshot.start);assert.deepEqual(originalA.snapshot.end,doneA.snapshot.end);assert.equal(originalA.snapshot.interval_saved,true);
   for(let i=1;(finalA.state!=='interval_recorded'||finalB.state!=='interval_recorded')&&i<=3;i++){
    for(const value of[finalA,finalB])assert(!['cancelled_unsent','outcome_unknown','handed_off','recording_degraded'].includes(value.state),JSON.stringify(value));
    const nextA=result(results,'takeover-final-a-'+i),nextB=result(results,'takeover-final-b-'+i);
    if(!nextA||!nextB)return emitMany(body,res,[{id:'takeover-final-a-'+i,name:'host.wait_execution',arguments:{execution_ref:fresh.execution_ref,after_revision:finalA.source_revision,wait_ms:30000,max_bytes:8192}},{id:'takeover-final-b-'+i,name:'host.wait_execution',arguments:{execution_ref:runB.execution_ref,after_revision:finalB.source_revision,wait_ms:30000,max_bytes:8192}}]);finalA=nextA;finalB=nextB;
   }
   assertIntervalRecorded(finalA,takeoverCommands.fresh,takeoverFreshMarker);assert(finalA.snapshot.execution_fence>doneA.snapshot.execution_fence);assert(finalA.snapshot.execution_input_epoch>=doneA.snapshot.input_epoch);assert.equal(finalA.snapshot.input_handed_off,false);assertIntervalRecorded(finalB,takeoverCommands.b,takeoverMarkerB);assert.equal(finalB.snapshot.input_handed_off,false);
   Object.assign(takeoverState,{finished_fresh_a:finalA,finished_b:finalB});return finish(res,stage);
  }
  if(stage==='NEGATIVE'){
   assert(negativeOnly);initialContext=result(results,'negative-context');if(!initialContext)return emitMany(body,res,[{id:'negative-context',name:'host.get_current_context',arguments:{}},{id:'negative-sessions',name:'host.list_sessions',arguments:{limit:16}}]);
   assert.equal(initialContext.execution_mode,'new_pty');const inventory=result(results,'negative-sessions');assert(inventory);assert.equal(inventory.sessions.length,1);initialSession=inventory.sessions[0];assert.equal(initialSession.ready,true);assert.equal(initialSession.session_ref,initialContext.binding_ref);
   const legacy=result(results,'negative-legacy-run',false);if(!legacy)return emit(body,res,'negative-legacy-run','run_command',{session_ids:[initialSession.session_id],command:stopCommand});
   assert(['rejected','failed'].includes(legacy.status),'legacy ModeConflict must be a known denial');assert.equal(legacy.error_code,'ModeConflict');assert.deepEqual(legacy.session_ids,[initialSession.session_id]);assert.equal(await exists(stopFile),false);
   const unknown=result(results,'negative-unknown-execution',false);if(!unknown)return emit(body,res,'negative-unknown-execution','host.get_execution',{execution_ref:unknownExecutionRef,max_bytes:1024});
   const rejected=results.get('negative-unknown-execution');assertHostRejected(rejected,'ExecutionNotFound');assert.equal(rejected.receipt.conversation_id,initialContext.conversation_id);assert.equal(rejected.receipt.task_id,initialContext.task_id);
   assert.equal(await exists(stopFile),false);return finish(res,stage);
  }
  if(stage==='CLOSE'){
   assert(closeOnly);assert(body.tools.some((tool:any)=>tool.function.name===wireName('host.run_in_terminal')),'the actual Driver must be started and advertised');
   initialContext=result(results,'close-context');if(!initialContext)return emitMany(body,res,[{id:'close-context',name:'host.get_current_context',arguments:{}},{id:'close-sessions',name:'host.list_sessions',arguments:{limit:16}}]);
   const inventory=result(results,'close-sessions');assert(inventory);assert.equal(inventory.sessions.length,1);initialSession=inventory.sessions[0];assert.equal(initialSession.ready,true);
   const group=result(results,'close-create-group');if(!group)return emit(body,res,'close-create-group','host.create_group',{initial_session_ref:initialSession.session_ref,name:'Normal close acceptance',request_key:key+'-normal-close-group'});
   assert.equal(group.state,'committed');assert.equal(group.same_conversation_id,initialContext.conversation_id);
   groupContext=result(results,'close-context-after-group');if(!groupContext)return emit(body,res,'close-context-after-group','host.get_current_context',{});
   assert.equal(groupContext.binding_ref,group.group_ref);assert.equal(groupContext.conversation_id,initialContext.conversation_id);assert.equal(groupContext.task_id,initialContext.task_id);
   return finish(res,stage);
  }
  if(stage==='LIFE'){
   initialContext=result(results,'life-context-1');if(!initialContext)return emitMany(body,res,[{id:'life-context-1',name:'host.get_current_context',arguments:{}},{id:'life-sessions-1',name:'host.list_sessions',arguments:{limit:16}}]);
   assert(initialContext.binding_ref.startsWith('s1:'));assert.equal(initialContext.initial_kind,'session');assert.equal(initialContext.execution_mode,'auto');
   const inventory=result(results,'life-sessions-1');if(!inventory)return emit(body,res,'life-sessions-1','host.list_sessions',{limit:16});
   assert.equal(inventory.sessions.length,1);initialSession=inventory.sessions[0];assert.equal(initialSession.session_ref,initialContext.binding_ref);assert.equal(initialSession.ready,true);assert.equal(initialSession.task_owned,false);
   const group=result(results,'life-create-group');if(!group)return emit(body,res,'life-create-group','host.create_group',{initial_session_ref:initialSession.session_ref,name:'Execution acceptance',request_key:key+'-group'});
   assert(group.group_ref.startsWith('g1:'));assert.equal(group.same_conversation_id,initialContext.conversation_id);assert.equal(group.initial_member,initialSession.session_id);
   groupContext=result(results,'life-context-2');if(!groupContext)return emit(body,res,'life-context-2','host.get_current_context',{});
   assert.equal(groupContext.conversation_id,initialContext.conversation_id);assert.equal(groupContext.task_id,initialContext.task_id);assert.equal(groupContext.binding_ref,group.group_ref);assert(groupContext.binding_revision>initialContext.binding_revision);
   const opened=result(results,'life-open');if(!opened)return emit(body,res,'life-open','host.open_session',{group_ref:groupContext.binding_ref,source_ref:initialSession.session_ref,connection_policy:'new_only',retention:'ask',request_key:key+'-open'});
   assert.equal(opened.ownership,'created_task');assert.equal(opened.retention,'ask');assert(opened.session_ref&&opened.operation_ref);assert.notEqual(opened.session_ref,initialSession.session_ref);
   const ready=result(results,'life-ready');if(!ready)return emit(body,res,'life-ready','host.wait_session_ready',{operation_ref:opened.operation_ref,after_revision:opened.source_revision,wait_ms:30000});
   assert.equal(ready.state,'ready');assert.equal(ready.membership_committed,true);assert.equal(ready.ownership,'created_task');
   ownedSession=ready;assert.equal(ownedSession.session_ref,opened.session_ref);
   const run=result(results,'life-run');if(!run)return emit(body,res,'life-run','host.run_in_terminal',{session_ref:ownedSession.session_ref,command,request_key:key+'-run'});
   assert(run.execution_ref);executionRef=run.execution_ref;
   let state=result(results,'life-wait');if(!state)return emit(body,res,'life-wait','host.wait_execution',{execution_ref:executionRef,after_revision:run.source_revision,wait_ms:30000,max_bytes:8192});
   for(let i=1;state.state!=='interval_recorded'&&i<30;i++){
    assert(!['cancelled_unsent','outcome_unknown','handed_off','recording_degraded'].includes(state.state),JSON.stringify(state));
    const id='life-wait-'+i,next=result(results,id);if(!next)return emit(body,res,id,'host.wait_execution',{execution_ref:executionRef,after_revision:state.source_revision,wait_ms:30000,max_bytes:8192});state=next;
   }
   assertIntervalRecorded(state);recorded=state;assert.equal(await readFile(markerFile,'utf8'),marker+'\n','one native write only');
   return finish(res,stage);
  }
  const contextId=stage.toLowerCase()+'-context',context=result(results,contextId);
  if(!context)return emit(body,res,contextId,'host.get_current_context',{});
  assert.equal(context.conversation_id,initialContext.conversation_id);assert.notEqual(context.task_id,initialContext.task_id);assert.equal(context.binding_ref,groupContext.binding_ref);
  const listId=stage.toLowerCase()+'-sessions',inventory=result(results,listId);
  if(!inventory)return emit(body,res,listId,'host.list_sessions',{limit:16,state_filter:'ready'});
  assert.equal(inventory.sessions.length,1,'TaskFinish must close only the owned terminal');assert.equal(inventory.sessions[0].session_ref,initialSession.session_ref);assert.equal(inventory.sessions[0].ready,true);
  if(stage==='STOP')return emit(body,res,'stop-run','host.run_in_terminal',{session_ref:initialSession.session_ref,command:stopCommand,request_key:key+'-stop'});
  const old=result(results,'after-old-execution',false);if(!old)return emit(body,res,'after-old-execution','host.get_execution',{execution_ref:executionRef,max_bytes:1024});
  assertHostRejected(results.get('after-old-execution'),'ExecutionNotFound');
  assert.equal(await exists(stopFile),false);assert.equal(await readFile(markerFile,'utf8'),marker+'\n');return finish(res,stage);
 }catch(error){if(takeoverOnly){if(error instanceof AcceptanceFailure)recordFailure(error.category,error.phase,error.message,error.evidence);else recordFailure('verification','provider-fixture-assertion',String(error),{active_call:activeCall})}fixtureFailure??=String(error);await writeFile(join(out,'fixture-failure.txt'),fixtureFailure);if(!res.headersSent)res.writeHead(500);res.end()}
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="execution-lifecycle-fixture"\npermission_mode="confirm"\nexecution_mode="${negativeOnly?'new_pty':'auto'}"\nsession_retention="ask"\n[[ai.providers]]\nid="execution-lifecycle-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="execution-lifecycle-fixture"\ncontext_window=200000\ndefault=true\n[log]\nring_mb=1\ncheckpoint_sec=1\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const binarySha256=createHash('sha256').update(await readFile(binary)).digest('hex');
if(process.env.ZW_AI_TEST_EXPECTED_SHA256)assert.equal(binarySha256,process.env.ZW_AI_TEST_EXPECTED_SHA256,'candidate binary differs from the explicitly delivered build');
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1',ZDOTDIR:zdot,OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
let appClosedAt:number|null=null;const ended=new Promise<void>(done=>app.once('close',()=>{appClosedAt=performance.now();done()}));
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join('');
// Query-node text is bounded to 200 UTF-8 bytes by Zenit's serializer. Native
// copy actions below verify complete approval details separately from previews.
const queryText=(value:string)=>Buffer.from(value).subarray(0,200).toString('utf8');
const controlledPane=(id:number)=>h.waitFor(async()=>{
 const pane=(await h.query('groups.pane.'+id)).find(shown);if(!pane)return null;const nodes=flat(pane),surface=nodes.find((node:any)=>node.test_id==='terminal.surface'&&shown(node)),tag=nodes.find((node:any)=>node.test_id==='terminal.ai_control'&&shown(node)),title=nodes.find((node:any)=>node.test_id==='terminal.ai_control.title'&&shown(node)),button=nodes.find((node:any)=>node.test_id==='terminal.ai_control.takeover'&&shown(node));return surface&&tag&&title&&button?{pane,surface,tag,title,button}:null;
},15000);
const cardNode=(card:any,id:string)=>flat(card).find((node:any)=>node.test_id===id&&shown(node));
const executionCard=(commandMarker:string,reference:string,id?:string,expectedSummary?:string)=>h.waitFor(async()=>{
 const roots=id?await h.query(id):flat(await h.query('ai.panel')).filter((node:any)=>/^ai\.tool\.result\.\d+\./.test(node.test_id??''));
 const command=Object.values(takeoverCommands).find(value=>value.includes(commandMarker));
 return roots.find((card:any)=>shown(card)&&(command?text(cardNode(card,'ai.execution.result.command'))===queryText(command):text(cardNode(card,'ai.execution.result.command')).includes(commandMarker))&&text(cardNode(card,'ai.execution.result.execution_id')).includes(reference)&&(!expectedSummary||text(cardNode(card,'ai.execution.result.summary')).includes(expectedSummary)))??null;
},15000);
const executionCardFacts=(card:any)=>({id:card.test_id,output_scope:text(cardNode(card,'ai.execution.result.output_scope')),output_attribution:text(cardNode(card,'ai.execution.result.output_attribution')),output_attribution_reason:text(cardNode(card,'ai.execution.result.output_attribution_reason')),output_limit:text(cardNode(card,'ai.execution.result.output_limit')),output_label:text(cardNode(card,'ai.execution.result.output_label')),summary:text(cardNode(card,'ai.execution.result.summary')),command:text(cardNode(card,'ai.execution.result.command')),execution_id:text(cardNode(card,'ai.execution.result.execution_id')),target:text(cardNode(card,'ai.execution.result.target')),process:cardNode(card,'ai.execution.result.process')?text(cardNode(card,'ai.execution.result.process')):null,output:text(cardNode(card,'ai.execution.result.terminal_output')),recording_id:text(cardNode(card,'ai.execution.result.recording_id')),stop:!!cardNode(card,'ai.execution.result.stop'),takeover:!!cardNode(card,'ai.execution.result.takeover'),view_terminal:!!cardNode(card,'ai.execution.result.view_terminal'),copy_recording:!!cardNode(card,'ai.execution.result.copy_recording'),copy_output:!!cardNode(card,'ai.execution.result.copy_output')});
const revealCardAction=async(id:string,action:string)=>{
 for(let attempt=0;attempt<10;attempt++){
  const viewport=(await h.query('ai.conversation.viewport')).find(shown),card=(await h.query(id)).find(shown),node=cardNode(card,action);if(!viewport||!card||!node)throw new AcceptanceFailure('query_contract','card-action',`missing ${id} / ${action}`);
  if(node.rect.y>=viewport.rect.y+2&&node.rect.y+node.rect.h<=viewport.rect.y+viewport.rect.h-2)return{card,node};
  const delta=Math.max(-600,Math.min(600,viewport.rect.y+viewport.rect.h/2-node.rect.y-node.rect.h/2));assert((await h.scrollAt(viewport.rect.x+viewport.rect.w-4,viewport.rect.y+viewport.rect.h/2,0,delta)).ok);await h.sleep(100);
 }
 throw new AcceptanceFailure('verification','card-action',`could not reveal ${id} / ${action} in the real conversation viewport`);
};
const copyNative=async(node:any,label:string)=>{
 if(!node)throw new AcceptanceFailure('query_contract','native-copy',`missing visible ${label} action`);
 assert((await h.clickAt(node.rect.x+node.rect.w/2,node.rect.y+node.rect.h/2)).ok,label);
 return(await promisify(execFile)('/usr/bin/pbpaste',[],{encoding:'utf8'})).stdout;
};
const assertIntervalCardScope=(facts:any,snapshot?:any)=>{
 assert(facts.output_scope.startsWith('同一终端观测片段 · '),'card must identify its observed PTY interval');
 assert(facts.output_label.includes('同一终端观测片段'));
 assert(facts.output_limit.includes('仅覆盖本次观测区间')&&facts.output_limit.includes('其他程序')&&facts.output_limit.includes('后台输出可能在前台结束后继续'),'card must state the interval/output limits');
 const attribution:any={unverified:'输出归属未确认',no_concurrent_owner_observed:'未观察到并发写入 · 输出归属未确认',concurrent_observed:'观察到并发写入 · 输出可能混有其他程序内容'};
 assert(Object.values(attribution).includes(facts.output_attribution));
 if(snapshot){assert.equal(facts.output_attribution,attribution[snapshot.output_attribution]);assert.equal(facts.output_scope,snapshot.interval_saved?'同一终端观测片段 · 已保存':'同一终端观测片段 · 保存待确认')}
 assert(!/完整输出|输出完整|记录已封存/.test([facts.summary,facts.output_label,facts.output_scope,facts.output_limit].join(' ')),'an observed interval must not claim exact complete output');
};
const visible=(id:string)=>h.waitFor(async()=>{assert.equal(fixtureFailure,null);return(await h.query(id)).find(shown)??null},20000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,15000);
const click=async(id:string)=>{report.last_action=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
const capture=async(name:string)=>{await h.mouseMove(1,1);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify({panel:await h.query('ai.panel'),group:await h.query('groups.workspace'),tabs:await h.query('tabs.strip')},null,2))};
const send=async(stage:string)=>{activeCall=null;finalEmitted=false;await click('ai.prompt');await h.key('a',{cmd:true});await h.type_(`[E-${stage}] 验收本次真实本机任务，仅按明确审批执行。`);await click('ai.send')};
const traceEvents=async()=>{
 const events:any[]=[];for(const line of(await readFile(join(out,'app.log'),'utf8')).split('\n')){
  const start=line.indexOf('AI_TOOL_TRACE ');if(start<0)continue;try{events.push(JSON.parse(line.slice(start+14)))}catch{}
 }return events;
};
const report:any={status:'running',binary,binary_sha256:binarySha256,started_at:new Date().toISOString(),checks:[],limits:['The local HTTP fixture supplies deterministic provider tool calls; all session, terminal, approval, lifecycle and recording results come from the real application.','Local uses its supported new_only policy. Real SSH reuse is a separate acceptance.','Initial discovery is batched; intermediate wait revisions require another genuine provider round and remain subject to the production tool-round budget.','Harness input, the normal owned-window close route and Metal screenshots cover the native window; physical keyboard, IME, VoiceOver and SSH are outside this case.']};
report.mode=takeoverOnly?'precise_takeover_only':negativeOnly?'execution_rejections_only':closeOnly?'normal_close_only':'full_execution_lifecycle';
async function normalClose(){
 await click(takeoverOnly?'ai.collapse':'ai.close');const windows=await h.request('POST','/zerowork/windows',{action:'snapshot'});assert.equal(windows.windows.length,1);
 const closingAt=performance.now(),route=takeoverOnly?'POST /quit':'POST /zerowork/windows close';
 assert((takeoverOnly?await h.request('POST','/quit'):await h.request('POST','/zerowork/windows',{action:'close',window:windows.windows[0].window})).ok);
 report.close_confirmations=[];let closingRpcUnavailable=false;
 while(app.exitCode===null&&app.signalCode===null&&performance.now()-closingAt<15000){
  // The final native window can unbind before its process exit notification.
  if(closingRpcUnavailable){await Promise.race([ended,h.sleep(80)]);continue}
  try{
   for(const id of ['groups.close.accept','local.close.accept','session.close.accept']){
    if(app.exitCode!==null||app.signalCode!==null)break;
    const queried=await h.query(id);if(!Array.isArray(queried)){report.close_rpc_after_unbind={id,response:queried};closingRpcUnavailable=true;break}
    if(queried.some(shown)){
     report.close_confirmations.push(id);
     if(report.close_confirmations.length===1){assert((await h.screenshot(join(out,'08-normal-window-close-confirmation.png'))).ok);await writeFile(join(out,'08-normal-window-close-confirmation.json'),JSON.stringify({group:await h.query('groups.close.confirm'),local:await h.query('local.close.confirmation'),session:await h.query('session.close.confirm')},null,2))}
     await click(id);
    }
   }
  }catch(error){if(app.exitCode===null&&app.signalCode===null){report.close_rpc_after_unbind={error:String(error)};closingRpcUnavailable=true}}
  if(app.exitCode===null&&app.signalCode===null)await h.sleep(80);
 }
 await Promise.race([ended,h.sleep(500)]);assert.equal(app.exitCode,0,'normal window close must exit without hanging');assert.equal(app.signalCode,null);
 report.normal_app_close={route,exit_code:app.exitCode,signal:app.signalCode,elapsed_ms:(appClosedAt??performance.now())-closingAt};
 report.checks.push(`${route} confirms remaining real Sessions as required, drains Driver and exits with code 0, no signal and no hang`);
}
try{acceptance:{
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.maximize');
 if(takeoverOnly){
  await send('TAKEOVER');const approved=new Set<string>(),startedAt=performance.now();
  const allowed=['takeover-group','takeover-open-a','takeover-open-b','takeover-run-a','takeover-run-b','takeover-fresh-a'];
  while(!finalEmitted&&performance.now()-startedAt<120000){
   assert.equal(fixtureFailure,null);assert.equal(takeoverUnexpectedProviderClose,false,'taking one Session must not cancel the provider');
   const recovery=(await h.query('ai.recovery')).find(shown);if(recovery)throw new AcceptanceFailure('product','provider-continuity',`provider failed: ${text(recovery)}`);
   if((await h.query('ai.host_approval')).some(shown)&&activeCall&&allowed.includes(activeCall.id)){
    if(!approved.has(activeCall.id)){
     if(activeCall.name==='host.run_in_terminal'){
      const expected=activeCall.arguments.command.replaceAll('\r\n','\n');
      const preview=text(await visible('ai.host_approval.summary'));if(preview!==queryText(expected))throw new AcceptanceFailure('query_contract','approval-preview','approval preview differs from its documented 200-byte query representation',{preview,expected:queryText(expected)});
      assert.equal(text(await visible('ai.host_approval.target')),activeCall.arguments.session_ref);
      await click('ai.host_approval.copy');const complete=(await promisify(execFile)('/usr/bin/pbpaste',[],{encoding:'utf8'})).stdout;
      if(complete!==expected)throw new AcceptanceFailure('product','approval-copy','the real pending approval copy must preserve the complete normalized command',{complete,expected});
      takeoverState.approval_commands??=[];takeoverState.approval_commands.push({call_id:activeCall.id,session_ref:activeCall.arguments.session_ref,preview:queryText(expected),complete});
     }
     if(activeCall.id==='takeover-fresh-a'){assert(takeoverState.user_input_sent);assert.equal(await exists(takeoverFiles.freshA),false);await capture('takeover-05-fresh-same-session-approval')}
     approved.add(activeCall.id);await click('ai.host_approval.accept');
    }
   }
   if(takeoverHeld?.kind==='before_handoff'){
    if(await exists(takeoverFiles.readyA)&&await exists(takeoverFiles.readyB)){
     releaseTakeover('before_handoff',[{id:'takeover-active-a',name:'host.get_execution',arguments:{execution_ref:takeoverState.execution_a,max_bytes:8192}},{id:'takeover-active-b',name:'host.get_execution',arguments:{execution_ref:takeoverState.execution_b,max_bytes:8192}}]);
    }else if(performance.now()-takeoverHeld.at>15000){
     takeoverState.readiness_timeout=true;takeoverState.pending_failure={category:'product',phase:'active-marker-readiness',reason:'both real execution readiness markers did not appear before the deadline',evidence:{a_ready:await exists(takeoverFiles.readyA),b_ready:await exists(takeoverFiles.readyB)}};
     releaseTakeover('before_handoff',[{id:'takeover-diagnostic-a',name:'host.get_execution',arguments:{execution_ref:takeoverState.execution_a,max_bytes:8192}},{id:'takeover-diagnostic-b',name:'host.get_execution',arguments:{execution_ref:takeoverState.execution_b,max_bytes:8192}}]);
    }
   }
   if(takeoverHeld?.kind==='diagnostic_failure')throw new AcceptanceFailure('product',takeoverState.primary_failure.phase,takeoverState.primary_failure.reason,takeoverState.failure_snapshots);
   if(takeoverHeld?.kind==='active_confirmed'){
     await visible('ai.stop');const initialCardA=await executionCard(takeoverMarkerA,takeoverState.execution_a),initialCardB=await executionCard(takeoverMarkerB,takeoverState.execution_b);takeoverState.ui_card_ids={a:initialCardA.test_id,b:initialCardB.test_id};takeoverState.ui_cards_initial=[executionCardFacts(initialCardA),executionCardFacts(initialCardB)];for(const card of takeoverState.ui_cards_initial){assert(card.summary.includes('最近观测')&&card.summary.includes('运行中'));assertIntervalCardScope(card);assert(!card.summary.includes('已完成'));assert(!card.process?.includes('退出码'))}await click('ai.collapse');
     const a=takeoverState.session_a.session_id,b=takeoverState.session_b.session_id;assert.notEqual(a,b);
     const paneA=await controlledPane(a),paneB=await controlledPane(b);takeoverState.control_tags_before=[];
     for(const[id,pane]of[[a,paneA],[b,paneB]]as const){const right=pane.surface.rect.x+pane.surface.rect.w-pane.tag.rect.x-pane.tag.rect.w,bottom=pane.surface.rect.y+pane.surface.rect.h-pane.tag.rect.y-pane.tag.rect.h;assert(Math.abs(pane.tag.rect.h-28)<=.5);assert(Math.abs(right-12)<=.5);assert(Math.abs(bottom-10)<=.5);assert.equal(text(pane.title),'AI 控制 • 只读');takeoverState.control_tags_before.push({session_id:id,surface:pane.surface.rect,tag:pane.tag.rect,right,bottom,title:text(pane.title),button:pane.button.rect})}
     await capture('takeover-01-two-real-executions-active');await click('toolbar.ai');await visible('ai.stop');
     await click('ai.task_finish.takeover');await visible('ai.task_finish.takeover.target.'+a);await visible('ai.task_finish.takeover.target.'+b);takeoverState.target_menu=[a,b];await capture('takeover-02-exact-target-menu');await click('ai.task_finish.takeover.target.'+a);
     const notice=text(await visible('ai.host_notice.body'));assert(notice.includes('你已接管终端'));assert(notice.includes(takeoverState.session_a.title));assert(notice.includes('命令')&&notice.includes('AI')&&notice.includes('重新申请权限'));takeoverState.native_notice=notice;
     await visible('ai.stop');takeoverState.provider_active_after_handoff=true;await capture('takeover-03-original-task-host-notice');
     releaseTakeover('active_confirmed',[{id:'takeover-handed-a',name:'host.get_execution',arguments:{execution_ref:takeoverState.execution_a,max_bytes:8192}},{id:'takeover-untouched-b',name:'host.get_execution',arguments:{execution_ref:takeoverState.execution_b,max_bytes:8192}}]);
   }
   if(takeoverHeld?.kind==='before_user_input'){
    assert(takeoverHandoffObserved);assert.equal(takeoverState.user_input_sent,false);await visible('ai.stop');
    const observedCardA=executionCardFacts(await executionCard(takeoverMarkerA,takeoverState.execution_a,takeoverState.ui_card_ids.a,'用户已接管')),observedCardB=executionCardFacts(await executionCard(takeoverMarkerB,takeoverState.execution_b,takeoverState.ui_card_ids.b,'运行中'));assertIntervalCardScope(observedCardA,takeoverState.handoff_snapshot.snapshot);assertIntervalCardScope(observedCardB,takeoverState.untouched_snapshot.snapshot);assert.equal(observedCardA.command,queryText(takeoverCommands.a));assert(observedCardA.summary.includes('命令继续运行'));assert(!observedCardA.stop&&!observedCardA.takeover);assert(!observedCardA.process?.includes('退出码'));assert(observedCardB.stop&&observedCardB.takeover);takeoverState.ui_cards_after_handoff=[observedCardA,observedCardB];await capture('takeover-03a-original-run-card-updated');await click('ai.collapse');
    await h.waitFor(async()=>{const pane=(await h.query('groups.pane.'+takeoverState.session_a.session_id)).find(shown);return pane&&!flat(pane).some((node:any)=>node.test_id==='terminal.ai_control'&&shown(node))||null},15000);const stillControlled=await controlledPane(takeoverState.session_b.session_id);takeoverState.control_tags_after={a_visible:false,b_tag:stillControlled.tag.rect};await capture('takeover-04a-one-pane-released-other-controlled');
    const pane=await visible('groups.pane.'+takeoverState.session_a.session_id),surface=flat(pane).find((node:any)=>node.test_id==='terminal.surface'&&shown(node));assert(surface,'the exact handed-off pane must own its real terminal surface');
    assert(surface.rect.x>=pane.rect.x-.5&&surface.rect.y>=pane.rect.y-.5&&surface.rect.x+surface.rect.w<=pane.rect.x+pane.rect.w+.5&&surface.rect.y+surface.rect.h<=pane.rect.y+pane.rect.h+.5);
    assert((await h.clickAt(surface.rect.x+surface.rect.w/2,surface.rect.y+surface.rect.h/2)).ok);assert((await h.type_(takeoverInput)).ok);assert((await h.key('return')).ok);takeoverState.user_input_sent=true;
    await h.waitFor(async()=>{try{return await readFile(takeoverFiles.doneA,'utf8')===takeoverInput+'\n'||null}catch{return null}},15000);
    await click('toolbar.ai');await visible('ai.stop');assert(text(await visible('ai.host_notice.body')).includes(takeoverState.native_notice));await capture('takeover-04-read-ended-by-normal-user-input');
    releaseTakeover('before_user_input',[{id:'takeover-finished-a',name:'host.get_execution',arguments:{execution_ref:takeoverState.execution_a,max_bytes:8192}}]);
   }
   if(takeoverHeld?.kind==='fresh_output'){
    const written=await exists(takeoverFiles.freshA);
    if(written||performance.now()-takeoverHeld.at>15000){
     if(written)assert.equal(await readFile(takeoverFiles.freshA,'utf8'),takeoverFreshMarker+'\n');else{takeoverState.fresh_output_timeout=true;takeoverState.pending_failure={category:'product',phase:'fresh-command-output',reason:'approved fresh command did not create its real result file',evidence:{}};releaseTakeover('fresh_output',[{id:'takeover-diagnostic-fresh-a',name:'host.get_execution',arguments:{execution_ref:takeoverState.fresh_execution_a,max_bytes:8192}},{id:'takeover-diagnostic-b',name:'host.get_execution',arguments:{execution_ref:takeoverState.execution_b,max_bytes:8192}}]);continue}
     assert(approved.has('takeover-fresh-a'));await writeFile(takeoverFiles.releaseB,'release after fresh A result');takeoverState.b_released=true;
     releaseTakeover('fresh_output',[{id:'takeover-final-a-0',name:'host.get_execution',arguments:{execution_ref:takeoverState.fresh_execution_a,max_bytes:8192}},{id:'takeover-final-b-0',name:'host.get_execution',arguments:{execution_ref:takeoverState.execution_b,max_bytes:8192}},{id:'takeover-original-a-again',name:'host.get_execution',arguments:{execution_ref:takeoverState.execution_a,max_bytes:8192}}]);
    }
   }
   if(!finalEmitted)await h.sleep(80);
  }
  assert(finalEmitted,'takeover acceptance timed out without a final provider answer');assert.equal(fixtureFailure,null);assert.equal(takeoverUnexpectedProviderClose,false);assert.deepEqual([...approved],allowed);await absent('ai.stop');await visible('ai.turn.complete');
  assert.equal(await readFile(takeoverFiles.doneA,'utf8'),takeoverInput+'\n');assert.equal(await readFile(takeoverFiles.freshA,'utf8'),takeoverFreshMarker+'\n');assert(takeoverState.b_released);assert(takeoverState.notices.some((notice:any)=>takeoverState.native_notice.includes(notice.text)||notice.text.includes(takeoverState.native_notice)));
  const events=await traceEvents(),identities=events.filter((event:any)=>event.event==='request_identity');assert.equal(identities.length,1,'handoff keeps the same original provider Task');assert(!events.some((event:any)=>event.event==='conversation_rollback'));
  for(const call of emitted.values())assert.equal(events.filter((event:any)=>event.event==='tool_feedback'&&event.call_id===call.id).length,1,call.id);
  for(const observation of observations.values()){const receipt=observation.envelope.receipt;assert.equal(receipt.conversation_id,initialContext.conversation_id);assert.equal(receipt.task_id,initialContext.task_id)}
  const journal=JSON.parse(await readFile(join(data,'ai/lifecycle.json'),'utf8'));const runs=journal.records.filter((record:any)=>record.tool_id==='host.run_in_terminal');assert.equal(runs.length,3);for(const run of runs){assert.equal(run.stage,'succeeded');assert.equal(run.execution_receipt.sealed,false);assert.equal(run.execution_receipt.interval_saved,true);assert.equal(run.execution_receipt.output_scope,'session_interval');assert.equal(run.remote_effect_unknown,false)}assert.equal(runs.find((run:any)=>run.original_call==='takeover-run-a').execution_receipt.input_handed_off,true);
  await writeFile(join(out,'lifecycle-journal.json'),JSON.stringify(journal,null,2));const manifests:any[]=[];
  for(const path of await readdir(data,{recursive:true}))if(String(path).endsWith('.json'))try{const document=JSON.parse(await readFile(join(data,String(path)),'utf8'));if(document.execution_ranges?.some((range:any)=>['x1:'+range.execution_id].some(ref=>[takeoverState.execution_a,takeoverState.execution_b,takeoverState.fresh_execution_a].includes(ref))))manifests.push({path:String(path),document})}catch{}
  for(const snapshot of[takeoverState.finished_original_a.snapshot,takeoverState.finished_b.snapshot,takeoverState.finished_fresh_a.snapshot]){
   const matching=manifests.filter(item=>item.document.execution_ranges.some((range:any)=>range.execution_id===snapshot.execution_id));assert.equal(matching.length,1,'one real manifest must own each execution interval');const document=matching[0].document,range=document.execution_ranges.find((range:any)=>range.execution_id===snapshot.execution_id),receipt=runs.find((run:any)=>run.execution_receipt.execution_id===snapshot.execution_id)?.execution_receipt;assert(receipt,'journal must retain the same original execution identity');
   assert.equal(range.sealed,false);assert.equal(range.interval_saved,true);assert.equal(range.output_scope,'session_interval');assert.equal(range.completion_evidence,'foreground_finished');assert.equal(range.recording_generation,snapshot.recording_generation);assert.equal(document.recording_id,Array.isArray(snapshot.recording_id)?Buffer.from(snapshot.recording_id).toString('utf8'):snapshot.recording_id);assert(document.manifest_revision>=snapshot.manifest_revision);
   assert.deepEqual(range.start,{raw_offset:snapshot.start.raw_offset,event_sequence:snapshot.start.event_sequence});assert.deepEqual(range.end,{raw_offset:snapshot.end.raw_offset,event_sequence:snapshot.end.event_sequence});assert.equal(range.start_boundary_sequence,snapshot.start.sequence);assert.equal(range.end_boundary_sequence,snapshot.end.sequence);assert.deepEqual(range.process_receipt,snapshot.process);assert.equal(range.output_attribution,snapshot.output_attribution);assert.equal(range.output_attribution_reason,snapshot.output_attribution_reason);
   for(const field of['command_hash','accepted_sequence','submit_sequence','submit_ack_sequence','submit_native_bytes','native_wake_written','recording_id','recording_generation','start','end','manifest_revision','process','recording_settled','recording_failed','output_scope','output_attribution','output_attribution_reason','interval_saved','input_handed_off','local_released','remote_effect_unknown'])assert.deepEqual(receipt[field],snapshot[field],`journal/snapshot ${snapshot.execution_id} ${field}`);
  }
  await writeFile(join(out,'takeover-recording-manifests.json'),JSON.stringify(manifests,null,2));takeoverState.provider_requests=requests.length;report.takeover=takeoverState;
  const finalCards=[{marker:takeoverMarkerA,reference:takeoverState.execution_a,id:takeoverState.ui_card_ids.a,command:takeoverCommands.a,session:takeoverState.session_a.session_id,snapshot:takeoverState.finished_original_a.snapshot},{marker:takeoverMarkerB,reference:takeoverState.execution_b,id:takeoverState.ui_card_ids.b,command:takeoverCommands.b,session:takeoverState.session_b.session_id,snapshot:takeoverState.finished_b.snapshot},{marker:takeoverFreshMarker,reference:takeoverState.fresh_execution_a,id:undefined,command:takeoverCommands.fresh,session:takeoverState.session_a.session_id,snapshot:takeoverState.finished_fresh_a.snapshot}];takeoverState.ui_cards_final=[];
  for(const expected of finalCards){const card=await executionCard(expected.marker,expected.reference,expected.id,'前台已结束 · 观测片段已保存'),facts=executionCardFacts(card);assertIntervalCardScope(facts,expected.snapshot);assert.equal(facts.command,queryText(expected.command));assert(facts.target.endsWith('#'+expected.session));assert(facts.process?.includes('前台已结束 · 退出码 0'));const revealed=await revealCardAction(card.test_id,'ai.execution.result.copy_output');const complete_output=await copyNative(revealed.node,'saved interval output copy');assert(complete_output.includes(expected.marker),'the real native copy must expose the marker beyond the bounded query preview');Object.assign(facts,{complete_output});const recording=Array.isArray(expected.snapshot.recording_id)?Buffer.from(expected.snapshot.recording_id).toString('utf8'):expected.snapshot.recording_id;assert(facts.recording_id.includes(recording));assert(!facts.stop&&!facts.takeover);assert(facts.view_terminal&&facts.copy_recording&&facts.copy_output);takeoverState.ui_cards_final.push(facts);await capture('takeover-06-final-interval-'+expected.reference.slice(3,11))}
  report.checks.push('A real same-Task Local builtin read and a second Local zselect loop run under independent approved execution grants','Native multi-target takeover selects only Session A: its input_handed_off/input_ready/local_released become true while Session B keeps its original live AI grant and running foreground','The original provider stream survives handoff, receives the host input_handoff notice in the original CID/Task, continues real get_execution calls and eventually emits final text','Normal terminal surface input ends the original builtin read; its original execution remains observable through true foreground exit, END and a durably saved same-PTY interval','A fresh exact approval runs another command in the same handed-off Session; the old execution keeps its saved interval and original identity and the new grant clears input_handed_off','All three original executions finish naturally with real saved PTY intervals, without stop_execution, provider cancellation, command replay or guard bypass');
  report.checks.push('The exact original run cards preserve command and execution identity while real get/wait results update the active handoff state, remove only A controls and retain B controls; only true foreground-finished interval receipts render exit 0, output and the real recording ID');
  assert.equal((await h.query('groups.pane.title')).filter(shown).length,3,'all real sessions remain until explicit normal close');await capture('takeover-06-final-same-task-and-recorded-intervals');await normalClose();report.status='passed_takeover_only';break acceptance;
 }
 if(negativeOnly){
  await send('NEGATIVE');
  await h.waitFor(async()=>{
   if(fixtureFailure||finalEmitted)return true;
   const recovery=(await h.query('ai.recovery')).find(shown);if(recovery){report.native_failure=text(recovery);return true}
   for(const id of ['ai.approval','ai.host_approval'])if((await h.query(id)).some(shown)){report.unexpected_approval=id;return true}
   return null;
  },30000);
  assert.equal(fixtureFailure,null);assert.equal(report.unexpected_approval,undefined,'fixed-mode denial must not request approval');assert(finalEmitted,report.native_failure);await absent('ai.stop');await visible('ai.turn.complete');
  assert.equal(await exists(stopFile),false);assert.equal(await exists(markerFile),false);
  const events=await traceEvents();assert(!events.some(event=>event.event==='exec_started'));
  const denied=events.filter(event=>event.event==='dynamic_rejected'&&event.call_id==='negative-legacy-run');assert.equal(denied.length,1);assert.equal(denied[0].reason,'ModeConflict');assert.equal(denied[0].dispatched,false);
  assert(![...emitted.values()].some(call=>call.name==='host.run_in_terminal'));report.rejections={legacy:observations.get('negative-legacy-run'),unknown_execution:observations.get('negative-unknown-execution')};
  report.checks.push('The real new_pty catalog discovers the current Local session ID; legacy run_command returns ModeConflict before approval or dispatch, with no exec_started and no marker file','Unknown x1 get_execution returns a structured rejected ExecutionNotFound with the same CID/Task, side_effect_started=false, local_released=true and remote_effect_unknown=false; the provider can continue to final text');
  await capture('negative-only-rejections');await normalClose();report.status='passed_negative_only';break acceptance;
 }
 if(closeOnly){
  await send('CLOSE');let approved=false;
  await h.waitFor(async()=>{
   if(fixtureFailure||finalEmitted)return true;
   const recovery=(await h.query('ai.recovery')).find(shown);if(recovery){report.native_failure=text(recovery);return true}
   if(!approved&&(await h.query('ai.host_approval')).some(shown)){assert.equal(activeCall?.id,'close-create-group');approved=true;await click('ai.host_approval.accept')}
   return null;
  },30000);
  assert.equal(fixtureFailure,null);assert(finalEmitted);assert(approved);await absent('ai.stop');await visible('ai.turn.complete');
  const journal=JSON.parse(await readFile(join(data,'ai/lifecycle.json'),'utf8'));const record=journal.records.find((r:any)=>r.original_call==='close-create-group');assert(record);assert.equal(record.stage,'succeeded');assert.equal(record.wire_notice_revision,record.notice_revision);assert.equal(record.local_released,true);assert.equal(record.remote_effect_unknown,false);assert.equal(record.context.conversation_id,initialContext.conversation_id);
  assert(![...emitted.values()].some(call=>call.name==='host.run_in_terminal'));
  await writeFile(join(out,'lifecycle-journal.json'),JSON.stringify(journal,null,2));await capture('close-only-ai-task-settled');
  report.checks.push('A real Local and completed AI lifecycle Task start the production Driver, advertise its execution catalog and persist a committed group operation in the real Journal','The close-only acceptance does not invoke terminal execution or weaken any execution/recording assertion');
  await normalClose();report.status='passed_close_only';break acceptance;
 }
 await send('LIFE');
 const approved=new Set<string>();
 await h.waitFor(async()=>{
  if(fixtureFailure||finalEmitted)return true;
  const recovery=(await h.query('ai.recovery')).find(shown);if(recovery){report.native_failure=text(recovery);return true}
  if((await h.query('ai.host_approval')).some(shown)){
   assert(activeCall);if(approved.has(activeCall.id))return null;
   const summary=text(await visible('ai.host_approval.summary'));
   assert.equal(await exists(markerFile),false,'command must have zero writes before its approval');
   if(activeCall.name==='host.run_in_terminal'){
    assert.equal(activeCall.id,'life-run');assert.equal(summary,normalizedCommand,'approval must show normalized command');
    assert.equal(text(await visible('ai.host_approval.title')),'执行命令');await capture('03-command-pending-zero-write');
   }else{assert(['life-create-group','life-open'].includes(activeCall.id),activeCall.id);await capture(activeCall.id==='life-create-group'?'01-group-pending':'02-owned-session-pending')}
   approved.add(activeCall.id);await click('ai.host_approval.accept');
  }return null;
 },90000);
 assert.equal(fixtureFailure,null);assert(finalEmitted,`native task failed before final text: ${report.native_failure??'unknown'}`);assert.deepEqual([...approved],['life-create-group','life-open','life-run']);await absent('ai.stop');await visible('ai.turn.complete');await visible('ai.task_finish.close');
 assert.equal(text(await visible('ai.task_finish.title')),'任务已结束');assert.equal((await h.query('groups.pane.title')).filter(shown).length,2);await capture('04-interval-recorded-task-finish-ask');
 await click('ai.task_finish.close');
 await h.waitFor(async()=>{
  if((await h.query('session.close.accept')).some(shown))await click('session.close.accept');
  if((await h.query('local.close.accept')).some(shown))await click('local.close.accept');
  return text((await h.query('ai.task_finish.title')).find(shown)).includes('已清理任务会话')||null;
 },20000);
 await h.waitFor(async()=>(await h.query('groups.pane.title')).filter(shown).length===1||null,10000);await capture('05-owned-closed-borrowed-retained');
 report.checks.push('Production discovery returns real scoped s1 refs; single-to-group handoff keeps ConversationId/TaskId and advances binding revision','Supported Local new_only creates a task-owned ready terminal in the group','Exact normalized CRLF command approval precedes all native writes, with original provider wire arguments and call IDs preserved','Actual Local private protocol confirms accepted/native-written/submit-ack/END/foreground exit and a durably saved same-PTY interval','TaskFinish ask closes only the owned terminal; the original borrowed terminal and group remain');
 // Persist independent disk evidence before the temporary application data is removed.
 const journal=JSON.parse(await readFile(join(data,'ai/lifecycle.json'),'utf8'));await writeFile(join(out,'lifecycle-journal.json'),JSON.stringify(journal,null,2));
 const runRecord=journal.records.find((r:any)=>r.original_call==='life-run');assert(runRecord);assert.equal(runRecord.stage,'succeeded');assert.equal(runRecord.execution_receipt.sealed,false);assert.equal(runRecord.execution_receipt.interval_saved,true);assert.equal(runRecord.execution_receipt.output_scope,'session_interval');assert.equal(runRecord.execution_receipt.recording_settled,true);assert.equal(journal.records.filter((r:any)=>r.tool_id==='host.run_in_terminal'&&r.execution).length,1);
 const files=await readdir(data,{recursive:true});let matchingManifest:any=null;
 for(const file of files){if(!String(file).endsWith('.json'))continue;try{const doc=JSON.parse(await readFile(join(data,String(file)),'utf8'));if(doc.execution_ranges?.some((r:any)=>'x1:'+r.execution_id===executionRef)){matchingManifest={path:String(file),document:doc};break}}catch{}}
 assert(matchingManifest,'the execution must have its real recording manifest');
 const range=matchingManifest.document.execution_ranges.find((r:any)=>'x1:'+r.execution_id===executionRef);assert.equal(range.sealed,false);assert.equal(range.interval_saved,true);assert.equal(range.output_scope,'session_interval');assert.equal(range.completion_evidence,'foreground_finished');assert(range.end&&range.end.raw_offset>=range.start.raw_offset);await writeFile(join(out,'execution-recording-manifest.json'),JSON.stringify(matchingManifest,null,2));
 await send('STOP');await visible('ai.host_approval');assert.equal(activeCall?.id,'stop-run');assert.equal(text(await visible('ai.host_approval.summary')),stopCommand);assert.equal(await exists(stopFile),false);await capture('06-stop-before-dispatch');
 const stopStart=performance.now();await click('ai.stop');await absent('ai.host_approval');await absent('ai.stop');
 const cancelled=await h.waitFor(async()=>(await traceEvents()).find((event:any)=>event.event==='tool_feedback'&&event.call_id==='stop-run')??null,15000);
 const envelope=JSON.parse(cancelled.content);assert.equal(envelope.error_code,'CancelledBeforeDispatch');assert.equal(envelope.receipt?.side_effect_started??envelope.side_effect_started,false);assert.equal(envelope.receipt?.local_released??envelope.local_released,true);assert.equal(envelope.receipt?.remote_effect_unknown??envelope.remote_effect_unknown,false);
 assert(!requests.some(r=>r.stage==='STOP'&&r.results.some((r:any)=>r.id==='stop-run')),'Stop must not request another provider round');report.stop={elapsed_ms:performance.now()-stopStart,envelope};
 await send('AFTER');await h.waitFor(async()=>{assert.equal(fixtureFailure,null);return finalEmitted||null},30000);await absent('ai.stop');await capture('07-next-task-old-execution-fenced');
 assert.equal(await exists(stopFile),false);assert.equal(await readFile(markerFile,'utf8'),marker+'\n');
 const events=await traceEvents(),feedback=events.filter((event:any)=>event.event==='tool_feedback');
 for(const call of emitted.values()){
  const first=feedback.find((event:any)=>event.call_id===call.id);assert(first,`${call.id} must have production feedback`);
  assert.equal(feedback.filter((event:any)=>event.call_id===call.id&&event.turn_id===first.turn_id).length,1,`${call.id} must settle once in its original turn`);
 }
 for(const[id,observation]of observations)if(id.startsWith('life-')){
  const receipt=observation.envelope.receipt??observation.envelope;
  assert.equal(receipt.conversation_id,initialContext.conversation_id);assert.equal(receipt.task_id,initialContext.task_id);
 }
 report.checks.push('Durable journal retains one successful original run and its interval-saved native receipt; the real recording manifest has one foreground_finished execution interval','Stop on a fresh pending terminal approval returns original-call CancelledBeforeDispatch and no writes/provider continuation','A later Task keeps the same ConversationId/group and borrowed terminal, rejects the old execution_ref and never replays the stopped command','Every fixture call settles once in its original turn with production tool_feedback; all lifecycle/execution receipts keep the original CID/Task and every provider followup contains complete original wire tool-call/result pairs');
 report.primary_execution_lifecycle_passed=true;report.marker=marker;report.execution=recorded;report.disk_execution_range=range;report.approved_calls=[...approved];
 await normalClose();
 report.status='passed';
}}catch(error){report.status='failed';report.error=String(error);report.fixture_failure=fixtureFailure;if(takeoverOnly){if(error instanceof AcceptanceFailure)recordFailure(error.category,error.phase,error.message,error.evidence);else recordFailure('verification','native-acceptance',String(error),{last_action:report.last_action});report.primary_failure=takeoverState.primary_failure}process.exitCode=1;await capture('failure').catch(()=>{});await writeFile(join(out,'failure-tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{})}
finally{
 takeoverTeardown=true;if(takeoverHeld){takeoverHeld.res.destroy();takeoverHeld=null}
 report.requests=requests;report.emitted=[...emitted.values()];report.observations=Object.fromEntries(observations);
 if(takeoverOnly){await writeFile(join(out,'raw-execution-snapshots.json'),JSON.stringify({observations:Object.fromEntries(observations),diagnostic:takeoverState.failure_snapshots??null},null,2));await writeFile(join(out,'provider-wire.json'),JSON.stringify(requests,null,2));takeoverState.provider_stream_aborted=takeoverUnexpectedProviderClose;takeoverState.files={};for(const[name,path]of Object.entries(takeoverFiles))try{takeoverState.files[name]=await readFile(path,'utf8')}catch{takeoverState.files[name]=null}report.takeover=takeoverState}
 const rawLog=await readFile(join(out,'app.log'),'utf8');report.native_errors=rawLog.split('\n').filter(line=>line.includes('ai worker turn failed:'));
 if(!report.status.startsWith('passed'))try{await writeFile(join(out,'diagnostic-lifecycle-journal.json'),await readFile(join(data,'ai/lifecycle.json')))}catch{}
 let forced=false;if(app.exitCode===null&&app.signalCode===null){forced=true;app.kill('SIGTERM')}await Promise.race([ended,h.sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}report.cleanup={exit_code:app.exitCode,signal:app.signalCode,forced};if(forced&&report.status.startsWith('passed')){report.status='failed';report.error='normal app close was not achieved; signal fallback is cleanup only';process.exitCode=1}server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();
 const preserveIsolation=takeoverOnly||!report.status.startsWith('passed');report.isolation={directory:iso,preserved:preserveIsolation,data,rpc,zdot};
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));if(!preserveIsolation)await rm(iso,{recursive:true,force:true});
}
console.log(JSON.stringify({status:report.status,error:report.error,report:join(out,'report.json')}));
