/** Main App acceptance for on-demand metadata authority.
 * Only provider proposals are deterministic; Local PTYs, approval, metadata,
 * conversation switching, execution receipts and Quit are production paths.
 * Run only after the native input slot is allocated and a candidate delivered:
 * ZW_AI_TEST_PREFIX=/tmp/zw-inventory-main-r10 ZW_AI_TEST_EXPECTED_SHA256=<sha>
 *   node e2e/ai_inventory_ondemand_native.ts /tmp/zw-inventory-evidence-<run>
 */
import assert from 'node:assert/strict';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash,randomBytes} from 'node:crypto';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,readdir,open,realpath,access} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-inventory-main-native');
const binary=resolve(process.env.ZW_AI_TEST_BINARY??join(prefix,'bin/zerowork'));
assert.match(process.env.ZW_AI_TEST_EXPECTED_SHA256??'',/^[a-f0-9]{64}$/,'root must deliver the candidate SHA before native acceptance');
const binarySha=createHash('sha256').update(await readFile(binary)).digest('hex');
assert.equal(binarySha,process.env.ZW_AI_TEST_EXPECTED_SHA256,'candidate differs from the delivered executable');
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-inventory-ondemand-evidence');await mkdir(out,{recursive:true});
try{await access(join(out,'report.json'));throw new Error('use a fresh evidence directory')}catch(e:any){if(e.code!=='ENOENT')throw e}
const iso=await realpath(await mkdtemp('/tmp/zw-inventory-main-')),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
await Promise.all([mkdir(data),mkdir(rpc),mkdir(zdot)]);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='inventory-test%# '\n");
const nonce='ZW_INVENTORY_'+randomBytes(12).toString('hex'),requestKey='inventory-'+randomBytes(8).toString('hex');
const stages=['DEFAULT','DENY','ONCE','CONTINUOUS','OTHER_CID','NEXT_REVOKE'] as const;
type Stage=typeof stages[number];
const commands=Object.fromEntries(['DENY','NEXT_REVOKE'].map(stage=>[stage,`printf '%s\\n' '${nonce}_${stage}_START'; sleep 25; printf '%s\\n' '${nonce}_${stage}_DONE'`])) as Record<string,string>;
const facts:any={},emitted=new Map<string,any>(),observations=new Map<string,any>(),requests:any[]=[];
let fixtureFailure:string|null=null,activeCall:any=null,finalStage:string|null=null,held:any=null,currentStage:Stage|null=null,quitting=false;
const report:any={status:'running',binary,binary_sha256:binarySha,started_at:new Date().toISOString(),checks:[],decisions:[],execution_approvals:[],screenshots:[],scenarios:{},isolation:{directory:iso,data,rpc,zdot,preserved:true},limitations:['Only the loopback provider supplies fixed tool proposals. Every result, UI decision, Local session, private PTY receipt and recording comes from the production App.','Only isolated Local terminals and two explicitly approved stdout-only printf/sleep commands containing random non-sensitive nonces are used. No SSH, external network, user vault or saved host configuration is read.','Backend named tests cover external metadata rows denying terminal body, execution and saved sources; this case verifies their metadata-only projection without duplicating those execution architectures.','Physical keyboard, real IME, VoiceOver and other macOS versions are outside this acceptance.']};
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const wireName=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
const payload=(envelope:any)=>{for(const block of envelope.content??[])if(['structured','text'].includes(block.type))try{return JSON.parse(block.text)}catch{}return envelope};
const result=(results:Map<string,any>,id:string,success=true):any=>{
 const envelope=results.get(id);if(!envelope)return null;const body=payload(envelope);observations.set(id,{envelope,body});
 if(success)assert.equal(envelope.status,'succeeded',`${id}: ${JSON.stringify(envelope)}`);return body;
};
function denied(results:Map<string,any>,id:string){
 const body=result(results,id,false);if(!body)return null;const envelope=results.get(id);
 assert(['rejected','failed','cancelled_unsent'].includes(envelope.status),`${id} succeeded without permission`);
 assert.equal(body.error_code,'InventoryApprovalDenied',`${id}: ${JSON.stringify(envelope)}`);
 assert.equal(envelope.receipt?.side_effect_started??body.side_effect_started,false);return body;
}
function emit(body:any,res:any,calls:any[]){
 const tool_calls=calls.map(({id,name,arguments:args},index)=>{
  const wire=wireName(name);assert(body.tools?.some((tool:any)=>tool.function.name===wire),`catalog lacks ${name}`);
  assert(!emitted.has(id),'fixture must not replay an original call');const call={id,name,wire,arguments:args};emitted.set(id,call);activeCall=call;
  return{index,id,type:'function',function:{name:wire,arguments:JSON.stringify(args)}};
 });res.end(frame({tool_calls})+'data: [DONE]\n\n');
}
const call=(id:string,name:string,args:any={})=>({id,name,arguments:args});
const one=(body:any,res:any,id:string,name:string,args:any={})=>emit(body,res,[call(id,name,args)]);
const getExecution=(id:string,ref:string)=>call(id,'host.get_execution',{execution_ref:ref,max_bytes:8192});
function hold(body:any,res:any,kind:string){
 assert.equal(held,null);activeCall=null;held={body,res,kind,at:performance.now()};res.write(frame({content:'继续检查当前任务的真实宿主状态。'}));
 held.heartbeat=setInterval(()=>{if(!res.writableEnded)res.write(': fixture awaiting native metadata action\n\n')},5000);
}
function release(kind:string,calls:any[]){assert.equal(held?.kind,kind);const value=held;clearInterval(value.heartbeat);held=null;emit(value.body,value.res,calls)}
function finish(res:any,stage:Stage){activeCall=null;finalStage=stage;res.end(frame({content:`[I-${stage}] 已核验按需元信息授权及真实宿主结果。`})+'data: [DONE]\n\n')}
function validateWire(body:any){
 const pending=new Map<string,any>();for(const message of body.messages){
  if(message.role==='assistant')for(const value of message.tool_calls??[]){assert(!pending.has(value.id));pending.set(value.id,value)}
  if(message.role==='tool'){const value=pending.get(message.tool_call_id),original=emitted.get(message.tool_call_id);assert(value&&original,'orphan original tool result');assert.equal(value.function.name,original.wire);assert.deepEqual(JSON.parse(value.function.arguments),original.arguments,'original call arguments changed');JSON.parse(message.content);pending.delete(message.tool_call_id)}
 }assert.equal(pending.size,0,'each original proposal must settle before the next provider round');
}
const assertMetadata=(inventory:any,count:number,binding:string)=>{
 assert.equal(inventory.sessions.length,count);assert.equal(inventory.next_cursor,null);
 for(const row of inventory.sessions){if(row.session_ref===binding){assert.equal(row.metadata_only,false);continue}
  assert.equal(row.metadata_only,true);assert.equal(row.source_ref,null);assert.equal(row.recording_ref,null);assert.equal(row.task_owned,false);assert.equal(row.capabilities.read_terminal,false);assert.equal(row.capabilities.batch_execution,false);assert.equal(row.capabilities.trusted_pty_execution,false);
 }
};
const assertRunning=(value:any)=>{assert.equal(value.state,'running');assert.equal(value.snapshot.submit_sent,true);assert(value.snapshot.submit_native_bytes>0);assert.equal(value.snapshot.process?.foreground_finished??false,false);assert.equal(value.snapshot.remote_effect_unknown,false)};
function recorded(body:any,res:any,results:Map<string,any>,base:string,run:any){
 let value=result(results,base+'-finished');if(!value){one(body,res,base+'-finished','host.wait_execution',{execution_ref:run.execution_ref,after_revision:facts[currentStage!].after.source_revision,wait_ms:30000,max_bytes:8192});return null}
 // The real driver publishes a heartbeat revision about every five seconds;
 // each wait may therefore return before the stdout-only sleep has finished.
 for(let i=1;value.state!=='interval_recorded'&&i<=8;i++){const id=base+'-finished-'+i,next=result(results,id);if(!next){one(body,res,id,'host.wait_execution',{execution_ref:run.execution_ref,after_revision:value.source_revision,wait_ms:30000,max_bytes:8192});return null}value=next}
 assert.equal(value.state,'interval_recorded');const snapshot=value.snapshot;assert.equal(snapshot.interval_saved,true);assert.equal(snapshot.process.foreground_finished,true);assert.equal(snapshot.process.exit_code,0);assert.equal(snapshot.process.signal,null);assert.equal(snapshot.recording_settled,true);assert.equal(snapshot.recording_failed,false);assert.equal(snapshot.local_released,true);assert.equal(snapshot.remote_effect_unknown,false);assert(value.output.includes(nonce+'_'+currentStage+'_START'));assert(value.output.includes(nonce+'_'+currentStage+'_DONE'));return value;
}
const server=createServer(async(req,res)=>{try{
 if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'inventory-native-fixture'}]}));return}
 assert(!quitting);let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);validateWire(body);
 const boundary=body.messages.findLastIndex((message:any)=>message.role==='user'&&/\[I-(DEFAULT|DENY|ONCE|CONTINUOUS|OTHER_CID|NEXT_REVOKE)\]/.test(String(message.content)));
 const stage=/\[I-(DEFAULT|DENY|ONCE|CONTINUOUS|OTHER_CID|NEXT_REVOKE)\]/.exec(String(body.messages[boundary]?.content))?.[1] as Stage;
 assert.equal(stage,currentStage);const base=stage.toLowerCase(),state=facts[stage]??=( {} );
 const results=new Map<string,any>(body.messages.slice(boundary+1).filter((message:any)=>message.role==='tool').map((message:any)=>[message.tool_call_id,JSON.parse(message.content)]));
 requests.push({at:new Date().toISOString(),stage,wire:body});await writeFile(join(out,'provider-wire.json'),JSON.stringify(requests,null,2));res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
 const context=result(results,base+'-context'),bound=result(results,base+'-bound');
 if(!context||!bound)return emit(body,res,[call(base+'-context','host.get_current_context'),call(base+'-bound','host.list_sessions',{limit:200})]);
 assertMetadata(bound,1,context.binding_ref);assert.equal(bound.sessions[0].session_ref,context.binding_ref);state.context=context;state.session=bound.sessions[0];
 if(stage==='DEFAULT'){assert.equal(context.grants.inventory,'current_binding');assert.equal(context.grants.expires_at,null);return finish(res,stage)}
 if(stage==='OTHER_CID'){assert.notEqual(context.conversation_id,facts.DEFAULT.context.conversation_id);assert.equal(context.grants.inventory,'current_binding')}
 else{assert.equal(context.conversation_id,facts.DEFAULT.context.conversation_id);assert.notEqual(context.task_id,facts.DEFAULT.context.task_id)}
 if(stage==='ONCE'||stage==='CONTINUOUS'||stage==='OTHER_CID'){
  const first=result(results,base+'-workspace',stage!=='OTHER_CID');if(!first)return one(body,res,base+'-workspace','host.list_sessions',{scope:'workspace',limit:200});
  if(stage==='OTHER_CID'){denied(results,base+'-workspace');state.denied=first;return finish(res,stage)}
  assertMetadata(first,2,context.binding_ref);state.workspace=first;
  const second=result(results,base+'-workspace-new-call',stage==='CONTINUOUS');if(!second)return one(body,res,base+'-workspace-new-call','host.list_sessions',{scope:'workspace',limit:200});
  if(stage==='ONCE'){
   denied(results,base+'-workspace-new-call');const third=denied(results,base+'-denied-same-semantics');if(!third)return one(body,res,base+'-denied-same-semantics','host.list_sessions',{limit:200,scope:'workspace'});
   state.second_denied=second;state.semantic_retry_denied=third;
  }else assertMetadata(second,2,context.binding_ref);
  const after=result(results,base+'-after-context'),defaultList=result(results,base+'-after-default');
  if(!after||!defaultList)return emit(body,res,[call(base+'-after-context','host.get_current_context'),call(base+'-after-default','host.list_sessions',{limit:200})]);
  assert.equal(after.task_id,context.task_id);assert.equal(after.grants.inventory,stage==='CONTINUOUS'?'workspace_open_metadata':'current_binding');assert.equal(after.grants.expires_at,null);assertMetadata(defaultList,1,context.binding_ref);state.after_context=after;return finish(res,stage);
 }
 if(stage==='NEXT_REVOKE'){
  assert.equal(context.grants.inventory,'workspace_open_metadata');assert.equal(context.grants.expires_at,null);assert.notEqual(context.task_id,facts.CONTINUOUS.context.task_id);
  const inventory=result(results,'next_revoke-before-workspace');if(!inventory)return one(body,res,'next_revoke-before-workspace','host.list_sessions',{scope:'workspace',limit:200});assertMetadata(inventory,3,context.binding_ref);state.workspace=inventory;
 }
 let capability:any;
 for(let attempt=0;attempt<3;attempt++){
  const id=base+'-capability'+(attempt?'-'+attempt:'');capability=result(results,id);if(!capability){if(attempt)await h.sleep(500);return one(body,res,id,'host.get_session',{session_ref:context.binding_ref})}
  if(capability.session.capabilities.trusted_pty_execution)break;assert(['initializing','busy'].includes(capability.session.capabilities.trusted_pty_state));assert(attempt<2,'real Local PTY did not become ready');
 }
 const run=result(results,base+'-run');if(!run)return one(body,res,base+'-run','host.run_in_terminal',{session_ref:context.binding_ref,command:commands[stage],request_key:requestKey+'-'+base});state.run=run;
 let before=result(results,base+'-running-before');if(!before){await h.sleep(300);return emit(body,res,[getExecution(base+'-running-before',run.execution_ref)])}
 for(let attempt=1;before.state!=='running'&&attempt<=5;attempt++){
  assert(['preparing','awaiting_start_boundary','awaiting_accept','awaiting_submit'].includes(before.state),`unexpected pre-run state: ${JSON.stringify(before)}`);const id=base+'-running-before-'+attempt,next=result(results,id);
  if(!next)return one(body,res,id,'host.wait_execution',{execution_ref:run.execution_ref,after_revision:before.source_revision,wait_ms:30000,max_bytes:8192});before=next;
 }assertRunning(before);state.before=before;
 if(stage==='NEXT_REVOKE'&&!results.has(base+'-workspace'))return hold(body,res,'revoke');
 const denial=denied(results,base+'-workspace');if(!denial)return one(body,res,base+'-workspace','host.list_sessions',{scope:'workspace',limit:200});state.denied=denial;
 const retry=denied(results,base+'-same-semantics-new-call');if(!retry)return one(body,res,base+'-same-semantics-new-call','host.list_sessions',{limit:200,scope:'workspace'});state.semantic_retry_denied=retry;
 const after=result(results,base+'-running-after'),afterContext=result(results,base+'-after-context');if(!after||!afterContext)return emit(body,res,[getExecution(base+'-running-after',run.execution_ref),call(base+'-after-context','host.get_current_context')]);
 assertRunning(after);assert.equal(after.execution_ref,before.execution_ref);assert.equal(after.snapshot.execution_id,before.snapshot.execution_id);assert.equal(afterContext.task_id,context.task_id);assert.equal(afterContext.grants.inventory,'current_binding');state.after=after;state.after_context=afterContext;
 const completed=recorded(body,res,results,base,run);if(!completed)return;assert.equal(completed.snapshot.execution_id,before.snapshot.execution_id);state.finished=completed;return finish(res,stage);
}catch(error){fixtureFailure??=String(error);await writeFile(join(out,'fixture-failure.txt'),fixtureFailure);if(!res.headersSent)res.writeHead(500);res.end()}});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
const initialConfig=`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="inventory-native-fixture"\npermission_mode="confirm"\nexecution_mode="auto"\nsession_retention="keep"\n[[ai.providers]]\nid="inventory-native-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="inventory-native-fixture"\ncontext_window=200000\ndefault=true\n[log]\nring_mb=1\ncheckpoint_sec=1\n`;
await writeFile(join(data,'config.toml'),initialConfig);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w'),env:any={...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1',ZDOTDIR:zdot,OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''};
for(const name of['ZEROWORK_AI_MOCK','ZEROWORK_AI_ENDPOINT','ZEROWORK_AI_MODEL','ZEROWORK_AI_PROVIDER'])delete env[name];
const app=spawn(binary,[],{env,stdio:['ignore',log.fd,log.fd]});let spawnError:string|null=null;const ended=new Promise<void>(done=>{app.once('error',error=>{spawnError=String(error);done()});app.once('close',()=>done())});
const alive=()=>app.exitCode===null&&app.signalCode===null&&spawnError===null;
const shown=(node:any)=>node&&node.hidden!==true&&node.visible!==false&&(node.effective_opacity??1)>0&&node.rect?.w>0&&node.rect?.h>0;
const flat=(node:any):any[]=>Array.isArray(node)?node.flatMap(flat):node?[node,...(node.children??[]).flatMap(flat)]:[];
const text=(node:any):string=>flat(node).map(value=>value.text??'').join('');
const visible=(id:string)=>h.waitFor(async()=>{assert.equal(fixtureFailure,null);assert.equal(spawnError,null);return(await h.query(id)).find(shown)??null},20000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,12000);
const click=async(id:string)=>{report.last_action=id;const node=await visible(id);assert((await h.clickAt(node.rect.x+node.rect.w/2,node.rect.y+node.rect.h/2)).ok,id)};
const capture=async(name:string)=>{await h.mouseMove(1,1);const path=join(out,name+'.png');assert((await h.screenshot(path)).ok);report.screenshots.push(path);await writeFile(join(out,name+'.json'),JSON.stringify({panel:await h.query('ai.panel'),inventory:await h.query('ai.inventory_grant'),permission:await h.query('ai.permission.menu'),tabs:await h.query('tabs.strip')},null,2))};
const decisionFor:Record<string,string>={'deny-workspace':'deny','once-workspace':'allow_once','once-workspace-new-call':'deny','continuous-workspace':'allow_conversation','other_cid-workspace':'deny','next_revoke-workspace':'deny'};
async function permissionMenu(authorized:boolean,name?:string){
 await click('ai.composer.permission');await visible('ai.permission.menu');
 if(authorized)await visible('ai.permission.revoke_inventory');else assert.equal((await h.query('ai.permission.revoke_inventory')).filter(shown).length,0,'unauthorized conversation must not offer revoke');
 if(name)await capture(name);await h.key('escape');await absent('ai.permission.menu');
}
async function drive(stage:Stage){
 currentStage=stage;finalStage=null;activeCall=null;facts[stage]={};await absent('ai.inventory_grant');await click('ai.prompt');await h.key('a',{cmd:true});await h.type_(`[I-${stage}] 在隔离本机验证按需元信息授权；仅执行本次明确批准的固定 stdout 诊断。`);await click('ai.send');const started=performance.now();
 while(finalStage!==stage&&performance.now()-started<180000){
  assert.equal(fixtureFailure,null);assert(alive());assert.equal((await h.query('ai.recovery')).filter(shown).length,0,'unexpected provider recovery');
  if((await h.query('ai.inventory_grant')).some(shown)){
   assert(activeCall,'pending inventory card needs an original call');const choice=decisionFor[activeCall.id];assert(choice,`unexpected metadata approval: ${JSON.stringify(activeCall)}`);assert(!report.decisions.some((value:any)=>value.call_id===activeCall.id),'one UI decision per pending request');
   const root=await visible('ai.inventory_grant');assert.equal(text(await visible('ai.inventory_grant.title')),'查看其他会话');const copy=text(await visible('ai.inventory_grant.explanation'));assert(copy.includes('名称、连接状态与分组'));assert(copy.includes('不会读取终端内容或执行命令'));assert(!/15\s*分钟|预授权/.test(text(root)));
   const wrapper=await visible('ai.inventory_grant.wrapper');
   const header=(await h.query('ai.step.header')).filter(shown).filter((node:any)=>node.rect.y+node.rect.h<=root.rect.y+.5).sort((a:any,b:any)=>b.rect.y-a.rect.y)[0];assert(header,'pending inventory approval needs its current visible tool step header');
   for(const [label,actual,expected] of [['left',root.rect.x,header.rect.x],['right',root.rect.x+root.rect.w,header.rect.x+header.rect.w],['width',root.rect.w,header.rect.w],['wrapper-left-inset',root.rect.x-wrapper.rect.x,14],['wrapper-right-inset',wrapper.rect.x+wrapper.rect.w-root.rect.x-root.rect.w,14]] as const)assert(Math.abs(actual-expected)<=.5,`${label}: ${actual} differs from ${expected}`);
   const footer=await h.waitFor(async()=>(await h.query('ai.turn.label')).filter(shown).filter((node:any)=>node.rect.y>=root.rect.y+root.rect.h-.5).sort((a:any,b:any)=>a.rect.y-b.rect.y).find((node:any)=>text(node)==='～等待你确认～')??null,10000);assert.equal(text(footer),'～等待你确认～');
   const buttons=[];for(const option of['deny','allow_once','allow_conversation']){const value=await visible('ai.inventory_grant.'+option);assert(value.rect.x>=root.rect.x&&value.rect.x+value.rect.w<=root.rect.x+root.rect.w+.5);assert(value.rect.y>=root.rect.y&&value.rect.y+value.rect.h<=root.rect.y+root.rect.h+.5);buttons.push({id:option,rect:value.rect})}
   report.decisions.push({stage,call_id:activeCall.id,choice,buttons,alignment:{card:root.rect,step_header:header.rect,wrapper:wrapper.rect,footer:text(footer)},at:new Date().toISOString()});await capture(activeCall.id+'-pending');await click('ai.inventory_grant.'+choice);
  }
  if((await h.query('ai.host_approval')).some(shown)){
   assert(activeCall?.name==='host.run_in_terminal');assert.equal(activeCall.id,stage.toLowerCase()+'-run');assert(!report.execution_approvals.some((value:any)=>value.call_id===activeCall.id));
   assert.equal(text(await visible('ai.host_approval.target')),activeCall.arguments.session_ref);await click('ai.host_approval.copy');assert.equal((await promisify(execFile)('/usr/bin/pbpaste',[],{encoding:'utf8'})).stdout,commands[stage],'real exact approval must preserve the full command');
   report.execution_approvals.push({stage,call_id:activeCall.id,command:commands[stage]});await capture(activeCall.id+'-approval');await click('ai.host_approval.accept');
  }
  if(held?.kind==='revoke'){
   await visible('ai.stop');await absent('ai.inventory_grant');await click('ai.composer.permission');await visible('ai.permission.menu');await visible('ai.permission.revoke_inventory');await capture('next-revoke-running-permission-menu');await click('ai.permission.revoke_inventory');await absent('ai.permission.menu');await visible('ai.stop');await absent('ai.inventory_grant');await capture('next-revoke-provider-still-running');
   report.revocation={same_task:facts.NEXT_REVOKE.context.task_id,execution_ref:facts.NEXT_REVOKE.run.execution_ref,provider_still_running:true};release('revoke',[call('next_revoke-workspace','host.list_sessions',{scope:'workspace',limit:200})]);
  }
  if(finalStage!==stage)await h.sleep(80);
 }
 assert.equal(fixtureFailure,null);assert.equal(finalStage,stage,'fixture did not complete');await absent('ai.stop');await visible('ai.turn.complete');await absent('ai.inventory_grant');await capture(stage.toLowerCase()+'-complete');report.scenarios[stage]={status:'passed',task_id:facts[stage].context.task_id,conversation_id:facts[stage].context.conversation_id};
}
async function normalQuit(){
 if(!alive())return;const started=performance.now();report.normal_quit={route:'POST /quit',confirmations:[],response:await h.request('POST','/quit')};let unavailable=false;
 while(alive()&&performance.now()-started<20000){
  if(!unavailable)try{for(const id of['groups.close.accept','local.close.accept','session.close.accept']){if(!alive())break;const nodes=await h.query(id);if(!Array.isArray(nodes)){unavailable=true;break}if(nodes.some(shown)){report.normal_quit.confirmations.push(id);assert((await h.clickTestId(id)).ok)}}}catch(error){unavailable=true;report.normal_quit.rpc_after_unbind=String(error)}
  if(alive())await Promise.race([ended,h.sleep(80)]);
 }report.normal_quit.exit_code=app.exitCode;report.normal_quit.signal=app.signalCode;report.normal_quit.passed=report.normal_quit.response?.ok===true&&app.exitCode===0&&app.signalCode===null;
}
try{
 report.phase='startup';await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1440,900);
 await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.new_session');await click('session.menu.local');await visible('terminal.surface');await h.sleep(750);
 const tabs=flat(await h.query('tabs.strip')).filter((node:any)=>/^tabs\.tab\.\d+$/.test(node.test_id??''));assert.equal(tabs.length,2);const boundTabId=tabs.at(-1).test_id;report.bound_tab=boundTabId;
 await click('toolbar.ai');await click('ai.maximize');await absent('ai.inventory_grant');await permissionMenu(false,'01-initial-no-preauthorization');
 report.phase='default';await drive('DEFAULT');assert.equal(report.decisions.length,0,'default current-binding reads need zero approval');await permissionMenu(false);
 report.phase='deny-with-real-process';await drive('DENY');await permissionMenu(false);assert.equal(report.decisions.filter((value:any)=>value.stage==='DENY').length,1,'same semantics under another call ID must not prompt again');
 report.phase='once';await drive('ONCE');await permissionMenu(false);assert.deepEqual(report.decisions.filter((value:any)=>value.stage==='ONCE').map((value:any)=>value.choice),['allow_once','deny']);
 report.phase='continuous';await drive('CONTINUOUS');await permissionMenu(true,'continuous-authorized-menu');assert.equal(report.decisions.filter((value:any)=>value.stage==='CONTINUOUS').length,1,'continuous subsequent invocation must skip a new card');
 await click('ai.sessions');await visible('ai.sessions.menu');const jumps=flat(await h.query('ai.sessions.menu')).filter((node:any)=>/^ai\.session\.jump\.\d+$/.test(node.test_id??'')&&shown(node));assert.equal(jumps.length,1);const originalJump=jumps[0].test_id;await h.key('escape');await absent('ai.sessions.menu');
 report.phase='new-conversation';await click('ai.session.new');await visible('ai.prompt');await absent('ai.inventory_grant');await permissionMenu(false);await drive('OTHER_CID');await permissionMenu(false);
 await click('ai.sessions');await visible('ai.sessions.menu');await click(originalJump);await absent('ai.sessions.menu');await permissionMenu(true,'original-conversation-grant-preserved');
 report.phase='new-workspace-local';await click('ai.collapse');await click('toolbar.new_session');await click('session.menu.local');await visible('terminal.surface');assert.equal(flat(await h.query('tabs.strip')).filter((node:any)=>/^tabs\.tab\.\d+$/.test(node.test_id??'')).length,3);await click(boundTabId);await click('toolbar.ai');await click('ai.maximize');await permissionMenu(true);
 report.phase='next-task-and-running-revoke';await drive('NEXT_REVOKE');await permissionMenu(false,'revoked-menu-no-action');assert.equal(report.decisions.filter((value:any)=>value.stage==='NEXT_REVOKE').length,1,'only the post-revoke invocation may request again');
 report.phase='aggregate';assert.equal(await readFile(join(data,'config.toml'),'utf8'),initialConfig,'metadata decisions must not rewrite config');
 assert.deepEqual(report.execution_approvals.map((value:any)=>value.call_id),['deny-run','next_revoke-run']);assert.equal(report.decisions.length,6);assert.equal(observations.size,emitted.size,'every original call must retain a real observed result');
 const ids=new Set(stages.map(stage=>facts[stage].context.task_id));assert.equal(ids.size,stages.length,'each composer turn is a fresh Task');
 report.checks.push('Two real Local sessions: initial AI panel has no inventory card or 15-minute preauthorization; default list_sessions returns only the bound session with zero approvals.','An actual workspace request shows deny/allow once/allow current conversation. Denial yields one tool result, the provider continues the same Task, and a new call ID with canonical-equivalent arguments is denied without another prompt.','Allow once returns the real workspace rows for only that invocation. A new same-argument invocation requires its own approval; its denial suppresses further semantic retries in that Task.','Continuous authority stays in one CID across Tasks and conversation switching. A separate CID requests independently, while returning to the original CID preserves its grant. Default reads remain current-binding only.','Opening a third real Local adds its metadata to the next Task without another approval; outside-binding rows expose no terminal body, execution or source capability.','The permission menu exposes revoke only while the current conversation is authorized. During a live provider Task, revoke removes authority, the next workspace request asks again, its denied retry stays quiet, and the provider continues.','Before and after both metadata denial and revocation, the same separately approved real stdout/sleep execution remains running; its original private PTY execution later finishes naturally with exit 0 and a durably saved interval.');
 report.acceptance_passed=true;
}catch(error){report.error=fixtureFailure??String(error);report.primary_failure={phase:report.phase,reason:report.error,last_action:report.last_action,active_call:activeCall};process.exitCode=1;await capture('failure').catch(()=>{});await h.tree().then((tree:any)=>writeFile(join(out,'failure-tree.json'),JSON.stringify(tree,null,2))).catch(()=>{})}
finally{
 quitting=true;if(held){clearInterval(held.heartbeat);held.res.destroy();held=null}await normalQuit().catch(error=>{report.normal_quit_error=String(error)});
 let forced=false;if(alive()){forced=true;app.kill('SIGTERM');await Promise.race([ended,h.sleep(2000)])}if(alive()){app.kill('SIGKILL');await ended}report.cleanup={forced,exit_code:app.exitCode,signal:app.signalCode,spawn_error:spawnError};
 server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();report.facts=facts;report.requests=requests;report.emitted=[...emitted.values()];report.observations=Object.fromEntries(observations);
 const rawLog=await readFile(join(out,'app.log'),'utf8'),events:any[]=[];for(const line of rawLog.split('\n')){const at=line.indexOf('AI_TOOL_TRACE ');if(at>=0)try{events.push(JSON.parse(line.slice(at+14)))}catch{}}
 report.events=events;report.native_errors=rawLog.split('\n').filter(line=>/ai worker turn failed:|error\(gpa\)|memory address .* leaked|General protection exception|Segmentation fault/.test(line));
 report.status=report.acceptance_passed&&report.normal_quit?.passed&&!forced&&!report.native_errors.length?'passed':'failed';if(report.status==='failed'){report.error??=report.native_errors[0]??'normal Quit did not exit with code 0';process.exitCode=1}else report.checks.push('The application confirms its remaining isolated Local sessions through POST /quit and exits 0 with no signal, forced cleanup or allocator leak report.');
 await writeFile(join(out,'tool-feedback.json'),JSON.stringify(events.filter((event:any)=>event.event==='tool_feedback').map((event:any)=>({...event,envelope:JSON.parse(event.content)})),null,2));
 await writeFile(join(out,'lifecycle-journal.json'),await readFile(join(data,'ai/lifecycle.json'))).catch(()=>{});
 const manifests:any[]=[];for(const file of await readdir(data,{recursive:true}))if(String(file).endsWith('.json'))try{const document=JSON.parse(await readFile(join(data,String(file)),'utf8'));if(document.execution_ranges?.length)manifests.push({path:String(file),document})}catch{}await writeFile(join(out,'recording-manifests.json'),JSON.stringify(manifests,null,2));
 await writeFile(join(out,'raw-call-results.json'),JSON.stringify(report.observations,null,2));await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(JSON.stringify({status:report.status,error:report.error,report:join(out,'report.json')}));
