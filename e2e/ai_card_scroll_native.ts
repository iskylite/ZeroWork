/** PATCH scroll ownership in the production window, using an owned deterministic SSE fixture. */
import assert from 'node:assert/strict';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'dist/patch-card-scroll-candidate');
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'dist/ui-acceptance/patch-card-scroll');await mkdir(out,{recursive:true});
const isolated=await realpath(await mkdtemp('/tmp/zw-card-scroll-')),data=join(isolated,'data'),rpc=join(isolated,'rpc');await mkdir(data);await mkdir(rpc);
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
let held:any=null,requests=0;
const server=createServer(async(req,res)=>{
 if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'card-scroll-fixture',context_window:200000}]}));return}
 let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);requests++;
 res.writeHead(200,{'content-type':'text/event-stream'});
 if(!body.messages.some((m:any)=>m.role==='tool')){
  const name='host__get_ucurrent_ucontext';assert(body.tools.some((t:any)=>t.function.name===name));
  res.end(frame({reasoning_content:'短思考。',tool_calls:[{index:0,id:'card-scroll-context',type:'function',function:{name,arguments:'{}'}}]})+'data: [DONE]\n\n');return;
 }
 res.write(frame({content:'检查结果。\n\n'+Array.from({length:45},(_,i)=>`- 对话正文第 ${i+1} 行：保留外层阅读位置。`).join('\n')}));held=res;
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="card-scroll-fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="card-scroll-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="card-scroll-fixture"\ncontext_window=200000\ndefault=true\nreasoning=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<any>(done=>app.once('exit',(code,signal)=>done({code,signal})));
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const rect=async(id:string)=>(await visible(id)).rect;
const snapshot=async()=>({outer:await rect('ai.conversation.viewport'),card:await rect('ai.tool.result.details'),content:await rect('ai.tool.result.stdout'),user:await rect('ai.message.user.bubble')});
const cap=async(name:string)=>{assert((await h.screenshot(join(out,`${name}.png`))).ok);await writeFile(join(out,`${name}.json`),JSON.stringify(await h.query('ai.panel'),null,2))};
const scrollOuter=async(dy:number)=>{const r=await rect('ai.conversation.viewport');await h.scrollAt(r.x+3,r.y+20,0,dy);await h.sleep(80)};
const sendBody=async(dy:number,mods:any={})=>{const r=await rect('ai.tool.result.details');await h.scrollAt(r.x+40,r.y+r.h/2,0,dy,mods);await h.sleep(50)};
const sameOuter=async(before:any)=>{const now=await snapshot();assert(Math.abs(now.card.y-before.card.y)<.1,'Card moved with outer conversation');assert(Math.abs(now.user.y-before.user.y)<.1,'User bubble moved with outer conversation');return now};
const report:any={status:'running',binary:join(prefix,'bin/zerowork'),isolated,checks:[],limits:['Owned local SSE fixture; no external model or user conversation was used.','Wheel and phased trackpad packets go through the native window harness; physical touchpad hardware was not driven.']};
try{
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1200,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.prompt');await h.type_('检查展开卡片的滚动。');await click('ai.send');await visible('ai.tool.result.header');await visible('ai.response');assert(held);
 await scrollOuter(100000);let thinking=await rect('ai.thinking');assert((await h.clickAt(thinking.x+90,thinking.y+16)).ok);await h.sleep(350);
 const shortNode=await visible('ai.step.details'),short=shortNode.rect,shortBefore=await rect('ai.thinking');assert(short.h<150);assert.equal(shortNode.children[1].rect.w,0,'Short card must not show a fake vertical scrollbar');await h.scrollAt(short.x+40,short.y+short.h/2,0,-35);await h.waitFor(async()=>(await rect('ai.thinking')).y<shortBefore.y-20||null,5000);report.checks.push('Short expanded thinking passes wheel input to the conversation');
 await scrollOuter(100000);await click('ai.tool.result.header');await h.sleep(350);let before=await snapshot();assert.equal(before.card.h,150);await cap('01-expanded-long-card');const initialThumb=(await visible('ai.tool.result.details')).children[1];assert(initialThumb.rect.w>0&&initialThumb.rect.h>0,'Overflow thumb must be visible before any scrolling');await h.mouseMove(2,850);await h.sleep(3000);const idleThumb=(await visible('ai.tool.result.details')).children[1];assert(idleThumb.rect.w>0&&idleThumb.rect.h>0,'Overflow thumb must remain visible while idle');assert((idleThumb.opacity??1)>0);report.idle_thumb={node_id:idleThumb.id,rect:idleThumb.rect,opacity:idleThumb.opacity??1};await cap('01-idle-long-card');report.checks.push('Initial expanded long-card thumb stays visible after three idle seconds; short card has no fake thumb');
 await sendBody(-45);let now=await sameOuter(before);assert(now.content.y<before.content.y-20);report.checks.push('Wheel over a long expanded host-result body moves the inner content only');
 const heldOffset=now.card.y-now.content.y;
 held.write(frame({reasoning_content:'\n补充思考触发对话重建。'}));await h.waitFor(async()=>(await visible('ai.step.detail')).text?.includes('补充思考')||null,5000);await h.sleep(150);now=await snapshot();assert(Math.abs(now.card.y-now.content.y-heldOffset)<.5,'Result body lost its reading offset during streamed conversation rebuild');await cap('02-remounted-reader-position');report.checks.push('Streamed thinking remount preserves tool-result and outer reading offsets');
 before=now;await sendBody(-100000);now=await sameOuter(before);assert(now.content.y<before.content.y-20);const bottom=now.content.y;await sendBody(-50);now=await sameOuter(before);assert(Math.abs(now.content.y-bottom)<.1);report.checks.push('Wheel crossing and pushing the bottom boundary stays contained');
 await sendBody(100000);now=await sameOuter(before);const top=now.content.y;await sendBody(50);now=await sameOuter(before);assert(Math.abs(now.content.y-top)<.1);report.checks.push('Wheel crossing and pushing the top boundary stays contained');
 await sendBody(-1);const detailNode=await visible('ai.tool.result.details'),bar=detailNode.children[1].rect;assert(bar.w>0&&bar.h>0,'Native vertical scrollbar should be available');const dragBefore=await snapshot();await h.mouseDown(bar.x+bar.w/2,bar.y+bar.h/2);await h.mouseMove(bar.x+bar.w/2,bar.y+bar.h/2+20);await h.mouseUp(bar.x+bar.w/2,bar.y+bar.h/2+20);await h.sleep(60);now=await sameOuter(dragBefore);assert(now.content.y<dragBefore.content.y-20);report.checks.push('Native scrollbar drag moves the inner card and leaves the conversation fixed');
 await click('ai.tool.result.copy_stdout');const copied=(await promisify(execFile)('/usr/bin/pbpaste',[],{encoding:'utf8'})).stdout;assert(copied.includes('binding_ref')&&copied.includes('conversation_id'));report.checks.push('Result copy preserves the full original structured result');before=await snapshot();

 await sendBody(0,{phase:'may_begin'});await sendBody(-40,{phase:'began'});await sendBody(-1000,{phase:'changed'});await sendBody(-30,{phase:'changed'});await sendBody(0,{phase:'ended'});await sendBody(-30,{momentum:'began'});await sendBody(-15,{momentum:'changed'});await sendBody(0,{momentum:'ended'});await h.sleep(700);await sameOuter(before);await cap('03-trackpad-bottom');report.checks.push('Phased trackpad and momentum stay in the long body at the boundary');
 await scrollOuter(-45);now=await snapshot();assert(now.card.y<before.card.y-20);report.checks.push('Pointer outside the card still scrolls the conversation');await cap('04-outer-scroll');
 await scrollOuter(100000);await click('ai.tool.result.header');await h.sleep(350);assert((await rect('ai.tool.result.header')).h===32);await click('ai.tool.result.header');await h.sleep(350);assert((await rect('ai.tool.result.details')).h===150);report.checks.push('Collapse and expand remain interactive');
 held.end('data: [DONE]\n\n');held=null;await visible('ai.turn.complete');await cap('05-completed');report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await cap('failure').catch(()=>{})}
finally{
 if(held)held.end();server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));
 if(app.exitCode===null&&app.signalCode===null){try{await h.request('POST','/quit');await h.waitFor(async()=>app.exitCode!==null||app.signalCode!==null||null,10000)}catch(error){report.shutdown_error=String(error);app.kill('SIGTERM')}}
 report.shutdown=await ended;await log.close();report.requests=requests;await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(JSON.stringify(report,null,2));
