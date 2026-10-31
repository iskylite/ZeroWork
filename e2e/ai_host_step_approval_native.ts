/** Host approval stage on the real native UI and Local PTY; fixture provider. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,writeFile,readFile,open,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/private/tmp/zw-settlement-build');
const out=resolve(process.argv[2]??'/private/tmp/zw-host-step-approval');await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-host-step-approval-'),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');for(const d of[data,rpc,zdot])await mkdir(d);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='approval-test%# '\n");
const wire=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const payload=(envelope:any)=>{for(const b of envelope.content??[])try{return JSON.parse(b.text)}catch{}return envelope};
let failed:string|null=null;let requests=0;const marker=join(iso,"approved-command");
const server=createServer(async(req,res)=>{try{
 if(req.method!=='POST')return res.end('{"data":[{"id":"approval-fixture"}]}');
 requests++;let raw='';for await(const b of req)raw+=b;const body=JSON.parse(raw);
 const results=new Map(body.messages.filter((m:any)=>m.role==='tool').map((m:any)=>[m.tool_call_id,payload(JSON.parse(m.content))]));
 const emit=(id:string,name:string,args:any)=>res.end((id==='approval-run'?frame({content:'APPROVAL_PREFACE：我会先请求确认，再执行这条命令。'}):'')+frame({tool_calls:[{index:0,id,type:'function',function:{name:wire(name),arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n');
 res.writeHead(200,{'content-type':'text/event-stream'});
 const context:any=results.get('approval-context');if(!context)return emit('approval-context','host.get_current_context',{});
 let ready=false;
 for(let i=0;i<8;i++){
  const facts:any=results.get('approval-ready-'+i);
  if(!facts){if(i)await new Promise(r=>setTimeout(r,350));return emit('approval-ready-'+i,'host.get_session',{session_ref:context.binding_ref});}
  if(facts.session?.capabilities?.trusted_pty_execution){ready=true;break}
 }
 assert(ready,'Local PTY did not report ready');
 const run:any=results.get('approval-run');if(!run)return emit('approval-run','host.run_in_terminal',{session_ref:context.binding_ref,command:`printf APPROVAL_NATIVE_OK; printf once >> '${marker}'`,request_key:'approval-native-once'});
 let observed:any=run;
 for(let i=0;observed.state!=='interval_recorded'&&i<8;i++){
  const next:any=results.get('approval-wait-'+i);
  if(!next)return emit('approval-wait-'+i,'host.wait_execution',{execution_ref:run.execution_ref,after_revision:observed.source_revision,wait_ms:30000,max_bytes:4096});
  observed=next;
 }
 assert.equal(observed.state,'interval_recorded');assert.equal(observed.snapshot.process.exit_code,0);
 res.end(frame({content:'APPROVAL_NATIVE_FINISHED'})+'data: [DONE]\n\n');
}catch(err){failed=String(err);res.end(frame({content:'FIXTURE_ERROR'})+'data: [DONE]\n\n')}});await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="approval-fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="approval-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="approval-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts'));const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join(' ');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok)};
const report:any={status:'running',scope:'Isolated native App, real Local zsh and deterministic provider; no production App or remote host accessed.'};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1200,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.prompt');await h.type_('在当前终端执行审批阶段验证');await click('ai.send');await visible('ai.host_approval');
 const requestCount=requests;
 const panel=flat(await h.query('ai.panel'));
 assert(!panel.some((n:any)=>n.test_id==='ai.step.projection'&&n.text?.includes('printf APPROVAL_NATIVE_OK')),'unapproved request must not have an execution step');
 assert.equal(await readFile(marker,'utf8').catch(()=>null),null,'command must not reach the PTY before approval');
 const nodes=flat(await h.query('ai.conversation'));
 const prose=nodes.find((n:any)=>n.test_id==='ai.message.assistant');
 assert(prose&&text(prose).includes('APPROVAL_PREFACE'),'model explanation remains before the approval');
 const approval=nodes.find((n:any)=>n.test_id==='ai.host_approval');assert(approval,'approval belongs inside the transcript');
 assert(Math.abs(prose.rect.x-approval.rect.x)<.5&&Math.abs(prose.rect.w-approval.rect.w)<.5,'model prose and approval share both outer edges');
 assert(prose.rect.y+prose.rect.h<=approval.rect.y,'approval follows the model explanation');
 assert(!(await h.query('ai.task_finish')).some(shown),'an idle task terminal must not claim that execution is running');
 await h.resizeWindow(860,480);await h.sleep(150);
 const compactProse=(await h.query('ai.message.assistant')).find(shown),compactApproval=(await h.query('ai.host_approval')).find(shown);
 assert(compactProse&&compactApproval);assert(Math.abs(compactProse.rect.x-compactApproval.rect.x)<.5&&Math.abs(compactProse.rect.w-compactApproval.rect.w)<.5);
 await h.screenshot(join(out,'compact-approval.png'));await h.resizeWindow(1200,900);

 const footerTime=()=>h.query('ai.turn.elapsed').then((n:any)=>text(n));
 const beforeTime=await footerTime();await h.sleep(1400);assert.equal(await footerTime(),beforeTime,'processing clock pauses during approval');
 assert.equal(requests,requestCount,'provider must not continue while waiting');
 await h.screenshot(join(out,'waiting-approval.png'));await writeFile(join(out,'waiting-approval.tree.json'),JSON.stringify(await h.query('ai.panel'),null,2));
 if(process.env.ZW_APPROVAL_EXPIRY_CHECK==='1'){
  await h.waitFor(async()=>text(await h.query('ai.host_approval.state')).includes('已过期')||null,135000);
  assert.equal(requests,requestCount,'expiry must not start another provider round or approval');
  assert.equal(await readFile(marker,'utf8').catch(()=>null),null);
  assert.equal(await footerTime(),beforeTime);
  await h.screenshot(join(out,'expired-approval.png'));
  await click('ai.host_approval.accept');
  await h.waitFor(async()=>text(await h.query('ai.host_approval.state')).includes('待确认')||null,5000);
  assert.equal(requests,requestCount,'renewal alone does not resume the flow');
  assert.equal(await readFile(marker,'utf8').catch(()=>null),null,'renewal must not approve or execute');
 }
 await click('ai.host_approval.accept');await h.waitFor(async()=>text(await h.query('ai.panel')).includes('APPROVAL_NATIVE_FINISHED')||null,30000);assert.equal(failed,null);assert.equal(await readFile(marker,'utf8'),'once');await h.screenshot(join(out,'approved-result.png'));
 report.status='passed';report.checks=['model prose precedes inline approval','no execution step or PTY write before approval','processing clock excludes approval wait','provider remains paused while waiting',...(process.env.ZW_APPROVAL_EXPIRY_CHECK==='1'?['expired approval remains paused without retry','explicit renewal still requires separate approval']:[]),'approval executes the Local command exactly once and resumes the provider'];
}catch(err){report.status='failed';report.error=String(err);await h.screenshot(join(out,'failure.png')).catch(()=>{});await writeFile(join(out,'failure.tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{});process.exitCode=1}
finally{app.kill('SIGTERM');await new Promise<void>(r=>{if(app.exitCode!==null||app.signalCode!==null)return r();app.once('close',()=>r());setTimeout(()=>{app.kill('SIGKILL');r()},3000)});server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));await log.close();await rm(iso,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report))}
