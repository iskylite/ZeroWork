/** v0.4 real parent/child tool gateway and same-Task continuation.
 * Uses isolated Local PTY, data and loopback provider; executes no commands.
 * ZW_AI_TEST_PREFIX=/tmp/zw-v04-task-build node e2e/ai_task_gateway_native.ts <out>
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,writeFile,readFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-v04-task-build'),binary=join(prefix,'bin/zerowork');
const out=resolve(process.argv[2]??'/tmp/zw-v04-task-gateway-native');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-task-gateway-')),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
for(const dir of [data,rpc,zdot])await mkdir(dir);await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='task-gateway%# '\n");
const steer=process.argv[3]==='steer';const requests:any[]=[];let childHeld:any=null,rootRound=0,childReleased=false;
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const finish=(res:any,text:string)=>res.end(frame({content:text})+'data: '+JSON.stringify({choices:[],usage:{prompt_tokens:17,completion_tokens:3}})+'\n\ndata: [DONE]\n\n');
const tool=(res:any,id:string,args:any)=>res.end(frame({tool_calls:[{index:0,id,type:'function',function:{name:'host__agent_utasks',arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n');
const server=createServer(async(req,res)=>{if(req.method!=='POST'){res.end('{"data":[{"id":"task-gateway"}]}');return}let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);res.writeHead(200,{'content-type':'text/event-stream'});
 if(!body.tools?.length){finish(res,'任务协作测试');return}
 requests.push(body);
 const child=JSON.stringify(body.messages).includes('CHILD_MATERIAL_TASK')&&!body.tools.some((t:any)=>t.function?.name==='host__agent_utasks');
 if(child){assert(!body.tools.some((t:any)=>t.function?.name==='host__agent_utasks'));assert(!JSON.stringify(body.messages).includes('ROOT_FIRST_TASK'),'independent child omits parent transcript');childHeld=res;res.write(frame({content:'CHILD_STARTED '}));return}
 const last=body.messages.filter((m:any)=>m.role==='user').at(-1)?.content??'';
 if(String(last).includes('QUEUED_SECOND')){finish(res,'SECOND_ROOT_DONE');return}
 rootRound++;
 if(rootRound===1){assert(body.tools.some((t:any)=>t.function?.name==='host__agent_utasks'));tool(res,'create-one',{action:'create',request_key:'reader-one',name:'材料检查',text:'CHILD_MATERIAL_TASK 检查给定材料',session_refs:[],reusable:true});return}
 if(rootRound===2){finish(res,'PROVISIONAL_PARENT must wait for its child');return}
 if(steer&&rootRound===3&&!childReleased){assert(String(last).includes('USER_STEER'));finish(res,'PROVISIONAL_AFTER_STEER');return}
 if(rootRound===(steer?4:3)){tool(res,'collect-one',{action:'wait_events',after_sequence:0,wait_ms:10000});return}
 assert(body.messages.some((m:any)=>m.role==='tool'&&String(m.content).includes('CHILD_FINAL_EVIDENCE')),'parent resumes with real child report tool result');finish(res,'PARENT_FINAL_WITH_CHILD');
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="task-gateway"\nfollow_up_mode="queue"\npermission_mode="auto"\n[[ai.providers]]\nid="task-gateway"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="task-gateway"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts'));const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(done=>app.once('close',done)),alive=()=>app.exitCode===null&&app.signalCode===null;
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(nodes:any)=>flat(nodes).map(n=>n.text??'').join(' ');
const visible=(id:string)=>h.waitFor(async()=>{assert(alive());return(await h.query(id)).find(shown)??null},15000);
const report:any={status:'running',isolation:iso,binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],screenshots:[]};
const click=async(id:string)=>{report.last_action=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
const capture=async(name:string)=>{await h.mouseMove(1,1);await h.sleep(200);assert((await h.screenshot(join(out,name+'.png'))).ok);report.screenshots.push(join(out,name+'.png'))};
const journal=async()=>String(await readFile(join(data,'ai-sessions.jsonl'),'utf8')).trim().split('\n').map(row=>JSON.parse(row));
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1200,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');
 await click('ai.prompt');await h.type_('ROOT_FIRST_TASK 委派材料检查并汇总');await click('ai.send');
 await h.waitFor(()=>childHeld||null,20000);
 await h.waitFor(async()=>(await journal()).some(row=>row.event?.task_fact?.status==='waiting_children')||null,20000);
 assert.equal(rootRound,2,'parent final response pauses same Task until child settles');await visible('ai.stop');await capture('01-parent-waits-for-child');
 if(steer){await click('ai.prompt');await h.type_('USER_STEER 补充材料约束，保持原任务');await h.key('return',{cmd:true,shift:true});await h.waitFor(()=>rootRound===3||null,15000);assert(childHeld,'steer resumes the parent while the child is still active');await h.waitFor(async()=>(await journal()).some(row=>row.receipt?.route==='steer'&&row.receipt.delivery==='consumed')||null,15000)}
 await click('ai.prompt');await h.type_('QUEUED_SECOND 原根任务收尾后再处理');await click('ai.send');await visible('ai.pending');assert.equal(rootRound,steer?3:2);
 childReleased=true;finish(childHeld,'CHILD_FINAL_EVIDENCE verified supplied material');childHeld=null;
 await h.waitFor(async()=>text(await h.query('ai.panel')).includes('SECOND_ROOT_DONE')||null,30000);
 await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,15000);
 assert.equal(rootRound,steer?5:4);assert.equal(requests.length,steer?7:6,'four parent requests, one child request and the next queued root');
 const rows=await journal();const launches=rows.filter(row=>row.event?.kind==='child_launch');assert.equal(launches.length,1);
 const launch=launches[0].event;assert.equal(launch.initial_text,'CHILD_MATERIAL_TASK 检查给定材料');assert(launch.initial_input&&launch.task_fact&&launch.child_info&&launch.targets.length===0,'one atomic row owns identity binding input and task');
 const parentTask=launch.task_fact.parent;const rootFacts=rows.flatMap(row=>row.event?.task_fact?[row.event.task_fact]:[]).filter(f=>f.task===parentTask);assert(rootFacts.some(f=>f.status==='waiting_children'));assert.equal(rootFacts.at(-1).status,'succeeded');assert.equal(rootFacts.at(-1).counters.requests,steer?6:5);assert.equal(rootFacts.at(-1).counters.calls,2);
 assert(rows.some(row=>row.event?.task_fact?.task===launch.task_fact.task&&row.event.task_fact.status==='succeeded'&&row.event.task_fact.delivered===true));
 const ended=rows.findIndex(row=>row.event?.kind==='unbind'&&row.event.conversation===launch.conversation),parentFinished=rows.findIndex(row=>row.event?.task_fact?.task===parentTask&&row.event.task_fact.status==='succeeded');assert(ended>=0&&ended<parentFinished,'parent completion follows child local release/unbind');
 await h.resizeWindow(860,480);await capture('02-completed-and-next-root');await writeFile(join(out,'journal.json'),JSON.stringify(rows,null,2));report.requests=requests;report.steer=steer;if(steer){const receipts=rows.flatMap(row=>row.receipt?.delivery==='consumed'?[row.receipt]:[]).filter(r=>r.fence.conversation===rootFacts[0].conversation);assert.equal(receipts[0].turn,receipts[1].turn);report.checks.push('user steer wakes parent dependency wait and is consumed in the original Task/Turn while the child remains active')}report.checks.push('real tool gateway creates exactly one material-only independent child with no delegation tools; atomic initial transaction persists before Worker startup','premature parent answer waits and continues under the original TaskId and budget; child report is a real wait_events tool result','queued input waits for the entire root to settle, then receives a fresh root budget; child Worker unbind precedes parent completion');report.status='passed';

}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await capture('failure').catch(()=>{});await h.query('ai.panel').then(tree=>writeFile(join(out,'failure-tree.json'),JSON.stringify(tree,null,2))).catch(()=>{})}
finally{
 if(childHeld){childHeld.destroy();childHeld=null}
 try{if(alive()){report.quit_response=await h.request('POST','/zerowork/windows',{action:'quit'});const start=performance.now();while(alive()&&performance.now()-start<15000){for(const id of ['groups.close.accept','local.close.accept','session.close.accept']){if(!alive())break;try{const q=await h.query(id);if(!Array.isArray(q))break;if(q.some(shown))await h.clickTestId(id)}catch{break}}await Promise.race([ended,h.sleep(80)])}}}catch(error){report.quit_error=String(error)}
 if(alive()){report.forced=true;app.kill('SIGTERM');await ended}report.exit_code=app.exitCode;report.signal=app.signalCode;if(report.forced||app.exitCode!==0){report.status='failed';process.exitCode=1}
 server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();const logs=await readFile(join(out,'app.log'),'utf8');if(/leaked \[addr:|panic:|double free/i.test(logs)){report.status='failed';process.exitCode=1}await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}));
}
