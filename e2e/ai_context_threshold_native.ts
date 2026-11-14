/** Own native application + loopback HTTP model. Exercises actual host wiring;
 * generated fixture summaries establish transport/state semantics, not LLM quality. */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, open, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { query, clickTestId, key, type_, inputState, screenshot, sleep, waitFor, waitForServerReady, resizeWindow } from '../zig-out/share/zenit/harness/client.ts';
const options: Record<string,string> = {};
for (let i=2; i<process.argv.length; i+=2) options[process.argv[i]] = process.argv[i+1];
assert(options['--binary'] && options['--out']);
const output=resolve(options['--out']), source=resolve(options['--binary']);
await mkdir(output,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-compaction-native-'), data=join(iso,'data'), rpc=join(iso,'rpc'), frozen=join(output,'frozen');
await Promise.all([mkdir(data),mkdir(rpc),mkdir(frozen,{recursive:true})]);
await copyFile(source,join(frozen,'zerowork')); await copyFile(join(dirname(source),'zw_ipc.so'),join(frozen,'zw_ipc.so'));
const contextWindow=32000;
let mode='success', summaryCount=0, ordinaryCount=0;
let releaseFailure:()=>void=()=>{};
const failCompaction=new Promise<void>(resolve=>{releaseFailure=resolve;});
const requests:any[]=[];
const server=createServer(async(req,res)=>{
  if(req.method==='GET') {res.setHeader('Content-Type','application/json');res.end(JSON.stringify({data:[{id:'compaction-native',context_window:contextWindow,reasoning:false,vision:false}]}));return;}
  let raw='';for await(const chunk of req)raw+=chunk;
  const body=JSON.parse(raw), summary=body.messages.some((m:any)=>m.role==='system' && m.content.includes('Create concise conversation memory'));
  const record:any={summary,mode,body};requests.push(record);
  let text:string;
  if(summary){
    summaryCount++;assert(!body.tools?.length);

    assert(!JSON.stringify(body.messages).includes('RECENT_NATIVE_SECOND'));
    if(mode==='failure'){await failCompaction;res.writeHead(400);res.end('summary failed');record.completed=true;return;}
    await sleep(mode==='cancel'?1800:550);
    text='MEMORY_NATIVE_BACKUP_TESTS_PASSED. Goal backup; constraint no deployment; pending review.';
  } else {
    ordinaryCount++;text='VISIBLE_NATIVE_ANSWER_'+ordinaryCount;
    if(ordinaryCount===1)text+=' '+ 'LARGE_OBSERVATION '.repeat(mode==='failure'?6175:6500);
  }
  res.writeHead(200,{'Content-Type':'text/event-stream'});
  res.end('data: '+JSON.stringify({choices:[{delta:{content:text}}]})+'\n\ndata: [DONE]\n\n');record.completed=true;
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[ai]\ndefault_provider = "local-summary"\npermission_mode = "confirm"\n[[ai.providers]]\nid = "local-summary"\nkind = "openai_compat"\nendpoint = "http://127.0.0.1:${port}/v1/chat/completions"\nenabled = true\n[[ai.providers.models]]\nname = "compaction-native"\ncontext_window = ${contextWindow}\ndefault = true\nreasoning = false\nvision = false\nefforts = []\n`);
const env={...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'};
for(const name of ['ZEROWORK_AI_MOCK','ZEROWORK_AI_ENDPOINT','ZEROWORK_AI_MODEL','ZEROWORK_AI_PROVIDER'])delete env[name];
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(output,'app.log'),'w');
const app=spawn(join(frozen,'zerowork'),[],{cwd:process.cwd(),env,stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const report:any={status:'running',isolated:iso,source,binary_sha256:createHash('sha256').update(await readFile(join(frozen,'zerowork'))).digest('hex'),stages:[],limits:['Synthetic Harness input in own background Metal window; no physical input claim','Loopback deterministic model fixture verifies real HTTP and native host wiring, not external LLM summary quality']};
function shown(n:any):boolean{return n?.rect&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;}
function text(n:any):string{return (n.text??'')+(n.children??[]).map(text).join('');}
async function visible(id:string){return waitFor(async()=>(await query(id)).find(shown)??null,20000);}
async function click(id:string){await visible(id);assert((await clickTestId(id)).ok,id);}
async function cap(name:string){const path=join(output,name+'.png');assert((await screenshot(path)).ok);const usage=await query('ai.usage.menu');await writeFile(join(output,name+'.usage.json'),JSON.stringify(usage,null,2));assert(!JSON.stringify(usage).includes('清空上下文'));assert(!JSON.stringify(usage).includes('clear_context'));report.stages.push({name,screenshot:path,usage_rect:usage.find(shown)?.rect});}
async function status(fragment:string){return waitFor(async()=>{const n=(await query('ai.usage.compaction.status')).find(shown);return n&&text(n).includes(fragment)?n:null;},20000);}
async function send(prompt:string,answer:number){await click('ai.prompt');assert((await key('a',{cmd:true})).ok);assert((await type_(prompt)).ok);await click('ai.send');await waitFor(async()=>{const responses=await query('ai.response');return responses.some(n=>text(n).includes('VISIBLE_NATIVE_ANSWER_'+answer))&&!(await query('ai.stop')).some(shown)||null;},20000);}
async function history(){return (await query('ai.message.user.bubble')).map(text);}
try{
  await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
  await resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await visible('ai.prompt');
  if(options['--failure']==='true') {
    mode='failure';
    await send('OLD_NATIVE_MARKER inspect the terminal',1);
    const original=('ORIGINAL_FAILED_INPUT '+ 'PREFLIGHT_DATA '.repeat(200)).trim();
    await click('ai.prompt');assert((await type_(original)).ok);await click('ai.send');
    await waitFor(async()=>summaryCount>0||null,20000);
    await click('ai.prompt');assert((await type_('NEW_DRAFT_DURING_COMPACTION')).ok);
    releaseFailure();
    await waitFor(async()=>requests.filter(r=>r.summary).every(r=>r.completed)&&!(await query('ai.stop')).some(shown)||null,20000);
    assert((await inputState('ai.prompt')).buffer.includes('NEW_DRAFT_DURING_COMPACTION'));
    assert.equal(ordinaryCount,1);
    assert((await history()).some(x=>x.includes('OLD_NATIVE_MARKER')), 'prior visible prompt preserved');
    const count=summaryCount;await sleep(2200);assert.equal(summaryCount,count,'failure must not restart automatic compaction');
    await click('ai.composer.usage');await visible('ai.usage.compaction.start');await cap('01-failed-compaction');
    await key('Escape');mode='success';await click('ai.prompt');assert((await key('a',{cmd:true})).ok);assert((await type_(original)).ok);await click('ai.send');
    await waitFor(async()=>summaryCount>count||null,20000);
    await waitFor(async()=>requests.filter(r=>r.summary).every(r=>r.completed)||null,20000);
    await sleep(800);
    await waitFor(async()=>(await query('ai.response')).some(n=>text(n).includes('VISIBLE_NATIVE_ANSWER_2'))||null,20000);
    report.status='passed';report.prior_prompt_preserved=true;report.concurrent_draft_preserved=true;report.manual_retry_available=true;
  } else {
  await send('OLD_NATIVE_MARKER inspect the terminal',1);
  await waitFor(async()=>summaryCount>0||null,20000);
  await waitFor(async()=>{const r=requests.filter(r=>r.summary);return r.length>0&&r.every(r=>r.completed)||null;},20000);
  await sleep(500);
  await click('ai.composer.usage');await cap('01-automatic-compaction');
  const summaryText=text((await query('ai.usage.summary')).find(shown));
  assert(!summaryText.includes('105%'));
  await key('Escape');await send('NEXT_NATIVE_REQUEST',2);
  const next=requests.filter(r=>!r.summary).at(-1).body;
  const wire=JSON.stringify(next.messages);
  assert(wire.includes('MEMORY_NATIVE_BACKUP_TESTS_PASSED'));
  assert(next.messages.some((m:any)=>m.role==='user'&&m.content==='OLD_NATIVE_MARKER inspect the terminal'));
  assert(!wire.includes('LARGE_OBSERVATION'));
  await click('ai.composer.usage');await cap('02-short-turn-manual-ready');
  const before=summaryCount;await click('ai.usage.compaction.start');await waitFor(async()=>summaryCount>before||null,20000);await sleep(800);
  await cap('03-short-turn-manual-completed');
  report.status='passed';report.automatic_compaction=true;report.next_request_uses_summary=true;report.short_turn_manual_compaction=true;
  }
}catch(e){report.status='failed';report.error=e instanceof Error?e.stack:String(e);try{await cap('failure');}catch{}}
finally{
  releaseFailure();report.requests=requests;report.finished_at=new Date().toISOString();if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await Promise.race([ended,sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}server.close();await log.close();await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,report:join(output,'report.json')}));
}
if(report.status!=='passed')process.exitCode=1;
