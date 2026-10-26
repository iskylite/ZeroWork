/** Test-only fixture through the production main application and public slots.
 * No alternate App/shell is created. Credentials/config supplied privately.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash,randomUUID} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,rm,copyFile,chmod,stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {request,waitForServerReady,waitFor,query,clickAt,key,type_,inputState,resizeWindow,screenshot,sleep} from '../vendor/zenit/e2e/client.ts';
const opts:Record<string,string>={};for(let i=2;i<process.argv.length;i+=2){assert(['--binary','--out','--config','--no-ai','--skip-child','--shared-presenter-only','--fresh-chat-per-turn','--continuous-ai','--expected-sha'].includes(process.argv[i])&&process.argv[i+1]);opts[process.argv[i]]=process.argv[i+1];}
assert(opts['--binary']&&opts['--out']&&opts['--config']);
const binary=resolve(opts['--binary']),out=resolve(opts['--out']);await mkdir(out,{recursive:true});
const continuous=opts['--continuous-ai']==='1';
assert(!continuous||opts['--fresh-chat-per-turn']!=='1','Continuous acceptance forbids replacing the assistant conversation');
assert(!continuous||(opts['--no-ai']!=='1'&&opts['--skip-child']!=='1'),'Strict continuous acceptance requires all public-entry and actual AI steps');
assert(!continuous||opts['--expected-sha'],'Continuous acceptance requires the root frozen binary SHA');
assert.equal((await stat(resolve(opts['--config']))).mode&0o077,0,'Provider configuration must be private');
if(opts['--expected-sha'])assert.equal(createHash('sha256').update(await readFile(binary)).digest('hex'),opts['--expected-sha']);
try{await stat(join(out,'report.json'));assert.fail('Preserve previous attempts in separate evidence directories');}catch(e:any){if(e.code!=='ENOENT')throw e;}

const iso=await mkdtemp(join(tmpdir(),'zw-v02-fixture-')),rpc=join(iso,'rpc'),data=join(iso,'data');await chmod(iso,0o700);await mkdir(rpc);await mkdir(data);await copyFile(resolve(opts['--config']),join(data,'config.toml'));await chmod(join(data,'config.toml'),0o600);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const logPath=join(out,'app.log'),log=await open(logPath,'w');
const app=spawn(binary,[],{cwd:process.cwd(),env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1'},stdio:['ignore',log.fd,log.fd]});
const sensitive=[...(await readFile(resolve(opts['--config']),'utf8')).matchAll(/^api_key\s*=\s*"([^"]+)"/gm)].map(m=>m[1]);
const redact=(s:string)=>sensitive.reduce((v,secret)=>v.replaceAll(secret,'[REDACTED]'),s);
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const report:any={conversation_mode:continuous?'strict_continuous_same_assistant_conversation':'default_continuous',status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),pid:app.pid,started_at:new Date().toISOString(),checks:[],stages:[],turns:[],limits:['Production main app with a test-only registry contribution; no alternate UI shell.','Public Harness input and real Metal PNGs; physical input/IME not claimed.','Nonce fixture connection secret is entered only at the real connect-time challenge; it is never written into evidence.','Failure cleanup may signal only this owned PID; successful acceptance requires the normal owned window close route.']};
function shown(n:any){return n?.rect&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;}
function nodes(n:any):any[]{return !n?[]:[n,...(n.children??[]).flatMap(nodes)];}
function text(n:any){return nodes(n).filter(shown).map(n=>n.text??'').join('');}
async function visible(id:string,timeout=15000){return waitFor(async()=>(await query(id)).findLast(shown)??null,timeout);}
async function clickNode(n:any){assert(shown(n));assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await sleep(100);}
async function click(id:string){await clickNode(await visible(id));}
async function set(id:string,value:string){await click(id);await key('a',{cmd:true});assert((await type_(value)).ok);}
async function absent(id:string){await waitFor(async()=>!(await query(id)).some(shown)||null,15000);}
async function connectSavedFixture(){
 const row=(await query('sidebar.host')).find(n=>shown(n)&&text(n).includes('V02 native fixture owner'));assert(row);await clickNode(row);
 const fresh=(await query('sidebar.host')).find(n=>shown(n)&&text(n).includes('V02 native fixture owner'));const connect=nodes(fresh).find(n=>shown(n)&&n.test_id==='sidebar.host.connect');assert(connect);await clickNode(connect);
}
async function challengeAnswer(){return waitFor(async()=>{for(const id of ['plugin.challenge.secret','host.challenge.answer','host.challenge.answer.0','plugin.challenge.answer','auth.challenge.answer.0']){const n=(await query(id)).find(shown);if(n){if(opts['--shared-presenter-only']==='1'){const modals=await query('plugin.challenge.modal');assert.equal(modals.length,1);assert.equal((await query('auth.challenge.modal')).length,0);if(report.shared_presenter)assert.equal(report.shared_presenter.node_id,modals[0].id);report.shared_presenter={modal_id:'plugin.challenge.modal',node_id:modals[0].id,registered_instances:1,legacy_auth_view_instances:0,reused_across_challenges:true};}return n;}}return null;},20000);}
async function traces(){const s=await readFile(logPath,'utf8');return s.slice(0,s.lastIndexOf('\n')+1).split('\n').flatMap((l,i)=>{const at=l.indexOf('AI_TOOL_TRACE ');return at<0?[]:[{...JSON.parse(l.slice(at+14)),log_line:i+1}];});}
async function capture(name:string){await sleep(250);const ids=['wizard.dialog','wizard.plugin.editor','fixture.editor','sidebar.host','tabs.strip','fixture.canvas','fixture.rgba','workspace.plugin.content','terminal.surface','ai.panel','ai.approval','ai.tool.results','plugin.challenge.modal','plugin.challenge.source','plugin.challenge.material','auth.challenge.modal'];const state=Object.fromEntries(await Promise.all(ids.map(async id=>[id,await query(id)])));await writeFile(join(out,name+'.json'),redact(JSON.stringify(state,null,2)));assert((await screenshot(join(out,name+'.png'))).ok);report.stages.push(name);await writeFile(join(out,'report.in-progress.json'),redact(JSON.stringify(report,null,2)));console.log(name);}
async function busy(){return(await query('ai.stop')).some(shown);}
async function submit(value:string){await set('ai.prompt',value);assert.equal((await inputState('ai.prompt')).buffer,value);await click('ai.send');}
function digest(value:any){return Array.isArray(value)?String.fromCharCode(...value):String(value??'');}
function verifyTurn(events:any[],tool:string,decision?:'accept'|'reject'){
 const calls=events.filter(e=>e.event==='dynamic_invocation');assert.equal(calls.length,1,`${tool}: exactly one invocation`);assert.equal(calls[0].tool_id,'fixture_uprobe__'+tool);
 const pending=events.filter(e=>e.event==='dynamic_approval_pending'),decided=events.filter(e=>e.event==='dynamic_approval_decision'),dispatch=events.filter(e=>e.event==='dynamic_dispatch'),result=events.filter(e=>e.event==='dynamic_result');
 assert.equal(pending.length,decision?1:0);assert.equal(decided.length,decision?1:0);
 if(decision){assert.equal(decided[0].approved,decision==='accept');assert.equal(digest(pending[0].arguments_hash),digest(decided[0].arguments_hash));}
 assert.equal(dispatch.length,decision==='reject'?0:1,`${tool}: actual dispatch count`);
 if(decision==='reject'){assert.equal(result.length,0);assert(events.some(e=>e.event==='dynamic_rejected'&&e.reason==='ToolApprovalRejected'&&e.dispatched===false));}
 else {assert.equal(result.length,1);assert.equal(result[0].status,'succeeded');assert.equal(result[0].local_released,true);assert.equal(result[0].remote_effect_unknown,false);assert.equal(result[0].call_id,calls[0].call_id);assert.equal(result[0].operation_id,dispatch[0].operation_id);}
 assert(events.some(e=>e.event==='wire_request'&&(e.tool_result_ids??[]).includes(calls[0].call_id)),`${tool}: original tool-call ID reaches provider as result`);
}
function verifyContinuation(events:any[]){
 if(!continuous)return;
 const first=events.find(e=>e.event==='wire_request');assert(first,'Actual provider request required');
 const identity=events.filter(e=>e.event==='request_identity');assert.equal(identity.length,1,'One actual Manager worker identity per user turn');
 const prepared=events.find(e=>e.event==='tools_prepared');assert(prepared&&Number.isInteger(identity[0].conversation_id));assert.equal(prepared.conversation_id,identity[0].conversation_id);
 const priorIdentity=report.turns[0]?.events.find((e:any)=>e.event==='request_identity');if(report.turns.length>1){assert.equal(identity[0].conversation_id,priorIdentity.conversation_id,'Same AI conversation across all user turns');assert.deepEqual(identity[0].owner,priorIdentity.owner,'Same captured owner across all user turns');assert(identity[0].history_messages>0,'Worker receives nonempty complete history');const previousIdentity=report.turns.at(-2).events.find((e:any)=>e.event==='request_identity');assert(identity[0].turn_id>previousIdentity.turn_id,'Distinct actual worker turn identity');}
 report.turns.at(-1).request_identity=identity[0];
 assert(events.some(e=>e.event==='provider_http_response'&&e.status===200),'Actual provider HTTP response received');
 assert(events.some(e=>e.event==='provider_response_finish'),'Provider finish reason retained');
 if(events.some(e=>e.event==='dynamic_invocation')){const finish=events.find(e=>e.event==='provider_response_finish');assert(['tool_calls','stop'].includes(finish.finish_reason),'Tool delta provider round finishes normally');assert(finish.tool_call_deltas>0&&finish.tool_plan_deltas>0);report.turns.at(-1).provider_tool_finish_protocol=finish.finish_reason==='tool_calls'?'tool_calls':'valid_tool_deltas_with_stop';}

 const previous=report.turns.slice(0,-1);
 const priorCalls=previous.flatMap((t:any)=>t.events.filter((e:any)=>e.event==='dynamic_invocation').map((e:any)=>e.call_id));
 for(const id of priorCalls){assert(first.tool_use_ids?.includes(id),'Next turn retains original assistant tool call '+id);assert(first.tool_result_ids?.includes(id),'Next turn retains original result ID '+id);}
 const oldImages=previous.flatMap((t:any)=>t.events.flatMap((e:any)=>e.event==='wire_request'?e.images??[]:[]));
 for(const img of oldImages)assert(first.images?.some((x:any)=>digest(x.sha256)===digest(img.sha256)),'Next turn retains prior observation image SHA');
 assert.deepEqual([...first.tool_names].sort(),['fixture_uprobe__ping','fixture_uprobe__observe','fixture_uprobe__input','fixture_uprobe__write'].sort(),'Fixture tools remain declared in every turn');
 report.turns.at(-1).continuation={prior_call_ids:priorCalls,first_wire_request:first,prior_images_retained:oldImages.length};
}
async function turn(name:string,prompt:string,decision?:'accept'|'reject'){
 if(opts['--fresh-chat-per-turn']==='1'){await click('ai.session.new');await visible('ai.prompt');if(name.includes('full-control')){await click('ai.composer.permission');await click('ai.permission.auto');}report.conversation_mode='fresh_assistant_conversation_per_tool_same_fixture_owner';}
 const offset=(await traces()).length;await submit(prompt);
 let completedWithoutApproval=false;
 if(decision){await waitFor(async()=>{const events=(await traces()).slice(offset);if((await query('ai.approval')).some(shown))return true;if(!await busy()&&events.some(e=>e.event==='wire_request')){completedWithoutApproval=true;return true;}return null;},150000);if(!completedWithoutApproval){await capture(name+'-pending');await click('ai.approval.'+decision);}}
 await waitFor(async()=>{const all=(await traces()).slice(offset);return !await busy()&&all.some(e=>e.event==='wire_request')||null;},150000);
 const events=(await traces()).slice(offset),response=(await query('ai.response')).filter(shown).map(text);report.turns.push({name,decision,events,response,completed_without_requested_approval:completedWithoutApproval});await capture(name+'-complete');verifyContinuation(events);return events;
}
async function normalClose(){const state=await request('POST','/zerowork/windows',{action:'snapshot'});assert.equal(state.windows.length,1);assert((await request('POST','/zerowork/windows',{action:'close',window:state.windows[0].window})).ok);await Promise.race([ended,sleep(10000)]);assert.equal(app.exitCode,0);assert.equal(app.signalCode,null);report.normal_app_close=true;}
let failure:any;
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1440,900);
 await click('sidebar.empty.new');await click('wizard.protocol');await click('wizard.protocol.fixture_probe');await visible('fixture.editor');
 await set('fixture.name','V02 native fixture owner');await set('fixture.destination','synthetic.invalid');
 assert(!(await query('wizard.steps')).some(shown),'Contributed editor does not impose the built-in three-step form');
 await click('fixture.route');await visible('fixture.child_ssh');await capture('00-fixture-conditional-editor');
 if(opts['--skip-child']!=='1'){
  await click('fixture.child_ssh');await visible('wizard.name');await set('wizard.name','V02 nested offline SSH');await set('wizard.host','127.0.0.1');await set('wizard.user','fixture-readonly');await set('wizard.port','1');
  await click('wizard.next.identity');await click('wizard.next.route');await click('wizard.save_only');await absent('wizard.name');await visible('fixture.editor');
  await waitFor(async()=>text(await visible('fixture.editor')).includes('SSH 配置已引用')||null,15000);report.checks.push('Nested ordinary SSH editor saves offline and returns its immutable reference without losing parent fields');
 }else{report.limits.push('Partial diagnostic: nested child editor deliberately skipped; this run cannot pass the complete public-entry acceptance gate.');}
 await click('fixture.route');await absent('fixture.child_ssh');
 assert.equal((await inputState('fixture.name')).buffer,'V02 native fixture owner','Conditional route toggle preserves other editor fields');
 await click('wizard.save_only');await absent('fixture.editor');
 const saved=await readFile(join(data,'hosts.toml'),'utf8');assert(saved.includes('V02 native fixture owner'));if(opts['--skip-child']!=='1')assert(saved.includes('V02 nested offline SSH'));assert(saved.includes('fixture_probe'));
 assert(!(await query('tabs.tab.1')).some(shown),'Offline save does not create any session');
 report.checks.push('Registered protocol opens its non-three-step conditional editor','Fixture offline save publishes ordinary sidebar asset and creates no runtime');await capture('01-offline-assets-published');
 await connectSavedFixture();
 await challengeAnswer();await capture('02-connect-secret-cancel-pending');await click('plugin.challenge.cancel');await absent('plugin.challenge.modal');assert(!(await query('fixture.canvas')).some(shown));
 const cancelledTab=(await query('tabs.strip')).flatMap(nodes).find(n=>shown(n)&&/^tabs\.tab\.\d+$/.test(n.test_id??''));
 report.cancelled_attempt={visible_tab:cancelledTab?.test_id??null};if(cancelledTab){await click(cancelledTab.test_id.replace('tabs.tab.','tabs.close.'));await sleep(150);if((await query('session.close.accept')).some(shown))await click('session.close.accept');await absent(cancelledTab.test_id);}assert(app.exitCode===null);report.checks.push('Cancelling the real connect-time secret challenge creates no ready content and leaves no visible owner tab; the same App stays alive');await capture('02-cancelled-owner-closed');
 await connectSavedFixture();
 // The shared HostContext presenter must expose the real per-owner challenge.
 const answer=await challengeAnswer();
 report.challenge={answer_test_id:answer.test_id,kind:'secret_input',secret_recorded:false};
 assert(!(await query('fixture.canvas')).some(shown),'No content may become ready before answering challenge');await capture('02-connect-time-secret-challenge');
 const secret='v02-connect-'+randomUUID();sensitive.push(secret);await clickNode(answer);await type_(secret);
 let submitted=false;for(const id of ['host.challenge.submit','plugin.challenge.submit','auth.challenge.submit']){const n=(await query(id)).find(shown);if(n){await clickNode(n);submitted=true;break;}}assert(submitted);
 await visible('fixture.canvas',20000);await visible('fixture.rgba');assert(!(await query('terminal.surface')).some(shown),'Non-terminal fixture mounts no terminal placeholder');
 assert(!(await query('status.connection.grid')).some(shown),'Non-terminal fixture hides terminal-only status metrics');
 const after=await readFile(join(data,'hosts.toml'),'utf8');assert(!after.includes(secret),'Connect-time secret is never persisted');assert.equal(after,saved);report.checks.push('Public per-owner connect-time secret challenge precedes ready; answer remains ephemeral','Independent non-terminal content renders a real synthetic RGBA texture without terminal/exec placeholders');await capture('02-real-nonterminal-canvas');
 const tab=(nodes(await visible('tabs.strip')).find(n=>shown(n)&&/^tabs\.tab\.\d+$/.test(n.test_id??'')));assert(tab);report.tab=tab.test_id;
 if(opts['--no-ai']!=='1'){
  await click('toolbar.ai');await visible('ai.prompt');
  const observe=await turn('03-observe','Call fixture_uprobe__observe exactly once for the current assistant_session_id. Do not call another tool. After the actual image is received, describe the visible synthetic grid and pointer in one short sentence.');
  verifyTurn(observe,'observe');
  const observed=observe.flatMap(e=>e.event==='wire_request'?e.images??[]:[]);assert(observed.some(i=>i.mime==='image/png'&&i.width===64&&i.height===40),'Actual serialized provider request contains the 64x40 PNG observation');
  await click('ai.tool.result.disclosure');await visible('ai.tool.result.image');await capture('03-observe-rendered-image');report.observation_images=observed;
  const currentSession=observe.find(e=>e.event==='dynamic_invocation').owner.session;assert(Number.isInteger(currentSession));
  verifyTurn(await turn('04-input',`Actually invoke the function fixture_uprobe__input exactly once with these exact JSON arguments: ${JSON.stringify({session_ids:[currentSession],kind:'pointer',x:30,y:20})}. This is a request to execute the tool, not a request for an acknowledgement. Do not claim completion without receiving its real tool result. Do not call any other tool or change parameters. After the host approves and the actual result is returned, briefly report that result.`,'accept'),'input','accept');
  const moved=await turn('05-reobserve','Call fixture_uprobe__observe exactly once for the current assistant_session_id. Do not call any other tool. After the actual image is received, describe the current pointer position briefly.');
  verifyTurn(moved,'observe');
  const changed=moved.flatMap(e=>e.event==='wire_request'?e.images??[]:[]);assert(changed.some(i=>i.sha256&&!observed.some(j=>digest(j.sha256)===digest(i.sha256))),'Approved structured input changes the actual observed frame digest');
  await click('ai.composer.permission');await click('ai.permission.auto');
  verifyTurn(await turn('06-write-reject-full-control',`Actually invoke fixture_uprobe__write exactly once with exact JSON arguments ${JSON.stringify({session_ids:[currentSession],powered:false})}. Do not merely acknowledge the request. Do not call another tool or retry if rejected. Wait for the actual host result and briefly report it.`,'reject'),'write','reject');
  verifyTurn(await turn('07-write-approve-full-control',`Actually invoke fixture_uprobe__write exactly once with exact JSON arguments ${JSON.stringify({session_ids:[currentSession],powered:false})}. Do not merely acknowledge or claim completion before a real tool result. Do not call another tool. Wait for explicit approval and briefly report the actual result.`,'accept'),'write','accept');
  report.checks.push('Actual provider receives native PNG observations and actual image result card','Structured pointer input requires approval and changes the next real image digest','always_confirm write still presents approval in full-control; reject and single approval both exercised');
 }
 await key('escape');await click(tab.test_id.replace('tabs.tab.','tabs.close.'));await sleep(150);if((await query('session.close.accept')).some(shown))await click('session.close.accept');await absent('fixture.canvas');await absent(tab.test_id);report.checks.push('Closing the exact fixture owner removes its content and tab while the App stays alive');assert(app.exitCode===null);await capture('08-owner-closed');
 await normalClose();
 report.status=continuous?'passed_strict_continuous_conversation':opts['--fresh-chat-per-turn']==='1'?'passed_fresh_assistant_conversation_per_tool_same_fixture_owner':opts['--skip-child']==='1'?'partial_diagnostic_child_skipped':opts['--no-ai']==='1'?'public_editor_connect_content_close_passed_ai_not_run':'passed_pending_dispatch_and_lease_receipt_review';
}catch(e){failure=e;report.status='failed';report.error=String(e);try{await capture('failure-live');}catch{}}
finally{
 try{report.traces=await traces();}catch{}
 if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await Promise.race([ended,sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}
 report.cleanup={exit_code:app.exitCode,signal:app.signalCode};await log.close();await writeFile(logPath,redact(await readFile(logPath,'utf8')));await rm(iso,{recursive:true,force:true});report.private_data_removed=true;report.finished_at=new Date().toISOString();await writeFile(join(out,'report.json'),redact(JSON.stringify(report,null,2)));
}
console.log(report.status);if(failure)throw failure;
