/** Real native app + real isolated SSH Shells; deterministic model tool calls.
 * Exercises proactive notices and missed alias detection through the same AI
 * attachment API after ordinary shell entry, without human attachment/approval clicks.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,open,readFile,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=process.env.ZW_NESTED_PREFIX??'/private/tmp/zw-shell-auto-build';
const python=process.env.ZW_TEST_PYTHON??'/private/tmp/zw-nested-shell-test-venv/bin/python';
const out=resolve(process.argv[2]??'/private/tmp/zw-shell-auto-native');await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-shell-auto-');await mkdir(join(iso,'data'));await mkdir(join(iso,'rpc'));
process.env.ZENIT_E2E_FILE_RPC_DIR=join(iso,'rpc');
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const report:any={status:'running',checks:[],observations:{},notices:[],approvals:0};
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const wire=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
const bodyOf=(result:any)=>{for(const block of result.content??[])try{return JSON.parse(block.text)}catch{}return result};
let phase='proactive',finished=false,fixtureFailure:string|null=null;
const emitted=new Set<string>();
const server=createServer(async(req,res)=>{
 try{
  if(req.method!=='POST'){res.end(JSON.stringify({data:[{id:'shell-auto-fixture'}]}));return}
  let raw='';for await(const chunk of req)raw+=chunk;const request=JSON.parse(raw),results=new Map<string,any>();
  await writeFile(join(out,phase+'-latest-request.json'),JSON.stringify(request,null,2));
  for(const message of request.messages??[]){
   if(message.role==='tool'){const envelope=JSON.parse(message.content),body=bodyOf(envelope);results.set(message.tool_call_id,body);report.observations[message.tool_call_id]={envelope,body}}
   else if(typeof message.content==='string'&&message.content.includes('shell_switches_json'))report.notices.push(message.content);
  }
  res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
  const get=(id:string)=>results.get(phase+'-'+id);
  const emit=(id:string,name:string,args:any)=>{
   const call=phase+'-'+id;assert(!emitted.has(call));emitted.add(call);
   assert(request.tools.some((t:any)=>t.function.name===wire(name)),name);
   if(id==='sessions')res.write(frame({content:'我先读取当前终端，确认目标 Shell 后接入。'}));
   res.end(frame({tool_calls:[{index:0,id:call,type:'function',function:{name:wire(name),arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n');
  };
  if(!get('sessions'))return emit('sessions','host.list_sessions',{limit:8});
  const source=get('sessions').sessions[0];assert(source?.ready);const reference=source.session_ref;
  if(phase==='unknown'){
   if(!get('run'))return emit('run','host.run_in_terminal',{session_ref:reference,request_key:'unknown-run',command:"PROMPT_COMMAND=__zw_osc_arm; printf 'UNKNOWN_SCREEN_OK\\n'",shell_id:source.control.shell_context.id,shell_revision:source.control.shell_context.revision});
   const run=get('run');assert(run.execution_ref,JSON.stringify(run));
   let last=run;
   for(let i=0;i<4&&!JSON.stringify(last).includes('outcome_unknown');i++){
    const value=get('wait-'+i);if(!value)return emit('wait-'+i,'host.wait_execution',{execution_ref:run.execution_ref,wait_ms:3000});last=value;
   }
   assert(JSON.stringify(last).includes('outcome_unknown'),JSON.stringify(last));
   assert.equal(last.snapshot.process,null);
   assert(!request.tools.some((t:any)=>[wire('host.run_in_terminal'),wire('host.attach_shell')].includes(t.function.name)),'unknown outcomes expose observation tools only');
   if(!get('screen'))return emit('screen','host.read_terminal',{session_ref:reference,max_lines:100,max_bytes:16384});
   assert(JSON.stringify(get('screen')).includes('UNKNOWN_SCREEN_OK'));
   finished=true;res.end(frame({content:'没有收到结束回执；屏幕已出现 UNKNOWN_SCREEN_OK。退出码仍未知，命令没有重发。'})+'data: [DONE]\n\n');return;
  }

  if(phase==='fallback'&&!get('unsent'))return emit('unsent','host.run_in_terminal',{session_ref:reference,command:'printf FALLBACK_UNSENT',request_key:'fallback-unsent',shell_id:source.control.shell_context.id,shell_revision:source.control.shell_context.revision});
  if(phase==='fallback')assert(['ShellPromptNotObserved','IntegrationUnavailable'].includes(get('unsent').error_code),JSON.stringify(get('unsent')));
  if(!get('screen'))return emit('screen','host.read_terminal',{session_ref:reference,max_lines:100,max_bytes:8192});
  assert(JSON.stringify(get('screen')).includes(phase==='proactive'?'fixture>':'bash-'),JSON.stringify(get('screen')));
  if(!get('before'))return emit('before','host.get_session',{session_ref:reference});
  const before=get('before').session,control=before.control;
  if(phase==='proactive'){assert(control.shell_switch.pending,'ordinary SSH must be a candidate');assert.equal(control.shell_switch.kind,'ssh')}
  else assert(!control.shell_switch.pending,'alias must exercise missed detection');
  const attachArgs={session_ref:reference,request_key:phase+'-attach',shell_id:control.shell_context.id,shell_revision:control.shell_context.revision,input_epoch:control.input_epoch,output_sequence:control.output_sequence,prompt_evidence:phase==='proactive'?'最新末行是空 Zsh fixture> 提示符，SSH 已完成连接，没有密码或确认问题。':'最新末行是空 bash-3.2$ 提示符，没有密码或确认问题。'};
  if(phase==='proactive'&&!get('stale'))return emit('stale','host.attach_shell',{...attachArgs,request_key:'stale-attach',input_epoch:control.input_epoch+1});
  if(phase==='proactive'){assert.equal(get('stale').error_code,'ShellAttachmentStale');assert.equal(get('stale').side_effect_started,false)}
  if(!get('attach'))return emit('attach','host.attach_shell',attachArgs);
  assert.equal(get('attach').state,'attaching');
  let current:any;
  for(let i=0;i<12;i++){
   const snapshot=get('ready-'+i);
   if(!snapshot){await new Promise(r=>setTimeout(r,450));return emit('ready-'+i,'host.get_session',{session_ref:reference})}
   current=snapshot.session;if(current.control.shell_context.prompt_ready)break;
  }
  assert(current?.control.shell_context.prompt_ready,JSON.stringify(current));
  assert.notEqual(current.control.shell_context.id,control.shell_context.id);
  if(phase==='proactive'&&!get('duplicate'))return emit('duplicate','host.attach_shell',attachArgs);
  if(phase==='proactive')assert.equal(get('duplicate').duplicate,true);
  if(phase==='proactive'&&!get('key-conflict'))return emit('key-conflict','host.attach_shell',{...attachArgs,prompt_evidence:'different request with the same key'});
  if(phase==='proactive')assert.equal(get('key-conflict').error_code,'IdempotencyConflict');
  if(!get('run'))return emit('run','host.run_in_terminal',{session_ref:reference,request_key:phase+'-run',command:`printf 'SHELL_AUTO_${phase}_OK\\n'`,shell_id:current.control.shell_context.id,shell_revision:current.control.shell_context.revision});
  assert(get('run').execution_ref,JSON.stringify(get('run')));
  let execution:any;
  for(let i=0;i<5;i++){
   const value=get('wait-'+i);if(!value)return emit('wait-'+i,'host.wait_execution',{execution_ref:get('run').execution_ref,wait_ms:3000});
   execution=value;if(JSON.stringify(value).includes('interval_recorded'))break;
  }
  assert(JSON.stringify(execution).includes('interval_recorded'),JSON.stringify(execution));
  finished=true;res.end(frame({content:'Shell 已原地接入，验证命令已完成。'})+'data: [DONE]\n\n');
 }catch(error){fixtureFailure=String(error);if(!res.headersSent)res.writeHead(500);res.end()}
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
const peerLog=await open(join(out,'peer.log'),'w');
const peer=spawn(python,['e2e/ssh_nested_shell_peer.py','--out',join(iso,'peer'),'--nested-ssh'],{stdio:['ignore',peerLog.fd,peerLog.fd]});
const peerEnded=new Promise(r=>peer.once('close',r));
let app:any,appEnded:any,appLog:any;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map((v:any)=>v.text??'').join('');
const shown=(n:any)=>n&&n.visible!==false&&!n.hidden&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>{assert.equal(fixtureFailure,null);return(await h.query(id)).find(shown)??null},20000);
const click=async(id:string)=>{const n=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)};
const command=async(value:string)=>{await click('terminal.input');await h.type_(value);await h.key('enter')};
const capture=async(name:string)=>{const headers=(await h.query('ai.step_group.header')).filter(shown);if(headers.length){const n=headers.at(-1);await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);await h.sleep(250)}await h.mouseMove(5,5);await h.screenshot(join(out,name+'.png'));await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.step_group'),null,2))};
const ask=async()=>{
 finished=false;await click('ai.prompt');await h.type_('查看当前终端，接入内层 Shell 后执行验证。');await click('ai.send');
 const deadline=performance.now()+100000;
 while(!finished&&performance.now()<deadline){assert.equal(fixtureFailure,null);assert(!(await h.query('ai.host_approval')).some(shown),'auto must not ask for attachment approval');await h.sleep(150)}
 assert.equal(fixtureFailure,null);assert(finished,'model fixture did not finish');await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,20000);
};
try{
 const ready=await h.waitFor(async()=>{try{return JSON.parse(await readFile(join(iso,'peer','ready.json'),'utf8'))}catch{return null}},15000);
 await writeFile(join(iso,'data','config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ssh]\nauto_reconnect=false\nauto_shell_integration=true\n[ai]\ndefault_provider="shell-auto-fixture"\npermission_mode="auto"\nexecution_mode="attached_pty"\nsession_retention="keep"\n[[ai.providers]]\nid="shell-auto-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="shell-auto-fixture"\ncontext_window=200000\ndefault=true\n`);
 await writeFile(join(iso,'data','hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Shell 自动接入验证"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
 appLog=await open(join(out,'app.log'),'w');app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:join(iso,'data'),ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_AI_TOOL_TRACE:'1'},stdio:['ignore',appLog.fd,appLog.fd]});appEnded=new Promise(r=>app.once('close',r));
 await h.waitForServerReady(60000);await h.resizeWindow(1440,900);const row=await visible('sidebar.host');await h.mouseMove(row.rect.x+row.rect.w-18,row.rect.y+row.rect.h/2);await click('sidebar.host.connect');
 await h.waitFor(async()=>{const modal=(await h.query('plugin.challenge.modal')).find(shown);if(modal){if(flat(modal).some((n:any)=>n.test_id==='plugin.challenge.choice.1'&&shown(n)))await click('plugin.challenge.choice.1');else if(flat(modal).some((n:any)=>n.test_id==='plugin.challenge.secret'&&shown(n))){await click('plugin.challenge.secret');await h.type_(ready.password);await click('plugin.challenge.submit')}}return text(await h.query('terminal.input')).includes('fixture>')||null},30000);
 await h.waitFor(async()=>{try{return JSON.parse(await readFile(join(iso,'peer','state.json'),'utf8')).contexts.length>=1||null}catch{return null}},25000);
 await command(`ssh -i "$HOME/nested-test-key" -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -p ${ready.port} shell-fixture@127.0.0.1`);await h.sleep(400);await click('toolbar.ai');await click('ai.maximize');await ask();await capture('01-ordinary-switch-ai-attached');
 assert(report.notices.some((notice:string)=>{try{return JSON.parse(JSON.parse(notice).shell_switches_json).some((item:any)=>item.kind==='ssh'&&item.pending)}catch{return false}}),'switch notice must reach the model');
 report.checks.push('Stale screen/input evidence rejects without initialization; repeated key returns duplicate without reinitializing; changed arguments with the same key reject');
 report.checks.push('Ordinary nested SSH entry -> bound model notice -> terminal read -> AI attach -> verified business execution; zero human attach or permission clicks');
 await click('ai.collapse');await command("alias inner='bash --noprofile --norc -i'");await h.sleep(200);await command('inner');await h.sleep(250);phase='fallback';await click('toolbar.ai');await click('ai.maximize');await ask();await capture('02-missed-alias-ai-recovery');
 report.checks.push('Alias entry missed by classifier -> known-unsent business rejection -> terminal read -> same AI attachment API -> one successful execution');
 phase='unknown';await ask();await capture('03-unknown-result-screen-observation');
 report.checks.push('Real missing Shell completion keeps exit unknown, permits a subsequent model round reading the terminal, and removes command/attachment effects from the tool catalog');
 const terminal=text(await h.query('terminal.input'));assert(!terminal.includes('FALLBACK_UNSENT'),'unsent business command must never reach the terminal');
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);report.fixture_failure=fixtureFailure;process.exitCode=1;await capture('failure').catch(()=>{})}
finally{
 if(app){app.kill('SIGTERM');await Promise.race([appEnded,new Promise(r=>setTimeout(()=>{app.kill('SIGKILL');r(null)},3000))]);await appLog.close()}
 peer.kill('SIGTERM');await peerEnded;await peerLog.close();report.peer=JSON.parse(await readFile(join(iso,'peer','report.json'),'utf8'));await new Promise<void>(r=>server.close(()=>r()));await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,report:join(out,'report.json')}));
}
