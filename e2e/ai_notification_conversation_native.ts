/** Exact original-dialog routing through real native AI and notification UI. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,stat,open,realpath,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'/tmp/zw-ai-reminder-conversation');await mkdir(out,{recursive:true});
const binary=resolve(process.env.ZW_AI_TEST_BINARY??'zig-out/bin/zerowork');
const iso=await realpath(await mkdtemp('/tmp/zw-ai-reminder-')),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
let pending:any=null,requests=0;
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const server=createServer(async(req,res)=>{
 if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'reminder-fixture'}]}));return;}
 let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);requests++;
 res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
 const results=body.messages.filter((m:any)=>m.role==='tool');
 if(results.some((m:any)=>m.tool_call_id==='reminder-approval')){assert(results.some((m:any)=>m.tool_call_id==='reminder-approval'&&m.content.includes('ToolApprovalRejected')));res.end(frame({content:'已取消该操作，未执行命令。'})+'data: [DONE]\n\n');return;}
 const system=body.messages.find((m:any)=>m.role==='system')?.content??'';
 assert(!/assistant_session_id=|provider=.*session_id=/.test(system));
 const contextResult=results.find((m:any)=>m.tool_call_id==='reminder-context');
 if(!contextResult){assert(body.tools.some((t:any)=>t.function.name==='host__get_ucurrent_ucontext'));res.end(frame({tool_calls:[{index:0,id:'reminder-context',type:'function',function:{name:'host__get_ucurrent_ucontext',arguments:'{}'}}]})+'data: [DONE]\n\n');return;}
 const state=JSON.parse(JSON.parse(contextResult.content).content[0].text);
 const id=Number(state.current_binding.session);assert(id>0);
 pending={res,id};
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ai]\ndefault_provider="reminder-fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="reminder-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="reminder-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w'),app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const capture=async(name:string)=>{await h.sleep(200);assert((await h.screenshot(join(out,name+'.png'))).ok);};
const report:any={status:'running',binary,checks:[],limits:['Local SSE fixture, actual native Local session and approval/notification controllers; no remote model or SSH used in this routing test.']};
try{
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.maximize');
 await click('ai.prompt');await h.type_('原对话：等待确认后再执行本地操作。');await click('ai.send');await h.waitFor(async()=>pending||null,10000);
 await click('ai.session.new');await visible('ai.prompt');await click('ai.prompt');await h.type_('另一段对话的独立草稿');assert.equal((await h.inputState('ai.prompt')).buffer,'另一段对话的独立草稿');
 const call=pending;pending=null;
 call.res.end(frame({tool_calls:[{index:0,id:'reminder-approval',type:'function',function:{name:'run_command',arguments:JSON.stringify({session_ids:[call.id],command:`mkdir '${join(iso,'should-not-be-created')}'`})}}]})+'data: [DONE]\n\n');
 await visible('notifications.unread');await click('toolbar.notifications');await visible('notifications.history.action');await capture('01-background-dialog-reminder');
 await click('notifications.history.action');await visible('ai.approval');await absent('notifications.history');await capture('02-exact-origin-approval');
 assert.notEqual((await h.inputState('ai.prompt')).buffer,'另一段对话的独立草稿');
 await click('ai.approval.reject');await absent('ai.approval');await visible('ai.turn.complete');
 const queryTitle=await h.waitFor(async()=>(await h.query('ai.tool.result.title')).find((n:any)=>shown(n)&&n.text==='读取对话状态')??null,10000);
 await h.clickAt(queryTitle.rect.x+20,queryTitle.rect.y+8);
 await h.waitFor(async()=>(await h.query('ai.tool.result.stdout')).some((n:any)=>shown(n)&&String(n.text).includes('conversation_id'))||null,10000);
 await capture('03-query-and-rejected-results');
 await h.clickAt(queryTitle.rect.x+20,queryTitle.rect.y+8);
 await click('ai.sessions');await visible('ai.session.jump.2');await h.sleep(250);await click('ai.session.jump.2');await absent('ai.sessions.menu');
 assert.equal((await h.inputState('ai.prompt')).buffer,'另一段对话的独立草稿');
 assert.equal(requests,3);await assert.rejects(stat(join(iso,'should-not-be-created')),{code:'ENOENT'});
 report.checks.push('Background approval reminder selects the original conversation, not the currently selected dialog','The other conversation retains its exact draft after switching back','Rejected approval returns the correlated tool result; no command is executed');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;await capture('failure').catch(()=>{});await writeFile(join(out,'failure-tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{});}
finally{pending?.res.destroy();if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(iso,{recursive:true,force:true});}
console.log(JSON.stringify(report));
