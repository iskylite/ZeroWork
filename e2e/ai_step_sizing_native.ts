/** Step disclosure sizing against a local SSE fixture and real Local commands. */
import {fixtureSessionIds} from './ai_fixture_discovery.ts';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'/tmp/zw-step-sizing');await mkdir(out,{recursive:true});
const manifest=JSON.parse(await readFile('dist/ui-check-build.json','utf8'));
const iso=await realpath(await mkdtemp('/tmp/zw-step-sizing-')),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
let mode='thinking',held:any=null;
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const server=createServer(async(req,res)=>{
 if(req.method!=='POST'){res.end(JSON.stringify({data:[{id:'step-fixture',context_window:200000}]}));return}
 let bytes='';for await(const c of req)bytes+=c;const body=JSON.parse(bytes);
 res.writeHead(200,{'content-type':'text/event-stream'});
 if(mode==='thinking'){res.write(frame({reasoning_content:'用户用中文询问我的身份。'}));held=res;return}
 if(!body.messages.slice(body.messages.findLastIndex((m:any)=>m.role==='user')+1).some((m:any)=>m.role==='tool'&&m.tool_call_id?.startsWith('sizing-'))){
  const ids=fixtureSessionIds(body,res);if(!ids)return;const id=ids[0];
  const command=mode==='empty'?'true':mode==='long'?"printf 'OUTPUT_LINE\\n%.0s' {1..30}":'printf SHORT_OUTPUT';
  res.end(frame({tool_calls:[{index:0,id:'sizing-'+mode,type:'function',function:{name:'run_command',arguments:JSON.stringify({session_ids:[id],command})}}]})+'data: [DONE]\n\n');return;
 }
 res.end(frame({content:'验证完成。'})+'data: [DONE]\n\n');
});
await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="step-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(manifest.bundle_path,'Contents/MacOS/ZeroWork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const header=async(id:string)=>{const n=await visible(id);assert((await h.clickAt(n.rect.x+100,n.rect.y+16)).ok)};
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,15000);
const cap=async(name:string)=>{await h.sleep(200);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2))};
const send=async()=>{await click('ai.prompt');await h.key('a',{cmd:true});await h.type_('检查步骤展开布局');await click('ai.send')};
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const resultCard=()=>h.waitFor(async()=>flat(await h.query('ai.panel')).find((n:any)=>/^ai\.tool\.result\.\d+\./.test(n.test_id??'')&&shown(n))??null,15000);
const report:any={status:'running',checks:[],heights:{},isolated:iso};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1200,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.maximize');
 await send();await visible('ai.thinking');await header('ai.thinking');
 await h.waitFor(async()=>Math.abs((await visible('ai.thinking')).rect.h-58)<1||null,5000);
 assert.equal((await h.query('ai.step.copy')).length,0);report.heights.shortThought=(await visible('ai.thinking')).rect.h;await cap('01-short-thinking');
 held.write(frame({reasoning_content:'\n'+Array.from({length:30},(_,i)=>`思考内容第 ${i+1} 行`).join('\n')}));
 await h.waitFor(async()=>(await visible('ai.thinking')).rect.h===182||null,5000);
 assert((await visible('ai.step.detail')).rect.h>150);report.heights.longThought=(await visible('ai.thinking')).rect.h;await cap('02-long-thinking');
 const body=await visible('ai.step.details'),before=(await visible('ai.step.detail')).rect.y;
 await h.scrollAt(body.rect.x+body.rect.w/2,body.rect.y+body.rect.h/2,0,-1000);
 await h.waitFor(async()=>(await visible('ai.step.detail')).rect.y<before||null,5000);
 held.end(frame({content:'验证完成。'})+'data: [DONE]\n\n');held=null;await absent('ai.stop');
 await header('ai.thinking');assert.equal((await visible('ai.thinking')).rect.h,32);report.checks.push('Thought: 58px short, capped at 182px long, scrolls, collapses to 32px, no Copy node');
 for(const kind of ['short','empty','long']){
  mode=kind;await click('ai.session.new');await send();await visible('ai.approval');await click('ai.approval.accept');await absent('ai.stop');await resultCard();await header('ai.tool.result.disclosure');
  await visible('ai.tool.result.details');await h.sleep(150);const card=await resultCard();report.heights[kind]=card.rect.h;assert(card.rect.h<=216);
  if(kind==='empty'){assert(card.rect.h<216);assert(!(await h.query('ai.tool.result.copy_stdout')).some(shown));assert(!(await h.query('ai.tool.result.copy_stderr')).some(shown))}
  if(kind==='short'){assert.equal((await visible('ai.tool.result.stdout')).text,'SHORT_OUTPUT');await click('ai.tool.result.copy_stdout');await click('ai.prompt');await h.key('v',{cmd:true});assert.equal((await h.inputState('ai.prompt')).buffer,'SHORT_OUTPUT')}
  if(kind==='long'){
   const viewport=await visible('ai.tool.result.details'),output=await visible('ai.tool.result.stdout_scroll');assert(output.rect.h>viewport.rect.h);assert((await visible('ai.tool.result.stdout')).rect.h>=480);
   const y=output.rect.y;await h.scrollAt(viewport.rect.x+viewport.rect.w/2,viewport.rect.y+viewport.rect.h/2,0,-1000);
   await h.waitFor(async()=>(await visible('ai.tool.result.stdout_scroll')).rect.y<y||null,5000);
  }
  await cap('03-tool-'+kind);await header('ai.tool.result.disclosure');assert.equal((await resultCard()).rect.h,32);
 }
 report.checks.push('Real Local short/empty/30-line results fit within 216px; empty result shrinks and hides copy actions; stdout copy preserves text; long output scrolls in outer body');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await cap('failure').catch(()=>{});process.exitCode=1}
finally{if(held)held.end();server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));app.kill('SIGTERM');if(app.exitCode===null&&app.signalCode===null)await new Promise(r=>app.once('close',r));await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2))}
console.log(JSON.stringify(report));
