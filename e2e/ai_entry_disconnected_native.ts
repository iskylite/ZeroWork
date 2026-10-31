/** AI entry regression: real native local zsh, two actual terminal tool turns,
 * retained ended Tab, all three entry points and a tools-free offline turn.
 * ZW_AI_TEST_PREFIX=/tmp/zw-ai-entry-build node e2e/ai_entry_disconnected_native.ts /tmp/zw-ai-entry-offline
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,writeFile,readFile,open,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/private/tmp/zw-ai-entry-build');
const out=resolve(process.argv[2]??'/private/tmp/zw-ai-entry-offline');await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-ai-entry-offline-'),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');for(const dir of[data,rpc,zdot])await mkdir(dir);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='entry-test%# '\n");
const wire=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const payload=(envelope:any)=>{for(const block of envelope.content??[])try{return JSON.parse(block.text)}catch{}return envelope};
const requests:any[]=[],finished:any[]=[];let providerFailure:string|null=null;
const server=createServer(async(req,res)=>{try{
 let raw='';for await(const b of req)raw+=b;if(!raw){res.writeHead(200,{'content-type':'application/json'});return res.end('{"data":[{"id":"entry-fixture"}]}')}
 const body=JSON.parse(raw);requests.push(body);res.writeHead(200,{'content-type':'text/event-stream'});
 const prompt=body.messages.filter((m:any)=>m.role==='user'&&/^(CONNECTED_FIRST|CONNECTED_SECOND|OFFLINE_AFTER_TOOLS)$/.test(m.content)).at(-1)?.content;
 const results=new Map(body.messages.filter((m:any)=>m.role==='tool').map((m:any)=>[m.tool_call_id,payload(JSON.parse(m.content))]));
 if(prompt==='OFFLINE_AFTER_TOOLS'){
  assert.equal((body.tools??[]).length,0,'offline turn must advertise no tools');
  assert(results.has('first-run')&&results.has('second-run'),'both real tool turns must remain in history');
  return res.end(frame({content:'OFFLINE_AI_REPLY'})+'data: [DONE]\n\n');
 }
 assert(prompt==='CONNECTED_FIRST'||prompt==='CONNECTED_SECOND','unexpected fixture prompt');
 const stage=prompt==='CONNECTED_FIRST'?'first':'second';
 const emit=(id:string,name:string,args:any)=>res.end(frame({tool_calls:[{index:0,id:stage+'-'+id,type:'function',function:{name:wire(name),arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n');
 const context:any=results.get(stage+'-context');if(!context)return emit('context','host.get_current_context',{});
 let ready=false;
 for(let i=0;i<8;i++){
  const facts:any=results.get(stage+'-ready-'+i);
  if(!facts){if(i)await new Promise(r=>setTimeout(r,350));return emit('ready-'+i,'host.get_session',{session_ref:context.binding_ref});}
  if(facts.session?.capabilities?.trusted_pty_execution){ready=true;break}
 }
 assert(ready,'real Local PTY did not become ready');
 const run:any=results.get(stage+'-run');if(!run)return emit('run','host.run_in_terminal',{session_ref:context.binding_ref,command:stage==='first'?'ZW_OFFLINE_HISTORY=preserved; printf "CONNECTED_FIRST=%s\\n" "$ZW_OFFLINE_HISTORY"':'printf "CONNECTED_SECOND=%s\\n" "$ZW_OFFLINE_HISTORY"; false',request_key:'offline-history-'+stage});
 let observed:any=run;
 for(let i=0;observed.state!=='interval_recorded'&&i<8;i++){
  const next:any=results.get(stage+'-wait-'+i);
  if(!next)return emit('wait-'+i,'host.wait_execution',{execution_ref:run.execution_ref,after_revision:observed.source_revision,wait_ms:30000,max_bytes:4096});
  observed=next;
 }
 assert.equal(observed.state,'interval_recorded');assert.equal(observed.snapshot.process.exit_code,stage==='first'?0:1);assert(observed.output.includes(`CONNECTED_${stage.toUpperCase()}=preserved`));
 finished.push({stage,execution_ref:observed.execution_ref,exit_code:observed.snapshot.process.exit_code,output:observed.output,recording_settled:observed.snapshot.recording_settled});
 res.end(frame({content:prompt+'_DONE'})+'data: [DONE]\n\n');
}catch(err){providerFailure=String(err);res.end(frame({content:'FIXTURE_ERROR: '+providerFailure})+'data: [DONE]\n\n')}});await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="entry-fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="entry-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="entry-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts'));const log=await open(join(out,'app.log'),'w');const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZDOTDIR:zdot,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];const text=(n:any)=>flat(n).map(n=>n.text??'').join(' ');const visible=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);const hidden=async(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);const click=async(id:string)=>{const n=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)};
const report:any={status:'running',checks:[],scope:'Actual isolated test-mode native App and real local zsh; deterministic HTTP provider requests two real host terminal executions and then text. No remote host or user data is accessed.'};
const verifyEntries=async(stage:string)=>{report.phase=stage+':strip-visible';await h.mouseMove(20,300);await visible('ai.strip');report.phase=stage+':toolbar';await click('toolbar.ai');await visible('ai.panel');await click('ai.collapse');await hidden('ai.panel');report.phase=stage+':strip';await click('ai.strip');await visible('ai.panel');await click('ai.collapse');await hidden('ai.panel');report.phase=stage+':command';await click('terminal.input');await h.type_('@ai');await h.key('return');await visible('ai.panel');await h.screenshot(join(out,stage+'-entries.png'));await click('ai.collapse');await hidden('ai.panel');report.checks.push(stage+': toolbar, strip and @ai all open AI; collapse works')};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await h.sleep(1000);await verifyEntries('connected');
 await click('toolbar.ai');
 for(const prompt of['CONNECTED_FIRST','CONNECTED_SECOND']){
  report.phase=prompt;await click('ai.prompt');await h.type_(prompt);await click('ai.send');
  await h.waitFor(async()=>{
   assert.equal(providerFailure,null);
   if((await h.query('ai.host_approval.accept')).some(shown))await click('ai.host_approval.accept');
   return text(await h.query('ai.panel')).includes(prompt+'_DONE')&&!(await h.query('ai.stop')).some(shown)||null;
  },45000);
 }
 assert.equal(finished.length,2);await writeFile(join(out,'real-terminal-turns.json'),JSON.stringify(finished,null,2));await h.screenshot(join(out,'connected-two-tool-turns.png'));report.checks.push('two real host terminal turns retain the same shell variable and report actual exit 0 then exit 1');await click('ai.collapse');await hidden('ai.panel');
 await click('terminal.surface');await h.type_('exit');await h.key('return');report.phase='wait-exit';await h.waitFor(async()=>text(await h.query('local.notice.title')).includes('退出')||(await h.query('local.ended.new')).some(shown)||null,15000);
 await verifyEntries('ended');await click('toolbar.ai');await click('ai.prompt');await h.type_('OFFLINE_AFTER_TOOLS');await click('ai.send');await h.waitFor(async()=>{assert.equal(providerFailure,null);return text(await h.query('ai.panel')).includes('OFFLINE_AI_REPLY')||null},15000);assert(requests.length>0);report.offline_tools=(requests.at(-1).tools??[]).map((tool:any)=>tool.function.name);await writeFile(join(out,'request-tool-names.json'),JSON.stringify(report.offline_tools,null,2));assert.equal(report.offline_tools.length,0,'offline request must advertise no tools');report.retained_tool_results=requests.at(-1).messages.filter((message:any)=>message.role==='tool').map((message:any)=>message.tool_call_id);assert(report.retained_tool_results.includes('first-run')&&report.retained_tool_results.includes('second-run'));await h.screenshot(join(out,'ended-conversation.png'));report.checks.push('ended: a new provider reply arrives with zero advertised tools and both prior host tool turns intact');report.request_count=requests.length;report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await h.screenshot(join(out,'failure.png')).catch(()=>{});await writeFile(join(out,'failure-tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{});process.exitCode=1}
finally{app.kill('SIGTERM');await new Promise<void>(r=>{if(app.exitCode!==null||app.signalCode!==null)return r();app.once('close',()=>r());setTimeout(()=>{app.kill('SIGKILL');r()},3000)});server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));await log.close();await rm(iso,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report))}
