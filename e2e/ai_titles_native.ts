/** One-time conversation titles against an owned local SSE fixture. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'zig-out');
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-ai-titles');await mkdir(out,{recursive:true});
const isolated=await realpath(await mkdtemp('/tmp/zw-ai-titles-'));
const data=join(isolated,'data'),rpc=join(isolated,'rpc');await mkdir(data);await mkdir(rpc);
const questions={first:'帮我排查 nginx 为什么启动失败',second:'分析磁盘占用，不要删除文件',failed:'分析 Redis 超时问题',deleted:'排查待删除会话的问题'};
const titles={first:'排查 nginx 启动失败',second:'分析磁盘占用'};
const held=new Map<string,any>();const requests:any[]=[];
const frame=(content:string)=>'data: '+JSON.stringify({choices:[{index:0,delta:{content}}]})+'\n\ndata: [DONE]\n\n';
const server=createServer(async(req,res)=>{
 if(req.method!=='POST'){res.end(JSON.stringify({data:[{id:'title-fixture'}]}));return;}
 let bytes='';for await(const chunk of req)bytes+=chunk;const body=JSON.parse(bytes);
 const system=body.messages.find((m:any)=>m.role==='system')?.content??'';
 const title=system.startsWith('将用户的问题概括为简短的会话标题');
 requests.push({title,body});
 if(title){
  assert.equal(body.tools,undefined);assert.equal(body.messages.length,2);
  const question=JSON.parse(body.messages[1].content).user_question;
  if(question===questions.failed){res.writeHead(503);res.end('unavailable');return;}
  res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
  if(question===questions.first||question===questions.deleted){held.set(question,res);return;}
  assert.equal(question,questions.second);res.end(frame(titles.second));return;
 }
 res.writeHead(200,{'content-type':'text/event-stream'});res.end(frame('已收到问题，仅提供分析。'));
});
await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="title-fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="title-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="title-fixture"\ncontext_window=32768\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>[n?.text??'',...(n?.children??[]).map(text)].join('');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const send=async(value:string)=>{await click('ai.prompt');await h.type_(value);await click('ai.send');await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,15000);await visible('ai.turn.complete')};
const row=async(id:number,value:string)=>h.waitFor(async()=>{const node=(await h.query(`ai.session.row.${id}`)).find(shown);return node&&text(node).includes(value)?node:null},10000);
const titleCount=()=>requests.filter(r=>r.title).length;
const report:any={status:'running',checks:[],isolated};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');
 await send(questions.first);await h.waitFor(async()=>held.has(questions.first)||null,5000);
 await click('ai.sessions');await row(1,questions.first);await click('ai.sessions.close');
 report.checks.push('The main reply completes while title generation is held; the list displays the first-question fallback');
 await click('ai.session.new');await send(questions.second);await click('ai.sessions');await row(2,titles.second);
 held.get(questions.first).end(frame(titles.first));await row(1,titles.first);await row(2,titles.second);
 assert((await h.screenshot(join(out,'01-generated-titles.png'))).ok);
 report.checks.push('A late title updates its original conversation while another conversation is selected and the list is open');
 await click('ai.sessions.close');await send('继续');assert.equal(titleCount(),2);
 await click('ai.sessions');await row(2,titles.second);await click('ai.session.jump.1');await send('好的');assert.equal(titleCount(),2);
 await click('ai.sessions');await row(1,titles.first);await click('ai.sessions.close');await click('ai.session.new');
 const recent=await h.query('ai.empty.recent.title');assert(recent.some((n:any)=>n.text===titles.first));assert(recent.some((n:any)=>n.text===titles.second));
 assert((await h.screenshot(join(out,'02-welcome-titles.png'))).ok);
 report.checks.push('Followups trigger no extra title requests; titles survive switching and match the welcome recent-conversation links');
 await send(questions.failed);await h.waitFor(async()=>titleCount()===3||null,5000);await h.sleep(300);await send('继续');assert.equal(titleCount(),3);
 await click('ai.sessions');await row(3,questions.failed);await click('ai.sessions.close');
 report.checks.push('A failed title request retains the original fallback and is not retried by a followup');
 await click('ai.session.new');await send(questions.deleted);await h.waitFor(async()=>held.has(questions.deleted)||null,5000);
 await click('ai.sessions');await click('ai.session.delete.4');await h.waitFor(async()=>!(await h.query('ai.session.row.4')).some(shown)||null,5000);
 held.get(questions.deleted).end(frame('不得出现的过期标题'));await h.sleep(300);
 assert(!(await h.query('ai.session.row.4')).some(shown));assert.equal(titleCount(),4);
 report.checks.push('Deleting a conversation discards its pending title without recreating a row or overwriting another conversation');
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);await h.screenshot(join(out,'failure.png')).catch(()=>{});process.exitCode=1;}
finally{
 for(const res of held.values())res.end();
 app.kill('SIGTERM');if(app.exitCode===null&&app.signalCode===null)await new Promise(r=>app.once('close',r));
 server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));await log.close();
 report.titleRequests=titleCount();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
