/** ReleaseFast before/after benchmark. Private Local PTY, provider, data and RPC. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, writeFile, open, realpath, stat} from 'node:fs/promises';
import {join, resolve} from 'node:path';

const prefix = resolve(process.argv[2]);
const out = resolve(process.argv[3]);
const code = process.argv.includes('--code');
const prose = process.argv.includes('--prose') || code;
const detailsInput = process.argv.includes('--details-input') || prose;
const chunks = Number(process.env.ZW_AI_PERF_CHUNKS ?? (detailsInput ? 240 : 1200));
const enforce = process.argv.includes('--enforce');
const largeHistory = process.argv.includes('--large-history');
await mkdir(out, {recursive:true});
const iso = await realpath(await mkdtemp('/tmp/zw-stream-perf-'));
const data = join(iso,'data'), rpc = join(iso,'rpc'), zdot = join(iso,'zdot');
for (const path of [data,rpc,zdot]) await mkdir(path);
await writeFile(join(zdot,'.zshrc'), "PS1='perf%# '\n");
const delay = (ms:number) => new Promise(r=>setTimeout(r,ms));
const frame = (delta:any) => 'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
let interactiveReady=!detailsInput;
let rounds=0, reasoningChunks=0, streaming=false, finish=false, fixtureError:string|null=null;
const server = createServer(async(req,res)=>{
 try {
  if(req.method!=='POST') return res.end(JSON.stringify({data:[{id:'perf',context_window:200000,reasoning:true,thinking:{values:['low','medium','high']}}]}));
  let raw=''; for await(const chunk of req) raw+=chunk;
  const body=JSON.parse(raw);
  res.writeHead(200,{'content-type':'text/event-stream'}); res.flushHeaders();
  if(!body.tools?.length) return res.end(frame({content:'性能验证'})+'data: [DONE]\n\n');
  rounds++;
  if(rounds<=18) {
   if(!detailsInput) res.write(frame({content:`第 ${rounds} 步核对。\n\n`}));
   for(let i=0;i<4;i++) {res.write(frame({reasoning_content:`正在核对第 ${rounds} 步，片段 ${i}。\n`}));await delay(15);}
   return res.end(frame({tool_calls:[{index:0,id:`perf-${rounds}`,type:'function',function:{name:'host__get_ucurrent_ucontext',arguments:'{}'}}]})+'data: [DONE]\n\n');
  }
  streaming=true;
  if(detailsInput && !prose) res.write(frame({reasoning_content:('长详情验证：保留已完成步骤，持续检查输入响应和阅读位置。'.repeat(3)+'\n').repeat(120)}));
  if(code) res.write(frame({content:'```zig\n'+Array.from({length:2000},(_,i)=>`const value_${i} = ${i};\n`).join('')}));
  else if(prose) res.write(frame({content:Array.from({length:30},(_,i)=>`已完成段落 ${i}：保留 **格式** 与中文。\n\n\`\`\`zig\nconst value = ${i};\n\`\`\`\n\n| 字段 | 值 |\n| --- | --- |\n| index | ${i} |\n\n`).join('')}));
  while(!interactiveReady && !res.destroyed) await delay(20);
  let i=0;
  while(!res.destroyed && i<chunks) {reasoningChunks=i+1;const text=code?`const appended_${i} = ${i};\n`:prose?(i%6===0?`\n\n新增段落 ${i}：`:'继续核对格式与输入响应。'):`持续推理片段 ${i}，检查已完成步骤与输入响应。\n`;i++;res.write(frame(prose?{content:text}:{reasoning_content:text}));await delay(20);}
  while(!finish && !res.destroyed) await delay(20);
  res.end(frame({content:code?'```\n\nPERF_COMPLETE':'PERF_COMPLETE'})+'data: [DONE]\n\n');
 } catch(e) {fixtureError=String(e);res.end();}
});
await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ai]\ndefault_provider="perf"\nstep_display="collapsed"\n[[ai.providers]]\nid="perf"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address() as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="perf"\ncontext_window=200000\ndefault=true\nreasoning=true\nefforts=["low","medium","high"]\n`);
const journalPath = join(data, 'ai-sessions.jsonl');
if (largeHistory) {
  const conversation = '0102030405060708090a0b0c0d0e0f10';
  const line = (event: object) => JSON.stringify({schema:1,event}) + '\n';
  const fixture = await open(journalPath, 'w', 0o600);
  const context = {role:'user',content:'synthetic immutable context '.repeat(32768)};
  // Write the legacy fixture one message at a time to keep runner memory bounded.
  try {
    await fixture.write(line({kind:'migrate_closed',conversation,revision:2,owner:{session:1},initial_origin:{session:1},turn:96}));
    const [header, trailer] = line({kind:'presentation',conversation,revision:2,presentation:'@@'}).split('@@');
    const escape = (text: string) => JSON.stringify(text).slice(1, -1);
    await fixture.write(header + escape('{"schema":1,"messages":['));
    for (let i=1; i<=96; i++) {
      const answer = '历史答复 ' + i;
      const turn = {
        id:i,task_id:null,sent_at_ms:1700000000000,ended_at_ms:1700000001000,started_mono_ms:0,elapsed_ms:1000,
        input_tokens:null,output_tokens:null,thinking_started_ms:null,thinking_ended_ms:null,thinking_expanded:false,file_source:null,
        before:[context],after:[context,{role:'assistant',content:answer}],
        answer,prose:'',thinking:'',steps:[],notices:[],timeline:[],groups:[],
      };
      await fixture.write((i===1?'':',')+escape(JSON.stringify({user:true,text:'历史问题 '+i,wire_text:null,images:null,attachments:null,turn})));
    }
    await fixture.write(']}'+trailer);
  } finally {
    await fixture.close();
  }
}
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZDOTDIR:zdot},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<any>(r=>app.once('exit',(code,signal)=>r({code,signal})));
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,30000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const report:any={status:'running',prefix,isolated:iso,latency_ms:[]};
try {
 await h.waitForServerReady(60000);await h.resizeWindow(1440,1000);
 await click('workspace.empty.local');await visible('terminal.surface');await click(largeHistory?'toolbar.ai':'ai.strip');
 if(largeHistory) {
  await click('ai.sessions');await click('ai.session.restore.1');await visible('ai.message.user.text');
  report.journal_before_bytes=(await stat(journalPath)).size;
 }
 await click('ai.prompt');await h.type_('连续核对当前上下文，验证十八个步骤');
 await h.resetTiming();const started=performance.now();await click('ai.send');
 await h.waitFor(()=>{assert.equal(fixtureError,null);return streaming||null},90000);
 report.steps_ms=performance.now()-started;report.step_stats=await h.stats();
 if(prose) {
  await visible('ai.response');
  await click('ai.prompt');
  const prefixId=flat((await h.query('ai.response')).at(-1)).find((n:any)=>code?n.test_id==='ai.message.code.text':n.text?.includes('已完成段落 0'))?.id;
  assert(prefixId,'long text prefix is rendered');
  await h.resetTiming();interactiveReady=true;let expected='';
  for(let i=0;i<24;i++) {
   await h.waitFor(()=>reasoningChunks>=(i+1)*chunks/24||null,30000);
   const fragment=i%2===0?'输':'a';expected+=fragment;
   const start=performance.now();assert((await h.type_(fragment)).ok);
   await h.waitFor(async()=>(await h.inputState('ai.prompt')).buffer===expected||null,5000);
   report.latency_ms.push(performance.now()-start);
  }
  report.stream_stats=await h.stats();
  report.prose_prefix_stable=flat((await h.query('ai.response')).at(-1)).some((n:any)=>n.id===prefixId);
  report.input_text=(await h.inputState('ai.prompt')).buffer;
  assert.equal(report.input_text,expected);
  if(enforce)assert(report.prose_prefix_stable,'completed Markdown blocks retain their nodes');
 } else if(detailsInput) {
  const group=(await h.query('ai.step_group.header')).at(-1);assert(group);
  let start=performance.now();assert((await h.clickAt(group.rect.x+group.rect.w/2,group.rect.y+16)).ok);
  await h.waitFor(async()=>(await h.query('ai.thinking')).length>0||null,10000);
  report.group_open_ms=performance.now()-start;
  // Also open an immutable tool result while later steps keep streaming.
  for(let attempt=0;attempt<30;attempt++) {
   const header=(await h.query('ai.tool.result.header')).at(-1);assert(header);
   const viewport=await h.screenPos('ai.conversation.viewport');
   if(header.rect.y>=viewport.y+1&&header.rect.y+32<=viewport.y+viewport.h-1) {
    assert((await h.clickAt(header.rect.x+header.rect.w/2,header.rect.y+16)).ok);break;
   }
   await h.scrollAt(viewport.x+viewport.w/2,viewport.y+viewport.h/2,0,header.rect.y<viewport.y?240:-400);await delay(50);
  }
  start=performance.now();
  for(let attempt=0;attempt<30;attempt++) {
   const thought=(await h.query('ai.thinking')).at(-1);assert(thought);
   const header=flat(thought).find((n:any)=>n.test_id==='ai.step.header');assert(header);
   const viewport=await h.screenPos('ai.conversation.viewport');
   if(header.rect.y>=viewport.y+1&&header.rect.y+32<=viewport.y+viewport.h-1) {
    assert((await h.clickAt(header.rect.x+header.rect.w/2,header.rect.y+16)).ok);break;
   }
   await h.scrollAt(viewport.x+viewport.w/2,viewport.y+viewport.h/2,0,header.rect.y<viewport.y?240:-400);await delay(50);
  }
  await h.waitFor(async()=>(await h.query('ai.thinking')).at(-1)?.rect.h>32||null,10000);
  report.detail_open_ms=performance.now()-start;
  const firstDetail=(await h.query('ai.step.detail')).at(-1)?.id;
  const firstTool=(await h.query('ai.tool.result.header'))[0]?.id;
  const openedTool=(await h.query('ai.tool.result.details')).at(-1)?.id;
  await click('ai.prompt');await h.resetTiming();interactiveReady=true;let expected='';
  for(let i=0;i<24;i++) {
   await h.waitFor(()=>reasoningChunks>=(i+1)*chunks/24||null,30000);
   const fragment=i%2===0?'输':'a';expected+=fragment;
   start=performance.now();assert((await h.type_(fragment)).ok);
   await h.waitFor(async()=>(await h.inputState('ai.prompt')).buffer===expected||null,5000);
   report.latency_ms.push(performance.now()-start);
  }
  report.stream_stats=await h.stats();
  report.thinking_detail_stable=(await h.query('ai.step.detail')).at(-1)?.id===firstDetail;
  report.completed_tool_stable=(await h.query('ai.tool.result.header'))[0]?.id===firstTool;
  report.opened_tool_detail_stable=(await h.query('ai.tool.result.details')).at(-1)?.id===openedTool;
  report.input_text=(await h.inputState('ai.prompt')).buffer;
  assert.equal(report.input_text,expected,'typing must preserve every character');
 } else {
 await click('ai.composer.model');await visible('ai.effort.slider.track');
 // Opening requests catalog discovery. Measure retention after that legitimate
 // catalog replacement has settled, while stream updates continue throughout.
 await delay(750);
 const firstRow=(await h.query('ai.message.user.row'))[0]?.id;
 const firstGroup=(await h.query('ai.step_group.header'))[0]?.id;
 report.collapsed_detail_nodes=(await h.query('ai.step.header')).length+(await h.query('ai.tool.result.header')).length;
 report.first_ids={row:firstRow,group:firstGroup};
 report.identity_samples=[];
 const modelNodes=flat(await h.query('ai.model.menu')).filter((n:any)=>n.test_id==='ai.model.option').map((n:any)=>n.id);
 await h.resetTiming();
 for(let i=0;i<24;i++) {
  await h.waitFor(()=>reasoningChunks>=(i+1)*chunks/24||null,30000);
  const track=await visible('ai.effort.slider.track');const high=i%2===0;
  const start=performance.now();
  assert((await h.clickAt(track.rect.x+1+(track.rect.w-2)*(high?1:0),track.rect.y+track.rect.h/2)).ok);
  await h.waitFor(async()=>flat(await h.query('ai.effort.value')).some((n:any)=>n.text===(high?'高':'低'))||null,5000);
  report.latency_ms.push(performance.now()-start);
  report.identity_samples.push({chunks:reasoningChunks,row:(await h.query('ai.message.user.row'))[0]?.id,group:(await h.query('ai.step_group.header'))[0]?.id,models:flat(await h.query('ai.model.menu')).filter((n:any)=>n.test_id==='ai.model.option').map((n:any)=>n.id)});
  await delay(40);
 }
 report.stream_stats=await h.stats();
 report.user_row_stable=(await h.query('ai.message.user.row'))[0]?.id===firstRow;
 report.completed_group_stable=(await h.query('ai.step_group.header'))[0]?.id===firstGroup;
 report.model_rows_stable=JSON.stringify(flat(await h.query('ai.model.menu')).filter((n:any)=>n.test_id==='ai.model.option').map((n:any)=>n.id))===JSON.stringify(modelNodes);
 report.latency_p95_ms=[...report.latency_ms].sort((a,b)=>a-b)[Math.ceil(report.latency_ms.length*.95)-1];
 }
 report.latency_p95_ms=[...report.latency_ms].sort((a,b)=>a-b)[Math.ceil(report.latency_ms.length*.95)-1];
 if(largeHistory) report.journal_during_bytes=(await stat(journalPath)).size;
 assert((await h.screenshot(join(out,'stream-effort.png'))).ok);
 if(prose) {
  const viewport=await h.screenPos('ai.conversation.viewport');
  for(let i=0;i<12;i++)await h.scrollAt(viewport.x+viewport.w/2,viewport.y+viewport.h/2,0,1200);
  await delay(250);assert((await h.screenshot(join(out,'prose-blocks.png'))).ok);
 }
 await h.key('escape');finish=true;await visible('ai.turn.complete');
 // Finished transcript must still expose its lazy details and survive a second turn.
 const header=(await h.query('ai.step_group.header')).find(shown);
 if(header) {await h.clickAt(header.rect.x+header.rect.w/2,header.rect.y+16);await delay(350);}
 assert((await h.screenshot(join(out,'completed.png'))).ok);
 if(enforce) {
  if(prose) {
   assert(report.prose_prefix_stable);
  } else if(detailsInput) {
   assert(report.thinking_detail_stable,'streaming must retain the opened thinking detail');
   assert(report.completed_tool_stable,'streaming must retain the other step cards');
   assert(report.opened_tool_detail_stable,'streaming must retain the opened tool details');
  } else {
  assert(report.user_row_stable,'streaming must retain the user row');
  assert(report.completed_group_stable,'streaming must retain completed group headers');
  assert(report.model_rows_stable,'usage/effort updates must retain model options');
  assert.equal(report.collapsed_detail_nodes,0,'collapsed groups must not instantiate details');
  }
  assert(report.stream_stats.timing_samples>=10,'need real rendered samples');
  assert(report.latency_p95_ms<250,detailsInput?'composer typing including RPC must respond within 250 ms p95':'effort input including RPC must respond within 250 ms p95');
  if(largeHistory) assert(report.journal_during_bytes-report.journal_before_bytes<8*1024*1024,'stream updates must not rewrite the legacy history');
 }
 assert((await h.request('POST','/zerowork/windows',{action:'quit'})).ok);
 const deadline=performance.now()+20000;
 while(app.exitCode===null&&app.signalCode===null&&performance.now()<deadline){
  for(const id of ['local.close.accept','session.close.accept','groups.close.accept'])try{if((await h.query(id)).some(shown))await h.clickTestId(id)}catch{}
  await Promise.race([ended,delay(100)]);
 }
 assert.notEqual(app.exitCode,null,'normal Quit');assert.deepEqual(await ended,{code:0,signal:null});report.status='passed';
 if(largeHistory) report.journal_final_bytes=(await stat(journalPath)).size;
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;await h.screenshot(join(out,'failure.png')).catch(()=>{});}
finally {
 interactiveReady=true;finish=true;if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await ended;}
 server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));await log.close();
 report.rounds=rounds;report.reasoning_chunks=reasoningChunks;await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(JSON.stringify(report,null,2));
