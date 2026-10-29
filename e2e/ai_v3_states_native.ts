/** Existing production AI states through an isolated local SSE provider and native Harness. */
import {fixtureSessionIds} from './ai_fixture_discovery.ts';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath,access} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-v3-ai-prefix';
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-v3-ai-states');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-ai-v3-states-')),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
const tailOnly=process.env.ZW_AI_ONLY_TAIL==='1';
const verifyToast=process.env.ZW_AI_VERIFY_TOAST_AVOIDANCE==='1';
let mode='answer',requests:any[]=[],held:any=null;
const server=createServer(async(req,res)=>{
 if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'v3-state-model',context_window:200000}]}));return;}
 let bytes='';for await(const c of req)bytes+=c;const body=JSON.parse(bytes);requests.push({mode,messages:body.messages});
 if(mode==='failure'){res.writeHead(401,{'content-type':'application/json'});res.end(JSON.stringify({error:{message:'V3 fixture unauthorized'}}));return;}
 res.writeHead(200,{'content-type':'text/event-stream'});
 const data=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
 if(mode==='waiting'){res.write(data({content:'正在分析测试上下文。'}));held=res;return;}
 if((mode==='approval'||mode==='accepted')&&!body.messages.some((m:any)=>m.role==='tool'&&m.tool_call_id?.startsWith('v3-safe-'))){
  const ids=fixtureSessionIds(body,res);if(!ids)return;
  res.end(data({tool_calls:[{index:0,id:'v3-safe-'+mode,type:'function',function:{name:'run_command',arguments:JSON.stringify({session_ids:[ids[0]],command:mode==='accepted'?'printf V3_APPROVAL_ACCEPTED':`printf V3_MUST_NOT_EXECUTE > '${join(iso,'must-not-execute')}'`})}}]})+'data: [DONE]\n\n');return;
 }
 res.end(data({content:mode==='approval'?'该调用已拒绝。':mode==='accepted'?'工具调用已完成。':'已完成只读分析。\n\n保留原始上下文。'})+'data: [DONE]\n\n');
});
await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="v3-states"\npermission_mode="confirm"\n[[ai.providers]]\nid="v3-states"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="v3-state-model"\ncontext_window=200000\ndefault=true\nvision=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1'},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join('\n');
const visible=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const absent=async(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,15000);
const click=async(id:string)=>{report.lastAction=id;const node=await visible(id);assert((await h.clickAt(node.rect.x+node.rect.w/2,node.rect.y+node.rect.h/2)).ok)};
const cap=async(name:string)=>{await h.sleep(160);assert((await h.screenshot(join(out,name+'.png'))).ok);const ids=['ai.panel','ai.recovery','ai.approval','ai.image','ai.image.preview.panel','ai.tool.results'];await writeFile(join(out,name+'.json'),JSON.stringify(Object.fromEntries(await Promise.all(ids.map(async id=>[id,await h.query(id)]))),null,2));};
const send=async(value:string)=>{await click('ai.prompt');await h.key('a',{cmd:true});await h.type_(value);assert.equal((await h.inputState('ai.prompt')).buffer,value);const before=requests.length;for(let attempt=0;attempt<20;attempt++){await click('ai.send');await h.sleep(100);const updating=text((await h.query('ai.panel')).find(shown)).includes('终端正在更新，请稍后重试');if(!updating)return;assert.equal(requests.length,before,'Busy preflight must not send a provider request');assert.equal((await h.inputState('ai.prompt')).buffer,value,'Busy preflight must preserve the draft');await h.sleep(100)}throw new Error('Terminal context remained busy before provider dispatch')};
const dismissNotices=async()=>{for(let i=0;i<3;i++){const id='notifications.dismiss.'+i;if((await h.query(id)).some(shown)){const n=await visible(id);await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)}}};
const fresh=async()=>{await dismissNotices();await click('ai.session.new');await h.sleep(220)};
const report:any={status:'running',checks:[],isolatedData:iso,provider:'own local SSE fixture; no external service',toolExecuted:false,pixelReview:'Screenshots require manual overflow and clipping review'};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(860,480);await click('workspace.empty.local');await visible('terminal.surface');await click('ai.strip');
 if(!tailOnly){
 mode='waiting';await send('观察等待与停止状态');await visible('ai.stop');await h.waitFor(async()=>text(await visible('ai.panel')).includes('正在分析测试上下文')||null,15000);await cap('01-waiting');await click('ai.stop');await absent('ai.stop');if(held){held.end();held=null;}await cap('02-stopped');report.checks.push('Local HTTP partial reply shows Stop; explicit Stop terminates generation');
 await fresh();mode='answer';await send('普通答复与用户问题');await absent('ai.stop');await h.waitFor(async()=>text(await visible('ai.panel')).includes('已完成只读分析')||null,15000);await cap('03-answer');report.checks.push('Real native user message and Markdown response painted');
 await fresh();mode='failure';await send('触发请求失败');await visible('ai.recovery');assert(text(await visible('ai.recovery.reason')).includes('HTTP 401'));assert(text(await visible('ai.recovery.reason')).includes('V3 fixture unauthorized'));await cap('04-error');await click('ai.recovery.edit');await h.waitFor(async()=>(await h.inputState('ai.prompt')).buffer.includes('触发请求失败')||null,5000);report.checks.push('HTTP 401 failure shows existing recovery; Edit restores original question');
 await fresh();mode='approval';await send('请求只展示待审批工具，不执行');await visible('ai.approval');assert(text(await visible('ai.approval.target')).includes('本机'));assert(text(await visible('ai.approval.command')).startsWith('printf V3_MUST_NOT_EXECUTE'));await cap('05-approval');const panel=(await visible('ai.panel')).rect,approval=(await visible('ai.approval')).rect,prompt=(await visible('ai.prompt')).rect;assert(approval.y+approval.h<=prompt.y+.5);assert(prompt.y+prompt.h<=panel.y+panel.h);await click('ai.approval.reject');await absent('ai.approval');await absent('ai.stop');await cap('06-rejected');let executed=false;try{await access(join(iso,'must-not-execute'));executed=true}catch{}assert(!executed);report.checks.push('Existing tool approval fits compact editor; Reject runs no command');
 if(verifyToast)await h.resizeWindow(1440,900);await fresh();mode='accepted';await send('批准只运行测试 printf，核验原始工具结果');await visible('ai.approval');await click('ai.approval.accept');await absent('ai.approval');await absent('ai.stop');await h.waitFor(async()=>requests.some((r:any)=>r.mode==='accepted'&&r.messages.some((m:any)=>m.role==='tool'&&m.content.includes('V3_APPROVAL_ACCEPTED')))||null,15000);await cap('06b-accepted-result');assert(!text((await h.query('notifications.presenter'))).includes('AnswerNotFinal'));report.toolExecuted=true;report.checks.push('Explicit approval executes only safe printf through the real Local service and returns its actual stdout to provider');
 if(verifyToast){
  const notices=await h.query('notifications.presenter'),dismissIds=['notifications.dismiss.0','notifications.dismiss.1','notifications.dismiss.2'];assert((await Promise.all(dismissIds.map(id=>h.query(id)))).flat().some(shown),'a completion toast must still be visible');await writeFile(join(out,'06c-toast-click-evidence.json'),JSON.stringify({panel:await h.query('ai.panel'),notifications:notices},null,2));assert((await h.clickTestId('ai.session.new')).ok,'visible completion toast must not intercept New');await h.waitFor(async()=>(await h.inputState('ai.prompt')).buffer===''||null,5000);assert((await h.clickTestId('ai.sessions')).ok,'visible completion toast must not intercept Sessions');await visible('ai.sessions.menu');await cap('06c-toast-session-actions');await click('ai.sessions.close');report.toastAvoidanceChecked=true;report.toastViewport={width:1440,height:900};report.checks.push('Completion toast remains visible while New and Sessions receive immediate native hits');
 }

 if(verifyToast)await h.resizeWindow(860,480);await fresh();await click('ai.composer.attachment');await visible('ai.attachment.menu');await cap('07-attachment-menu');await h.key('escape');await dismissNotices();const input=await visible('ai.prompt'),before=requests.length;const image=resolve('assets/macos/AppIcon.png');await h.dragAt(input.rect.x+20,input.rect.y+20,0,image);await h.dragAt(input.rect.x+20,input.rect.y+20,3,image);await visible('ai.image');await h.sleep(350);await cap('08-image-attached');await click('ai.image.preview');await visible('ai.image.preview.panel');await cap('09-image-preview');await click('ai.image.preview.close');await click('ai.image.remove');await absent('ai.image');assert.equal(requests.length,before);report.checks.push('Native image file drop, attachment menu, preview and removal work without dispatching a request');
 }
 await fresh();mode='answer';await send('回看长对话滚动\n'+Array.from({length:35},(_,i)=>'终端诊断上下文行 '+(i+1)+'：保留原始问题与分析记录。').join('\n'));await absent('ai.stop');await h.waitFor(async()=>{const r=(await h.query('ai.response')).find(shown),p=(await h.query('ai.panel')).find(shown),input=(await h.query('ai.prompt')).find(shown);return r&&p&&input&&r.rect.y>=p.rect.y+49-.5&&r.rect.y+r.rect.h<=input.rect.y-12+.5?true:null},15000);await cap('10-long-conversation-tail');report.checks.push('Long question creates scrolling; latest reply geometry fits body, with overflow pixels requiring manual review');
 const logs=await readFile(join(out,'app.log'),'utf8');const starts=logs.split('\n').filter(line=>line.includes('"event":"exec_started"'));assert.equal(starts.length,tailOnly?0:1);if(!tailOnly)assert(starts[0].includes('v3-safe-accepted'));report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await cap('failure').catch(()=>{});process.exitCode=1;}
finally{if(held)held.end();server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));app.kill('SIGTERM');if(app.exitCode===null&&app.signalCode===null)await new Promise(r=>app.once('close',r));await log.close();report.requests=requests;await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
console.log(JSON.stringify(report));
