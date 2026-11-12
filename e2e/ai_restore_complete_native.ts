/** Full display-history recovery and post-turn tool-catalog lifetime regression.
 * Owned Local terminals and loopback model only; no external credentials.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-conversation-restore-test');
const out=resolve(process.argv[2]??'/tmp/zw-conversation-restore-results');await mkdir(out,{recursive:true});
const isolated=await realpath(await mkdtemp('/tmp/zw-restore-'));
const data=join(isolated,'data'),rpc=join(isolated,'rpc'),zdot=join(isolated,'zdot');for(const p of [data,rpc,zdot])await mkdir(p);
await writeFile(join(zdot,'.zshrc'),"PS1='restore-test%# '\n");
const event=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
let calls=0;const requests:any[]=[];
const server=createServer(async(req,res)=>{
 if(req.method!=='POST'){res.end(JSON.stringify({data:[{id:'restore-fixture',context_window:200000,reasoning:false,vision:false}]}));return}
 let raw='';for await(const c of req)raw+=c;const body=JSON.parse(raw);requests.push(body);res.writeHead(200,{'content-type':'text/event-stream'});
 if(!body.tools?.length){res.end(event({content:'终端恢复检查'})+'data: [DONE]\n\n');return}
 const user=body.messages.findLastIndex((m:any)=>m.role==='user'),question=String(body.messages[user].content);
 const tail=body.messages.slice(user+1);
 if(!tail.some((m:any)=>m.role==='tool')){
  const tool=body.tools.find((t:any)=>t.function.name==='host__read_uterminal');assert(tool,'terminal reader advertised');
  const reference=tool.function.parameters.properties.session_ref.enum[0];assert(reference);
  res.write(event({reasoning_content:'先读取当前终端，再回答这个问题。'}));
  res.end(event({tool_calls:[{index:0,id:'read-'+(++calls),type:'function',function:{name:tool.function.name,arguments:JSON.stringify({session_ref:reference,max_lines:5})}}]})+'data: '+JSON.stringify({choices:[],usage:{prompt_tokens:1234,completion_tokens:56}})+'\n\ndata: [DONE]\n\n');return;
 }
 res.end(event({content:'已读取终端，回答：'+question+' ✅'})+'data: '+JSON.stringify({choices:[],usage:{prompt_tokens:1234,completion_tokens:56}})+'\n\ndata: [DONE]\n\n');
});await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="restore-fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="restore-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="restore-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts'));const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join(' ');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,20000);
const report:any={status:'running',isolated,checks:[]};
const click=async(id:string)=>{report.last_action=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
async function tokenValues() {
 const values: string[] = [];
 for (const trigger of (await h.query('ai.turn.tokens')).filter(shown)) {
  const {x, y, w, h: height} = trigger.rect;
  assert((await h.clickAt(x + w / 2, y + height / 2)).ok);
  values.push(text(await visible('ai.turn.usage.total')));
  await h.key('escape');
  await h.waitFor(async () => !(await h.query('ai.turn.usage.details')).some(shown) || null, 5000);
 }
 return values;
}
async function stable(count:number){await h.waitFor(async()=>{const n=(await h.query('ai.turn.complete')).filter(shown);return n.length===count&&n||null},20000);await h.sleep(400);assert(!text(await h.tree()).includes('InvalidUtf8'),'no freed-catalog UTF8 error after completion');}
async function send(value:string,count:number){await click('ai.prompt');await h.type_(value);await click('ai.send');await stable(count)}
async function confirmIfNeeded(){await h.sleep(150);if((await h.query('ai.session.close.accept')).some(shown))await click('ai.session.close.accept')}
async function full(count: number, contains: string[]) {
 await stable(count);
 const users = (await h.query('ai.message.user.text')).filter(shown);
 assert.equal(users.length, count, 'visible user messages');
 for (const value of contains) assert(text(users).includes(value));
 assert.equal((await h.query('ai.turn.tokens')).filter(shown).length, count, 'visible usage details actions');
 assert.equal((await h.query('ai.turn.process.toggle')).filter(shown).length, count, 'visible process disclosure actions');
}
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1280,960);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');
 await send('FIRST 检查当前终端 🧑‍💻',1);await full(1,['FIRST']);const originalTokens=(await tokenValues())[0];assert(originalTokens.includes('2.6K Token'));report.checks.push('A fresh conversation completes with user, reasoning/tool group and usage; idle updates do not read freed tools');
 await click('ai.collapse');await click('toolbar.new_session');await click('session.menu.local');await visible('terminal.surface');await click('toolbar.ai');await send('NEW_CONNECTION 新连接问答',1);report.checks.push('A second connection and new AI conversation also complete without InvalidUtf8');
 await click('ai.sessions');await click('ai.session.copy_use.1');await confirmIfNeeded();await full(1,['FIRST']);assert.equal((await tokenValues())[0],originalTokens);
 assert(!text(await h.query('ai.message.user.text')).includes('NEW_CONNECTION'));
 await send('COPY_FOLLOWUP 副本继续问答',2);await full(2,['FIRST','COPY_FOLLOWUP']);const copiedTokens=await tokenValues();assert((await h.screenshot(join(out,'01-copy-complete.png'))).ok);
 report.checks.push('Copy-and-use retains original question, reasoning/tool timeline, timing and tokens; next Chinese/emoji turn succeeds');
 await click('ai.session.new');await confirmIfNeeded();await click('ai.sessions');await click('ai.session.restore.3');await confirmIfNeeded();await full(2,['FIRST','COPY_FOLLOWUP']);assert.deepEqual(await tokenValues(),copiedTokens);
 await send('RESTORED_FOLLOWUP 恢复后继续 ✅',3);await full(3,['FIRST','COPY_FOLLOWUP','RESTORED_FOLLOWUP']);assert((await h.screenshot(join(out,'02-restored-complete.png'))).ok);
 report.checks.push('Restore retains both complete turns and the next turn succeeds without InvalidUtf8 or tool replay');
 assert.equal(calls,4,'exactly one read per submitted task; restoring/copying never replays tools');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await h.screenshot(join(out,'failure.png')).catch(()=>{});await writeFile(join(out,'failure-tree.json'),JSON.stringify(await h.tree().catch(()=>null),null,2));process.exitCode=1;}
finally{app.kill('SIGTERM');if(app.exitCode===null&&app.signalCode===null)await new Promise(r=>app.once('close',r));server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));await log.close();report.toolCalls=calls;report.requests=requests.length;await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
