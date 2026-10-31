/** Real native handoff, window dismissal, owner switching and original wire-history retention. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath,readdir} from 'node:fs/promises';
import {join,resolve,dirname} from 'node:path';
const out=resolve(process.argv[2]??'/private/tmp/zw-ai-handoff-retention');
const binary=resolve(process.argv[3]??'/private/tmp/zw-handoff-retention-build/bin/zerowork');
const prefix=dirname(dirname(binary));
await mkdir(out,{recursive:true});
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const iso=await realpath(await mkdtemp('/private/tmp/zw-ai-handoff-retention-'));
const data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
const executionPidPath=join(iso,'foreground.pid'),executionSentinelPath=join(iso,'after-stop');
for(const path of[data,rpc,zdot])await mkdir(path);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='handoff-retention%# '\n");
const requests:any[]=[],calls:any[]=[],results:any={};
const report:any={status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),isolation:{iso,data,rpc,zdot},checks:[],approvals:[],limits:['Loopback only proposes provider calls; real native App, Local shell, host lifecycle, group and message retention are exercised.','One precisely approved Local sleep validates actual process stop/lease release; an unapproved sentinel command must never dispatch. Stop retains the existing conservative outcome_unknown receipt when exact completion is unavailable. No SSH, production App/configuration or reconstructed call.']};
const wire=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const payload=(envelope:any)=>{for(const block of envelope.content??[])try{return JSON.parse(block.text)}catch{}return envelope};
let initial:any,group:any,initialMessages:any[]=[],fixtureFailure:string|null=null,currentCall:string|null=null,originalDone=false,continuedDone=false,holdClosed=0,pendingOffered=false,runStarted=false,executionRef:string|null=null,verifiedStop=false;
function get(map:Map<string,any>,id:string,success=true){const envelope=map.get(id);if(!envelope)return null;const body=payload(envelope);results[id]={envelope,body};if(success)assert.equal(envelope.status,'succeeded',id+': '+JSON.stringify(envelope));return body}
function emit(body:any,res:any,id:string,name:string,args:any){assert(body.tools.some((tool:any)=>tool.function.name===wire(name)),name+' unavailable');assert(!calls.some(call=>call.id===id),'tool call must not be reconstructed/reissued');calls.push({id,name,args});currentCall=id;res.end(frame({tool_calls:[{index:0,id,type:'function',function:{name:wire(name),arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n')}
const server=createServer(async(req,res)=>{try{
 if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});return res.end(JSON.stringify({data:[{id:'fixture-default'},{id:'fixture-retained'}]}))}
 let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);requests.push(body);await writeFile(join(out,'provider-wire.json'),JSON.stringify(requests,null,2));
 res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
 const map=new Map<string,any>(body.messages.filter((message:any)=>message.role==='tool').map((message:any)=>[message.tool_call_id,JSON.parse(message.content)]));
 const question=[...body.messages].reverse().find((message:any)=>message.role==='user')?.content??'';
 assert.equal(body.model,'fixture-retained','explicit conversation model must survive handoff/dismiss/reopen');
 if(String(question).includes('HOLD_CLOSE_STREAM')){currentCall=null;res.on('close',()=>holdClosed++);res.write(frame({content:'HOLD_STREAM_PARTIAL'}));return;}
 if(String(question).includes('AWAIT_CLOSE_APPROVAL')){
  const cancelled=get(map,'retention-pending-close',false);
  if(!cancelled){pendingOffered=true;return emit(body,res,'retention-pending-close','host.run_in_terminal',{session_ref:initial.binding_ref,command:'printf SHOULD_NOT_DISPATCH_CLOSE',request_key:'retention-unapproved-close'});}
  currentCall=null;return res.end(frame({content:'PENDING_CALL_SETTLED'})+'data: [DONE]\n\n');
 }
 if(String(question).includes('RUN_CLOSE_EXECUTION')){
  const ran=get(map,'retention-run-close');if(!ran)return emit(body,res,'retention-run-close','host.run_in_terminal',{session_ref:initial.binding_ref,command:`sh -c 'printf "%s" "$$" > "${executionPidPath}"; exec sleep 30'; printf SHOULD_NOT_RUN_AFTER_CLOSE > "${executionSentinelPath}"`,request_key:'retention-active-close'});
  executionRef=ran.execution_ref;let accepted=ran;
  for(let attempt=0;!(accepted.snapshot?.command_accepted&&accepted.snapshot?.submit_sent)&&attempt<5;attempt++){
   const next=get(map,'retention-run-started-'+attempt);if(!next)return emit(body,res,'retention-run-started-'+attempt,'host.wait_execution',{execution_ref:executionRef,after_revision:accepted.source_revision,wait_ms:1000,max_bytes:4096});accepted=next;
  }
  assert(accepted.snapshot?.command_accepted&&accepted.snapshot?.submit_sent,'actual Local native submission/acceptance required before closing');runStarted=true;
  const waited=get(map,'retention-run-wait',false);if(!waited)return emit(body,res,'retention-run-wait','host.wait_execution',{execution_ref:executionRef,after_revision:ran.source_revision,wait_ms:30000,max_bytes:4096});
  currentCall=null;return res.end(frame({content:'RUN_CALL_SETTLED'})+'data: [DONE]\n\n');
 }
 if(String(question).includes('VERIFY_STOPPED_EXECUTION')){
  const context=get(map,'retention-stopped-context');if(!context)return emit(body,res,'retention-stopped-context','host.get_current_context',{});
  assert.equal(context.conversation_id,initial.conversation_id);assert.equal(context.binding_ref,group.group_ref);
  let observed:any=null;for(let attempt=0;attempt<6;attempt++){
   observed=get(map,'retention-stopped-execution-'+attempt,false);if(!observed)return emit(body,res,'retention-stopped-execution-'+attempt,'host.get_execution',{execution_ref:executionRef,max_bytes:4096});
   assert(['succeeded','outcome_unknown'].includes(map.get('retention-stopped-execution-'+attempt).status));
   if(observed.snapshot?.local_released&&observed.snapshot?.input_ready&&observed.snapshot?.grant==null&&['interval_recorded','sealed','recording_degraded','outcome_unknown'].includes(observed.state))break;
   if(attempt===5)assert.fail('Original Local execution did not release after confirmed close');await new Promise(done=>setTimeout(done,100));
  }
  assert(observed.snapshot.command_accepted&&observed.snapshot.submit_sent);assert.equal(observed.execution_ref,executionRef);assert(observed.snapshot.recording_settled);
  if(observed.state==='outcome_unknown'){assert.equal(observed.snapshot.failure,'Stopped');assert(observed.snapshot.remote_effect_unknown);assert.equal(observed.snapshot.process,null)}else assert(observed.snapshot.process&&observed.snapshot.process.exit_code!==0);
  report.stopped_execution=observed;verifiedStop=true;currentCall=null;return res.end(frame({content:'STOPPED_EXECUTION_VERIFIED'})+'data: [DONE]\n\n');
 }
 if(String(question).includes('CONTINUE_AFTER_REOPEN')){
  for(const original of initialMessages.filter((message:any)=>message.role==='tool'||message.tool_calls?.length)){
   const matches=body.messages.filter((message:any)=>original.role==='tool'?message.role==='tool'&&message.tool_call_id===original.tool_call_id:JSON.stringify(message.tool_calls)===JSON.stringify(original.tool_calls));
   assert.equal(matches.length,1,'original tool messages retained exactly once');assert.deepEqual(matches[0],original,'original wire message must remain unchanged');
  }
  assert(body.messages.some((message:any)=>message.role==='assistant'&&String(message.content).includes('ORIGINAL_HANDOFF_RESULT')));
  const after=get(map,'retention-next-context');if(!after)return emit(body,res,'retention-next-context','host.get_current_context',{});
  assert.equal(after.conversation_id,initial.conversation_id);assert.equal(after.binding_ref,group.group_ref);assert.notEqual(after.task_id,initial.task_id);
  continuedDone=true;currentCall=null;res.end(frame({content:'CONTINUE_AFTER_REOPEN_OK'})+'data: [DONE]\n\n');return;
 }
 initial=get(map,'retention-initial-context');if(!initial)return emit(body,res,'retention-initial-context','host.get_current_context',{});
 group=get(map,'retention-create-group');if(!group)return emit(body,res,'retention-create-group','host.create_group',{initial_session_ref:initial.binding_ref,name:'Handoff retention group',request_key:'handoff-retention-create'});
 const moved=get(map,'retention-group-context');if(!moved)return emit(body,res,'retention-group-context','host.get_current_context',{});
 assert.equal(moved.conversation_id,initial.conversation_id);assert.equal(moved.task_id,initial.task_id);assert.equal(moved.binding_ref,group.group_ref);
 const failed=get(map,'retention-failed-read',false);if(!failed)return emit(body,res,'retention-failed-read','host.get_session',{session_ref:initial.binding_ref.slice(0,initial.binding_ref.lastIndexOf(':')+1)+'999999'});
 assert.notEqual(map.get('retention-failed-read').status,'succeeded');assert.equal(failed.error_code??failed.code,'StaleReference');
 initialMessages=structuredClone(body.messages);originalDone=true;currentCall=null;res.end(frame({content:'ORIGINAL_HANDOFF_RESULT — exact original host calls and failed read retained.'})+'data: [DONE]\n\n');
}catch(error){fixtureFailure=String(error);if(!res.headersSent)res.writeHead(500);res.end()}});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ai]\ndefault_provider="retention-fixture"\npermission_mode="confirm"\nexecution_mode="auto"\nsession_retention="keep"\n[[ai.providers]]\nid="retention-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="fixture-default"\ncontext_window=500000\ndefault=true\n[[ai.providers.models]]\nname="fixture-retained"\ncontext_window=500000\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1',ZDOTDIR:zdot},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const alive=()=>app.exitCode===null&&app.signalCode===null;
const shown=(node:any)=>node&&node.hidden!==true&&node.visible!==false&&(node.effective_opacity??1)>0&&node.rect?.w>0&&node.rect?.h>0;
const flat=(node:any):any[]=>node?[node,...(node.children??[]).flatMap(flat)]:[];
const text=(node:any)=>flat(node).map((value:any)=>value.text??'').join('\n');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const hidden=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,15000);
const click=async(id:string)=>{report.last_action=id;const node=await visible(id);const clicked=await h.clickTestId(id);report.last_click={id,rect:node.rect,result:clicked};assert(clicked.ok,id)};
const capture=async(name:string)=>{await h.mouseMove(10,10);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify({panel:await h.query('ai.panel'),tabs:await h.query('tabs.strip'),confirmation:await h.query('ai.close.confirmation'),destructive_confirmation:await h.query('ai.session.close.confirmation')},null,2))};
async function settle(done:()=>boolean){const start=performance.now();while(!done()&&performance.now()-start<45000){assert.equal(fixtureFailure,null);if((await h.query('ai.host_approval')).some(shown)){assert(['retention-create-group','retention-run-close'].includes(currentCall!));report.approvals.push(currentCall);await click('ai.host_approval.accept')}await h.sleep(60)}assert.equal(fixtureFailure,null);assert(done());await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,15000);await visible('ai.turn.complete')}
async function dismiss(){await click('ai.close');await visible('ai.close.confirmation');await click('ai.close.confirmation.confirm');await h.mouseMove(20,300);await hidden('ai.panel');assert(!(await h.query('ai.session.close.confirmation')).some(shown),'window close must never use the destructive conversation dialog')}
async function reopen(){await click('toolbar.ai');await visible('ai.prompt');assert(text(await visible('ai.panel')).includes('ORIGINAL_HANDOFF_RESULT'));assert(text(await visible('ai.composer.model')).includes('fixture-retained'))}
async function quit(){const start=performance.now();const response=await h.request('POST','/quit');const confirmations:string[]=[];while(alive()&&performance.now()-start<20000){try{for(const id of['groups.close.accept','local.close.accept','session.close.accept'])if((await h.query(id)).some(shown)){confirmations.push(id);await h.clickTestId(id)}}catch{}if(alive())await Promise.race([ended,h.sleep(70)])}report.normal_quit={response,confirmations,exit_code:app.exitCode,signal:app.signalCode};assert.equal(app.exitCode,0);assert.equal(app.signalCode,null)}
try{
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1440,900);
 await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.composer.model');
 const model=await h.waitFor(async()=>(await h.query('ai.model.option')).find((node:any)=>shown(node)&&text(node).includes('fixture-retained'))??null,15000);await h.clickAt(model.rect.x+model.rect.w/2,model.rect.y+model.rect.h/2);
 await click('ai.prompt');await h.type_('ORIGINAL_HANDOFF_QUESTION: create a group from this current terminal, then inspect one stale generation without executing commands.');await click('ai.send');await settle(()=>originalDone);await capture('01-original-handoff');await click('ai.close');await visible('ai.close.confirmation');await capture('01b-completed-close-confirmation');await click('ai.close.confirmation.cancel');await visible('ai.prompt');assert(text(await visible('ai.panel')).includes('ORIGINAL_HANDOFF_RESULT'));
 const groupTab=flat((await h.query('groups.tab')).find(shown)).find((node:any)=>/^tabs\.tab\./.test(node.test_id??''));assert(groupTab);report.group_tab_id=groupTab.test_id;
 await dismiss();await reopen();await capture('02-close-reopen');report.checks.push('Completed AI window × hides presentation and preserves original real host-call transcript and explicit model.');
 await dismiss();await click('toolbar.new_session');await click('session.menu.local');await visible('terminal.surface');await click('toolbar.ai');await visible('ai.prompt');assert(!text(await visible('ai.panel')).includes('ORIGINAL_HANDOFF_RESULT'));await dismiss();
 await click(groupTab.test_id);await reopen();await click('ai.sessions');await visible('ai.session.jump.1');assert(text(await visible('ai.session.row.1')).includes('ORIGINAL_HANDOFF_QUESTION'));await capture('03-group-restored-in-list');await click('ai.sessions.close');
 report.checks.push('Switching to an independent real Local and back restores the group conversation with its listed original row, history and selected model.');
 await click('ai.prompt');await h.type_('CONTINUE_AFTER_REOPEN');await click('ai.send');await settle(()=>continuedDone);await capture('04-next-task-same-conversation');
 report.checks.push('Next Task has the same CID/group, a new TaskId, and every original tool-call/result wire message unchanged and present exactly once.');
 await click('ai.prompt');await h.type_('HOLD_CLOSE_STREAM');await click('ai.send');await h.waitFor(async()=>text(await visible('ai.panel')).includes('HOLD_STREAM_PARTIAL')||null,15000);
 await click('ai.close');await visible('ai.close.confirmation');assert(text(await visible('ai.close.confirmation.title')).includes('停止本轮'));assert.equal(holdClosed,0);await capture('05-running-close-confirmation');await click('ai.close.confirmation.cancel');await visible('ai.prompt');assert.equal(holdClosed,0);
 await click('ai.collapse');await h.mouseMove(20,300);await hidden('ai.panel');assert.equal(holdClosed,0,'collapse continues provider');await reopen();await dismiss();await h.waitFor(()=>holdClosed===1||null,15000);await reopen();await visible('ai.turn.complete');
 report.checks.push('Running × asks confirmation: cancel preserves provider/window, minus hides while provider continues, confirm cancels provider and hides while retaining the same conversation.');
 await click('ai.prompt');await h.type_('AWAIT_CLOSE_APPROVAL');await click('ai.send');await visible('ai.host_approval');assert(pendingOffered);await click('ai.close');await visible('ai.close.confirmation');await click('ai.close.confirmation.cancel');await visible('ai.host_approval');await dismiss();await reopen();await h.waitFor(async()=>!(await h.query('ai.host_approval')).some(shown)&&!(await h.query('ai.stop')).some(shown)||null,15000);await visible('ai.turn.complete');await capture('06-unapproved-call-stopped');
 report.checks.push('Confirmed close while an original host tool awaits approval cancels that call; cancel leaves the approval pending and no command is dispatched.');
 await click('ai.prompt');await h.type_('RUN_CLOSE_EXECUTION');await click('ai.send');const started=performance.now();while(!runStarted&&performance.now()-started<20000){assert.equal(fixtureFailure,null);if((await h.query('ai.host_approval')).some(shown)){assert.equal(currentCall,'retention-run-close');report.approvals.push(currentCall);await click('ai.host_approval.accept')}await h.sleep(60)}assert(runStarted);const foregroundPid=await h.waitFor(async()=>{try{const pid=Number(await readFile(executionPidPath,'utf8'));return pid>0?pid:null}catch{return null}},15000);process.kill(foregroundPid,0);report.foreground_pid=foregroundPid;await visible('terminal.ai_control.takeover');await click('ai.close');await visible('ai.close.confirmation');await capture('07-active-execution-close');await click('ai.close.confirmation.confirm');await h.mouseMove(20,300);await hidden('ai.panel');await h.waitFor(()=>{try{process.kill(foregroundPid,0);return null}catch{return true}},10000);assert.equal(await readFile(executionSentinelPath,'utf8').catch(()=>null),null,'post-sleep effect never ran');report.foreground_stopped=true;await reopen();await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,15000);
 await click('ai.prompt');await h.type_('VERIFY_STOPPED_EXECUTION');await click('ai.send');
 const stoppedEnvelope=await h.waitFor(async()=>{const trace=await readFile(join(out,'app.log'),'utf8');for(const line of trace.split('\n').reverse()){const at=line.indexOf('AI_TOOL_TRACE ');if(at<0)continue;try{const event=JSON.parse(line.slice(at+14));if(event.event==='tool_feedback'&&event.call_id==='retention-stopped-execution-0')return JSON.parse(event.content)}catch{}}return null},15000);
 assert(['succeeded','outcome_unknown'].includes(stoppedEnvelope.status));const stopped=payload(stoppedEnvelope);assert.equal(stopped.execution_ref,executionRef);assert(stopped.snapshot.command_accepted&&stopped.snapshot.submit_sent);assert(stopped.snapshot.local_released&&stopped.snapshot.input_ready&&stopped.snapshot.grant==null&&stopped.snapshot.recording_settled);if(stopped.state==='outcome_unknown'){assert.equal(stopped.snapshot.failure,'Stopped');assert(stopped.snapshot.remote_effect_unknown);assert.equal(stopped.snapshot.process,null)}else assert(stopped.snapshot.process&&stopped.snapshot.process.exit_code!==0);report.stopped_execution=stopped;report.stopped_envelope=stoppedEnvelope;verifiedStop=true;
 await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,15000);await visible('ai.turn.complete');await capture('08-stop-receipt-retained');
 report.checks.push('Confirmed close interrupts the exact real Local foreground execution and releases its input grant; a later Task reads its original settled stop receipt in the same CID, preserving unknown outcome when exact completion is unavailable.');
 await click('ai.collapse');await h.mouseMove(10,10);await hidden('ai.panel');await capture('09-stopped-terminal');report.command_annotations={ai:await h.query('terminal.command.metadata.ai'),status:await h.query('terminal.command.status')};
 await quit();const casts=(await readdir(data,{recursive:true})).filter(path=>String(path).endsWith('.cast'));assert(casts.length>0,'real terminal recordings required');for(const path of casts)assert(!(await readFile(join(data,String(path)),'utf8')).includes('SHOULD_NOT_DISPATCH_CLOSE'),'unapproved command absent from every real terminal recording');report.recordings_checked=casts;report.status='passed';
}catch(error){report.status='failed';report.error=String(error);report.fixture_failure=fixtureFailure;process.exitCode=1;await capture('failure').catch(()=>{})}
finally{report.requests=requests.length;report.calls=calls;report.results=results;let forced=false;if(alive()){forced=true;app.kill('SIGTERM')}await ended;report.cleanup={forced,exit_code:app.exitCode,signal:app.signalCode};server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}))}
