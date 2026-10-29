/** Main App acceptance for explicit Local input helpers. Only provider output
 * is a fixture: original calls traverse the real Bridge, Driver, approval,
 * private PTY, native AppKit secret collector and recording/journal paths.
 *
 * Allocate one native slot and use the exact candidate delivered by root:
 * ZW_AI_TEST_PREFIX=/tmp/zw-patch-main-native \
 * ZW_AI_TEST_EXPECTED_SHA256=<delivered sha256> \
 * node e2e/ai_execution_input_native.ts /tmp/zw-ai-input-native-evidence
 *
 * The SECRET stage first emits ZW_NATIVE_SECRET_PREPARED, writes
 * collector-prepared.json and holds the original provider response before
 * opening AppKit. Bind CUA to the exact app, then write collector-armed.json
 * containing {run_id:"<prepared run_id>",cua_bound:true}. When Metal main-window
 * AX binding times out but the exact independent app identity/path is known,
 * use {run_id:"<prepared run_id>",cua_bound:false,bind_on_collector:true}; CUA
 * must still bind the real small collector before any input/evidence. It emits
 * ZW_NATIVE_SECRET_COLLECTOR_READY and writes collector-waiting.json. Use one
 * CUA call to type the agreed synthetic string and submit within its 60 s life.
 * Do not use harness type_, pasteboard, a secret-dump API or real credentials.
 * Save CUA metadata (without the string) to native-cua-evidence.json:
 * {run_id:"<waiting run_id>",observed_with_cua:true,window_title:"安全输入",
 *  field_label:"本次宿主安全输入",secure_field_observed:true,
 *  synthetic_input_only:true,submitted:true,screenshot_ref:"...",
 *  visual_verified:false,screenshot_status:"white_capture_unavailable",
 *  visual_limitation:"CUA captured a white image; collector pixels unverified"}
 * Use visual_verified:true/screenshot_status:"captured_masked"/field_masked:true
 * only when the real collector's masked pixels were actually inspected.
 */
import assert from 'node:assert/strict';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash,randomBytes} from 'node:crypto';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,readdir,open,realpath,access,stat} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-patch-main-native');
const binary=resolve(process.env.ZW_AI_TEST_BINARY??join(prefix,'bin/zerowork'));
const binarySha256=createHash('sha256').update(await readFile(binary)).digest('hex');
assert(process.env.ZW_AI_TEST_EXPECTED_SHA256,'root must provide the delivered candidate hash before native acceptance');assert.equal(binarySha256,process.env.ZW_AI_TEST_EXPECTED_SHA256,'candidate differs from root-delivered binary');
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-ai-input-native-evidence');await mkdir(out,{recursive:true});
// This is a public, fixed test vector, never a credential. It is used only for
// negative leak scans; it is never passed into the App's environment or tools.
const syntheticSecret='ZW_SYNTHETIC_NOT_A_CREDENTIAL_20261030';
const iso=await realpath(await mkdtemp('/tmp/zw-ai-input-native-'));
const data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
await Promise.all([mkdir(data),mkdir(rpc),mkdir(zdot)]);
await writeFile(join(zdot,'.zshrc'),`bindkey -e\nPS1='input-test%# '\nHISTFILE='${join(zdot,'history')}'\nHISTSIZE=100\nSAVEHIST=100\ncd '${iso}'\n`);
const shellVersion=(await promisify(execFile)('/bin/zsh',['-fc','print -r -- $ZSH_VERSION'],{encoding:'utf8'})).stdout.trim();
assert.equal(shellVersion,'5.9','this acceptance targets the shipped Local zsh 5.9 ABI');
const token=randomBytes(8).toString('hex'),requestKey='native-input-'+token;
const textA='ordinary-'+token+'-',textB='line',userInput='USER_TAKEOVER_'+token;
const paths={inputReady:join(iso,'input-ready'),inputDone:join(iso,'input-line'),takeoverReady:join(iso,'takeover-ready'),takeoverDone:join(iso,'takeover-line'),secretReady:join(iso,'secret-ready'),secretDone:join(iso,'secret-consumed'),version:join(iso,'local-zsh-version')};
const markers={INPUT:'ZW_INPUT_DONE_'+token,TAKEOVER:'ZW_TAKEOVER_DONE_'+token,SECRET:'ZW_SECRET_CONSUMED_'+token};
const commands={
 INPUT:`printf '%s\\n' "$ZSH_VERSION" > '${paths.version}'; printf ready > '${paths.inputReady}'; zerowork_read && { printf '%s\\n' "$REPLY" > '${paths.inputDone}'; printf '%s\\n' '${markers.INPUT}'; }`,
 TAKEOVER:`printf ready > '${paths.takeoverReady}'; zerowork_read && { printf '%s\\n' "$REPLY" > '${paths.takeoverDone}'; printf '%s\\n' '${markers.TAKEOVER}'; }`,
 SECRET:`printf ready > '${paths.secretReady}'; zerowork_secret_consume && { printf consumed > '${paths.secretDone}'; printf '%s\\n' '${markers.SECRET}'; }`,
};
type Stage=keyof typeof commands;
type Call={id:string,name:string,wire:string,arguments:any};
const emitted=new Map<string,Call>(),observations=new Map<string,any>(),requests:any[]=[];
const states:Record<Stage,any>={INPUT:{},TAKEOVER:{},SECRET:{}};
let fixtureFailure:string|null=null,activeCall:Call|null=null,finalEmitted=false,quitting=false;
let held:any=null,unexpectedProviderClose=false,currentStage:Stage|null=null;
const exists=async(path:string)=>{try{await access(path);return true}catch{return false}};
const payload=(envelope:any)=>{for(const block of envelope.content??[])if(block.type==='structured'||block.type==='text'){try{return JSON.parse(block.text)}catch{}}return envelope};
const wireName=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const result=(results:Map<string,any>,id:string)=>{
 const envelope=results.get(id);if(!envelope)return null;
 assert.equal(envelope.status,'succeeded',`${id}: ${JSON.stringify(envelope)}`);const body=payload(envelope);
 if(body.snapshot)assert(!['cancelled_unsent','outcome_unknown','recording_degraded'].includes(body.state),`${id}: ${JSON.stringify(body)}`);
 observations.set(id,{envelope,body});return body;
};
const emitMany=(body:any,res:any,calls:{id:string,name:string,arguments:any}[])=>{
 const tool_calls=calls.map(({id,name,arguments:args},index)=>{
  const wire=wireName(name);assert(body.tools?.some((tool:any)=>tool.function.name===wire),`production catalog lacks ${wire}`);
  assert(!emitted.has(id),'fixture may issue each original call ID exactly once');
  const call={id,name,wire,arguments:args};emitted.set(id,call);activeCall=call;
  return{index,id,type:'function',function:{name:wire,arguments:JSON.stringify(args)}};
 });res.end(frame({tool_calls})+'data: [DONE]\n\n');
};
const emit=(body:any,res:any,id:string,name:string,args:any)=>emitMany(body,res,[{id,name,arguments:args}]);
const hold=(body:any,res:any,kind:string)=>{
 assert.equal(held,null);activeCall=null;held={body,res,kind,at:performance.now()};
 res.write(frame({content:'继续观察本次真实终端状态。'}));
 held.heartbeat=setInterval(()=>{if(!res.writableEnded)res.write(': fixture waiting for native input\n\n')},5000);
 res.once('close',()=>{if(!res.writableEnded&&!quitting)unexpectedProviderClose=true});
};
const release=(kind:string,calls:{id:string,name:string,arguments:any}[])=>{assert.equal(held?.kind,kind);const pending=held;clearInterval(pending.heartbeat);held=null;emitMany(pending.body,pending.res,calls)};
const finish=(res:any,stage:Stage)=>{activeCall=null;finalEmitted=true;res.end(frame({content:`[NATIVE-${stage}] 已核验本次真实输入与终端结果。`})+'data: [DONE]\n\n')};
const get=(id:string,reference:string)=>({id,name:'host.get_execution',arguments:{execution_ref:reference,max_bytes:8192}});
const assertRunning=(body:any,kind?:string)=>{
 assert.equal(body.state,'running');const s=body.snapshot;assert.equal(s.submit_sent,true);assert(s.submit_native_bytes>0);assert.equal(s.process?.foreground_finished??false,false);
 if(kind){assert.equal(s.input_wait?.kind,kind);assert(s.input_wait.sequence>0);assert(s.grant);assert.equal(s.input_handed_off,false);assert.equal(s.local_released,false)}
};
const assertConsumed=(body:any,kind:string,sequence?:number,waitSequence?:number,bytes?:number)=>{
 const receipt=body.input_receipt??body.snapshot?.input_receipt;assert(receipt);assert.equal(receipt.kind,kind);assert.equal(receipt.stage,'consumed');
 if(sequence!==undefined)assert.equal(receipt.input_sequence,sequence);if(waitSequence!==undefined)assert.equal(receipt.wait_sequence,waitSequence);if(bytes!==undefined)assert.equal(receipt.accepted_bytes,bytes);return receipt;
};
const assertRecorded=(body:any,stage:Stage)=>{
 const s=body.snapshot;assert.equal(body.state,'interval_recorded');assert.equal(s.state,'interval_recorded');assert.equal(s.output_scope,'session_interval');assert.equal(s.interval_saved,true);
 assert.equal(body.execution_ref,'x1:'+s.execution_id);assert.equal(s.command_accepted,true);assert.equal(s.submit_sent,true);assert(s.submit_native_bytes>0);assert.equal(s.native_wake_written,true);
 assert(s.accepted_sequence>0&&s.submit_sequence>0&&s.submit_ack_sequence>0);assert(s.start&&s.end&&s.end.sequence>s.start.sequence&&s.end.event_sequence>s.start.event_sequence);
 assert.equal(s.process.foreground_finished,true);assert.equal(s.process.exit_code,0);assert.equal(s.process.signal,null);assert.equal(s.recording_settled,true);assert.equal(s.recording_failed,false);assert(s.recording_id&&s.recording_generation>0&&s.manifest_revision>0);
 assert.equal(s.local_released,true);assert.equal(s.remote_effect_unknown,false);assert.equal(s.grant,null);assert(body.output.includes(markers[stage]));
 const bytes=typeof s.command_hash==='string'?[...Buffer.from(s.command_hash,'utf8')]:s.command_hash;assert.deepEqual(bytes,[...createHash('sha256').update(commands[stage]).digest()]);
};
// Observe a genuine result, then wait for at most three real revisions. A
// fixture timer or a disk marker never substitutes for a private PTY receipt.
const settle=(body:any,res:any,results:Map<string,any>,id:string,reference:string,predicate:(value:any)=>boolean)=>{
 let observation=result(results,id);if(!observation){emit(body,res,id,'host.get_execution',{execution_ref:reference,max_bytes:8192});return null}
 for(let attempt=1;!predicate(observation)&&attempt<=3;attempt++){
  const nextId=id+'-'+attempt,next=result(results,nextId);if(!next){emit(body,res,nextId,'host.wait_execution',{execution_ref:reference,after_revision:observation.source_revision,wait_ms:30000,max_bytes:8192});return null}observation=next;
 }assert(predicate(observation),`${id} never reached the required real receipt: ${JSON.stringify(observation)}`);return observation;
};
const validateWire=(body:any)=>{
 const pending=new Map<string,any>();
 for(const message of body.messages){
  if(message.role==='assistant')for(const call of message.tool_calls??[]){assert(!pending.has(call.id));pending.set(call.id,call)}
  if(message.role==='tool'){
   const call=pending.get(message.tool_call_id);assert(call,'orphan tool result');const original=emitted.get(call.id);assert(original,'result has no original provider call');
   assert.equal(call.function.name,original.wire);assert.deepEqual(JSON.parse(call.function.arguments),original.arguments,'original provider wire arguments changed');JSON.parse(message.content);pending.delete(call.id);
  }
 }assert.equal(pending.size,0,'all original calls need their real results before followup');
};
const server=createServer(async(req,res)=>{
 try{
  if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'input-native-fixture'}]}));return}
  let raw='';for await(const chunk of req)raw+=chunk;assert(!raw.includes(syntheticSecret),'synthetic secure input leaked into the provider request');
  const body=JSON.parse(raw);validateWire(body);
  const boundary=body.messages.findLastIndex((m:any)=>m.role==='user'&&/\[NATIVE-(INPUT|TAKEOVER|SECRET)\]/.test(String(m.content)));
  const stage=/\[NATIVE-(INPUT|TAKEOVER|SECRET)\]/.exec(String(body.messages[boundary]?.content??''))?.[1] as Stage;assert(stage);assert.equal(stage,currentStage);
  const current=body.messages.slice(boundary+1),results=new Map<string,any>(current.filter((m:any)=>m.role==='tool').map((m:any)=>[m.tool_call_id,JSON.parse(m.content)]));
  const notices=current.filter((m:any)=>m.role==='user').flatMap((m:any)=>{try{const value=JSON.parse(m.content);return value.input_handoffs??(value.host_input_handoff?[value]:[])}catch{return[]}});
  requests.push({at:new Date().toISOString(),stage,wire:body.messages,results:[...results].map(([id,envelope])=>({id,envelope})),host_notices:notices});
  res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
  const state=states[stage],base=stage.toLowerCase();
  const context=result(results,base+'-context'),inventory=result(results,base+'-sessions');
  if(!context||!inventory)return emitMany(body,res,[{id:base+'-context',name:'host.get_current_context',arguments:{}},{id:base+'-sessions',name:'host.list_sessions',arguments:{limit:16,state_filter:'ready'}}]);
  assert.equal(inventory.sessions.length,1);const session=inventory.sessions[0];assert.equal(session.ready,true);assert.equal(session.session_ref,context.binding_ref);assert.equal(session.task_owned,false);assert.equal(context.execution_mode,'auto');
  if(stage!=='INPUT'){assert.equal(context.conversation_id,states.INPUT.context.conversation_id);assert.notEqual(context.task_id,states.INPUT.context.task_id)}
  if(stage==='SECRET')assert.notEqual(context.task_id,states.TAKEOVER.context.task_id);
  Object.assign(state,{context,session});
  let facts:any;
  for(let attempt=0;attempt<3;attempt++){
   const id=base+'-capability'+(attempt?'-'+attempt:'');facts=result(results,id);
   if(!facts){if(attempt)await h.sleep(500);return emit(body,res,id,'host.get_session',{session_ref:session.session_ref})}
   assert.equal(facts.session.ready,true);assert(['ready','initializing','busy'].includes(facts.session.capabilities.trusted_pty_state),JSON.stringify(facts));
   if(facts.session.capabilities.trusted_pty_execution)break;assert(attempt<2,'private PTY never became ready during bounded read-only observations');
  }state.capability=facts.session.capabilities;
  const run=result(results,base+'-run');if(!run)return emit(body,res,base+'-run','host.run_in_terminal',{session_ref:session.session_ref,command:commands[stage],request_key:requestKey+'-'+base+'-run'});
  state.execution_ref=run.execution_ref;
  const firstWaiting=result(results,base+'-waiting');if(!firstWaiting)return hold(body,res,base+'-helper-ready');
  const waitKind=stage==='SECRET'?'host_secret':'controlled_line';
  const initial=settle(body,res,results,base+'-waiting',run.execution_ref,value=>value.state==='running'&&value.snapshot.input_wait?.kind===waitKind);if(!initial)return;
  assertRunning(initial,waitKind);state.initial=initial;
  if(stage==='INPUT'){
   const a=result(results,'input-text-a');if(!a)return emit(body,res,'input-text-a','host.send_execution_input',{execution_ref:run.execution_ref,request_key:requestKey+'-text-a',text:textA});
   const afterA=settle(body,res,results,'input-after-a',run.execution_ref,value=>value.snapshot.input_receipt?.stage==='consumed');if(!afterA)return;
   assertRunning(afterA,'controlled_line');const aReceipt=assertConsumed(afterA,'text',a.input_receipt.input_sequence,initial.snapshot.input_wait.sequence,Buffer.byteLength(textA));if(!state.after_a)assert.equal(await exists(paths.inputDone),false,'text alone must not submit the line');state.after_a=afterA;
   const repeated=result(results,'input-text-a-same-key');if(!repeated)return emit(body,res,'input-text-a-same-key','host.send_execution_input',{execution_ref:run.execution_ref,request_key:requestKey+'-text-a',text:textA});
   assertConsumed(repeated,'text',aReceipt.input_sequence,aReceipt.wait_sequence,Buffer.byteLength(textA));state.same_key=repeated;
   const b=result(results,'input-text-b');if(!b)return emit(body,res,'input-text-b','host.send_execution_input',{execution_ref:run.execution_ref,request_key:requestKey+'-text-b',text:textB});
   assert(b.input_receipt.input_sequence>aReceipt.input_sequence);
   const afterB=settle(body,res,results,'input-after-b',run.execution_ref,value=>value.snapshot.input_receipt?.stage==='consumed'&&value.snapshot.input_receipt?.input_sequence===b.input_receipt.input_sequence);if(!afterB)return;
   assertRunning(afterB,'controlled_line');assertConsumed(afterB,'text',b.input_receipt.input_sequence,aReceipt.wait_sequence,Buffer.byteLength(textB));if(!state.after_b)assert.equal(await exists(paths.inputDone),false,'second text still must not submit the line');state.after_b=afterB;
   const enter=result(results,'input-enter');if(!enter)return emit(body,res,'input-enter','host.send_execution_input',{execution_ref:run.execution_ref,request_key:requestKey+'-enter',key:'enter'});
   assert(enter.input_receipt.input_sequence>b.input_receipt.input_sequence);
   const done=settle(body,res,results,'input-finished',run.execution_ref,value=>value.state==='interval_recorded');if(!done)return;
   assertRecorded(done,stage);assertConsumed(done,'enter',enter.input_receipt.input_sequence,aReceipt.wait_sequence,0);assert.equal(await readFile(paths.inputDone,'utf8'),textA+textB+'\n','same key must not duplicate the consumed text');assert.equal(await readFile(paths.version,'utf8'),'5.9\n');state.finished=done;return finish(res,stage);
  }
  if(stage==='TAKEOVER'){
   const handed=result(results,'takeover-handed');if(!handed)return hold(body,res,'takeover-before-handoff');
   assertRunning(handed);assert.equal(handed.snapshot.input_handed_off,true);assert.equal(handed.snapshot.grant,null);assert.equal(handed.snapshot.local_released,true);assert.equal(handed.snapshot.input_ready,true);assert.equal(handed.execution_ref,run.execution_ref);assert.equal(handed.snapshot.execution_id,initial.snapshot.execution_id);state.handed=handed;
   const notice=notices.find((item:any)=>item.text?.includes('你已接管终端')&&(item.task_id??item.context?.task_id)===context.task_id);assert(notice,'the original provider Task needs the actual host handoff notice');state.host_notice=notice;
   const first=result(results,'takeover-finished');if(!first)return hold(body,res,'takeover-before-user-input');
   const done=settle(body,res,results,'takeover-finished',run.execution_ref,value=>value.state==='interval_recorded');if(!done)return;
   assertRecorded(done,stage);assert.equal(done.snapshot.input_handed_off,true);assert.equal(done.snapshot.execution_id,initial.snapshot.execution_id);assert.equal(await readFile(paths.takeoverDone,'utf8'),userInput+'\n');state.finished=done;return finish(res,stage);
  }
  const secret=result(results,'secret-request');if(!secret){
   if(!state.cua_armed){
    await writeFile(join(out,'collector-prepared.json'),JSON.stringify({status:'awaiting_cua_binding_before_collector',run_id:token,pid:app.pid,binary,binary_sha256:binarySha256,rpc,isolation:iso,execution_ref:run.execution_ref,arm_file:join(out,'collector-armed.json'),prepare_deadline_seconds:60},null,2));
    console.log('ZW_NATIVE_SECRET_PREPARED '+join(out,'collector-prepared.json'));return hold(body,res,'secret-awaiting-arm');
   }
   return emit(body,res,'secret-request','host.send_execution_input',{execution_ref:run.execution_ref,request_key:requestKey+'-secret',host_secret_request:true});
  }
  assert.equal(secret.host_secret_status,'awaiting_host_secret');assert.equal(secret.input_receipt.kind,'host_secret');assert.equal(secret.input_receipt.stage,'awaiting_host_secret');assert.equal(secret.input_receipt.accepted_bytes,0);assert.equal(secret.input_receipt.wait_sequence,initial.snapshot.input_wait.sequence);state.request=secret;
  const doneFirst=result(results,'secret-finished');if(!doneFirst){
   await writeFile(join(out,'collector-waiting.json'),JSON.stringify({status:'awaiting_native_cua_input',run_id:token,pid:app.pid,binary_sha256:binarySha256,rpc,isolation:iso,execution_ref:run.execution_ref,input_sequence:secret.input_receipt.input_sequence,wait_sequence:secret.input_receipt.wait_sequence,deadline_seconds:60,required_evidence:join(out,'native-cua-evidence.json')},null,2));
   console.log('ZW_NATIVE_SECRET_COLLECTOR_READY '+join(out,'collector-waiting.json'));return hold(body,res,'secret-awaiting-native-cua');
  }
  const done=settle(body,res,results,'secret-finished',run.execution_ref,value=>value.state==='interval_recorded');if(!done)return;
  assertRecorded(done,stage);assertConsumed(done,'host_secret',secret.input_receipt.input_sequence,secret.input_receipt.wait_sequence,0);assert.equal(done.snapshot.input_wait,null);assert.equal(await readFile(paths.secretDone,'utf8'),'consumed');state.finished=done;
  const repeated=result(results,'secret-same-key');if(!repeated)return emit(body,res,'secret-same-key','host.send_execution_input',{execution_ref:run.execution_ref,request_key:requestKey+'-secret',host_secret_request:true});
  assert.equal(repeated.host_secret_status,'secret_submitted');assertConsumed(repeated,'host_secret',secret.input_receipt.input_sequence,secret.input_receipt.wait_sequence,0);state.same_key=repeated;return finish(res,stage);
 }catch(error){fixtureFailure??=String(error);await writeFile(join(out,'fixture-failure.txt'),fixtureFailure);if(!res.headersSent)res.writeHead(500);res.end()}
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="input-native-fixture"\npermission_mode="confirm"\nexecution_mode="auto"\nsession_retention="ask"\n[[ai.providers]]\nid="input-native-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="input-native-fixture"\ncontext_window=200000\ndefault=true\n[log]\nring_mb=1\ncheckpoint_sec=1\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1',ZDOTDIR:zdot,OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
let appClosedAt:number|null=null;const ended=new Promise<void>(done=>app.once('close',()=>{appClosedAt=performance.now();done()}));
const report:any={status:'running',binary,binary_sha256:binarySha256,started_at:new Date().toISOString(),shell_version:shellVersion,checks:[],approvals:[],limits:['Only deterministic provider tool output is simulated; all host results, private PTY receipts, journal, recording and native windows are production paths.','The secret sink consumes and erases one synthetic test vector; this case does not claim authentication or arbitrary password/OTP input support.','Secret entry is an external CUA action on AppKit, never a Zenit harness text injection.','Three explicit stages use distinct Tasks in one conversation to remain inside the real production tool-round limit.']};
const shown=(node:any)=>node&&node.hidden!==true&&node.visible!==false&&(node.effective_opacity??1)>0&&node.rect?.w>0&&node.rect?.h>0;
const flat=(node:any):any[]=>Array.isArray(node)?node.flatMap(flat):node?[node,...(node.children??[]).flatMap(flat)]:[];
const text=(node:any)=>flat(node).map(n=>n.text??'').join('');
const queryText=(value:string)=>Buffer.from(value).subarray(0,200).toString('utf8');
const visible=(id:string)=>h.waitFor(async()=>{assert.equal(fixtureFailure,null);return(await h.query(id)).find(shown)??null},20000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,15000);
// Task-finish rows from earlier turns retain their test IDs while hidden.
// Click the actual visible node's measured bounds, not the first global ID.
const click=async(id:string)=>{report.last_action=id;const node=await visible(id);assert((await h.clickAt(node.rect.x+node.rect.w/2,node.rect.y+node.rect.h/2)).ok,id)};
const capture=async(name:string)=>{await h.mouseMove(1,1);assert((await h.screenshot(join(out,name+'.png'))).ok);const view={panel:await h.query('ai.panel'),terminal:await h.query('terminal.surface'),tabs:await h.query('tabs.strip')};assert(!JSON.stringify(view).includes(syntheticSecret),'secure input leaked to the Zenit query tree');await writeFile(join(out,name+'.json'),JSON.stringify(view,null,2))};
async function approvePending(approved:Set<string>){
 if(!(await h.query('ai.host_approval')).some(shown))return;assert(activeCall,'approval has no current provider call');if(approved.has(activeCall.id))return;
 const call=activeCall;assert(call.name==='host.run_in_terminal'||call.name==='host.send_execution_input');assert.equal(call.arguments.host_secret_request,undefined,'secret input must use its own real AppKit collector');
 const expected=call.arguments.command??call.arguments.text??'按下 Enter（提交已接收的当前行）';assert.equal(text(await visible('ai.host_approval.summary')),queryText(expected));assert.equal(text(await visible('ai.host_approval.target')),call.arguments.session_ref??call.arguments.execution_ref);
 if(call.name==='host.run_in_terminal'){
  const path=currentStage==='INPUT'?paths.inputReady:currentStage==='TAKEOVER'?paths.takeoverReady:paths.secretReady;assert.equal(await exists(path),false,'command has no effect before exact native approval');
  await click('ai.host_approval.copy');assert.equal((await promisify(execFile)('/usr/bin/pbpaste',[],{encoding:'utf8'})).stdout,expected,'full native approval copy changed the exact command');
 }else{
  assert.equal(await exists(paths.inputDone),false,'ordinary text and pending Enter must leave the helper waiting');const impact=text(await visible('ai.host_approval.impact'));assert(impact.includes('zerowork_read')&&impact.includes('等待序号')&&impact.includes('已接收输入序号'));
 }
 const record={call_id:call.id,name:call.name,summary:queryText(expected),target:call.arguments.session_ref??call.arguments.execution_ref,at:new Date().toISOString()};report.approvals.push(record);await capture(call.id+'-approval');approved.add(call.id);await click('ai.host_approval.accept');
}
async function normalQuit(){
 if(app.exitCode!==null||app.signalCode!==null)return;
 const started=performance.now();assert((await h.request('POST','/quit')).ok);report.close_confirmations=[];let unbound=false;
 while(app.exitCode===null&&app.signalCode===null&&performance.now()-started<15000){
  if(unbound){await Promise.race([ended,h.sleep(80)]);continue}
  try{for(const id of['groups.close.accept','local.close.accept','session.close.accept']){
   if(app.exitCode!==null||app.signalCode!==null)break;const found=await h.query(id);if(!Array.isArray(found)){unbound=true;break}if(found.some(shown)){report.close_confirmations.push(id);assert((await h.clickTestId(id)).ok,id)}
  }}catch{unbound=true}if(app.exitCode===null&&app.signalCode===null)await h.sleep(80);
 }await Promise.race([ended,h.sleep(500)]);assert.equal(app.exitCode,0,'normal Quit must exit with no hang');assert.equal(app.signalCode,null);report.normal_app_close={route:'POST /quit',exit_code:app.exitCode,signal:app.signalCode,elapsed_ms:(appClosedAt??performance.now())-started};
}
async function scanLeaks(){
 const checked:string[]=[],leaks:string[]=[];
 for(const root of[data,zdot,out])for(const relative of await readdir(root,{recursive:true})){
  const path=join(root,String(relative));if(!(await stat(path)).isFile())continue;const bytes=await readFile(path);checked.push(path);if(bytes.includes(Buffer.from(syntheticSecret)))leaks.push(path);
 }assert(!JSON.stringify(requests).includes(syntheticSecret));assert(!JSON.stringify([...emitted.values()]).includes(syntheticSecret));assert(!JSON.stringify([...observations.values()]).includes(syntheticSecret));
 assert.deepEqual(leaks,[],'synthetic secure input persisted outside its private native consumer');return{files_checked:checked.length,provider_requests_checked:requests.length,original_calls_checked:emitted.size,matches:leaks.length};
}
try{
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.maximize');
 for(const stage of['INPUT','TAKEOVER','SECRET'] as Stage[]){
  currentStage=stage;activeCall=null;finalEmitted=false;const approved=new Set<string>();
  await click('ai.prompt');await h.key('a',{cmd:true});await h.type_(`[NATIVE-${stage}] 验收受控本机输入，仅按明确审批执行。`);await click('ai.send');
  const started=performance.now();
  while(!finalEmitted&&performance.now()-started<120000){
   assert.equal(fixtureFailure,null);assert.equal(unexpectedProviderClose,false,'original provider stream must survive input handoff');
   const recovery=(await h.query('ai.recovery')).find(shown);assert(!recovery,`provider recovery: ${text(recovery)}`);await approvePending(approved);
   if(held?.kind===stage.toLowerCase()+'-helper-ready'){
    const path=stage==='INPUT'?paths.inputReady:stage==='TAKEOVER'?paths.takeoverReady:paths.secretReady;
    if(await exists(path)){await h.sleep(100);release(held.kind,[get(stage.toLowerCase()+'-waiting',states[stage].execution_ref)])}
    else assert(performance.now()-held.at<15000,'approved helper never started in the real PTY');
   }
   if(held?.kind==='takeover-before-handoff'){
    await visible('ai.stop');assert.equal(await exists(paths.takeoverDone),false);await capture('takeover-original-task-running');
    await click('ai.task_finish.takeover');const target='ai.task_finish.takeover.target.'+states.TAKEOVER.session.session_id;if((await h.query(target)).some(shown))await click(target);
    const notice=text(await visible('ai.host_notice.body'));assert(notice.includes('你已接管终端')&&notice.includes('不会中断 AI')&&notice.includes('重新申请权限'));states.TAKEOVER.native_notice=notice;await visible('ai.stop');await capture('takeover-same-task-host-notice');release('takeover-before-handoff',[get('takeover-handed',states.TAKEOVER.execution_ref)]);
   }
   if(held?.kind==='takeover-before-user-input'){
    await visible('ai.stop');assert.equal(await exists(paths.takeoverDone),false);await click('ai.collapse');await absent('terminal.ai_control');const surface=await visible('terminal.surface');
    assert((await h.clickAt(surface.rect.x+surface.rect.w/2,surface.rect.y+surface.rect.h/2)).ok);assert((await h.type_(userInput)).ok);assert((await h.key('return')).ok);
    await h.waitFor(async()=>{try{return await readFile(paths.takeoverDone,'utf8')===userInput+'\n'||null}catch{return null}},15000);await click('toolbar.ai');await visible('ai.stop');await capture('takeover-original-helper-ended-by-user');release('takeover-before-user-input',[get('takeover-finished',states.TAKEOVER.execution_ref)]);
   }
   if(held?.kind==='secret-awaiting-arm'){
    if(await exists(join(out,'collector-armed.json'))){const armed=JSON.parse(await readFile(join(out,'collector-armed.json'),'utf8'));assert.equal(armed.run_id,token);assert(armed.cua_bound===true||armed.cua_bound===false&&armed.bind_on_collector===true,'arming needs either a real bound app or explicit deferred binding to the collector');states.SECRET.cua_armed=true;states.SECRET.cua_arm_mode=armed.cua_bound?'bound_app':'bind_on_collector';release('secret-awaiting-arm',[{id:'secret-request',name:'host.send_execution_input',arguments:{execution_ref:states.SECRET.execution_ref,request_key:requestKey+'-secret',host_secret_request:true}}])}
    else assert(performance.now()-held.at<60000,'CUA was not bound and armed within the pre-collector preparation deadline');
   }
   if(held?.kind==='secret-awaiting-native-cua'){
    if(await exists(paths.secretDone))release('secret-awaiting-native-cua',[get('secret-finished',states.SECRET.execution_ref)]);
    else assert(performance.now()-held.at<65000,'native collector did not consume the CUA synthetic input within its lifetime');
   }
   if(!finalEmitted)await h.sleep(80);
  }
  assert(finalEmitted,`${stage} failed to reach final provider text`);assert.equal(fixtureFailure,null);await absent('ai.stop');await visible('ai.turn.complete');states[stage].approved=[...approved];
  for(const[id,observation]of observations)if(id.startsWith(stage.toLowerCase()+'-')){assert.equal(observation.envelope.receipt.conversation_id,states[stage].context.conversation_id);assert.equal(observation.envelope.receipt.task_id,states[stage].context.task_id)}
  await capture(stage.toLowerCase()+'-finished');
 }
 assert(states.INPUT.approved.includes('input-text-a')&&states.INPUT.approved.includes('input-text-b')&&states.INPUT.approved.includes('input-enter'),'each new ordinary input needs a separate native approval');
 // This is metadata coordination after the private consumer has finished;
 // it does not extend the production collector's fixed 60-second lifetime.
 await h.waitFor(async()=>await exists(join(out,'native-cua-evidence.json'))||null,60000);
 const cuaEvidence=JSON.parse(await readFile(join(out,'native-cua-evidence.json'),'utf8'));assert.equal(cuaEvidence.run_id,token,'CUA evidence must belong to this exact native run');for(const flag of['observed_with_cua','secure_field_observed','synthetic_input_only','submitted'])assert.equal(cuaEvidence[flag],true,`missing real CUA evidence: ${flag}`);assert.equal(cuaEvidence.window_title,'安全输入');assert.equal(cuaEvidence.field_label,'本次宿主安全输入');assert(cuaEvidence.screenshot_ref);assert(!JSON.stringify(cuaEvidence).includes(syntheticSecret));
 assert.equal(typeof cuaEvidence.visual_verified,'boolean');if(cuaEvidence.visual_verified){assert.equal(cuaEvidence.screenshot_status,'captured_masked');assert.equal(cuaEvidence.field_masked,true)}else{assert.equal(cuaEvidence.screenshot_status,'white_capture_unavailable');assert.equal(typeof cuaEvidence.visual_limitation,'string');assert(cuaEvidence.visual_limitation.length>0);report.limits.push(cuaEvidence.visual_limitation)}report.native_cua_evidence=cuaEvidence;
 await normalQuit();assert(report.normal_app_close,'successful acceptance requires the actual normal Quit route');
 const trace:any[]=[];for(const line of(await readFile(join(out,'app.log'),'utf8')).split('\n')){const start=line.indexOf('AI_TOOL_TRACE ');if(start>=0)try{trace.push(JSON.parse(line.slice(start+14)))}catch{}}
 const identities=trace.filter(event=>event.event==='request_identity');assert.equal(identities.length,3,'handoff must not create another Task');assert(!trace.some(event=>event.event==='conversation_rollback'));
 for(const call of emitted.values()){const first=trace.find(event=>event.event==='tool_feedback'&&event.call_id===call.id);assert(first,`${call.id} needs real production feedback`);assert.equal(trace.filter(event=>event.event==='tool_feedback'&&event.call_id===call.id&&event.turn_id===first.turn_id).length,1,`${call.id} must settle once in its original turn`)}
 const journal=JSON.parse(await readFile(join(data,'ai/lifecycle.json'),'utf8')),runs=journal.records.filter((record:any)=>record.tool_id==='host.run_in_terminal'),inputs=journal.records.filter((record:any)=>record.tool_id==='host.send_execution_input');assert.equal(runs.length,3);assert.equal(inputs.length,4,'same-key ordinary and secret calls must reuse their original operations');
 for(const stage of['INPUT','TAKEOVER','SECRET'] as Stage[]){const run=runs.find((record:any)=>record.original_call===stage.toLowerCase()+'-run');assert(run);assert.equal(run.stage,'succeeded');assert.equal(run.execution_receipt.execution_id,states[stage].finished.snapshot.execution_id);assert.equal(run.execution_receipt.interval_saved,true);assert.equal(run.execution_receipt.output_scope,'session_interval');assert.equal(run.remote_effect_unknown,false)}
 for(const id of['input-text-a','input-text-b','input-enter','secret-request']){const record=inputs.find((item:any)=>item.original_call===id);assert(record,id);assert.equal(record.stage,'succeeded');assert.equal(record.execution_receipt.input_receipt.stage,'consumed');assert.equal(record.remote_effect_unknown,false)}
 await writeFile(join(out,'lifecycle-journal.json'),JSON.stringify(journal,null,2));
 const manifests:any[]=[];for(const relative of await readdir(data,{recursive:true}))if(String(relative).endsWith('.json'))try{const document=JSON.parse(await readFile(join(data,String(relative)),'utf8'));if(document.execution_ranges?.some((range:any)=>Object.values(states).some(state=>state.execution_ref==='x1:'+range.execution_id)))manifests.push({path:String(relative),document})}catch{}
 for(const state of Object.values(states)){const s=state.finished.snapshot,matching=manifests.filter(item=>item.document.execution_ranges.some((range:any)=>range.execution_id===s.execution_id));assert.equal(matching.length,1);const range=matching[0].document.execution_ranges.find((item:any)=>item.execution_id===s.execution_id);assert.equal(range.interval_saved,true);assert.equal(range.completion_evidence,'foreground_finished');assert.deepEqual(range.start,{raw_offset:s.start.raw_offset,event_sequence:s.start.event_sequence});assert.deepEqual(range.end,{raw_offset:s.end.raw_offset,event_sequence:s.end.event_sequence});assert.deepEqual(range.process_receipt,s.process)}
 await writeFile(join(out,'recording-manifests.json'),JSON.stringify(manifests,null,2));report.leak_scan=await scanLeaks();
 report.checks.push('Two separately approved text fragments remain in one attested zerowork_read wait until a separately approved Enter consumes the exact concatenated line','A new original call with the same text request_key retains its original input_sequence and creates no repeated text or journal operation','Native user takeover preserves the original live provider Task and running command, delivers the real host notice, and ordinary terminal input finishes that same helper/execution naturally','A genuine AppKit secure collector accepts only the externally typed synthetic vector; its exact host_secret consumed receipt has accepted_bytes=0 and the fixed native sink completes naturally','Same-key secret retry returns secret_submitted with the original consumed sequence and no new journal operation','All three real PTY intervals are saved with true foreground exit 0, and normal Quit exits 0 without a signal','The synthetic secure vector is absent from provider wire, tool calls/results, Zenit queries, isolated history, journal, logs and every captured local evidence/data file');report.status=cuaEvidence.visual_verified?'passed':'passed_with_collector_visual_limit';
}catch(error){report.status='failed';report.error=String(error);report.active_call=activeCall;process.exitCode=1;try{await capture('failure')}catch{}
}finally{
 quitting=true;if(held){clearInterval(held.heartbeat);held.res.end('data: [DONE]\n\n');held=null}
 try{if(app.exitCode===null&&app.signalCode===null)await normalQuit()}catch(error){report.normal_quit_error=String(error)}
 await writeFile(join(out,'provider-requests.json'),JSON.stringify(requests,null,2));await writeFile(join(out,'original-calls-and-results.json'),JSON.stringify({calls:[...emitted.values()],results:[...observations].map(([id,observation])=>({id,...observation}))},null,2));
 if(report.status==='failed')try{await writeFile(join(out,'diagnostic-lifecycle-journal.json'),await readFile(join(data,'ai/lifecycle.json')))}catch{}
 try{report.final_leak_scan=await scanLeaks()}catch(error){report.status='failed';report.security_leak_failure=String(error);process.exitCode=1}
 report.states=states;report.isolation={directory:iso,data,rpc,zdot,preserved:true};report.cleanup={exit_code:app.exitCode,signal:app.signalCode,forced:false};
 if(app.exitCode===null&&app.signalCode===null){report.status='failed';report.error??='normal Quit did not close the App; native slot requires operator attention';process.exitCode=1;app.unref()}
 server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
 // Preserve isolated data for root's final review, including leak scans and
 // the actual private PTY recordings. No production state is ever modified.
}
console.log(JSON.stringify({status:report.status,error:report.error,report:join(out,'report.json')}));
