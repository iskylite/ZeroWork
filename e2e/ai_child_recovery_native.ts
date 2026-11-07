/** v0.4 child data recovery in the real App. Seeds only an isolated schema-1/2
 * journal; the Provider is loopback. No child execution is restored or started.
 * ZW_AI_TEST_PREFIX=/tmp/zw-v04-child-build node e2e/ai_child_recovery_native.ts <out>
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {createHash,randomBytes} from 'node:crypto';
import {mkdir,mkdtemp,writeFile,readFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-v04-child-build'),binary=join(prefix,'bin/zerowork');
const out=resolve(process.argv[2]??'/tmp/zw-v04-child-recovery-native');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-child-recovery-')),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
for(const dir of [data,rpc,zdot])await mkdir(dir);await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='child-recovery%# '\n");
const stable=()=>randomBytes(16).toString('hex');
const parent=stable(),child=stable(),oldParentAgent=stable(),childAgent=stable();
const parentFence={agent:oldParentAgent,conversation:parent,binding:2,environment:1};
const childInfo={agent:childAgent,owning_parent_conversation:parent,created_by_agent:oldParentAgent,request_key:'saved-child',name:'HIDDEN_CHILD_HISTORY',context_mode:'independent',reusable:true,initial_context_hash:[...createHash('sha256').update('[]').digest()]};
const seeded=[
 {schema:1,event:{kind:'create',conversation:parent,agent:oldParentAgent,owner:{group:7},revision:2}},
 {schema:1,event:{kind:'checkpoint',conversation:parent,agent:oldParentAgent,revision:2,turn:1},messages:[{role:'user',content:'PARENT_HISTORY'},{role:'assistant',content:'PARENT_SAVED_ANSWER'}]},
 {schema:2,event:{kind:'child_create',conversation:child,revision:1,child_info:childInfo,parent_binding:parentFence,initial_origin:{group:7}}},
 {schema:2,event:{kind:'child_bind',conversation:child,agent:childAgent,owner:{group:7},revision:2,environment:2,parent_binding:parentFence,targets:[{session_id:11,generation:3}]}}
];
await writeFile(join(data,'ai-sessions.jsonl'),seeded.map(row=>JSON.stringify(row)).join('\n')+'\n');
const requests:any[]=[];const frame=(content:string)=>'data: '+JSON.stringify({choices:[{index:0,delta:{content}}]})+'\n\n';
const server=createServer(async(req,res)=>{if(req.method!=='POST'){res.end('{"data":[{"id":"child-recovery"}]}');return}let text='';for await(const part of req)text+=part;const body=JSON.parse(text);if(body.tools?.length)requests.push(body);res.writeHead(200,{'content-type':'text/event-stream'});res.end(frame(body.tools?.length?'RESTORED_ROOT_REPLY':'恢复测试')+'data: [DONE]\n\n')});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="child-recovery"\n[[ai.providers]]\nid="child-recovery"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="child-recovery"\ncontext_window=200000\ndefault=true\n`);
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
 await h.waitForServerReady(60000);await h.resizeWindow(1200,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.sessions');
 const menu=await visible('ai.sessions.menu'),rows=flat(menu).filter(n=>/^ai\.session\.row\.\d+$/.test(n.test_id??''));assert.equal(rows.length,2,'saved parent plus the current empty welcome conversation');assert(rows.some(n=>n.test_id==='ai.session.row.1'));assert(!rows.some(n=>n.test_id==='ai.session.row.2'),'saved child must not enter the main list');assert(!text(menu).includes('HIDDEN_CHILD_HISTORY'));assert.equal(requests.length,0);await capture('01-parent-list-only');
 const recovered=await journal();const unbinds=recovered.filter(row=>row.event?.kind==='unbind');assert.equal(unbinds.length,2);assert.equal(unbinds[0].event.conversation,child);assert.equal(unbinds[1].event.conversation,parent);report.checks.push('Production orphan recovery saves child End before parent End; hidden child data never selects or enters the main conversation list; zero model requests');
 await click('ai.session.restore.1');await h.waitFor(async()=>text(await h.query('ai.panel')).includes('PARENT_SAVED_ANSWER')||null,15000);assert.equal(requests.length,0);await h.resizeWindow(860,480);await capture('02-restored-parent-compact');
 await click('ai.prompt');await h.type_('RESTORED_ROOT 继续当前连接');await click('ai.send');await h.waitFor(async()=>text(await h.query('ai.panel')).includes('RESTORED_ROOT_REPLY')||null,20000);await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,15000);
 assert.equal(requests.length,1);assert(requests[0].messages.some((m:any)=>m.role==='assistant'&&m.content.includes('PARENT_SAVED_ANSWER')));await capture('03-new-parent-worker');
 const current=await journal(),bound=current.filter(row=>row.event?.kind==='bind'&&row.event.conversation===parent);assert.equal(bound.length,1);assert.notEqual(bound[0].event.agent,oldParentAgent);assert.equal(current.filter(row=>row.event?.kind==='child_bind').length,1);assert.deepEqual(current.find(row=>row.event?.kind==='child_create').event.child_info,childInfo);await writeFile(join(out,'journal.json'),JSON.stringify(current,null,2));report.checks.push('Explicit parent restore keeps ConversationId and creates a new attached AgentId; only explicit send starts one new root request; child identity, creation parent and saved context remain data with no implicit rebind');
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await capture('failure').catch(()=>{});await h.query('ai.panel').then(tree=>writeFile(join(out,'failure-tree.json'),JSON.stringify(tree,null,2))).catch(()=>{})}
finally{
 try{if(alive()){report.quit_response=await h.request('POST','/zerowork/windows',{action:'quit'});const start=performance.now();while(alive()&&performance.now()-start<15000){for(const id of ['groups.close.accept','local.close.accept','session.close.accept']){if(!alive())break;try{const q=await h.query(id);if(!Array.isArray(q))break;if(q.some(shown))await h.clickTestId(id)}catch{break}}await Promise.race([ended,h.sleep(80)])}}}catch(error){report.quit_error=String(error)}
 if(alive()){report.forced=true;app.kill('SIGTERM');await ended}report.exit_code=app.exitCode;report.signal=app.signalCode;if(report.forced||app.exitCode!==0){report.status='failed';process.exitCode=1}
 server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();const logs=await readFile(join(out,'app.log'),'utf8');if(/leaked \[addr:|panic:|double free/i.test(logs)){report.status='failed';process.exitCode=1}await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}));
}
