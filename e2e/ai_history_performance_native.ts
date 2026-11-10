/** Long durable transcript restored into the real native conversation. Private data/RPC only. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile,realpath} from 'node:fs/promises';
import {resolve,join} from 'node:path';
const prefix=resolve(process.argv[2]),out=resolve(process.argv[3]);
await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-history-perf-'));
const data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
for(const p of [data,rpc,zdot])await mkdir(p);
await writeFile(join(zdot,'.zshrc'),"PS1='perf%# '\n");
await writeFile(join(data,'config.toml'),'[ui]\ntheme="dark"\n[ai]\ndefault_provider="perf"\n[[ai.providers]]\nid="perf"\nkind="openai_compat"\nendpoint="http://127.0.0.1:9/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="perf"\ncontext_window=200000\ndefault=true\n');
const messages:any[]=[],display:any[]=[];
for(let i=0;i<500;i++){
 const text=`历史问题 ${i}：验证滚动、输入与内容完整性。`,answer=`历史回答 ${i}：保留 **格式**。\n\n这里是第 ${i} 条记录的正文。\n\n\`\`\`zig\nconst value = ${i};\n\`\`\``;
 messages.push({role:'user',content:text},{role:'assistant',content:answer});
 const turn={id:i+1,task_id:null,sent_at_ms:i*1000,ended_at_ms:i*1000+100,started_mono_ms:0,elapsed_ms:100,input_tokens:10,output_tokens:20,request_count:1,thinking_started_ms:null,thinking_ended_ms:null,thinking_expanded:false,file_source:null,before:[],after:[],answer,prose:answer,thinking:'',steps:[],notices:[],timeline:[{message:{text:answer,started_ms:0,ended_ms:100,expanded:false,submission:null}}],groups:[]};
 display.push({user:true,text,wire_text:null,turn,attachments:null,images:null},{user:false,text:answer,wire_text:null,turn:null,attachments:null,images:null});
}
await writeFile(join(data,'ai-sessions.jsonl'),JSON.stringify({schema:1,event:{kind:'migrate_closed',initial_origin:{session:987654},conversation:'11111111111111111111111111111111',revision:2,turn:500,presentation:JSON.stringify({schema:1,messages:display})},messages})+'\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZDOTDIR:zdot,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('exit',(code,signal)=>r({code,signal})));
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)||null,30000);
const click=async(id:string)=>{report.stage=id;await visible(id);await h.sleep(250);const n=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok,id)};
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const report:any={prefix,isolated:iso,history_messages:1000,status:'running',latency_ms:[]};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1440,1000);
 await click('workspace.empty.local');await visible('terminal.surface');await click('ai.strip');await visible('ai.panel');
 await click('ai.sessions');await visible('ai.session.copy_use.1');
 await h.resetTiming();const start=performance.now();await click('ai.session.copy_use.1');
 if((await h.query('ai.session.close.accept')).some(shown))await click('ai.session.close.accept');
 report.stage='virtual history';await visible('ai.history.virtual');report.open_ms=performance.now()-start;
 const bounded=async()=>{const count=(await h.query('ai.message.user.row')).length;assert(count<40,`resident user rows: ${count}`);return count};
 report.resident_rows=[await bounded()];
 const v=await h.screenPos('ai.conversation.viewport');
 await h.resetTiming();
 for(let i=0;i<36;i++)await h.scrollAt(v.x+v.w/2,v.y+v.h/2,0,600);
 await h.sleep(400);report.resident_rows.push(await bounded());report.scroll_stats=await h.stats();
 await h.screenshot(join(out,'history-scrolled.png'));
 await click('ai.prompt');let expected='';await h.resetTiming();
 for(let i=0;i<24;i++){const fragment=i%2?'a':'输';expected+=fragment;const start=performance.now();assert((await h.type_(fragment)).ok);await h.waitFor(async()=>(await h.inputState('ai.prompt')).buffer===expected||null,5000);report.latency_ms.push(performance.now()-start)}
 report.input_stats=await h.stats();assert.equal((await h.inputState('ai.prompt')).buffer,expected);
 report.latency_p95_ms=[...report.latency_ms].sort((a,b)=>a-b)[22];assert(report.latency_p95_ms<250);
 await h.resizeWindow(1100,800);await h.sleep(400);report.resident_rows.push(await bounded());await h.screenshot(join(out,'history-resized.png'));
 report.total_nodes=flat(await h.query('ai.history.virtual')).length;
 // Recycling a row must preserve an unsaved editor's owned value.
 const current=await h.screenPos('ai.conversation.viewport');
 await h.scrollAt(current.x+current.w/2,current.y+current.h/2,0,1000000);await h.sleep(500);
 const row=flat(await h.query('ai.message.user.row')).find((n:any)=>n.test_id==='ai.message.user.row'&&flat(n).some((t:any)=>t.text?.includes('历史问题 0：')));assert(row,'first historical message is reachable');
 const edit=flat(row).find((n:any)=>n.test_id==='ai.message.edit');assert(edit);
 assert((await h.clickAt(edit.rect.x+edit.rect.w/2,edit.rect.y+edit.rect.h/2)).ok);await visible('ai.message.edit.input');
 await click('ai.message.edit.input');await h.key('a',{cmd:true});await h.type_('尚未保存的历史编辑草稿');
 await h.scrollAt(current.x+current.w/2,current.y+current.h/2,0,-10000);await h.sleep(400);
 assert(!(await h.query('ai.message.edit.input')).length,'editor row leaves the viewport pool');
 await h.scrollAt(current.x+current.w/2,current.y+current.h/2,0,1000000);await visible('ai.message.edit.input');
 assert.equal((await h.inputState('ai.message.edit.input')).buffer,'尚未保存的历史编辑草稿');
 await click('ai.message.edit.cancel');report.recycled_edit_draft_preserved=true;
 assert((await h.request('POST','/zerowork/windows',{action:'quit'})).ok);
 const deadline=performance.now()+20000;
 while(app.exitCode===null&&app.signalCode===null&&performance.now()<deadline){for(const id of ['local.close.accept','session.close.accept','groups.close.accept'])try{if((await h.query(id)).some(shown))await h.clickTestId(id)}catch{};await h.sleep(80)}
 assert.notEqual(app.exitCode,null,'normal Quit completes');assert.deepEqual(await ended,{code:0,signal:null});report.status='passed';
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;await h.screenshot(join(out,'failure.png')).catch(()=>{})}
finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await ended}await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
console.log(JSON.stringify(report,null,2));
