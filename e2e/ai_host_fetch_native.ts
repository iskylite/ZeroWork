/** Complete App host.fetch_url acceptance. The SSE fixture emits only the real
 * registered fetch tool. No user config, proxy bypass, SSH or remote model. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {execFileSync} from 'node:child_process';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-patch-integrated');
const binary=resolve(process.env.ZW_AI_TEST_BINARY??join(prefix,'bin/zerowork'));
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'dist/ui-acceptance/ai-host-fetch-integrated');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-ai-host-fetch-')),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
const publicUrl='https://example.com/docs/release-notes?version=0.2.6';
const stages=['REJECT','STOP','PROXY','BACKGROUND'] as const;
type Stage=typeof stages[number];
const callId=(stage:Stage)=>`fetch-${stage.toLowerCase()}-original-call`;
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const toolFrame=(stage:Stage)=>frame({tool_calls:[{index:0,id:callId(stage),type:'function',function:{name:'host__fetch_uurl',arguments:JSON.stringify({url:publicUrl})}}]})+'data: [DONE]\n\n';
const requests:any[]=[],observations:Partial<Record<Stage,any>>={};let background:any=null,fixtureFailure:string|null=null;
const stageOf=(body:any):Stage=>{
 const question=body.messages.findLast((m:any)=>m.role==='user')?.content??'';
 const stage=stages.find(value=>String(question).includes(`[G-${value}]`));assert(stage,'expected an explicit fixture stage');return stage;
};
const networkBody=(envelope:any)=>{
 for(const block of envelope.content??[])if(block.type==='structured'||block.type==='text'){try{const value=JSON.parse(block.text);if(value.execution_location==='client')return value;}catch{}}
 return envelope;
};
const checkUnsent=(envelope:any)=>{
 const body=networkBody(envelope),receipt=envelope.receipt??envelope;
 assert.equal(body.request_sent??receipt.request_sent,false,'an unsent receipt must say request_sent=false explicitly');
 assert.equal(receipt.side_effect_started??body.side_effect_started,false);
 assert.equal(receipt.local_released??body.local_released,true);
 assert.equal(receipt.remote_effect_unknown??body.remote_effect_unknown,false);
};
const server=createServer(async(req,res)=>{
 try{
  if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'host-fetch-fixture'}]}));return;}
  let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw),stage=stageOf(body);
  const current=body.messages.slice(body.messages.findLastIndex((m:any)=>m.role==='user')+1),result=current.find((m:any)=>m.role==='tool'&&m.tool_call_id===callId(stage));
  const definition=body.tools?.find((tool:any)=>tool.function.name==='host__fetch_uurl');assert(definition,'host.fetch_url must be advertised by the production catalog');
  assert.deepEqual(Object.keys(definition.function.parameters.properties),['url']);assert.deepEqual(definition.function.parameters.required,['url']);assert.equal(definition.function.parameters.additionalProperties,false);
  assert(!/assistant_session_id=|provider=.*session_id=/.test(body.messages.find((m:any)=>m.role==='system')?.content??''));
  requests.push({stage,result_id:result?.tool_call_id??null,tool_names:body.tools.map((tool:any)=>tool.function.name),tool_calls:current.flatMap((m:any)=>m.tool_calls??[]).map((call:any)=>({id:call.id,name:call.function.name}))});
  res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
  if(result){
   const envelope=JSON.parse(result.content);observations[stage]={call_id:result.tool_call_id,envelope};
   if(stage==='REJECT'||stage==='BACKGROUND'){assert.equal(envelope.error_code,'ToolApprovalRejected');assert.equal(envelope.status,'rejected');checkUnsent(envelope);}
   if(stage==='PROXY'){
    const net=networkBody(envelope);assert.equal(net.code,'CapabilityUnavailable');assert.equal(net.execution_location,'client');assert.equal(net.requested_url,publicUrl);assert.equal(net.http_status,null);assert.equal(net.text,'');checkUnsent(envelope);
   }
   res.end(frame({content:`[G-${stage}] 已保留本次本机读取的真实结果。`})+'data: [DONE]\n\n');return;
  }
  if(stage==='BACKGROUND'){assert.equal(background,null);background=res;return;}
  res.end(toolFrame(stage));
 }catch(error){fixtureFailure=String(error);if(!res.headersSent)res.writeHead(500);res.end();}
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ai]\ndefault_provider="host-fetch-fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="host-fetch-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="host-fetch-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w'),app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(resolve=>app.once('close',resolve));
const shown=(node:any)=>node&&node.hidden!==true&&node.visible!==false&&(node.effective_opacity??1)>0&&node.rect?.w>0&&node.rect?.h>0;
const text=(node:any):string=>node.text??(node.children??[]).map(text).join('');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const send=async(stage:Stage)=>{await click('ai.prompt');await h.key('a',{cmd:true});await h.type_(`[G-${stage}] 获取已知公共URL资料，按本次独立网络授权执行。`);await click('ai.send');};
const capture=async(name:string)=>{await h.mouseMove(1,1);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2));};
const pending=async()=>{
 await visible('ai.host_approval');assert.equal(text(await visible('ai.host_approval.title')),'获取网页');
 const address=await visible('ai.host_approval.address_bar');assert.equal(address.rect.h,38);
 const icon=await visible('ai.host_approval.icon.network'),title=await visible('ai.host_approval.title');assert(Math.abs(icon.rect.y+icon.rect.h/2-title.rect.y-title.rect.h/2)<.5);
 assert.equal(text(await visible('ai.host_approval.url')),publicUrl);
 assert(!(await h.query('ai.approval')).some(shown),'host URL approval must not use the legacy session approval');
};
const complete=async(stage:Stage)=>{
 await absent('ai.host_approval');await absent('ai.stop');
 await h.waitFor(async()=>observations[stage]||fixtureFailure?true:null,15000);assert.equal(fixtureFailure,null);
 assert(observations[stage]);await visible('ai.turn.complete');
};
const traceEvents=async()=>{
 const raw=await readFile(join(out,'app.log'),'utf8'),events:any[]=[];
 for(const line of raw.split('\n')){const start=line.indexOf('AI_TOOL_TRACE ');if(start<0)continue;try{events.push(JSON.parse(line.slice(start+14)));}catch{}}
 return events;
};
const report:any={status:'running',binary,checks:[],limits:['Full native application, actual host catalog/Bridge/independent approval/Gate/results and notification routing; only model output is supplied by a local SSE fixture.','Current configured system proxy is tested as a real CapabilityUnavailable boundary; this run does not establish direct public-network 200/redirect/compressed-body success.']};
try{
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 // Inspect the actual local proxy state without changing it. This test is
 // intentionally specific to the current required production proxy boundary.
 const proxy=execFileSync('/usr/sbin/scutil',['--proxy'],{encoding:'utf8'});assert(/HTTPSEnable\s*:\s*1/.test(proxy),'this acceptance case requires the configured HTTPS proxy');report.system_https_proxy_enabled=true;
 await h.resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.maximize');
 await send('REJECT');await pending();await h.resizeWindow(860,480);
 await h.waitFor(async()=>{const node=(await h.query('ai.panel')).find(shown);return node&&node.rect.x+node.rect.w<=860.5&&node.rect.y+node.rect.h<=480.5?true:null;},10000);
 const panel=await visible('ai.panel'),viewport=await visible('ai.conversation.viewport'),bar=await visible('ai.host_approval.address_bar'),accept=await visible('ai.host_approval.accept'),reject=await visible('ai.host_approval.reject');
 for(const node of [bar,accept,reject]){assert(node.rect.x>=0&&node.rect.y>=0&&node.rect.x+node.rect.w<=860.5&&node.rect.y+node.rect.h<=480.5);assert(node.rect.y>=viewport.rect.y-.5&&node.rect.y+node.rect.h<=viewport.rect.y+viewport.rect.h+.5,'approval actions/address must be inside the real conversation viewport');}
 assert(panel.rect.w<=860);await capture('01-reject-pending-860x480');await click('ai.host_approval.reject');await complete('REJECT');await capture('02-rejected-original-call');
 report.checks.push('The real host.fetch_url catalog has the fixed URL-only schema; native 860×480 address/decisions are visible and actionable','Reject returns ToolApprovalRejected against the exact original provider call, with explicit unsent/released facts');

 await send('STOP');await pending();await capture('03-stop-pending');const stoppedAt=performance.now();await click('ai.stop');await absent('ai.host_approval');await absent('ai.stop');
 const stopped=await h.waitFor(async()=>{const event=(await traceEvents()).find(event=>event.event==='tool_feedback'&&event.call_id===callId('STOP'));return event??null;},15000);
 const stopEnvelope=JSON.parse(stopped.content);assert.equal(stopEnvelope.error_code,'CancelledBeforeDispatch');checkUnsent(stopEnvelope);assert(performance.now()-stoppedAt<10000);assert(!observations.STOP,'Stop must not start a subsequent provider round for the cancelled task');
 report.stop={call_id:callId('STOP'),elapsed_ms:performance.now()-stoppedAt,envelope:stopEnvelope};await capture('04-stopped-released');
 report.checks.push('Stop cancels the pending independent host approval, releases the original call and leaves an explicit unsent result without a new provider request');

 await send('PROXY');await pending();await click('ai.host_approval.accept');await complete('PROXY');await capture('05-approved-real-proxy-boundary');
 report.checks.push('A fresh task can request approval after Stop; approval reaches the production local HTTP backend and reports the actual configured-proxy CapabilityUnavailable with request_sent=false');

 await h.resizeWindow(1440,900);await send('BACKGROUND');await h.waitFor(async()=>background||fixtureFailure?true:null,10000);assert.equal(fixtureFailure,null);
 await click('ai.session.new');await visible('ai.prompt');await click('ai.prompt');await h.type_('G 测试另一对话独立草稿');assert.equal((await h.inputState('ai.prompt')).buffer,'G 测试另一对话独立草稿');
 const held=background;background=null;held.end(toolFrame('BACKGROUND'));
 await visible('notifications.unread');assert(!(await h.query('ai.host_approval')).some(shown));await click('toolbar.notifications');await visible('notifications.history.action');await capture('06-background-host-approval-reminder');
 await click('notifications.history.action');await absent('notifications.history');await pending();assert.notEqual((await h.inputState('ai.prompt')).buffer,'G 测试另一对话独立草稿');await capture('07-original-dialog-host-approval');
 await click('ai.host_approval.reject');await complete('BACKGROUND');
 const originCid=observations.REJECT.envelope.conversation_id??observations.REJECT.envelope.receipt?.conversation_id;
 const returnedCid=observations.BACKGROUND.envelope.conversation_id??observations.BACKGROUND.envelope.receipt?.conversation_id;assert(originCid&&returnedCid);assert.equal(returnedCid,originCid);
 await click('ai.sessions');await visible('ai.session.jump.2');await click('ai.session.jump.2');await absent('ai.sessions.menu');assert.equal((await h.inputState('ai.prompt')).buffer,'G 测试另一对话独立草稿');
 report.checks.push('A background host approval generates a reminder that returns to the exact original ConversationId; the other conversation retains its independent draft');
 assert.equal(fixtureFailure,null);assert.deepEqual(requests.flatMap(request=>request.tool_calls).map(call=>call.name).filter((value,index,all)=>all.indexOf(value)===index),['host__fetch_uurl']);
 const events=await traceEvents();assert(!events.some(event=>event.event==='exec_started'),'fetch must never dispatch the terminal command backend');
 report.status='passed';report.requests=requests;report.observations=observations;
}catch(error){report.status='failed';report.error=String(error);report.fixture_failure=fixtureFailure;report.requests=requests;report.observations=observations;process.exitCode=1;await capture('failure').catch(()=>{});await writeFile(join(out,'failure-tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{});}
finally{background?.destroy();if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(iso,{recursive:true,force:true});}
console.log(JSON.stringify(report,null,2));
