/** Production Bridge + actual Local terminal + the approved local Magpie gateway.
 * Default mode retains explicit context/list/read capability acceptance.
 * ZW_AI_TEST_MINIMAL_READ=1 tests production guidance with a natural current-terminal
 * request: exactly one read_terminal, no preparatory discovery or side effects.
 * Requires a delivered candidate and the native-app slot; never retries a model run.
 */
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const minimalRead=process.env.ZW_AI_TEST_MINIMAL_READ==='1';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-patch-discovery-native');
const binary=resolve(process.env.ZW_AI_TEST_BINARY??join(prefix,'bin/zerowork'));
const binarySha256=createHash('sha256').update(await readFile(binary)).digest('hex');
if(minimalRead){
 assert(process.env.ZW_AI_TEST_PREFIX,'minimal-read acceptance requires an explicitly delivered candidate');
 assert.match(process.env.ZW_AI_TEST_EXPECTED_SHA256??'',/^[a-f0-9]{64}$/,'the delivered candidate SHA-256 is required');
 assert.equal(binarySha256,process.env.ZW_AI_TEST_EXPECTED_SHA256,'candidate differs from the explicitly delivered build');
}
const model=process.env.ZW_AI_TEST_MODEL??'codex/gpt-6.1-sol';
assert(['grok/grok-4.7@500k','codex/gpt-6.1-sol','auto/glm-5.3'].includes(model),'choose one approved real model');
const gateway=process.env.ZW_AI_TEST_GATEWAY??'http://127.0.0.1:3425/v1';
assert.equal(gateway,'http://127.0.0.1:3425/v1','only the approved local Magpie gateway is in scope');
process.env.ZENIT_E2E_HTTP_JOB_ID='';
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-host-discovery-live');await mkdir(out,{recursive:true});
try{await readFile(join(out,'report.json'));throw new Error('evidence directory already contains a run; use a fresh path')}catch(e:any){if(e.code!=='ENOENT')throw e}
const iso=await realpath(await mkdtemp('/tmp/zw-host-discovery-')),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
await Promise.all([mkdir(data),mkdir(rpc),mkdir(zdot)]);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='discovery-test%# '\n");
type Call={id:string,name:string,wire:string,arguments:any};
const requests:any[]=[],responses:any[]=[],providerProbes:any[]=[];
const calls=new Map<string,Call>(),results=new Map<string,any>();
let marker='',lastAnswer='',providerFailure:string|null=null,quitting=false,forwardedRequests=0;
const report:any={status:'running',mode:minimalRead?'minimal_read':'explicit_discovery',model,gateway,binary,binary_sha256:binarySha256,started_at:new Date().toISOString(),checks:[],isolation:{directory:iso,data,rpc,zdot,preserved:true},limits:['Actual native Local and real Magpie text provider; SSH and image semantics are outside this case.','Provider responses are buffered for the read-only boundary and forwarded unchanged. Raw requests, responses and original tool results are preserved; no model or tool result is fabricated.']};
const logical=(name:string)=>name.replaceAll('__','.').replaceAll('_u','_');
const readOnly=['read_terminal','host.get_current_context','host.list_sessions','host.get_session','host.list_groups','host.get_group','host.list_group_members','host.wait_session_ready','host.get_execution','host.wait_execution'];
function terminalOutput(target:any):string{
 if(typeof target.stdout==='string')return target.stdout;
 return(target.content??[]).flatMap((block:any)=>{
  if(block.type!=='structured')return[];
  try{const value=JSON.parse(block.text);return value.status==='succeeded'&&typeof value.stdout==='string'?[value.stdout]:[]}catch{return[]}
 }).join('\n');
}
function observeRequest(body:any){
 assert.equal(body.model,model);
 const system=String(body.messages.find((m:any)=>m.role==='system')?.content??'');
 const dynamicFacts=/assistant_session_id=|provider=.*session_id=/.test(system)||!!marker&&system.includes(marker);
 const schema=body.tools?.find((t:any)=>t.function.name==='read_terminal')?.function.parameters;
 const summary:any={at:new Date().toISOString(),model:body.model,tool_names:(body.tools??[]).map((t:any)=>t.function.name),read_terminal_schema:schema,system_has_dynamic_facts:dynamicFacts,messages:[]};
 requests.push(summary);
 assert(!dynamicFacts,'dynamic session or terminal facts must not be injected into system rules');
 if(minimalRead){
  const targets=schema?.properties?.session_ids;
  assert.equal(targets?.items?.enum?.length,1,'read_terminal schema must advertise exactly one authorized session ID');
  assert.equal(targets.maxItems,1);assert.equal(targets.items.enum[0]>0,true);
  if(requests.length===1)assert(!JSON.stringify(body.messages).includes(marker),'the nonce must not reach the model before the actual terminal result');
 }
 for(const message of body.messages){
  if(message.role==='tool'){
   const call=calls.get(message.tool_call_id);assert(call,'tool result must correspond to an actual provider call');
   const envelope=JSON.parse(message.content);
   if(results.has(call.id))assert.deepEqual(results.get(call.id),envelope,'historical tool result changed');
   results.set(call.id,envelope);summary.messages.push({role:'tool',call_id:call.id,name:call.name,status:envelope.status??null,targets:envelope.targets?.map((t:any)=>({session_id:t.session_id,status:t.status,stdout_characters:terminalOutput(t).length}))});
  }else summary.messages.push({role:message.role,...(message.tool_calls?{calls:message.tool_calls.map((c:any)=>({id:c.id,name:logical(c.function.name),arguments:JSON.parse(c.function.arguments)}))}:{characters:String(message.content??'').length})});
 }
}
function parseProvider(raw:string,contentType:string){
 let answer='',proposed:any[]=[];
 if(contentType.includes('text/event-stream')){
  const fragments=new Map<number,any>();
  for(const line of raw.split(/\r?\n/)){
   if(!line.startsWith('data:')||line.slice(5).trim()==='[DONE]')continue;
   const event=JSON.parse(line.slice(5));assert(!event.error,JSON.stringify(event.error));
   const delta=event.choices?.[0]?.delta??{};answer+=delta.content??'';
   for(const part of delta.tool_calls??[]){
    const call=fragments.get(part.index)??{id:'',function:{name:'',arguments:''}};
    if(part.id)call.id+=part.id;if(part.function?.name)call.function.name+=part.function.name;if(part.function?.arguments)call.function.arguments+=part.function.arguments;fragments.set(part.index,call);
   }
  }
  proposed=[...fragments.entries()].sort((a,b)=>a[0]-b[0]).map(([,v])=>v);
 }else{
  const event=JSON.parse(raw);assert(!event.error,JSON.stringify(event.error));const message=event.choices?.[0]?.message??{};answer=message.content??'';proposed=message.tool_calls??[];
 }
 const parsed:Call[]=proposed.map(c=>({id:c.id,wire:c.function.name,name:logical(c.function.name),arguments:JSON.parse(c.function.arguments)}));
 responses.push({at:new Date().toISOString(),answer,calls:parsed});lastAnswer=answer;
 for(const call of parsed){
  assert(!calls.has(call.id),'provider must not replay a call ID');calls.set(call.id,call);
  assert(readOnly.includes(call.name),`out-of-scope tool proposed at the read-only boundary: ${call.name}`);
 }
}
const server=createServer(async(req,res)=>{
 try{
  assert(!quitting,'provider request arrived during teardown');
  assert.equal(providerFailure,null,'a failed real-provider attempt must not be retried');
  if(req.method==='GET'){
   assert(['/v1/models','/models'].includes(req.url??''));
   const upstream=await fetch(gateway+'/models',{headers:{authorization:'Bearer local-gateway'},signal:AbortSignal.timeout(30000)});
   const response=await upstream.text();providerProbes.push({path:req.url,status:upstream.status});res.writeHead(upstream.status,{'content-type':upstream.headers.get('content-type')??'application/json'});res.end(response);return;
  }
  assert.equal(req.method,'POST');assert.equal(req.url,'/v1/chat/completions');
  let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw),index=requests.length+1;
  await writeFile(join(out,`request-${index}.json`),raw);observeRequest(body);
  forwardedRequests++;
  const upstream=await fetch(gateway+'/chat/completions',{method:'POST',headers:{'content-type':'application/json',authorization:'Bearer local-gateway'},body:raw,signal:AbortSignal.timeout(120000)});
  const contentType=upstream.headers.get('content-type')??'',response=await upstream.text();
  await writeFile(join(out,`response-${index}.txt`),response);responses.push({request:index,http_status:upstream.status,content_type:contentType,raw_file:`response-${index}.txt`});
  assert(upstream.ok,`real gateway HTTP ${upstream.status}: ${response.slice(0,500)}`);parseProvider(response,contentType);
  res.writeHead(upstream.status,{'content-type':contentType});res.end(response);
 }catch(e){providerFailure??=String(e);if(!res.headersSent)res.writeHead(502,{'content-type':'application/json'});res.end(JSON.stringify({error:'live acceptance boundary or gateway failure'}));}
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ai]\ndefault_provider="magpie-live"\npermission_mode="confirm"\nsession_retention="ask"\n[[ai.providers]]\nid="magpie-live"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\napi_key="local-gateway"\nenabled=true\n[[ai.providers.models]]\nname="${model}"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1',ZDOTDIR:zdot,OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
let spawnError:string|null=null,appClosedAt:number|null=null;
const ended=new Promise<void>(done=>{app.once('error',e=>{spawnError=String(e);done()});app.once('close',()=>{appClosedAt=performance.now();done()})});
const alive=()=>app.exitCode===null&&app.signalCode===null&&spawnError===null;
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>{assert.equal(providerFailure,null);assert.equal(spawnError,null);return(await h.query(id)).find(shown)??null},20000);
const click=async(id:string)=>{report.last_action=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
async function normalQuit(){
 const start=performance.now();report.normal_quit={attempted:true,route:'POST /quit',confirmations:[]};
 if(!alive()){report.normal_quit.before_request={exit_code:app.exitCode,signal:app.signalCode,spawn_error:spawnError};return}
 try{report.normal_quit.response=await h.request('POST','/quit');}catch(error){report.normal_quit.request_error=String(error)}
 let rpcUnavailable=false;
 while(alive()&&performance.now()-start<20000){
  if(!rpcUnavailable)try{
   for(const id of ['groups.close.accept','local.close.accept','session.close.accept']){
    if(!alive())break;const nodes=await h.query(id);if(!Array.isArray(nodes)){rpcUnavailable=true;break}
    if(nodes.some(shown)){report.normal_quit.confirmations.push(id);assert((await h.clickTestId(id)).ok,id)}
   }
  }catch(error){report.normal_quit.rpc_after_unbind=String(error);rpcUnavailable=true}
  if(alive())await Promise.race([ended,h.sleep(80)]);
 }
 await Promise.race([ended,h.sleep(200)]);report.normal_quit.exit_code=app.exitCode;report.normal_quit.signal=app.signalCode;report.normal_quit.elapsed_ms=(appClosedAt??performance.now())-start;
 report.normal_quit.passed=report.normal_quit.response?.ok===true&&app.exitCode===0&&app.signalCode===null;
}
try{
 report.phase='startup';
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 report.phase='terminal_fixture';
 await h.resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await h.sleep(700);await click('terminal.surface');
 const ready=join(iso,'ready');
 await h.type_(`discovery_marker="ZW_DISCOVERY_$(/usr/bin/uuidgen)"; printf '%s\\n' "$discovery_marker"; printf '%s' "$discovery_marker" > '${ready}'`);await h.key('return');
 await h.waitFor(async()=>{try{marker=await readFile(ready,'utf8');return /^ZW_DISCOVERY_[0-9A-F-]{36}$/i.test(marker)||null}catch{return null}},15000);
 await writeFile(join(out,'terminal-marker.txt'),marker);
 await click('toolbar.ai');await click('ai.maximize');await click('ai.prompt');
 const prompt=minimalRead?'请查看当前会话终端里可见的内容，只返回其中以 ZW_DISCOVERY_ 开头的完整随机标记。标记必须从实际终端内容读取，不得猜测，也不要执行命令。':'先调用对话状态和会话列表查询工具确认当前目标，再读取当前终端。只返回终端中以 ZW_DISCOVERY_ 开头的完整随机标记。不得猜测标记，不得执行命令。';
 await writeFile(join(out,'user-prompt.txt'),prompt);assert(!prompt.includes(marker));await h.type_(prompt);report.phase='model_turn';await click('ai.send');
 const turnStarted=performance.now();let turnComplete=false;
 while(performance.now()-turnStarted<150000){
  assert.equal(providerFailure,null);assert(alive(),'application exited before model acceptance');
  assert(!(await h.query('ai.recovery')).some(shown),'production AI entered recovery; inspect captured wire evidence');
  assert(!(await h.query('ai.approval')).some(shown)&&!(await h.query('ai.host_approval')).some(shown),'read-only acceptance must not request side-effect approval');
  if((await h.query('ai.turn.complete')).some(shown)&&!(await h.query('ai.stop')).some(shown)){turnComplete=true;break}
  await h.sleep(100);
 }
 assert(turnComplete,'the real provider turn did not complete within the bounded deadline');
 report.phase='model_acceptance';assert.equal(providerFailure,null);assert(lastAnswer.includes(marker),'model must echo the unpredictable marker from the actual terminal');
 const actualCalls=[...calls.values()];
 if(minimalRead){assert.equal(actualCalls.length,1,'unambiguous current-terminal read must use exactly one tool call');assert.equal(actualCalls[0].name,'read_terminal');assert.deepEqual(actualCalls[0].arguments.session_ids,requests[0].read_terminal_schema.properties.session_ids.items.enum)}
 else for(const name of ['host.get_current_context','host.list_sessions','read_terminal'])assert(actualCalls.some(c=>c.name===name),name);
 const reads=actualCalls.filter(c=>c.name==='read_terminal');assert(reads.some(c=>results.get(c.id)?.targets?.some((t:any)=>t.status==='succeeded'&&terminalOutput(t).includes(marker))),'the actual successful read_terminal target stdout must contain the shell-generated nonce');
 assert(!String(await readFile(join(out,'app.log'),'utf8')).includes('"event":"exec_started"'),'no execution may be dispatched');
 assert((await h.screenshot(join(out,'completed.png'))).ok);report.acceptance_passed=true;report.random_marker_echoed=true;
 report.checks.push(minimalRead?'Natural current-terminal request uses exactly one read_terminal from the unique authorized schema target, with zero preparatory discovery calls.':'Real model discovers the native conversation and session through registered host tools.','Production read_terminal returns actual Local output and the model echoes a shell-generated unpredictable marker.','No dynamic session facts are injected into system rules; no command or side-effect tool is dispatched.');
}catch(e){report.status='failed';report.error=providerFailure??String(e);report.primary_failure={phase:report.phase??'startup',reason:report.error};process.exitCode=1;await h.screenshot(join(out,'failure.png')).catch(()=>{});await h.tree().then((tree:any)=>writeFile(join(out,'failure-tree.json'),JSON.stringify(tree,null,2))).catch(()=>{});}
finally{
 quitting=true;await normalQuit().catch(error=>{report.normal_quit_error=String(error)});
 let forced=false;if(alive()){forced=true;app.kill('SIGTERM');await Promise.race([ended,h.sleep(2000)])}if(alive()){app.kill('SIGKILL');await ended}
 report.cleanup={exit_code:app.exitCode,signal:app.signalCode,forced,spawn_error:spawnError};
 if(report.acceptance_passed&&report.normal_quit?.passed&&!forced){report.status='passed';report.checks.push('Actual POST /quit exits the application with code 0, no signal and no forced fallback.')}
 else{report.status='failed';report.error??='normal application Quit with code 0 was not achieved';report.primary_failure??={phase:'normal_quit',reason:report.error};process.exitCode=1}
 report.provider_failure=providerFailure;report.provider_probes=providerProbes;report.forwarded_model_requests=forwardedRequests;report.requests=requests;report.responses=responses;report.calls=[...calls.values()];report.results=Object.fromEntries(results);report.answer=lastAnswer;
 server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();
 if(report.status==='passed'){await rm(iso,{recursive:true,force:true});report.isolation.preserved=false}
 report.finished_at=new Date().toISOString();await writeFile(join(out,'provider-wire-summary.json'),JSON.stringify({requests,responses},null,2));await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(JSON.stringify({status:report.status,mode:report.mode,model,error:report.error,forwarded_model_requests:forwardedRequests,normal_quit:report.normal_quit,cleanup:report.cleanup,isolation:report.isolation,report:join(out,'report.json')}));
