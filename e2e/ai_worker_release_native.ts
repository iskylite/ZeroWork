/** v0.4 first foundation: real AiHost End/rebuild, original conversation and
 * tool results. Only the Provider is a loopback fixture; no remote credentials.
 * Build: zig build -Dtest-mode=true --prefix /tmp/zw-v04-build -j2
 * Run: ZW_AI_TEST_PREFIX=/tmp/zw-v04-build node e2e/ai_worker_release_native.ts <out>
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,writeFile,readFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-v04-build');
const binary=join(prefix,'bin/zerowork');
const out=resolve(process.argv[2]??'/tmp/zw-v04-worker-native');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-worker-native-'));
const data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
for(const dir of [data,rpc,zdot])await mkdir(dir);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='worker-native%# '\n");
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const requests:any[]=[];let held:any=null,heldClosed=false,fixtureFailure:any=null;
const server=createServer(async(req,res)=>{try{
 if(req.method!=='POST'){res.end('{"data":[{"id":"worker-fixture"}]}');return}
 let raw='';for await(const part of req)raw+=part;
 const body=JSON.parse(raw);res.writeHead(200,{'content-type':'text/event-stream'});
 if(!body.tools?.length){res.end(frame({content:'Worker 验证'})+'data: [DONE]\n\n');return}
 requests.push(body);
 const user=String(body.messages.filter((m:any)=>m.role==='user').at(-1)?.content??'');
 const stage=/WORKER_(FIRST|SECOND|HOLD)/.exec(user)?.[1];assert(stage,'explicit stage required');
 const call='worker-context-'+stage;
 if(!body.messages.some((m:any)=>m.role==='tool'&&m.tool_call_id===call)){
  const name='host__get_ucurrent_ucontext';assert(body.tools.some((t:any)=>t.function.name===name));
  res.end(frame({tool_calls:[{index:0,id:call,type:'function',function:{name,arguments:'{}'}}]})+'data: [DONE]\n\n');return
 }
 const receipt=JSON.parse(body.messages.find((m:any)=>m.role==='tool'&&m.tool_call_id===call).content);
 assert.equal(receipt.status,'succeeded');
 if(stage==='HOLD'){held=res;res.write(frame({content:'WORKER_HOLD_STREAM'}));res.once('close',()=>{heldClosed=true;held=null});return}
 res.end(frame({content:'WORKER_'+stage+'_FINISHED'})+'data: [DONE]\n\n');
}catch(error){fixtureFailure=String(error);if(!res.headersSent)res.writeHead(500);res.end()}});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="worker-fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="worker-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="worker-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(done=>app.once('close',done));
const alive=()=>app.exitCode===null&&app.signalCode===null;
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join(' ');
const visible=(id:string)=>h.waitFor(async()=>{assert(alive());assert.equal(fixtureFailure,null);return(await h.query(id)).find(shown)??null},15000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,15000);
const report:any={status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),isolation:iso,checks:[],screenshots:[]};
const click=async(id:string)=>{report.last_action=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
const input=async(value:string)=>{await click('ai.prompt');await h.key('a',{cmd:true});await h.type_(value)};
const send=async(value:string)=>{await input(value);await click('ai.send')};
const capture=async(name:string)=>{await h.mouseMove(1,1);await h.sleep(200);assert((await h.screenshot(join(out,name+'.png'))).ok);report.screenshots.push(join(out,name+'.png'))};
const journal=async()=>String(await readFile(join(data,'ai-sessions.jsonl'),'utf8')).trim().split('\n').map(line=>JSON.parse(line));
async function endConversation(){await click('ai.close');await click('ai.close.confirmation.confirm');await absent('ai.panel');await visible('terminal.surface')}
async function restore(){
 await click('toolbar.ai');await click('ai.sessions');await click('ai.session.restore.1');
 await h.waitFor(async()=>{if((await h.query('ai.session.close.accept')).some(shown))await click('ai.session.close.accept');return !(await h.query('ai.sessions.menu')).some(shown)&&!(await h.query('ai.session.close.confirmation')).some(shown)||null},15000);
 await visible('ai.prompt');
}
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1200,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');
 assert.equal(requests.length,0);
 await send('WORKER_FIRST 读取当前会话信息');await h.waitFor(async()=>text(await h.query('ai.panel')).includes('WORKER_FIRST_FINISHED')||null,20000);await absent('ai.stop');assert.equal(requests.length,2);
 await input('解绑后保留的草稿');await capture('01-completed');await endConversation();
 const firstEvents=await journal();const source=firstEvents.find(e=>e.event?.kind==='checkpoint').event.conversation;
 assert(firstEvents.some(e=>e.event?.kind==='unbind'&&e.event.conversation===source));
 report.checks.push('Real tool result completes, End saves history/draft and unbinds while the Local PTY remains open');
 await restore();assert.equal((await h.inputState('ai.prompt')).buffer,'解绑后保留的草稿');assert.equal(requests.length,2);await capture('02-restored-no-model');
 await send('WORKER_SECOND 再次读取当前会话信息');await h.waitFor(async()=>text(await h.query('ai.panel')).includes('WORKER_SECOND_FINISHED')||null,20000);await absent('ai.stop');assert.equal(requests.length,4);
 assert(requests[2].messages.some((m:any)=>m.role==='assistant'&&m.content?.includes('WORKER_FIRST_FINISHED')));
 await h.resizeWindow(860,480);await capture('03-rebuilt-compact');await endConversation();
 report.checks.push('Restore starts no Provider request; explicit input rebuilds execution, keeps the original history and produces a fresh real host tool result');
 await restore();assert.equal(requests.length,4);await send('WORKER_HOLD 等待期间结束');await h.waitFor(()=>held||null,20000);await visible('ai.stop');await capture('04-streaming');await endConversation();await h.waitFor(()=>heldClosed||null,15000);
 const finalEvents=await journal();const unbound=finalEvents.filter(e=>e.event?.kind==='unbind'&&e.event.conversation===source);assert.equal(unbound.length,3);
 assert.equal(requests.length,6);report.requests=requests;await writeFile(join(out,'journal.json'),JSON.stringify(finalEvents,null,2));
 report.checks.push('End during streaming cancels the original network response, preserves interrupted facts, unbinds the same conversation and leaves the business connection alive');
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await capture('failure').catch(()=>{});await h.query('ai.panel').then(tree=>writeFile(join(out,'failure-tree.json'),JSON.stringify(tree,null,2))).catch(()=>{})}
finally{
 try{if(alive()){const windows=await h.request('POST','/zerowork/windows',{action:'snapshot'});assert.equal(windows.windows.length,1);report.close_route='POST /zerowork/windows quit';report.quit_response=await h.request('POST','/zerowork/windows',{action:'quit'});assert(report.quit_response.ok);const start=performance.now();while(alive()&&performance.now()-start<15000){for(const id of ['groups.close.accept','local.close.accept','session.close.accept'])try{if((await h.query(id)).some(shown))await h.clickTestId(id)}catch{}await Promise.race([ended,h.sleep(80)])}}}catch(error){report.quit_error=String(error)}
 if(alive()){report.quit_snapshot=await h.request('POST','/zerowork/windows',{action:'snapshot'}).catch(String);await writeFile(join(out,'quit-tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{});await capture('quit-pending').catch(()=>{});report.forced=true;app.kill('SIGTERM');await ended}
 report.exit_code=app.exitCode;report.signal=app.signalCode;if(report.forced||app.exitCode!==0){report.status='failed';process.exitCode=1}
 if(held)held.destroy();server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();
 const logs=await readFile(join(out,'app.log'),'utf8');if(/leaked \[addr:|panic:|double free|use.after.free/i.test(logs)){report.status='failed';report.memory_error=true;process.exitCode=1}
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}));
}
