/** Real terminal history pagination and assistant close/minimize lifecycle. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,open,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'zig-out');
const out=resolve(process.argv[2]??'/tmp/zw-ai-history-close-evidence');await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-ai-history-close-'),data=join(iso,'data'),rpc=join(iso,'rpc');
await mkdir(data);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const wire=(s:string)=>s.replaceAll('_','_u').replaceAll('.','__');
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const payload=(text:string)=>{const value=JSON.parse(text);for(const block of value.content??[])try{return JSON.parse(block.text)}catch{}return value;};
const report:any={status:'running',checks:[],pages:[]};let failure:any=null,held:any=null;
const server=createServer(async(req,res)=>{try{
 if(req.method!=='POST')return res.end('{"data":[{"id":"history-close-fixture"}]}');
 let raw='';for await(const chunk of req)raw+=chunk;const body=JSON.parse(raw);
 res.writeHead(200,{'content-type':'text/event-stream'});
 const question=body.messages.findLast((m:any)=>m.role==='user')?.content;
 if(question==='SECOND_CONVERSATION')return res.end(frame({content:'SECOND_CONVERSATION_MARKER'})+'data: [DONE]\n\n');
 if(question==='CONTINUE_AFTER_CLOSE'){
  assert(body.messages.some((m:any)=>m.role==='assistant'&&m.content?.includes('HISTORY_READ_COMPLETE')),'reopened conversation retains provider context');
  return res.end(frame({content:'REOPENED_CONTEXT_RETAINED'})+'data: [DONE]\n\n');
 }
 if(question==='HOLD_CURRENT_TURN'){
  res.write(frame({content:'RUNNING_HISTORY_MARKER'}));held=res;return;
 }
 assert(!body.tools.some((t:any)=>t.function.name==='read_terminal'),'legacy tail-only tool must not be offered');
 const definition=body.tools.find((t:any)=>t.function.name===wire('host.read_terminal'))?.function;
 assert(definition,'unified history tool');const refs=definition.parameters.properties.session_ref.enum;assert.equal(refs.length,1);
 const source=refs[0],results=new Map(body.messages.filter((m:any)=>m.role==='tool').map((m:any)=>[m.tool_call_id,payload(m.content)]));
 const call=(id:string,args:any)=>res.end(frame({tool_calls:[{index:0,id,type:'function',function:{name:definition.name,arguments:JSON.stringify({session_ref:source,...args})}}]})+'data: [DONE]\n\n');
 if(!results.has('history-tail'))return call('history-tail',{max_lines:2});
 const tail:any=results.get('history-tail');assert(tail.range_returned,JSON.stringify(tail));
 if(!results.has('history-page-0'))return call('history-page-0',{range_kind:'lines',start_line:0,end_line:tail.range_returned.total_retained_lines-1,max_lines:12});
 let index=0,last:any;const lines:any[]=[];
 while(results.has('history-page-'+index)){last=results.get('history-page-'+index);assert(last.lines,JSON.stringify(last));lines.push(...last.lines);index++;}
 if(last.next_cursor)return call('history-page-'+index,{range_kind:'cursor',cursor:last.next_cursor,max_lines:12});
 const text=lines.map(l=>l.text).join('\n');
 assert(text.includes('HISTORY_ROW_001'));assert(text.includes('HISTORY_ROW_016'));
 assert(index>1);assert.equal(new Set(lines.map(l=>l.line)).size,lines.length,'pages must advance without repeated rows');
 report.pages=Array.from({length:index},(_,i)=>{const page:any=results.get('history-page-'+i);return page.range_returned});
 res.end(frame({content:'HISTORY_READ_COMPLETE'})+'data: [DONE]\n\n');
}catch(error){failure=String(error);res.end(frame({content:'FIXTURE_ERROR '+failure})+'data: [DONE]\n\n');}});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="history-close-fixture"\ncontext_window=200000\ndefault=true\n`);
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>n&&n.visible!==false&&!n.hidden&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,15000);
const click=async(id:string)=>{report.lastAction=id;await visible(id);assert((await h.clickTestId(id)).ok,id);};
const text=(n:any):string=>Array.isArray(n)?n.map(text).join(' '):n?[n.text??'',...(n.children??[]).map(text)].join(' '):'';
const send=async(value:string)=>{await click('ai.prompt');await h.type_(value);await click('ai.send');};
const cap=async(name:string)=>{await h.mouseMove(1,1);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2));};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1200,900);await click('workspace.empty.local');await click('terminal.surface');
 await h.type_("printf 'HISTORY_ROW_%03d\\n' {1..16}");await h.key('return');
 // Wait for actual PTY output, rather than assuming shell startup/printing
 // finishes within a fixed delay before revision-bound pagination begins.
 await h.waitFor(async()=>text(await h.query('terminal.surface')).includes('HISTORY_ROW_016')||null,15000);
 const strip=await visible('ai.strip');await h.mouseMove(strip.rect.x+strip.rect.w/2,strip.rect.y+strip.rect.h/2);await visible('ai.panel');await send('READ_HISTORY');
 await h.waitFor(async()=>failure||text(await h.query('ai.conversation')).includes('HISTORY_READ_COMPLETE')||null,30000);
 assert.equal(failure,null);await absent('ai.stop');await cap('01-history-pages');
 report.checks.push('Only host.read_terminal is advertised; real early and late terminal rows are read across distinct revision-bound pages');
 // Hover preview and @ai/context entry paths can start an unlisted conversation.
 // Closing must retain it even if the toolbar has never been clicked.
 await click('ai.close');await click('ai.close.confirmation.confirm');await absent('ai.panel');await click('toolbar.ai');await visible('ai.empty.configured');
 await click('ai.close');await absent('ai.panel');await absent('ai.close.confirmation');await click('toolbar.ai');await visible('ai.empty.configured');
 report.checks.push('Configured welcome with retained history closes without confirmation and reopens without creating another conversation');
 await visible('ai.empty.recent');assert(text(await h.query('ai.empty.recent')).includes('READ_HISTORY'));
 await click('ai.sessions');await visible('ai.session.row.1');await click('ai.session.jump.1');await absent('ai.sessions.menu');
 assert(text(await h.query('ai.conversation')).includes('HISTORY_READ_COMPLETE'));
 report.checks.push('A conversation started through hover preview is retained in the list and welcome recent history after X');
 await click('ai.collapse');await absent('ai.panel');await click('toolbar.ai');
 assert(text(await h.query('ai.conversation')).includes('HISTORY_READ_COMPLETE'));
 report.checks.push('Minus preserves the current conversation');
 // Keep a second conversation to catch accidental clearing of the whole list.
 await click('ai.session.new');await send('SECOND_CONVERSATION');
 await h.waitFor(async()=>text(await h.query('ai.conversation')).includes('SECOND_CONVERSATION_MARKER')||null,10000);await absent('ai.stop');
 await click('ai.sessions');await visible('ai.session.row.1');await visible('ai.session.row.3');await click('ai.session.jump.1');await absent('ai.sessions.menu');
 assert(text(await h.query('ai.conversation')).includes('HISTORY_READ_COMPLETE'));
 await click('ai.prompt');await h.type_('UNSENT_DRAFT');
 await click('ai.close');await visible('ai.close.confirmation');await cap('02-close-confirmation');
 await click('ai.close.confirmation.cancel');await absent('ai.close.confirmation');
 assert(text(await h.query('ai.conversation')).includes('HISTORY_READ_COMPLETE'));assert.equal((await h.inputState('ai.prompt')).buffer,'UNSENT_DRAFT');
 await click('ai.close');await click('ai.close.confirmation.confirm');await absent('ai.panel');await click('toolbar.ai');await visible('ai.empty.configured');
 assert(!text(await h.query('ai.conversation')).includes('HISTORY_READ_COMPLETE'));assert.equal((await h.inputState('ai.prompt')).buffer,'');
 await visible('ai.empty.recent');assert(text(await h.query('ai.empty.recent')).includes('READ_HISTORY'));assert(text(await h.query('ai.empty.recent')).includes('SECOND_CONVERSATION'));
 await cap('03-welcome-with-history');
 await click('ai.sessions');await visible('ai.session.row.1');await visible('ai.session.row.3');
 await cap('04-retained-conversation-list');await click('ai.session.jump.3');await absent('ai.sessions.menu');
 assert(text(await h.query('ai.conversation')).includes('SECOND_CONVERSATION_MARKER'));
 await click('ai.sessions');await click('ai.session.jump.4');await absent('ai.sessions.menu');await visible('ai.empty.configured');
 const recent=(await h.query('ai.session.row.1')).find((n:any)=>shown(n)&&text(n).includes('READ_HISTORY'));assert(recent,'ended conversation is in welcome recent history');
 await click('ai.session.restore.1');
 await h.waitFor(async()=>text(await h.query('ai.conversation')).includes('HISTORY_READ_COMPLETE')||null,10000);assert.equal((await h.inputState('ai.prompt')).buffer,'UNSENT_DRAFT');
 report.checks.push('X opens a fresh welcome page with an empty draft; both histories remain in the list and recent history; either entry restores its transcript and saved draft');
 await click('ai.prompt');await h.key('a',{cmd:true});await h.type_('CONTINUE_AFTER_CLOSE');await click('ai.send');
 await h.waitFor(async()=>failure||text(await h.query('ai.conversation')).includes('REOPENED_CONTEXT_RETAINED')||null,15000);assert.equal(failure,null);await absent('ai.stop');
 report.checks.push('A follow-up after X sends the original transcript back to the provider');
 await send('HOLD_CURRENT_TURN');await h.waitFor(async()=>held||null,10000);await visible('ai.stop');
 await click('ai.prompt');await h.type_('RUNNING_UNSENT_DRAFT');
 await click('ai.collapse');await absent('ai.panel');await click('toolbar.ai');await visible('ai.stop');
 assert(text(await h.query('ai.conversation')).includes('RUNNING_HISTORY_MARKER'));
 await click('ai.close');assert.equal(text(await visible('ai.close.confirmation.title')).trim(),'停止并结束当前会话？');
 await click('ai.close.confirmation.confirm');await absent('ai.panel');await click('toolbar.ai');await visible('ai.empty.configured');await absent('ai.stop');
 assert(!text(await h.query('ai.conversation')).includes('RUNNING_HISTORY_MARKER'));assert.equal((await h.inputState('ai.prompt')).buffer,'');
 await visible('ai.empty.recent');assert(text(await h.query('ai.empty.recent')).includes('HOLD_CURRENT_TURN'));await cap('05-welcome-after-stop');
 await click('ai.sessions');await visible('ai.session.row.1');await visible('ai.session.row.3');await click('ai.session.jump.1');await absent('ai.sessions.menu');
 await h.waitFor(async()=>text(await h.query('ai.conversation')).includes('RUNNING_HISTORY_MARKER')||null,10000);await absent('ai.stop');
 assert(text(await h.query('ai.conversation')).includes('HISTORY_READ_COMPLETE'));assert.equal((await h.inputState('ai.prompt')).buffer,'RUNNING_UNSENT_DRAFT');await cap('06-restored-stopped-history');
 report.checks.push('Minus leaves a running turn active; X stops it, opens a new welcome page and retains the ended conversation in recent history and the list, including partial output and draft');
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);await cap('failure').catch(()=>{});process.exitCode=1;}
finally{
 if(held)held.end();server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));
 try{await h.request('POST','/quit');await h.waitFor(async()=>app.exitCode!==null||app.signalCode!==null||null,10000);}catch{app.kill('SIGTERM');}
 if(app.exitCode===null&&app.signalCode===null)await new Promise(done=>app.once('close',done));
 if(app.exitCode!==0){report.status='failed';report.shutdown={code:app.exitCode,signal:app.signalCode};process.exitCode=1;}
 await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}
