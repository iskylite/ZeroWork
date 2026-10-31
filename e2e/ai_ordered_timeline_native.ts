/** Real native transcript: preserve channel switches, tool slots and history. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,open,readFile,writeFile,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/private/tmp/zw-ordered-timeline-build');
const out=resolve(process.argv[2]??'/private/tmp/zw-ordered-timeline-evidence');await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-ordered-timeline-'),data=join(iso,'data'),rpc=join(iso,'rpc');for(const p of[data,rpc])await mkdir(p);
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const wire=(s:string)=>s.replaceAll('_','_u').replaceAll('.','__');
let held:any=null,failed:string|null=null;
const payload=(s:string)=>{const envelope=JSON.parse(s);for(const block of envelope.content??[])try{return JSON.parse(block.text)}catch{}return envelope;};
const server=createServer(async(req,res)=>{try{
 if(req.method!=='POST')return res.end('{"data":[{"id":"timeline-fixture"}]}');
 let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);
 res.writeHead(200,{'content-type':'text/event-stream'});
 if(body.messages.findLast((m:any)=>m.role==='user')?.content==='SECOND_TURN')return res.end(frame({content:'SECOND_MESSAGE'})+'data: [DONE]\n\n');
 const results=new Map(body.messages.filter((m:any)=>m.role==='tool').map((m:any)=>[m.tool_call_id,payload(m.content)]));
 const thinking=(n:number)=>res.write(frame({reasoning_content:'THOUGHT'+n+' · 独立思考段'}));
 const message=(n:number)=>res.write(frame({content:'MESSAGE'+n+' · 独立模型消息'}));
 const tool=(id:string,name:string,args:any)=>res.end(frame({tool_calls:[{index:0,id,type:'function',function:{name:wire(name),arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n');
 if(!results.has('timeline-context')){thinking(1);res.write(frame({reasoning_content:'，同一段的后续字符。'}));message(1);thinking(2);message(2);return tool('timeline-context','host.get_current_context',{});}
 if(!results.has('timeline-session')){thinking(3);message(3);return tool('timeline-session','host.get_session',{session_ref:(results.get('timeline-context')as any).binding_ref});}
 thinking(4);message(4);thinking(5);message(5);held=res;
}catch(error){failed=String(error);res.end(frame({content:'FIXTURE_ERROR'})+'data: [DONE]\n\n');}});await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="timeline-fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="timeline-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="timeline-fixture"\ncontext_window=200000\ndefault=true\nreasoning=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const log=await open(join(out,'app.log'),'w');const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join(' ');
const shown=(n:any)=>n&&n.visible!==false&&!n.hidden&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok)};
const timeline=async()=>{const root=(await h.query('ai.conversation'))[0];assert(root,'conversation root');return(root.children??[]).flatMap((n:any)=>{
 if(n.test_id==='ai.thinking')return[{kind:'thinking',label:text(n).match(/THOUGHT\d+/)?.[0],rect:n.rect}];
 if(n.test_id==='ai.message.assistant')return[{kind:'message',label:text(n).match(/MESSAGE\d+|SECOND_MESSAGE/)?.[0],rect:n.rect}];
 if(n.test_id==='ai.step.tool'||flat(n).some((c:any)=>c.test_id==='ai.tool.result.title'))return[{kind:'tool',label:'TOOL',rect:n.rect}];
 return[];
});};
const labels=(items:any[])=>items.map(n=>n.label);
const send=async(value:string)=>{await click('ai.prompt');await h.type_(value);await click('ai.send')};
const report:any={status:'running',checks:[]};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1440,1000);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.maximize');await send('按实际时间顺序输出每个步骤。');
 const expected=['THOUGHT1','MESSAGE1','THOUGHT2','MESSAGE2','TOOL','THOUGHT3','MESSAGE3','TOOL','THOUGHT4','MESSAGE4','THOUGHT5','MESSAGE5'];
 await h.waitFor(async()=>held&&labels(await timeline()).includes('MESSAGE5')||null,20000);assert.equal(failed,null);
 let items=await timeline();assert.deepEqual(labels(items),expected);
 const firstThinking=items[0].rect;await h.clickAt(firstThinking.x+80,firstThinking.y+16);
 await h.waitFor(async()=>(await timeline())[0].rect.h>32||null,5000);
 let independent=await timeline();assert.equal(independent[2].rect.h,32,'another thinking segment stays collapsed');
 await h.clickAt(firstThinking.x+80,firstThinking.y+16);await h.waitFor(async()=>(await timeline())[0].rect.h===32||null,5000);items=await timeline();

 for(let i=1;i<items.length;i++)assert(items[i].rect.y>=items[i-1].rect.y+items[i-1].rect.h-.5,'native layout follows event order');
 const before=JSON.stringify(items.slice(0,-1));held.write(frame({content:' · tail stays in MESSAGE5'}));await h.waitFor(async()=>text(await h.query('ai.conversation')).includes('tail stays')||null,5000);items=await timeline();assert.deepEqual(labels(items),expected);assert.equal(JSON.stringify(items.slice(0,-1)),before,'earlier cards keep content and layout');
 held.write(frame({reasoning_content:'THOUGHT6 · 工具后新思考'}));held.write(frame({content:'MESSAGE6 · 新模型消息'}));expected.push('THOUGHT6','MESSAGE6');await h.waitFor(async()=>labels(await timeline()).includes('MESSAGE6')||null,5000);assert.deepEqual(labels(await timeline()),expected);
 await h.screenshot(join(out,'streamed-order.png'));await writeFile(join(out,'streamed-order.tree.json'),JSON.stringify(await h.query('ai.conversation'),null,2));
 held.end('data: [DONE]\n\n');held=null;await visible('ai.turn.complete');assert.deepEqual(labels(await timeline()),expected);
 await send('SECOND_TURN');await h.waitFor(async()=>labels(await timeline()).includes('SECOND_MESSAGE')||null,10000);assert.deepEqual(labels(await timeline()),[...expected,'SECOND_MESSAGE']);
 await h.resizeWindow(860,480);assert.deepEqual(labels(await timeline()),[...expected,'SECOND_MESSAGE']);await h.resizeWindow(1440,1000);await h.screenshot(join(out,'history-order.png'));await writeFile(join(out,'history-order.tree.json'),JSON.stringify(await h.query('ai.conversation'),null,2));
 report.status='passed';report.order=expected;report.checks=['six independent thinking segments and six independent model messages interleave with two actual tools','only consecutive chunks update their own segment','thinking disclosures remain independent','new content appends after existing steps','completion, history clone and resize preserve order'];
}catch(error){report.status='failed';report.error=String(error);await h.screenshot(join(out,'failure.png')).catch(()=>{});await writeFile(join(out,'failure.tree.json'),JSON.stringify(await h.query('ai.conversation'),null,2)).catch(()=>{});process.exitCode=1;}
finally{if(held)held.end();server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));app.kill('SIGTERM');await new Promise<void>(r=>{if(app.exitCode!==null||app.signalCode!==null)return r();app.once('close',()=>r());setTimeout(()=>{app.kill('SIGKILL');r()},3000)});await log.close();await rm(iso,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));}
