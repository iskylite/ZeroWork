/** Cancel unsent input in the native composer while a local model fixture holds the first request. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,open} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'zig-out');
const isolated=await mkdtemp('/private/tmp/zw-pending-cancel-native-');
const out=resolve(process.argv[2]??isolated);
await mkdir(out,{recursive:true});
const data=join(isolated,'data'),rpc=join(isolated,'rpc'),zdot=join(isolated,'zdot');
for(const dir of [data,rpc,zdot])await mkdir(dir);
await writeFile(join(zdot,'.zshrc'),"PS1='queue-fixture%# '\n");
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
let requests=0;
let receivedCancelledInput=false;
const server=createServer(async(req,res)=>{
 if(req.method!=='POST'){res.end('{"data":[{"id":"cancel-fixture"}]}');return}
 let raw='';for await(const bytes of req)raw+=bytes;
 const body=JSON.parse(raw);
 const content=JSON.stringify(body.messages);
 if(/NORMAL_QUEUE|PAUSED_QUEUE|ACCEPTED_STEER/.test(content))receivedCancelledInput=true;
 res.writeHead(200,{'content-type':'text/event-stream'});
 const frame=(content:string)=>'data: '+JSON.stringify({choices:[{index:0,delta:{content}}]})+'\n\n';
 if(!content.includes('ACTIVE_REQUEST')){res.end(frame('取消排队测试')+'data: [DONE]\n\n');return}
 requests++;
 res.write(frame('等待当前回合…'));
});
await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
await writeFile(join(data,'config.toml'),`[meta]
config_revision=1
[ai]
default_provider="cancel-fixture"
permission_mode="confirm"
follow_up_mode="queue"
[[ai.providers]]
id="cancel-fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="cancel-fixture"
context_window=200000
default=true
`);
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>{assert.equal(app.exitCode,null);return(await h.query(id)).find(shown)??null},12000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,12000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const send=async(text:string,steer=false)=>{await click('ai.prompt');await h.type_(text);if(steer)await h.key('return',{cmd:true,shift:true});else await click('ai.send')};
const check=async()=>{
 await h.waitForServerReady(40000);await h.resizeWindow(1400,900);
 await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');
 await send('ACTIVE_REQUEST');await h.waitFor(async()=>requests===1||null,12000);
 await send('NORMAL_QUEUE');await visible('ai.pending.card.0');await h.mouseMove(5,5);await visible('ai.pending.remove.0');
 await click('ai.pending.remove.0');await absent('ai.pending.card.0');
 await send('PAUSED_QUEUE');await visible('ai.pending.card.0');
 await send('ACCEPTED_STEER',true);await visible('ai.followup.pending');
 await click('ai.stop');await visible('ai.pending.card.1');await visible('ai.pending.cancel_message.1');
 await h.mouseMove(5,5);assert((await h.screenshot(join(out,'paused-cancel.png'))).ok);
 await click('ai.pending.cancel_message.1');await absent('ai.pending.card.1');
 await visible('ai.pending.card.0');await h.mouseMove(5,5);await visible('ai.pending.remove.0');
 await click('ai.pending.remove.0');await absent('ai.pending.card.0');
 const journal=await readFile(join(data,'ai-sessions.jsonl'),'utf8');
 const rows=journal.trim().split('\n').map(line=>JSON.parse(line)).filter(row=>row.receipt?.delivery==='cancelled');
 assert.equal(rows.length,3);assert.equal(rows.filter(row=>row.receipt.route==='steer').length,1);
 assert.equal(requests,1,'the active request was sent exactly once');
 assert(!receivedCancelledInput,'queued and accepted messages were never sent to provider');
};
let failure:string|null=null;
try{await check()}catch(e){failure=String(e);await h.screenshot(join(out,'failure.png')).catch(()=>{});process.exitCode=1}
finally{
 if(app.exitCode===null)app.kill('SIGTERM');await ended;server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));await log.close();
 const report={status:failure?'failed':'passed',failure,requests,out};await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report))
}
