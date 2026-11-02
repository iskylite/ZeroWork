/** One real batch execution; continuation survives a later conversation turn. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,open,readFile,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-pagination-build');
const out=resolve(process.argv[2]??'/tmp/zw-batch-pagination-native');await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-batch-pagination-'),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const wire=(s:string)=>s.replaceAll('_','_u').replaceAll('.','__');
const payload=(s:string)=>{let value:any=JSON.parse(s);if(value.targets?.length===1)value=value.targets[0];for(const block of value.content??[])try{return JSON.parse(block.text)}catch{}return value;};
let first:any=null,failure:any=null;const counter=join(data,'executed-once'),overflowMarker=join(data,'overflow-done');
const expected='BEGIN\n'+Array.from({length:1500},(_,i)=>'你好-'+String(i+1).padStart(4,'0')+'\n').join('')+'END\n';
const report:any={status:'running',checks:[],pages:0};
const server=createServer(async(req,res)=>{try{
 if(req.method!=='POST')return res.end('{"data":[{"id":"batch-pagination-fixture"}]}');
 let raw='';for await(const c of req)raw+=c;const body=JSON.parse(raw);res.writeHead(200,{'content-type':'text/event-stream'});
 const userIndex=body.messages.findLastIndex((m:any)=>m.role==='user');
 const results=new Map(body.messages.slice(userIndex+1).filter((m:any)=>m.role==='tool').map((m:any)=>[m.tool_call_id,payload(m.content)]));
 const call=(id:string,name:string,args:any)=>res.end(frame({tool_calls:[{index:0,id,type:'function',function:{name,arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n');
 if(body.messages[userIndex].content==='OVERFLOW_BATCH'){
  if(!results.has('overflow-once')){
   const tool=body.tools.find((t:any)=>t.function.name==='run_command');assert(tool);
   const program=`import sys;sys.stdout.write("中"*1500000);sys.stdout.flush();open("${overflowMarker}","w").write("done")`;
   return call('overflow-once','run_command',{session_ids:[tool.function.parameters.properties.session_ids.items.enum[0]],command:`python3 -c '${program}'`});
  }
  const overflow:any=results.get('overflow-once');assert.equal(overflow.status,'succeeded');assert(overflow.retained_truncated);
  assert.equal(await readFile(overflowMarker,'utf8'),'done','capture overflow must not cancel the command');
  if(!results.has('overflow-tail'))return call('overflow-tail',wire('host.read_command_output'),{output_ref:overflow.output_ref,output_cursor:4*1024*1024-31,max_bytes:4096});
  const tail:any=results.get('overflow-tail');assert.equal(tail.stdout,'中'.repeat(10));assert.equal(tail.next_output_cursor,null);assert(tail.retained_truncated);assert.equal(tail.retained_bytes,4*1024*1024-1);
  return res.end(frame({content:'OVERFLOW_RETAINED_LIMIT_VERIFIED'})+'data: [DONE]\n\n');
 }
 if(body.messages[userIndex].content==='INITIAL_BATCH'){
  if(!results.has('batch-once')){
   const tool=body.tools.find((t:any)=>t.function.name==='run_command');assert(tool);
   return call('batch-once','run_command',{session_ids:[tool.function.parameters.properties.session_ids.items.enum[0]],command:`printf 'once\\n' >> '${counter}'; printf 'BEGIN\\n'; printf '你好-%04d\\n' {1..1500}; printf 'END\\n'; printf 'ERR_STREAM\\n' >&2`});
  }
  first=results.get('batch-once');assert.equal(first.status,'succeeded',JSON.stringify(first));
  assert.equal(first.output_ref.length,32);assert(first.next_output_cursor>0);assert(first.truncated);assert.equal(first.retained_truncated,false);
  return res.end(frame({content:'FIRST_PAGE_AVAILABLE'})+'data: [DONE]\n\n');
 }
 assert(first);assert(body.tools.some((t:any)=>t.function.name===wire('host.read_command_output')));
 let stdout=first.stdout,stderr=first.stderr,cursor=first.next_output_cursor,index=0;
 while(results.has('batch-page-'+index)){
  const page:any=results.get('batch-page-'+index);assert.equal(page.status,'succeeded',JSON.stringify(page));
  assert.equal(page.output_ref,first.output_ref);assert.equal(page.retained_truncated,false);assert.equal(page.output_cursor,cursor);
  stdout+=page.stdout;stderr+=page.stderr;cursor=page.next_output_cursor;index++;
 }
 if(cursor!==null)return call('batch-page-'+index,wire('host.read_command_output'),{output_ref:first.output_ref,output_cursor:cursor,max_bytes:4096});
 assert.equal(stdout,expected);assert.equal(stderr,'ERR_STREAM\n');assert.equal(await readFile(counter,'utf8'),'once\n');
 report.pages=index+1;report.outputBytes=Buffer.byteLength(stdout)+Buffer.byteLength(stderr);
 res.end(frame({content:'ALL_BATCH_PAGES_VERIFIED'})+'data: [DONE]\n\n');
}catch(error){failure=String(error);res.end(frame({content:'FIXTURE_ERROR '+failure})+'data: [DONE]\n\n');}});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="batch-pagination-fixture"\ncontext_window=200000\ndefault=true\n`);
const log=await open(join(out,'app.log'),'w');const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>n&&n.visible!==false&&!n.hidden&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{report.lastAction=id;await visible(id);assert((await h.clickTestId(id)).ok);};
const text=(n:any):string=>Array.isArray(n)?n.map(text).join(' '):n?[n.text??'',...(n.children??[]).map(text)].join(' '):'';
const send=async(value:string)=>{await click('ai.prompt');await h.type_(value);await click('ai.send');};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1200,900);await click('workspace.empty.local');await click('toolbar.ai');
 await send('INITIAL_BATCH');await click('ai.approval.accept');
 await h.waitFor(async()=>failure||text(await h.query('ai.conversation')).includes('FIRST_PAGE_AVAILABLE')||null,30000);assert.equal(failure,null);
 await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,10000);
 await send('CONTINUE_PREVIOUS_OUTPUT');
 await h.waitFor(async()=>failure||text(await h.query('ai.conversation')).includes('ALL_BATCH_PAGES_VERIFIED')||null,30000);assert.equal(failure,null);
 await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,10000);
 await send('OVERFLOW_BATCH');await click('ai.approval.accept');
 await h.waitFor(async()=>failure||text(await h.query('ai.conversation')).includes('OVERFLOW_RETAINED_LIMIT_VERIFIED')||null,30000);assert.equal(failure,null);
 assert(report.pages>1);assert((await h.screenshot(join(out,'complete.png'))).ok);
 report.checks=['one real native batch execution despite several output pages','stdout, stderr and Chinese UTF-8 text reassemble exactly','read-only continuation survives a later turn without another approval or command replay','capture overflow preserves a valid UTF-8 prefix, reports the retention limit, and lets the command complete'];report.status='passed';
}catch(error){report.status='failed';report.error=String(error);await h.screenshot(join(out,'failure.png')).catch(()=>{});await writeFile(join(out,'failure.json'),JSON.stringify(await h.query('ai.panel'),null,2)).catch(()=>{});process.exitCode=1;}
finally{
 server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));
 try{await h.request('POST','/quit');await h.waitFor(async()=>app.exitCode!==null||app.signalCode!==null||null,10000);}catch{app.kill('SIGTERM');}
 if(app.exitCode===null&&app.signalCode===null)await new Promise(done=>app.once('close',done));
 await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}
