/** Local built-ins through the actual AI tool catalog; isolated data and PTY. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,open,writeFile,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'zig-out');
const out=resolve(process.argv[2]??'/tmp/zw-ai-builtin-commands');await mkdir(out,{recursive:true});
const isolated=await mkdtemp('/private/tmp/zw-ai-builtins-'),data=join(isolated,'data'),rpc=join(isolated,'rpc');await mkdir(data);await mkdir(rpc);
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const wire=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
const payload=(envelope:any)=>{for(const b of envelope.content??[])try{return JSON.parse(b.text)}catch{}return envelope;};
let failure:any=null;const checks:string[]=[];
const server=createServer(async(req,res)=>{try{
 if(req.method!=='POST')return res.end('{"data":[{"id":"builtin-fixture"}]}');
 let raw='';for await(const b of req)raw+=b;const body=JSON.parse(raw);
 res.writeHead(200,{'content-type':'text/event-stream'});
 if(!body.tools?.length)return res.end(frame({content:'Built-in display'})+'data: [DONE]\n\n');
 const builtin=body.tools.find((t:any)=>t.function.name===wire('host.run_builtin'));assert(builtin);
 assert(JSON.stringify(body.messages[0]).includes('@dots'));assert(JSON.stringify(body.messages[0]).includes('local application actions'));
 const command=body.messages.filter((m:any)=>m.role==='user').at(-1).content.includes('@help')?'@help':'@dots';
 const results=new Map(body.messages.filter((m:any)=>m.role==='tool').map((m:any)=>[m.tool_call_id,JSON.parse(m.content)]));
 const call=(id:string,name:string,args:any)=>res.end(frame({tool_calls:[{index:0,id,type:'function',function:{name:wire(name),arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n');
 const key=command==='@dots'?'dots':'help';
 const context:any=results.get(key+'-context');if(!context)return call(key+'-context','host.get_current_context',{});
 const reference=payload(context).binding_ref;assert(reference);
 assert(builtin.function.parameters.properties.session_ref.enum.includes(reference),'tool schema constrains exact authorized session');
 if(!results.has(key+'-invalid'))return call(key+'-invalid','host.run_builtin',{session_ref:reference.replace(/:[^:]+$/,':999999'),command});
 assert.notEqual((results.get(key+'-invalid')as any).status,'succeeded','forged target is rejected');
 if(!results.has(key+'-display'))return call(key+'-display','host.run_builtin',{session_ref:reference,command});
 const result:any=results.get(key+'-display');assert.equal(result.status,'succeeded',JSON.stringify(result));
 const receipt=payload(result);assert.equal(receipt.state,'displayed');assert.equal(receipt.command,command);assert.equal(receipt.shell_input_sent,false);
 checks.push(command+' displays locally with no shell input; forged target rejected');
 return res.end(frame({content:'BUILTIN_DISPLAYED_'+key})+'data: [DONE]\n\n');
}catch(error){failure=String(error);res.end(frame({content:'FIXTURE_ERROR '+failure})+'data: [DONE]\n\n');}});
await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="builtin-fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="builtin-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="builtin-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts'));const log=await open(join(out,'app.log'),'w');
const environment={...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'};
for(const key of ['ZEROWORK_AI_MOCK','ZEROWORK_AI_ENDPOINT','ZEROWORK_AI_MODEL','ZEROWORK_AI_PROVIDER'])delete environment[key];
const app=spawn(join(prefix,'bin/zerowork'),[],{env:environment,stdio:['ignore',log.fd,log.fd]});const ended=new Promise(done=>app.once('exit',(code,signal)=>done({code,signal})));
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join('');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok);};
const report:any={status:'running',checks};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1200,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');
 for(const [command,key]of [['@dots','dots'],['@help','help']]){
  await click('ai.prompt');await h.type_('请在当前终端执行 '+command);await click('ai.send');
  await h.waitFor(async()=>{if(failure)throw Error(failure);return text(await h.query('ai.panel')).includes('BUILTIN_DISPLAYED_'+key)||null;},30000);
  if(key==='dots')await visible('terminal.dots.qr');
  await h.screenshot(join(out,key+'.png'));
 }
 assert.equal(failure,null);assert.equal(checks.length,2);
 assert(!text(await h.query('terminal.surface')).includes('command not found'));
 assert((await h.request('POST','/zerowork/windows',{action:'quit'})).ok);assert.deepEqual(await ended,{code:0,signal:null});report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await h.screenshot(join(out,'failure.png')).catch(()=>{});}
finally{
 if(app.exitCode===null&&app.signalCode===null){app.kill();await ended;}await log.close();server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));await rm(isolated,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(JSON.stringify(report,null,2));
