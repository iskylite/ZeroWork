/** Isolated main-entry regression: real loopback HTTP/SSE, Local exec and native UI.
 * No external AI/SSH traffic. Writes only the runner's own temporary marker.
 */
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,writeFile,readFile,open,copyFile,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {waitForServerReady,waitFor,query,clickTestId,key,type_,inputState,resizeWindow,screenshot,sleep,scrollAt} from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'dist/ui-acceptance/fix-three-20261022/native-dark'),theme=process.argv[3]??'dark';
await mkdir(out,{recursive:true});
const iso=await mkdtemp(join(tmpdir(),'zw-three-fixes-')),rpc=join(iso,'rpc'),data=join(iso,'data'),marker=join(iso,'executions.txt');
await mkdir(rpc);await mkdir(data);
const requests:any[]=[],report:any={status:'running',theme,checks:[],screenshots:[],provider:'controlled loopback OpenAI-compatible HTTP/SSE, production transport',input:'synthetic public Harness, real isolated main-entry Metal window',limits:['No external model behavior or physical IME claim','SIGTERM cleanup is not normal-close evidence']};
let next='tool',call=0,forceFailure=true;
const server=createServer(async(req,res)=>{try{let body='';for await(const chunk of req)body+=chunk;const parsed=JSON.parse(body);requests.push(parsed);res.writeHead(200,{'content-type':'text/event-stream'});
 const frame=(delta:any)=>res.write('data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n');
 if(next==='tool'){
  const sys=parsed.messages.find((m:any)=>m.role==='system')?.content??'';const id=Number(sys.match(/assistant_session_id=(\d+)/)?.[1]);assert(id>0);
  call++;const command=`printf 'x\\n' >> '${marker}'`;
  frame({tool_calls:[{index:0,id:'fix-call-'+call,type:'function',function:{name:'run_command',arguments:JSON.stringify({session_ids:[id],command})}}]});
  res.end('data: [DONE]\n\n');next='feedback';
 }else if(next==='feedback'){
  assert(parsed.messages.some((m:any)=>m.role==='tool'));frame({content:forceFailure?'PARTIAL_REPLY_KEPT':'FINAL_PLAN_DONE'});
  if(forceFailure){forceFailure=false;next='answer';res.end();}else{res.end('data: [DONE]\n\n');next='tool';}
 }else{
  assert(!parsed.tools?.length,'Answer retry must not advertise tools');assert(parsed.messages.some((m:any)=>m.role==='tool'&&m.tool_call_id==='fix-call-'+call));
  frame({content:'ANSWER_RETRY_DONE'});res.end('data: [DONE]\n\n');next='tool';
 }
}catch(e){report.server_error=String(e);res.destroy();}});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision = 1\n[ui]\ntheme = "${theme}"\n[ai]\ndefault_provider = "controlled"\npermission_mode = "confirm"\n[[ai.providers]]\nid = "controlled"\nkind = "openai_compat"\nendpoint = "http://127.0.0.1:${port}/v1/chat/completions"\napi_key = "isolated-test"\nenabled = true\n[[ai.providers.models]]\nname = "controlled"\ncontext_window = 200000\ndefault = true\n`);
const binary=join(out,'zerowork-frozen');await copyFile('zig-out/bin/zerowork',binary);await copyFile('zig-out/bin/zw_ipc.so',join(out,'zw_ipc.so'));report.binary_sha256=createHash('sha256').update(await readFile(binary)).digest('hex');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const env={...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1'};
for(const k of ['ZEROWORK_AI_MOCK','ZEROWORK_AI_ENDPOINT','ZEROWORK_AI_MODEL','ZEROWORK_AI_PROVIDER'])delete env[k];
const log=await open(join(out,'app.log'),'w'),app=spawn(binary,[],{env,stdio:['ignore',log.fd,log.fd]});const ended=new Promise<void>(done=>app.once('close',()=>done()));
const shown=(n:any)=>n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>shown(n)?[n,...(n.children??[]).flatMap(flat)]:[];
const txt=(n:any)=>flat(n).map(x=>x.text??'').join('');
async function visible(id:string){return waitFor(async()=>(await query(id)).find(shown)??null,15000)}
async function click(id:string){report.last_action=id;await visible(id);assert((await clickTestId(id)).ok);await sleep(100)}
async function edit(id:string,text:string){await click(id);await key('a',{cmd:true});await type_(text)}
async function cap(name:string){await sleep(100);const path=join(out,name+'.png');assert((await screenshot(path)).ok);report.screenshots.push(path);const nodes:any={};for(const id of ['ai.panel','quick.connect','wizard.panel','wizard.encoding'])nodes[id]=await query(id);await writeFile(join(out,name+'.queries.json'),JSON.stringify(nodes,null,2));}
async function count(){return (await readFile(marker,'utf8').catch(()=>'' )).trim().split('\n').filter(Boolean).length}
async function submit(question:string){await edit('ai.prompt',question);await click('ai.send')}
async function approve(expected:number){await visible('ai.approval');assert.equal(await count(),expected,'No execution before explicit approval');await click('ai.approval.accept');}
async function recovery(){await visible('ai.recovery');assert(txt((await query('ai.panel')).find(shown)).includes('PARTIAL_REPLY_KEPT'));}
try{
 await waitForServerReady();await resizeWindow(1440,900);
 await click('toolbar.quick_connect');await cap('00-quick-icon');await key('escape');
 // The wizard is opened through the normal new-profile entry; no host saved.
 await key('t',{cmd:true});await click('session.menu.new_profile');
 await edit('wizard.name','encoding-test');await edit('wizard.host','127.0.0.1');await edit('wizard.user','tester');
 await click('wizard.identity.toggle');await click('wizard.advanced.toggle');
 const before=await inputState('wizard.encoding');await edit('wizard.encoding','GB18030');
 assert.equal((await inputState('wizard.encoding')).buffer,'UTF-8');report.checks.push('UTF-8 readonly capability prevents unsupported edit');await cap('01-encoding-readonly');await resizeWindow(860,480);await cap('01b-encoding-compact');await resizeWindow(1440,900);await key('escape');
 await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');
 await submit('controlled first question');await approve(0);await recovery();assert.equal(await count(),1);await cap('02-recovery-original');
 // Retain a separate next draft and prove editing does not request or execute.
 await edit('ai.prompt','next draft');const requestCount=requests.length;await click('ai.recovery.edit');assert.equal(requests.length,requestCount);assert.equal(await count(),1);assert((await inputState('ai.prompt')).buffer.includes('next draft'));assert((await inputState('ai.prompt')).buffer.includes('controlled first question'));const edited=(await inputState('ai.prompt')).buffer;await click('ai.recovery.edit');assert.equal((await inputState('ai.prompt')).buffer,edited);
 await resizeWindow(860,480);await cap('02b-recovery-compact');const bounds=await visible('ai.panel');for(const id of ['ai.recovery.answer','ai.recovery.edit','ai.recovery.regenerate']){const n=await visible(id);assert.equal(n.rect.h,28);assert.equal(n.rect.w,id==='ai.recovery.edit'?104:140);assert(n.rect.x>=bounds.rect.x&&n.rect.x+n.rect.w<=bounds.rect.x+bounds.rect.w);assert(n.rect.y>=bounds.rect.y&&n.rect.y+n.rect.h<=bounds.rect.y+bounds.rect.h-90)}await click('ai.recovery.answer');await waitFor(async()=>txt((await query('ai.panel')).find(shown)).includes('ANSWER_RETRY_DONE')||null,15000);assert.equal(await count(),1);assert.equal(requests.length,requestCount+1);assert.equal((await inputState('ai.prompt')).buffer,'next draft\ncontrolled first question');assert(txt((await query('ai.panel')).find(shown)).includes('PARTIAL_REPLY_KEPT'));await resizeWindow(1440,900);await cap('03-answer-only-no-replay');report.checks.push('same ledger answer-only retry: one original execution, no tools advertised, partial retained separately, next draft unchanged');
 forceFailure=true;await submit('controlled second question');await approve(1);await recovery();assert.equal(await count(),2);await cap('04-before-new-plan');
 // Switching owners must not expose the failed owner's recovery actions.
 await key('t',{cmd:true});await click('session.menu.local');await sleep(250);assert(!(await query('ai.recovery')).some(shown));await click('tabs.tab.1');await recovery();
 await edit('ai.prompt','next plan draft');next='tool';forceFailure=false;await click('ai.recovery.regenerate');await approve(2);await waitFor(async()=>txt((await query('ai.panel')).find(shown)).includes('FINAL_PLAN_DONE')||null,15000);assert.equal(await count(),3);assert.equal((await inputState('ai.prompt')).buffer,'next plan draft');await cap('05-new-plan-fresh-approval');report.checks.push('new plan used new call, explicitly reapproved; owner switch kept recovery with original owner');
 await resizeWindow(860,480);await cap('06-compact');
 const events=(await readFile(join(out,'app.log'),'utf8')).split('\n').flatMap(line=>{const i=line.indexOf('AI_TOOL_TRACE ');if(i<0)return[];try{return[JSON.parse(line.slice(i+14))]}catch{return[]}});
 const dispatched=events.filter(e=>e.event==='exec_started');assert.equal(dispatched.length,3);assert.equal(new Set(dispatched.map(e=>e.turn_id)).size,3);assert.equal(requests.length,7);assert(!report.server_error);report.dispatches=dispatched;report.checks.push('three explicit approvals created three distinct production turns; answer retry created no execution');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);try{await cap('failure')}catch{}}
finally{report.requests=requests.map(r=>({tools:r.tools?.map((v:any)=>v.function?.name),messages:r.messages}));report.executions=await count();report.server_error??=null;if(app.exitCode===null)app.kill('SIGTERM');await Promise.race([ended,sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}report.cleanup={exit:app.exitCode,signal:app.signalCode};await log.close();await new Promise<void>(done=>server.close(()=>done()));await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(iso,{recursive:true,force:true});console.log(JSON.stringify({status:report.status,error:report.error,out}));}
if(report.status!=='passed')process.exitCode=1;
