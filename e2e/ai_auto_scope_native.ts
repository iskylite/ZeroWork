/** Automatic permissions across group commands, lifecycle and saved hosts.
 * Uses an isolated real Local pair; only the model replies are deterministic.
 * ZW_AI_TEST_PREFIX=$PWD/zig-out node e2e/ai_auto_scope_native.ts /tmp/zw-auto-scope-evidence
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath,rm,readdir,access} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'zig-out');
const binary=resolve(process.env.ZW_AI_TEST_BINARY??join(prefix,'bin/zerowork'));
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-auto-scope-evidence');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-auto-scope-'));
const data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot'),empty=join(iso,'empty'),marker=join(iso,'group-write');
await Promise.all([mkdir(data),mkdir(rpc),mkdir(zdot),mkdir(empty)]);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='auto-scope%# '\n");
const command=`touch ${marker}`,blocked=`rm -rf ${empty}`;
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const wire=(name:string)=>name==='run_command'?name:name.replaceAll('_','_u').replaceAll('.','__');
const emitted=new Set<string>(),observations=new Map<string,any>();
let source:any,fixtureFailure:string|null=null,finished=false;
const report:any={status:'running',binary,command,blocked,checks:[],user_approvals:0};
const bodyOf=(result:any)=>{for(const block of result.content??[])try{return JSON.parse(block.text)}catch{}return result};
const server=createServer(async(req,res)=>{
 try{
  if(req.method!=='POST'){res.end(JSON.stringify({data:[{id:'auto-scope-fixture'}]}));return}
  let raw='';for await(const chunk of req)raw+=chunk;const request=JSON.parse(raw),results=new Map<string,any>();
  for(const message of request.messages??[])if(message.role==='tool'){
   const envelope=JSON.parse(message.content),body=bodyOf(envelope);observations.set(message.tool_call_id,{envelope,body});results.set(message.tool_call_id,body);
  }
  res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
  const emit=(id:string,name:string,args:any)=>{
   assert(!emitted.has(id),`call ${id} must execute at most once`);emitted.add(id);
   const tool=wire(name);assert(request.tools.some((entry:any)=>entry.function.name===tool),tool);
   res.end(frame({tool_calls:[{index:0,id,type:'function',function:{name:tool,arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n');
  };
  if(!results.has('initial-context'))return emit('initial-context','host.get_current_context',{});
  assert.equal(results.get('initial-context').permission_mode,'confirm');
  if(!results.has('initial-sessions'))return emit('initial-sessions','host.list_sessions',{limit:8});
  source=results.get('initial-sessions').sessions[0];assert(source?.ready);
  if(!results.has('create-group'))return emit('create-group','host.create_group',{initial_session_ref:source.session_ref,name:'Auto scope fixture',request_key:'auto-create-group'});
  const group=results.get('create-group');assert.equal(group.state,'committed',JSON.stringify(group));
  if(!results.has('group-context'))return emit('group-context','host.get_current_context',{});
  const context=results.get('group-context');assert.equal(context.permission_mode,'auto');assert.equal(context.binding_ref,group.group_ref);
  if(!results.has('open-session'))return emit('open-session','host.open_session',{group_ref:group.group_ref,source_ref:source.session_ref,connection_policy:'new_only',retention:'keep',request_key:'auto-open-session'});
  const opened=results.get('open-session');assert.equal(opened.ownership,'created_task',JSON.stringify(opened));
  let ready:any=null;
  for(let i=0;i<4;i++){
   const id='ready-'+i,value=results.get(id);
   if(!value)return emit(id,'host.wait_session_ready',{operation_ref:opened.operation_ref,after_revision:ready?.source_revision??opened.source_revision,wait_ms:30000});
   ready=value;if(ready.state==='ready')break;
  }
  assert.equal(ready.state,'ready');assert.equal(ready.membership_committed,true);
  if(!results.has('group-sessions'))return emit('group-sessions','host.list_sessions',{limit:8});
  const sessions=results.get('group-sessions').sessions;assert.equal(sessions.length,2);assert(sessions.every((item:any)=>item.ready));
  const ids=sessions.map((item:any)=>item.session_id);report.group_session_ids=ids;
  if(!results.has('group-write'))return emit('group-write','run_command',{session_ids:ids,command});
  const written=results.get('group-write');assert.equal(written.targets.length,2,JSON.stringify(written));
  for(const target of written.targets){assert.equal(target.status,'succeeded');assert.equal(bodyOf(target).exit,0)}
  if(!results.has('group-blocked'))return emit('group-blocked','run_command',{session_ids:ids,command:blocked});
  assert(JSON.stringify(results.get('group-blocked')).includes('ToolExecutionDenied'));
  if(!results.has('save-host'))return emit('save-host','host.create_host',{name:'Auto saved host fixture',host:'192.0.2.7',user:'fixture',auth_mode:'agent',request_key:'auto-save-host'});
  const saved=results.get('save-host');assert(saved.host?.source_ref,JSON.stringify(saved));assert(saved.operation_ref);assert.equal(saved.connection_started,false);
  report.saved_host=saved;finished=true;res.end(frame({content:'AUTO_SCOPE_VERIFIED'})+'data: [DONE]\n\n');
 }catch(error){fixtureFailure=String(error);if(!res.headersSent)res.writeHead(500);res.end()}
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="auto-scope-fixture"\npermission_mode="confirm"\nexecution_mode="isolated_exec"\nsession_retention="keep"\n[[ai.providers]]\nid="auto-scope-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="auto-scope-fixture"\ncontext_window=200000\ndefault=true\n[log]\nring_mb=1\ncheckpoint_sec=1\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1',ZDOTDIR:zdot,OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>{assert.equal(fixtureFailure,null);return(await h.query(id)).find(shown)??null},20000);
const click=async(id:string)=>{report.last_action=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
const capture=async(name:string)=>{
 assert((await h.screenshot(join(out,name+'.png'))).ok);
 await writeFile(join(out,name+'.json'),JSON.stringify({permission:await h.query('ai.composer.permission'),approval:await h.query('ai.host_approval'),group:await h.query('groups.workspace')},null,2));
};
try{
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.maximize');
 await click('ai.prompt');await h.type_('验证自动模式下当前授权范围内的组写入和工具操作。');await click('ai.send');
 await visible('ai.host_approval');await capture('01-lifecycle-pending');
 await click('ai.composer.permission');await click('ai.permission.auto');
 await h.waitFor(async()=>!(await h.query('ai.host_approval')).some(shown)||null,10000);
 report.checks.push('switching a pending lifecycle call to auto resumes its original group creation');
 const started=performance.now();
 while(!finished&&performance.now()-started<120000){
  assert.equal(fixtureFailure,null);assert(!(await h.query('ai.host_approval')).some(shown),'auto must not display another host permission card');
  assert(!(await h.query('ai.approval.accept')).some(shown),'auto must not ask for group command approval');
  await h.sleep(100);
 }
 assert.equal(fixtureFailure,null);assert(finished,'fixture did not finish');
 await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,20000);
 await access(marker);assert.equal((await readdir(empty)).length,0);
 const events:any[]=[];for(const line of(await readFile(join(out,'app.log'),'utf8')).split('\n')){const i=line.indexOf('AI_TOOL_TRACE ');if(i>=0)try{events.push(JSON.parse(line.slice(i+14)))}catch{}}
 const starts=events.filter(event=>event.event==='exec_started');assert.equal(starts.length,2);assert(starts.every(event=>event.call_id==='group-write'));
 report.checks.push('a plain non-whitelisted write command dispatches once to each of the two real Local group members');
 report.checks.push('group dangerous-command preflight rejects the entire call with zero dispatch');
 assert((await readFile(join(data,'hosts.toml'),'utf8')).includes('Auto saved host fixture'));
 report.checks.push('session creation and saving nonsecret host configuration follow auto mode without another approval');
 await capture('02-auto-group-complete');
 await click('ai.collapse');assert((await h.request('POST','/quit')).ok);
 const quitAt=performance.now();while(app.exitCode===null&&app.signalCode===null&&performance.now()-quitAt<15000){
  try{for(const id of ['groups.close.accept','local.close.accept','session.close.accept'])if((await h.query(id)).some(shown))await click(id)}catch{}
  await Promise.race([ended,h.sleep(100)]);
 }
 assert.equal(app.exitCode,0);assert.equal(app.signalCode,null);report.normal_quit=true;report.status='passed';
}catch(error){report.status='failed';report.error=String(error);report.fixture_failure=fixtureFailure;try{await capture('failure')}catch{}}
finally{
 if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,h.sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}
 await new Promise<void>(done=>server.close(()=>done()));await log.close();report.observations=Object.fromEntries(observations);
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(iso,{recursive:true,force:true});
 console.log(JSON.stringify({status:report.status,error:report.error,report:join(out,'report.json')}));
}
if(report.status!=='passed')process.exitCode=1;
