/** Production Bridge + actual Local terminal + the user's Magpie gateway. */
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-patch-discovery-native';
const model=process.env.ZW_AI_TEST_MODEL??'codex/gpt-6.1-sol';
const gateway=process.env.ZW_AI_TEST_GATEWAY??'http://127.0.0.1:3425/v1';
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-host-discovery-live');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-host-discovery-')),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
await Promise.all([mkdir(data),mkdir(rpc),mkdir(zdot)]);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='discovery-test%# '\n");
const marker='ZW_DISCOVERY_'+randomBytes(16).toString('hex');
const requests:any[]=[];let lastAnswer='',forwardFailure:string|null=null;
const server=createServer(async(req,res)=>{
 try{
  if(req.method!=='POST'){const upstream=await fetch(gateway.replace(/\/$/,'')+'/models',{headers:{authorization:'Bearer local-gateway'}});res.writeHead(upstream.status,{'content-type':'application/json'});res.end(await upstream.text());return;}
  let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);
  const tools=body.messages.filter((m:any)=>m.role==='tool').map((m:any)=>({call_id:m.tool_call_id,...JSON.parse(m.content)}));
  requests.push({model:body.model,tool_names:body.tools.map((t:any)=>t.function.name),calls:body.messages.flatMap((m:any)=>m.tool_calls??[]).map((c:any)=>({id:c.id,name:c.function.name})),results:tools.map((r:any)=>({call_id:r.call_id,status:r.status,local_released:r.receipt?.local_released??r.local_released,remote_effect_unknown:r.receipt?.remote_effect_unknown??r.remote_effect_unknown})),system_has_dynamic_facts:/assistant_session_id=|provider=.*session_id=/.test(body.messages.find((m:any)=>m.role==='system')?.content??'')});
  const upstream=await fetch(gateway.replace(/\/$/,'')+'/chat/completions',{method:'POST',headers:{'content-type':'application/json',authorization:'Bearer local-gateway'},body:raw,signal:AbortSignal.timeout(120000)});
  res.writeHead(upstream.status,{'content-type':upstream.headers.get('content-type')??'text/event-stream'});
  let pending='',answer='';const decoder=new TextDecoder();
  for await(const part of upstream.body!){res.write(part);pending+=decoder.decode(part,{stream:true});let end;while((end=pending.indexOf('\n'))>=0){const line=pending.slice(0,end).trim();pending=pending.slice(end+1);if(!line.startsWith('data:')||line==='data: [DONE]')continue;try{const event=JSON.parse(line.slice(5));answer+=event.choices?.[0]?.delta?.content??'';}catch{}}}
  lastAnswer=answer;res.end();
 }catch(e){forwardFailure=String(e);if(!res.headersSent)res.writeHead(502);res.end();}
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ai]\ndefault_provider="magpie-live"\npermission_mode="confirm"\n[[ai.providers]]\nid="magpie-live"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\napi_key="local-gateway"\nenabled=true\n[[ai.providers.models]]\nname="${model}"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1',ZDOTDIR:zdot,OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,20000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const report:any={status:'running',model,gateway,checks:[],limits:['Actual native Local and Magpie text provider; SSH and image semantics are outside this case.']};
try{
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await h.sleep(700);await click('terminal.surface');
 const ready=join(iso,'ready');await h.type_(`printf '${marker}\\n'; printf ready > '${ready}'`);await h.key('return');
 await h.waitFor(async()=>{try{return await readFile(ready,'utf8')==='ready'||null}catch{return null}},15000);
 await click('toolbar.ai');await click('ai.maximize');await click('ai.prompt');
 await h.type_('先调用对话状态和会话列表查询工具确认当前目标，再读取当前终端。只返回终端中以 ZW_DISCOVERY_ 开头的完整随机标记。不得猜测标记，不得执行命令。');await click('ai.send');
 await h.waitFor(async()=>(await h.query('ai.turn.complete')).some(shown)||null,150000);
 assert.equal(forwardFailure,null);assert(lastAnswer.includes(marker),'model must echo the unpredictable marker from the actual terminal');
 assert(requests.every(r=>!r.system_has_dynamic_facts));const calls=requests.flatMap(r=>r.calls);
 for(const name of ['host__get_ucurrent_ucontext','host__list_usessions','read_terminal'])assert(calls.some((c:any)=>c.name===name),name);
 assert(!calls.some((c:any)=>c.name==='run_command'));
 assert(!String(await readFile(join(out,'app.log'),'utf8')).includes('"event":"exec_started"'));
 assert((await h.screenshot(join(out,'completed.png'))).ok);
 report.status='passed';report.requests=requests;report.random_marker_echoed=true;
 report.checks.push('Real model discovers the native conversation and session through registered host tools','Production read_terminal returns the actual Local output and the model echoes an unpredictable marker','No dynamic session facts are injected into system rules; no command execution is dispatched');
}catch(e){report.status='failed';report.error=String(e);report.requests=requests;process.exitCode=1;await h.screenshot(join(out,'failure.png')).catch(()=>{});await writeFile(join(out,'failure-tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{});}
finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(iso,{recursive:true,force:true});}
console.log(JSON.stringify(report));
