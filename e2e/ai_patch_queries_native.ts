/** Main App PATCH query acceptance. Only provider tool proposals are fake.
 * Requires the allocated native slot and an explicitly delivered test build:
 * ZW_AI_TEST_PREFIX=/tmp/zw-patch-main-native ZW_AI_TEST_EXPECTED_SHA256=<hash> \
 *   node e2e/ai_patch_queries_native.ts /tmp/zw-patch-query-evidence-<run>
 * Real Local services, UI approvals, PTY output, command index and archive IO.
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
assert.match(process.env.ZW_AI_TEST_EXPECTED_SHA256??'',/^[a-f0-9]{64}$/,'an explicitly delivered candidate SHA-256 is required');
const binarySha=createHash('sha256').update(await readFile(binary)).digest('hex');assert.equal(binarySha,process.env.ZW_AI_TEST_EXPECTED_SHA256);
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-patch-query-evidence');await mkdir(out,{recursive:true});
try{await access(join(out,'report.json'));throw new Error('use a fresh evidence directory')}catch(e:any){if(e.code!=='ENOENT')throw e}
const iso=await realpath(await mkdtemp('/tmp/zw-patch-queries-')),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
await Promise.all([mkdir(data),mkdir(rpc),mkdir(zdot)]);await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='patch-query%# '\n");
const nonce='ZW_QUERY_'+randomBytes(12).toString('hex'),plain=nonce+'_PLAIN',color=nonce+'_COLOR',longLine=nonce+'_LONG_'+'x'.repeat(240);
const markerFile=join(iso,'executed-once'),forbiddenFile=join(iso,'must-not-execute'),seedFile=join(iso,'seed-ready'),executionMarker=nonce+'_EXEC';
const seedCommand=`printf '\\033[31m%s\\033[0m\\n%s\\n%s\\n' '${color}' '${plain}' '${longLine}'; printf ready > '${seedFile}'`;
const command=`printf '%s\\n' '${executionMarker}' > '${markerFile}'; printf '%s\\n' '${executionMarker}'`;
const deniedCommand=`printf '%s\\n' '${nonce}_DENIED' > '${forbiddenFile}'`;
const key='patch-query-'+randomBytes(8).toString('hex'),frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const wireName=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
const calls=new Map<string,any>(),observations=new Map<string,any>(),requests:any[]=[];
let failure:string|null=null,finalStage:string|null=null,activeCall:any=null,held:any=null,quitting=false;
let bound:any,defaultContext:any,grantBeforeContext:any,grantContext:any,globalCursor:string,external:any[],owned:any,execution:any,recordingRef:string,commandRef:string;
const report:any={status:'running',binary,binary_sha256:binarySha,started_at:new Date().toISOString(),checks:[],screenshots:[],isolation:{directory:iso,data,rpc,zdot,preserved:true},limitations:['The loopback provider supplies fixed tool proposals; all host results and native actions use the production main App.','Only isolated Local terminals and fixed printf commands containing non-sensitive random nonces are used. No SSH accounts or credentials are accessed.','Terminal tail/search represent retained logical lines. Execution ranges remain observed PTY intervals and never claim a complete transcript.']};
const exists=async(path:string)=>{try{await access(path);return true}catch{return false}};
const payload=(envelope:any)=>{for(const block of envelope.content??[])if(['structured','text'].includes(block.type))try{return JSON.parse(block.text)}catch{}return envelope};
function result(results:Map<string,any>,id:string,success=true):any{
 const envelope=results.get(id);if(!envelope)return null;const body=payload(envelope);observations.set(id,{envelope,body});
 if(success)assert.equal(envelope.status,'succeeded',`${id}: ${JSON.stringify(envelope)}`);return body;
}
function rejected(results:Map<string,any>,id:string,codes:string[]){
 const body=result(results,id,false),envelope=results.get(id);if(!body)return null;
 assert(['rejected','failed'].includes(envelope.status),`${id} unexpectedly succeeded`);assert(codes.includes(body.error_code),`${id}: ${JSON.stringify(envelope)}`);
 const receipt=envelope.receipt??body;assert.equal(receipt.side_effect_started??body.side_effect_started,false);assert.equal(receipt.remote_effect_unknown??body.remote_effect_unknown,false);return body;
}
function emit(res:any,items:any[]){
 const tool_calls=items.map(({id,name,arguments:args},index)=>{const call={id,name,wire:wireName(name),arguments:args};assert(!calls.has(id),'fixture must never replay a call');calls.set(id,call);activeCall=call;return{index,id,type:'function',function:{name:call.wire,arguments:JSON.stringify(args)}}});
 res.end(frame({tool_calls})+'data: [DONE]\n\n');
}
const one=(res:any,id:string,name:string,args:any)=>emit(res,[{id,name,arguments:args}]);
const finish=(res:any,stage:string)=>{activeCall=null;finalStage=stage;res.end(frame({content:`[Q-${stage}] 已核验真实宿主结果。`})+'data: [DONE]\n\n')};
function hold(res:any,kind:string){assert.equal(held,null);activeCall=null;held={res,kind,at:performance.now()};res.write(frame({content:'继续检查本任务的真实宿主状态。'}))}
function release(kind:string,items:any[]){assert.equal(held?.kind,kind);const res=held.res;held=null;emit(res,items)}
const contentText=(body:any)=>(body.lines??[]).map((line:any)=>line.text).join('\n')+(body.output??body.terminal_output??'');
const assertPlain=(body:any)=>{assert.equal(body.coordinate_basis,'retained_logical_lines');assert(!contentText(body).includes('\x1b'),'logical-line queries must not expose raw ANSI');assert.equal(body.complete,false)};
function validateWire(body:any){
 assert(!/assistant_session_id=|provider=.*session_id=/.test(String(body.messages.find((m:any)=>m.role==='system')?.content??'')));
 const pending=new Map<string,any>();for(const message of body.messages){
  if(message.role==='assistant')for(const call of message.tool_calls??[]){assert(!pending.has(call.id));pending.set(call.id,call)}
  if(message.role==='tool'){const call=pending.get(message.tool_call_id);assert(call,'orphan tool result');const original=calls.get(call.id);assert(original);assert.equal(call.function.name,original.wire);assert.deepEqual(JSON.parse(call.function.arguments),original.arguments);JSON.parse(message.content);pending.delete(call.id)}
 }assert.equal(pending.size,0);
}
const server=createServer(async(req,res)=>{try{
 if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'patch-queries-fixture'}]}));return}
 assert(!quitting);let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);validateWire(body);
 const index=body.messages.findLastIndex((m:any)=>m.role==='user'&&/\[Q-(DEFAULT|GRANT|CONTENT)\]/.test(String(m.content)));
 const stage=/\[Q-(DEFAULT|GRANT|CONTENT)\]/.exec(String(body.messages[index]?.content))?.[1];assert(stage,'explicit fixture stage required');
 const results=new Map<string,any>(body.messages.slice(index+1).filter((m:any)=>m.role==='tool').map((m:any)=>[m.tool_call_id,JSON.parse(m.content)]));
 requests.push({at:new Date().toISOString(),stage,wire:body});await writeFile(join(out,'provider-wire.json'),JSON.stringify(requests,null,2));
 res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
 if(stage==='DEFAULT'){
  defaultContext=result(results,'default-context');const inventory=result(results,'default-sessions');
  if(!defaultContext||!inventory)return emit(res,[{id:'default-context',name:'host.get_current_context',arguments:{}},{id:'default-sessions',name:'host.list_sessions',arguments:{limit:200}}]);
  assert.equal(defaultContext.grants.inventory,'current_binding');assert.equal(inventory.sessions.length,1,'two real outside-scope Locals must remain hidden');bound=inventory.sessions[0];assert.equal(bound.session_ref,defaultContext.binding_ref);assert.equal(bound.metadata_only,false);
  const tail=result(results,'default-tail'),search=result(results,'default-search');
  if(!tail||!search)return emit(res,[{id:'default-tail',name:'host.read_terminal',arguments:{session_ref:bound.session_ref,max_lines:100,max_bytes:8192}},{id:'default-search',name:'host.search_terminal',arguments:{session_ref:bound.session_ref,query:nonce+'_LONG_',max_lines:100,max_bytes:8192,limit:20}}]);
  assertPlain(tail);assert(tail.lines.some((line:any)=>line.text===color));assert(tail.lines.some((line:any)=>line.text===plain));const logical=tail.lines.find((line:any)=>line.text===longLine);assert(logical,'soft-wrapped native output must remain one logical line');
  assert.equal(search.coordinate_basis,'retained_logical_lines');assert(search.matches.some((match:any)=>match.logical_line===logical.line&&match.context.includes(nonce+'_LONG_')));assert(search.matches.every((match:any)=>!match.context.includes('\x1b')));
  const lines=result(results,'default-lines');if(!lines)return one(res,'default-lines','host.read_terminal',{session_ref:bound.session_ref,range_kind:'lines',start_line:logical.line,end_line:logical.line,max_lines:5,max_bytes:8192});
  assertPlain(lines);assert.equal(lines.lines.length,1);assert.equal(lines.lines[0].text,longLine);report.live_logical_line=logical;return finish(res,stage);
 }
 if(stage==='GRANT'){
  grantBeforeContext=result(results,'grant-before-context');const before=result(results,'grant-before-sessions');
  if(!grantBeforeContext||!before)return emit(res,[{id:'grant-before-context',name:'host.get_current_context',arguments:{}},{id:'grant-before-sessions',name:'host.list_sessions',arguments:{limit:200}}]);
  assert.equal(grantBeforeContext.conversation_id,defaultContext.conversation_id);assert.notEqual(grantBeforeContext.task_id,defaultContext.task_id);assert.equal(grantBeforeContext.grants.inventory,'current_binding');assert.equal(before.sessions.length,1);assert.equal(before.sessions[0].session_ref,bound.session_ref);
  const inventory=result(results,'grant-sessions');if(!inventory)return one(res,'grant-sessions','host.list_sessions',{scope:'workspace',limit:200});
  grantContext=result(results,'grant-context');const page=result(results,'grant-page'),groups=result(results,'grant-groups'),defaultList=result(results,'grant-default-sessions');
  if(!grantContext||!page||!groups||!defaultList)return emit(res,[{id:'grant-context',name:'host.get_current_context',arguments:{}},{id:'grant-page',name:'host.list_sessions',arguments:{scope:'workspace',limit:1}},{id:'grant-groups',name:'host.list_groups',arguments:{scope:'workspace',limit:200}},{id:'grant-default-sessions',name:'host.list_sessions',arguments:{limit:200}}]);
  assert.equal(grantContext.task_id,grantBeforeContext.task_id);assert.equal(grantContext.grants.inventory,'workspace_open_metadata');assert.equal(grantContext.grants.grant_revision,grantBeforeContext.grants.grant_revision,'metadata approval must not change execution/config grant revision');assert.equal(grantContext.grants.expires_at,null);assert.equal(grantContext.grants.duration,'conversation');assert.equal(groups.groups.length,0);assert.equal(defaultList.sessions.length,1,'continuous approval must not widen an implicit default list');assert.equal(defaultList.sessions[0].session_ref,bound.session_ref);
  assert.equal(inventory.sessions.length,3);external=inventory.sessions.filter((s:any)=>s.session_ref!==bound.session_ref);assert.equal(external.length,2);assert(page.next_cursor);globalCursor=page.next_cursor;
  for(const s of external){assert.equal(s.metadata_only,true);assert.equal(s.source_ref,null);assert.equal(s.recording_ref,null);assert.equal(s.task_owned,false);assert.equal(s.capabilities.read_terminal,false);assert.equal(s.capabilities.batch_execution,false);assert.equal(s.capabilities.trusted_pty_execution,false)}
  if(!results.has('grant-read-0'))return emit(res,external.flatMap((s:any,i:number)=>[{id:'grant-read-'+i,name:'host.read_terminal',arguments:{session_ref:s.session_ref,max_bytes:1024}},{id:'grant-run-'+i,name:'host.run_in_terminal',arguments:{session_ref:s.session_ref,command:deniedCommand,request_key:key+'-denied-'+i}},{id:'grant-get-'+i,name:'host.get_session',arguments:{session_ref:s.session_ref}}]));
  for(let i=0;i<2;i++){rejected(results,'grant-read-'+i,['TargetOutsideAssistant','TargetOutsideScope','PermissionDenied']);rejected(results,'grant-run-'+i,['TargetOutsideAssistant','TargetOutsideScope','PermissionDenied']);assert.equal(result(results,'grant-get-'+i).session.metadata_only,true)}assert.equal(await exists(forbiddenFile),false);
  if(!results.has('revoke-context'))return hold(res,'revoke');
  const after=result(results,'revoke-context'),scoped=result(results,'revoke-sessions');assert.equal(after.task_id,grantContext.task_id);assert.equal(after.grants.inventory,'current_binding');assert.equal(scoped.sessions.length,1);assert.equal(scoped.sessions[0].session_ref,bound.session_ref);
  assert.equal(after.grants.expires_at,null);assert.equal(after.grants.duration,null);assert.equal(after.grants.grant_revision,grantContext.grants.grant_revision);rejected(results,'revoke-external',['TargetOutsideScope']);
  if(!results.has('revoke-old-cursor'))return one(res,'revoke-old-cursor','host.list_sessions',{scope:'workspace',limit:1,cursor:globalCursor});
  rejected(results,'revoke-old-cursor',['CursorExpired','SnapshotChanged']);assert.equal(report.inventory_decisions.find((decision:any)=>decision.call_id==='revoke-old-cursor')?.choice,'allow_once','revoked authority requires a fresh exact decision before the old workspace cursor can be checked');report.metadata={default:defaultContext,before:grantBeforeContext,granted:grantContext,revoked:after,external,old_cursor:globalCursor};return finish(res,stage);
 }
 const context=result(results,'content-context');if(!context)return one(res,'content-context','host.get_current_context',{});
 assert.equal(context.conversation_id,defaultContext.conversation_id);assert.notEqual(context.task_id,grantContext.task_id);assert.equal(context.grants.inventory,'current_binding');
 const group=result(results,'content-group');if(!group)return one(res,'content-group','host.create_group',{initial_session_ref:bound.session_ref,name:'PATCH real query acceptance',request_key:key+'-group'});
 const groupContext=result(results,'content-group-context');if(!groupContext)return one(res,'content-group-context','host.get_current_context',{});assert.equal(groupContext.task_id,context.task_id);assert.equal(groupContext.binding_ref,group.group_ref);
 const opened=result(results,'content-open');if(!opened)return one(res,'content-open','host.open_session',{group_ref:group.group_ref,source_ref:bound.session_ref,connection_policy:'new_only',retention:'keep',request_key:key+'-open'});
 owned=result(results,'content-ready');if(!owned)return one(res,'content-ready','host.wait_session_ready',{operation_ref:opened.operation_ref,after_revision:opened.source_revision,wait_ms:30000});assert.equal(owned.state,'ready');assert.equal(owned.ownership,'created_task');
 let facts=result(results,'content-source');if(!facts)return one(res,'content-source','host.get_session',{session_ref:owned.session_ref});
 for(let i=1;!facts.session.capabilities.trusted_pty_execution&&i<=2;i++){assert(['initializing','busy'].includes(facts.session.capabilities.trusted_pty_state));const id='content-source-'+i,next=result(results,id);if(!next){await h.sleep(750);return one(res,id,'host.get_session',{session_ref:owned.session_ref})}facts=next}assert.equal(facts.session.capabilities.trusted_pty_execution,true);owned={...owned,...facts.session};
 const run=result(results,'content-run');if(!run)return one(res,'content-run','host.run_in_terminal',{session_ref:owned.session_ref,command,request_key:key+'-run'});
 execution=result(results,'content-wait');if(!execution){report.pending_execution={execution_ref:run.execution_ref,source_revision:run.source_revision};return hold(res,'execution-file')}
 for(let i=1;execution.state!=='interval_recorded'&&i<=2;i++){assert(!['cancelled_unsent','outcome_unknown','recording_degraded','handed_off'].includes(execution.state));const id='content-wait-'+i,next=result(results,id);if(!next)return one(res,id,'host.wait_execution',{execution_ref:run.execution_ref,after_revision:execution.source_revision,wait_ms:30000,max_bytes:8192});execution=next}
 assert.equal(execution.state,'interval_recorded');assert.equal(execution.snapshot.interval_saved,true);assert.equal(execution.snapshot.process.foreground_finished,true);assert.equal(execution.snapshot.process.exit_code,0);assert(execution.output.includes(executionMarker));assert.equal(await readFile(markerFile,'utf8'),executionMarker+'\n');
 const source=result(results,'content-recording-source'),commands=result(results,'content-commands'),tail=result(results,'content-tail'),search=result(results,'content-search');
 if(!source||!commands||!tail||!search)return emit(res,[{id:'content-recording-source',name:'host.get_session',arguments:{session_ref:owned.session_ref}},{id:'content-commands',name:'host.list_terminal_commands',arguments:{session_ref:owned.session_ref,limit:20,max_bytes:8192}},{id:'content-tail',name:'host.read_terminal',arguments:{session_ref:owned.session_ref,max_lines:100,max_bytes:8192}},{id:'content-search',name:'host.search_terminal',arguments:{session_ref:owned.session_ref,query:executionMarker,max_lines:100,max_bytes:8192}}]);
 recordingRef=source.session.recording_ref;assert.match(recordingRef,/^r1:/,'recording reference must come from the original real host result');const entry=commands.commands.find((c:any)=>c.submitted_command===command);assert(entry,'Driver command index must expose the exact real approved command');commandRef=entry.reference;assert.match(commandRef,/^c1:/);assert.equal(entry.verified,true);assert.equal(entry.exit_code,0);assert.equal(entry.complete,false,'an observed interval is not an exact command transcript');assertPlain(tail);assert(tail.lines.some((l:any)=>l.text===executionMarker));assert(search.matches.some((m:any)=>m.context.includes(executionMarker)));
 const range=result(results,'content-command-range');if(!range)return one(res,'content-command-range','host.read_terminal',{session_ref:owned.session_ref,range_kind:'command',command_ref:commandRef,max_bytes:8192,max_lines:100});assert(contentText(range).includes(executionMarker));assert.equal(range.command_ref,commandRef);
 const close=result(results,'content-close');if(!close)return one(res,'content-close','host.close_session',{session_ref:owned.session_ref,request_key:key+'-close'});
 if(!results.has('closed-tail-0'))return hold(res,'closed');
 for(const kind of ['tail','command']){
  const args:any={recording_ref:recordingRef,max_bytes:6000,max_lines:100,...(kind==='command'?{range_kind:'command',command_ref:commandRef}:{})};let page=result(results,'closed-'+kind+'-0');
  if(!page)return one(res,'closed-'+kind+'-0','host.read_terminal',args);
  for(let i=1;page.next_cursor&&i<=6;i++){const id='closed-'+kind+'-'+i,next=result(results,id);if(!next)return one(res,id,'host.read_terminal',{...args,cursor:page.next_cursor});page=next}
  assert.equal(page.next_cursor,null,'small committed recording must finish within bounded continuation');assert.equal(page.source_ref,recordingRef);assert.equal(page.time_basis,'cast_first_event_elapsed_ms');assert.equal(page.complete,false);assert(contentText(page).includes(executionMarker),`${kind}: worker-replayed data must contain the original output`);
  if(kind==='tail'){assert.equal(page.coordinate_basis,'recorded_snapshot_logical_lines');assert(!contentText(page).includes('\x1b'))}else{assert.equal(page.command_ref,commandRef);assert.equal(page.output_scope,'session_interval')}
  report['closed_'+kind]=page;
 }
 report.execution=execution;report.owned=owned;report.recording_ref=recordingRef;report.command_ref=commandRef;report.close_receipt=close;return finish(res,stage);
}catch(error){failure??=String(error);await writeFile(join(out,'fixture-failure.txt'),failure);if(!res.headersSent)res.writeHead(500);res.end()}});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
const initialConfig=`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="patch-queries-fixture"\npermission_mode="confirm"\nexecution_mode="auto"\nsession_retention="keep"\n[[ai.providers]]\nid="patch-queries-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="patch-queries-fixture"\ncontext_window=200000\ndefault=true\n[log]\nring_mb=1\ncheckpoint_sec=1\n`;
await writeFile(join(data,'config.toml'),initialConfig);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;process.env.ZENIT_E2E_HTTP_JOB_ID='';
const log=await open(join(out,'app.log'),'w'),env:any={...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1',ZDOTDIR:zdot,OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''};for(const name of ['ZEROWORK_AI_MOCK','ZEROWORK_AI_ENDPOINT','ZEROWORK_AI_MODEL','ZEROWORK_AI_PROVIDER'])delete env[name];
const app=spawn(binary,[],{env,stdio:['ignore',log.fd,log.fd]});let spawnError:string|null=null;const ended=new Promise<void>(done=>{app.once('error',e=>{spawnError=String(e);done()});app.once('close',()=>done())});
const alive=()=>app.exitCode===null&&app.signalCode===null&&spawnError===null;
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[],text=(n:any):string=>flat(n).map((n:any)=>n.text??'').join('');
const visible=(id:string)=>h.waitFor(async()=>{assert.equal(failure,null);assert.equal(spawnError,null);return(await h.query(id)).find(shown)??null},20000);
const click=async(id:string)=>{report.last_action=id;const node=await visible(id);const result=id==='terminal.surface'?await h.clickAt(node.rect.x+node.rect.w/2,node.rect.y+node.rect.h/2):await h.clickTestId(id);assert(result.ok,`${id}: ${JSON.stringify(result)}`)};
const capture=async(name:string)=>{await h.mouseMove(1,1);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify({inventory:await h.query('ai.inventory_grant'),permission:await h.query('ai.permission.menu'),panel:await h.query('ai.panel'),group:await h.query('groups.workspace'),tabs:await h.query('tabs.strip')},null,2));report.screenshots.push(join(out,name+'.png'))};
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
async function inventoryGeometry(label:string){const root=await visible('ai.inventory_grant'),nodes=flat(root),icon=nodes.find((n:any)=>n.test_id==='ai.inventory_grant.icon'),title=nodes.find((n:any)=>n.test_id==='ai.inventory_grant.title'),copy=nodes.find((n:any)=>n.test_id==='ai.inventory_grant.explanation');assert(icon&&title&&copy);assert(Math.abs(icon.rect.y+icon.rect.h/2-title.rect.y-title.rect.h/2)<.5);assert.equal(icon.rect.w,16);assert.equal(icon.rect.h,16);for(const n of [icon,title,copy])assert.equal(n.effective_opacity??1,1);assert.equal(text(title),'查看其他会话');assert(text(copy).includes('名称、连接状态与分组'));assert(text(copy).includes('不会读取终端内容或执行命令'));assert(!/15\s*分钟|预授权/.test(text(root)));const buttons=['deny','allow_once','allow_conversation'].map(option=>{const button=nodes.find((n:any)=>n.test_id==='ai.inventory_grant.'+option&&shown(n));assert(button,option);assert(button.rect.x>=root.rect.x&&button.rect.x+button.rect.w<=root.rect.x+root.rect.w+.5);assert(button.rect.y>=root.rect.y&&button.rect.y+button.rect.h<=root.rect.y+root.rect.h+.5);return{id:option,rect:button.rect}});report.inventory_geometry??=[];report.inventory_geometry.push({label,icon:icon.rect,title:title.rect,explanation:copy.rect,buttons})}
async function drive(stage:string){
 finalStage=null;activeCall=null;await absent('ai.inventory_grant');await click('ai.prompt');await h.key('a',{cmd:true});await h.type_(`[Q-${stage}] 核验隔离本机任务，仅执行明确批准的固定 printf。`);await click('ai.send');const start=performance.now();
 while(finalStage!==stage&&performance.now()-start<150000){
  assert.equal(failure,null);assert(alive());const recovery=(await h.query('ai.recovery')).find(shown);assert(!recovery,`native provider failure: ${text(recovery)}`);
  if((await h.query('ai.inventory_grant')).some(shown)){
   assert.equal(stage,'GRANT');const choice=activeCall?.id==='grant-sessions'?'allow_conversation':activeCall?.id==='revoke-old-cursor'?'allow_once':null;assert(choice,`unexpected metadata approval: ${JSON.stringify(activeCall)}`);report.inventory_decisions??=[];assert(!report.inventory_decisions.some((decision:any)=>decision.call_id===activeCall.id));await inventoryGeometry(activeCall.id);await capture(activeCall.id+'-pending');report.inventory_decisions.push({call_id:activeCall.id,choice});await click('ai.inventory_grant.'+choice);await absent('ai.inventory_grant');
  }
  if((await h.query('ai.host_approval')).some(shown)){
   assert.equal(stage,'CONTENT','metadata/query denial must not request approval');assert(['content-group','content-open','content-run','content-close'].includes(activeCall?.id),JSON.stringify(activeCall));
   report.approved??=[];assert(!report.approved.includes(activeCall.id));
   if(activeCall.id==='content-run'){assert.equal(await exists(markerFile),false);assert.equal(text(await visible('ai.host_approval.target')),owned.session_ref);await click('ai.host_approval.copy');assert.equal((await promisify(execFile)('/usr/bin/pbpaste',[],{encoding:'utf8'})).stdout,command)}
   await capture('approval-'+activeCall.id);report.approved.push(activeCall.id);await click('ai.host_approval.accept');
  }
  if(held?.kind==='revoke'){
   await visible('ai.stop');await absent('ai.inventory_grant');await click('ai.composer.permission');await visible('ai.permission.menu');await visible('ai.permission.revoke_inventory');await capture('03-active-conversation-permission');await click('ai.permission.revoke_inventory');await absent('ai.permission.menu');await visible('ai.stop');await absent('ai.inventory_grant');await capture('04-revoked-same-task');
   release('revoke',[{id:'revoke-context',name:'host.get_current_context',arguments:{}},{id:'revoke-sessions',name:'host.list_sessions',arguments:{limit:200}},{id:'revoke-external',name:'host.get_session',arguments:{session_ref:external[0].session_ref}}]);
  }
  if(held?.kind==='execution-file'){
   if(await exists(markerFile)){assert.equal(await readFile(markerFile,'utf8'),executionMarker+'\n');await h.sleep(1100);release('execution-file',[{id:'content-wait',name:'host.wait_execution',arguments:{execution_ref:report.pending_execution.execution_ref,after_revision:report.pending_execution.source_revision,wait_ms:30000,max_bytes:8192}}])}
   else assert(performance.now()-held.at<15000,'real approved printf marker did not appear before the bounded observation deadline');
  }
  if(held?.kind==='closed'){
   for(const id of ['session.close.accept','local.close.accept'])if((await h.query(id)).some(shown))await click(id);
   if(!(await h.query('groups.pane.'+owned.session_id)).some(shown)){await capture('06-owned-closed-original-task-active');release('closed',[{id:'closed-tail-0',name:'host.read_terminal',arguments:{recording_ref:recordingRef,max_bytes:6000,max_lines:100}}])}
   else assert(performance.now()-held.at<20000,'owned terminal did not close normally');
  }
  if(finalStage!==stage)await h.sleep(80);
 }
 assert.equal(failure,null);assert.equal(finalStage,stage,'provider fixture did not finish');await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,20000);await visible('ai.turn.complete');await absent('ai.inventory_grant');
}
async function normalQuit(){
 report.normal_quit={route:'POST /quit',confirmations:[]};const start=performance.now();if(!alive())return;report.normal_quit.response=await h.request('POST','/quit');let unavailable=false;
 while(alive()&&performance.now()-start<20000){if(!unavailable)try{for(const id of ['groups.close.accept','local.close.accept','session.close.accept']){if(!alive())break;const nodes=await h.query(id);if(!Array.isArray(nodes)){unavailable=true;break}if(nodes.some(shown)){report.normal_quit.confirmations.push(id);assert((await h.clickTestId(id)).ok)}}}catch(error){unavailable=true;report.normal_quit.rpc_after_unbind=String(error)}if(alive())await Promise.race([ended,h.sleep(80)])}
 report.normal_quit.exit_code=app.exitCode;report.normal_quit.signal=app.signalCode;report.normal_quit.elapsed_ms=performance.now()-start;report.normal_quit.passed=report.normal_quit.response?.ok===true&&app.exitCode===0&&app.signalCode===null;
}
try{
 report.phase='startup';await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1440,900);
 await click('workspace.empty.local');await visible('terminal.surface');for(let i=0;i<2;i++){await click('toolbar.new_session');await click('session.menu.local');await visible('terminal.surface')}
 assert.equal(flat(await h.query('tabs.strip')).filter((n:any)=>/^tabs\.tab\.\d+$/.test(n.test_id??'')).length,3);await h.sleep(750);await click('terminal.surface');await h.type_(seedCommand);await h.key('return');await h.waitFor(async()=>await exists(seedFile)||null,15000);
 await click('toolbar.ai');await click('ai.maximize');await absent('ai.inventory_grant');await capture('01-default-current-binding');
 report.phase='default-scope-and-logical-lines';await drive('DEFAULT');await capture('02-default-real-live-queries');report.checks.push('With three real Local terminals, default metadata lists only the bound terminal. Actual native ANSI output becomes plain retained logical lines; tail, exact line range and literal search agree on the unwrapped long output line.');
 report.phase='ondemand-metadata-approval';await absent('ai.inventory_grant');await drive('GRANT');assert.deepEqual(report.inventory_decisions,[{call_id:'grant-sessions',choice:'allow_conversation'},{call_id:'revoke-old-cursor',choice:'allow_once'}]);report.checks.push('Only an explicit workspace list requests the real three-choice metadata approval. Conversation permission exposes precisely two extra metadata-only Local rows for workspace lists and pagination, leaves default lists scoped to the binding, and denies external content/execution before approval or dispatch. Grant/config revision stays unchanged, duration is conversation and expires_at is null.','Revoking through the existing permission menu keeps the same Task running and narrows subsequent metadata to the current binding. Reusing the original workspace cursor needs a fresh exact one-time approval and still returns SnapshotChanged/CursorExpired; the external session reference is rejected.');
 report.phase='owned-execution-and-worker-recording';await drive('CONTENT');await capture('07-worker-replayed-recording');assert.deepEqual(report.approved,['content-group','content-open','content-run','content-close']);assert.equal(await exists(forbiddenFile),false);assert.equal(await readFile(markerFile,'utf8'),executionMarker+'\n');
 assert.equal(await readFile(join(data,'config.toml'),'utf8'),initialConfig,'the test must leave theme, transparency and config revision unchanged');
 const manifests:any[]=[];for(const file of await readdir(data,{recursive:true}))if(String(file).endsWith('.json'))try{const document=JSON.parse(await readFile(join(data,String(file)),'utf8'));if(document.execution_ranges?.some((range:any)=>range.execution_id===execution.snapshot.execution_id))manifests.push({path:String(file),document})}catch{}
 assert.equal(manifests.length,1);assert.equal(manifests[0].document.state,'closed');await writeFile(join(out,'real-closed-recording-manifest.json'),JSON.stringify(manifests[0],null,2));await writeFile(join(out,'lifecycle-journal.json'),await readFile(join(data,'ai/lifecycle.json')));
 report.closed_recording_continuation_calls=[...calls.values()].filter(call=>call.id.startsWith('closed-')&&call.arguments.cursor).length;
 report.checks.push('An exact native approval runs one fixed printf in a real task-owned Local. Driver commandIndex returns the original submitted command and typed command_ref with verified exit 0 while complete=false; live command range returns its real observed interval.','The same Task closes only its owned Local normally, retains the original typed recording_ref from get_session, and reads the real closed manifest through worker checksum/VT replay. Logical tail and original typed command range expose the original output. '+(report.closed_recording_continuation_calls?`${report.closed_recording_continuation_calls} original cursor continuation calls reach ready data.`:'This small recording returns ready data in each first call; the continuation branch is not exercised.'),'The on-demand approval is absent at idle, its icon and title share a center line, all three decisions and metadata-only disclosure remain visible, and theme/transparency/config bytes are unchanged.');
 report.acceptance_passed=true;
}catch(error){report.status='failed';report.error=failure??String(error);report.primary_failure={phase:report.phase,reason:report.error,last_action:report.last_action};process.exitCode=1;await capture('failure').catch(()=>{});await h.tree().then((tree:any)=>writeFile(join(out,'failure-tree.json'),JSON.stringify(tree,null,2))).catch(()=>{})}
finally{
 quitting=true;if(held){held.res.destroy();held=null}await normalQuit().catch(error=>{report.normal_quit_error=String(error)});
 let forced=false;if(alive()){forced=true;app.kill('SIGTERM');await Promise.race([ended,h.sleep(2000)])}if(alive()){app.kill('SIGKILL');await ended}report.cleanup={forced,exit_code:app.exitCode,signal:app.signalCode,spawn_error:spawnError};
 report.status=report.acceptance_passed&&report.normal_quit?.passed&&!forced?'passed':'failed';if(report.status==='failed'){report.error??='normal Quit did not exit with code 0';process.exitCode=1}else report.checks.push('POST /quit confirms remaining owned test Local sessions, drains the real application and exits with code 0 and no signal.');
 server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();report.fixture_failure=failure;report.calls=[...calls.values()];report.observations=Object.fromEntries(observations);report.requests=requests;
 const rawLog=await readFile(join(out,'app.log'),'utf8'),feedback:any[]=[];for(const line of rawLog.split('\n')){const at=line.indexOf('AI_TOOL_TRACE ');if(at<0)continue;try{const event=JSON.parse(line.slice(at+14));if(event.event==='tool_feedback'&&calls.has(event.call_id))feedback.push({...event,envelope:JSON.parse(event.content)})}catch{}}
 report.native_errors=rawLog.split('\n').filter(line=>line.includes('ai worker turn failed:'));await writeFile(join(out,'trace-tool-feedback.json'),JSON.stringify(feedback,null,2));await writeFile(join(out,'lifecycle-journal.json'),await readFile(join(data,'ai/lifecycle.json'))).catch(()=>{});
 if(execution?.snapshot?.execution_id){const found:any[]=[];for(const path of await readdir(data,{recursive:true}))if(String(path).endsWith('.json'))try{const document=JSON.parse(await readFile(join(data,String(path)),'utf8'));if(document.execution_ranges?.some((range:any)=>range.execution_id===execution.snapshot.execution_id))found.push({path:String(path),document})}catch{}await writeFile(join(out,'execution-recording-manifests.json'),JSON.stringify(found,null,2))}
 await writeFile(join(out,'raw-call-results.json'),JSON.stringify(report.observations,null,2));await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(JSON.stringify({status:report.status,error:report.error,report:join(out,'report.json')}));
