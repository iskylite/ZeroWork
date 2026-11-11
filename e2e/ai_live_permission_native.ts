/** Live mode changes and compound commands through the production composer and existing Local PTY.
 * ZW_AI_TEST_PREFIX=$PWD/zig-out node e2e/ai_live_permission_native.ts /tmp/zw-live-permission-evidence
 * Provider replies are deterministic; commands, approvals and recordings use the real App.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath,rm,readdir,access} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'zig-out');
const binary=resolve(process.env.ZW_AI_TEST_BINARY??join(prefix,'bin/zerowork'));
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-live-permission-evidence');
await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-live-permission-'));
const data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot'),empty=join(iso,'empty');
await Promise.all([mkdir(data),mkdir(rpc),mkdir(zdot),mkdir(empty)]);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='live-permission%# '\n");
const output=join(iso,'compound-output');
const command=`if true; then printf '%s\n' COMPOUND_OK | cat > '${output}'; fi; true`;
const blocked=`printf 'safe\\n'; if true; then r""m -rf ${empty}; fi`;
const unapproved=join(iso,'unapproved-marker'),uncertain=`"$ZW_REVIEW_EXECUTABLE" '${unapproved}'`;
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const wire=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
const observations=new Map<string,any>(),emitted=new Set<string>();
let source:any,fixtureFailure:string|null=null,readyToDowngrade=false,continueAfterDowngrade:()=>void=()=>{},readyForBlocked=false,continueBlocked:()=>void=()=>{},finished=false;
const downgraded=new Promise<void>(done=>continueAfterDowngrade=done);
const autoForBlocked=new Promise<void>(done=>continueBlocked=done);
const report:any={status:'running',binary,checks:[],decisions:[]};
const bodyOf=(result:any)=>{
 for(const block of result.content??[])try{return JSON.parse(block.text)}catch{}
 return result;
};
const server=createServer(async(req,res)=>{
 try{
  if(req.method!=='POST'){res.end(JSON.stringify({data:[{id:'live-permission-fixture'}]}));return}
  let raw='';for await(const chunk of req)raw+=chunk;
  const request=JSON.parse(raw),results=new Map<string,any>();
  for(const message of request.messages??[])if(message.role==='tool'){
   const envelope=JSON.parse(message.content),body=bodyOf(envelope);
   observations.set(message.tool_call_id,{envelope,body});results.set(message.tool_call_id,body);
  }
  res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
  const emit=(id:string,name:string,args:any)=>{
   assert(!emitted.has(id),`call ${id} must not be replayed`);emitted.add(id);
   const tool=wire(name);assert(request.tools.some((entry:any)=>entry.function.name===tool),tool);
   res.end(frame({tool_calls:[{index:0,id,type:'function',function:{name:tool,arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n');
  };
  const run=(id:string,cmd=command)=>emit(id,'host.run_in_terminal',{session_ref:source.session_ref,command:cmd,request_key:id});
  const completed=(id:string)=>{
   const runResult=results.get(id);if(!runResult)return false;
   assert(runResult.execution_ref,JSON.stringify(runResult));
   for(let i=0;i<12;i++){
    const waitId=id+'-wait-'+i,value=results.get(waitId);
    if(!value){const previous=i===0?runResult:results.get(id+'-wait-'+(i-1));emit(waitId,'host.wait_execution',{execution_ref:runResult.execution_ref,after_revision:previous.source_revision,wait_ms:1000,max_bytes:8192});return false}
    assert(!['cancelled_unsent','outcome_unknown','handed_off','recording_degraded'].includes(value.state),JSON.stringify(value));
    if(value.state==='interval_recorded'){
     assert.equal(value.snapshot.process.exit_code,0);assert.equal(value.snapshot.interval_saved,true);return true;
    }
   }
   throw Error('execution did not settle');
  };
  if(!results.has('initial-context'))return emit('initial-context','host.get_current_context',{});
  assert.equal(results.get('initial-context').permission_mode,'confirm');
  if(!results.has('sessions'))return emit('sessions','host.list_sessions',{limit:8});
  source=results.get('sessions').sessions[0];assert(source?.ready);
  for(let attempt=0;attempt<3;attempt++){
   const id='pty-ready-'+attempt,value=results.get(id);
   if(!value){if(attempt)await h.sleep(attempt===1?1500:3000);return emit(id,'host.get_session',{session_ref:source.session_ref})}
   assert(['ready','initializing','busy'].includes(value.session.capabilities.trusted_pty_state),JSON.stringify(value));
   if(value.session.capabilities.trusted_pty_execution)break;
   assert(attempt<2,'Local private shell integration did not become ready');
  }
  if(!results.has('pending-run'))return run('pending-run');
  if(!completed('pending-run'))return;
  if(!results.has('auto-context'))return emit('auto-context','host.get_current_context',{});
  assert.equal(results.get('auto-context').permission_mode,'auto');
  if(!results.has('automatic-run'))return run('automatic-run');
  if(!completed('automatic-run'))return;
  if(!results.has('confirm-context')){
   readyToDowngrade=true;await downgraded;
   return emit('confirm-context','host.get_current_context',{});
  }
  assert.equal(results.get('confirm-context').permission_mode,'confirm');
  if(!results.has('confirm-run'))return run('confirm-run');
  assert.equal(observations.get('confirm-run').envelope.status,'rejected');
  if(!results.has('blocked-run')){readyForBlocked=true;await autoForBlocked;return run('blocked-run',blocked)}
  assert.equal(observations.get('blocked-run').envelope.status,'rejected');
  assert.equal(results.get('blocked-run').side_effect_started,false);
  assert.equal(results.get('blocked-run').error_code,'PermissionDenied');
  if(!results.has('dynamic-run'))return run('dynamic-run',uncertain);
  assert.equal(observations.get('dynamic-run').envelope.status,'rejected');
  finished=true;res.end(frame({content:'LIVE_PERMISSION_VERIFIED'})+'data: [DONE]\n\n');
 }catch(error){fixtureFailure=String(error);if(!res.headersSent)res.writeHead(500);res.end()}
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="live-permission-fixture"\npermission_mode="confirm"\nexecution_mode="attached_pty"\nsession_retention="auto_idle"\n[[ai.providers]]\nid="live-permission-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="live-permission-fixture"\ncontext_window=200000\ndefault=true\n[log]\nring_mb=1\ncheckpoint_sec=1\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1',ZDOTDIR:zdot,ZW_REVIEW_EXECUTABLE:'/usr/bin/touch',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join('');
const visible=(id:string)=>h.waitFor(async()=>{assert.equal(fixtureFailure,null);return(await h.query(id)).find(shown)??null},20000);
const click=async(id:string)=>{report.last_action=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
const capture=async(name:string)=>{
 assert((await h.screenshot(join(out,name+'.png'))).ok);
 await writeFile(join(out,name+'.json'),JSON.stringify({permission:await h.query('ai.composer.permission'),approval:await h.query('ai.interaction.panel'),status:await h.query('ai.turn.status')},null,2));
};
const mode=async(value:'auto'|'confirm')=>{
 if((await h.query('ai.interaction.panel')).some(shown))await click('ai.interaction.postpone');
 await click('ai.composer.permission');await click('ai.permission.'+value);
 await h.waitFor(async()=>text(await visible('ai.composer.permission')).includes(value==='auto'?'自动执行':'确认后执行')||null,5000);
};
try{
 await h.waitForServerReady(60000);
 assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.maximize');
 await click('ai.prompt');await h.type_('验证回合中权限立即生效，仅执行测试工具调用。');await click('ai.send');
 await visible('ai.interaction.panel');await capture('01-confirm-pending');
 assert.equal(text(await visible('ai.interaction.command')),command);
 await mode('auto');report.checks.push('confirm -> auto resumes the original waiting PTY call without clicking approve');
 await h.waitFor(async()=>{assert.equal(fixtureFailure,null);return readyToDowngrade||null},60000);
 assert(!(await h.query('ai.interaction.panel')).some(shown));await capture('02-auto-continued');
 assert.equal(await readFile(output,'utf8'),'COMPOUND_OK\n');
 report.checks.push('compound PTY commands with a conditional, semicolons, a pipeline and redirection run automatically and produce the expected file');
 await mode('confirm');continueAfterDowngrade();
 await visible('ai.interaction.panel');assert.equal(text(await visible('ai.interaction.command')),command);await capture('03-confirm-restored');
 report.checks.push('auto -> confirm during provider streaming makes the next PTY call wait');
 await click('ai.interaction.reject');report.decisions.push({call:'confirm-run',approved:false});
 await h.waitFor(async()=>{assert.equal(fixtureFailure,null);return readyForBlocked||null},20000);
 await mode('auto');continueBlocked();
 await visible('ai.interaction.panel');assert.equal(text(await visible('ai.interaction.command')),uncertain);
 await capture('04-dynamic-command-pending');
 assert.equal(await access(unapproved).then(()=>true,()=>false),false);
 await click('ai.interaction.reject');report.decisions.push({call:'dynamic-run',approved:false});
 report.checks.push('An expanded executable name still requires exact approval in auto mode; rejection leaves its marker absent');
 await h.waitFor(async()=>{assert.equal(fixtureFailure,null);return finished||null},30000);
 await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,20000);
 assert.equal((await readdir(empty)).length,0);report.checks.push('quote-spliced dangerous rm inside a compound command is blocked in auto mode before dispatch and preserves the owned empty target');
 const journal=JSON.parse(await readFile(join(data,'ai/lifecycle.json'),'utf8'));
 const runs=journal.records.filter((record:any)=>record.tool_id==='host.run_in_terminal'&&record.execution);
 assert.deepEqual(runs.map((record:any)=>record.original_call).sort(),['automatic-run','pending-run']);
 for(const record of runs){assert.equal(record.stage,'succeeded');assert.equal(record.execution_receipt.interval_saved,true)}
 report.checks.push('exactly the two authorized original calls have saved PTY execution receipts');
 await capture('05-complete');
 await click('ai.collapse');assert((await h.request('POST','/zerowork/windows',{action:'quit'})).ok);
 const quitAt=performance.now();
 while(app.exitCode===null&&app.signalCode===null&&performance.now()-quitAt<15000){
  try{for(const id of ['groups.close.accept','local.close.accept','session.close.accept'])if((await h.query(id)).some(shown))await click(id)}catch{}
  await Promise.race([ended,h.sleep(100)]);
 }
 assert.equal(app.exitCode,0);assert.equal(app.signalCode,null);report.normal_quit=true;report.status='passed';
}catch(error){report.status='failed';report.error=String(error);report.fixture_failure=fixtureFailure;try{await capture('failure')}catch{}}
finally{
 continueAfterDowngrade();continueBlocked();
 if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,h.sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}
 await new Promise<void>(done=>server.close(()=>done()));await log.close();
 report.observations=Object.fromEntries(observations);await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
 await rm(iso,{recursive:true,force:true});console.log(JSON.stringify({status:report.status,error:report.error,report:join(out,'report.json')}));
}
if(report.status!=='passed')process.exitCode=1;
