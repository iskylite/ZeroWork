/** Expanded thinking follows streamed updates and preserves deliberate reader scroll. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'dist/ui-acceptance/ai-thinking-scroll');await mkdir(out,{recursive:true});
const manifest=JSON.parse(await readFile('dist/ui-check-build.json','utf8'));
const binary=process.argv[3]??join(manifest.bundle_path,'Contents/MacOS/ZeroWork');
const isolated=await realpath(await mkdtemp('/tmp/zw-thinking-scroll-')),data=join(isolated,'data'),rpc=join(isolated,'rpc');await mkdir(data);await mkdir(rpc);
let held:any=null;
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const server=createServer(async(req,res)=>{
 if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'thinking-fixture',context_window:200000}]}));return;}
 for await(const _ of req){};
 res.writeHead(200,{'content-type':'text/event-stream'});res.write(frame({reasoning_content:'开始核对问题。\n'}));held=res;
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="thinking-fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="thinking-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="thinking-fixture"\ncontext_window=200000\ndefault=true\nreasoning=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const geometry=async()=>({viewport:(await visible('ai.step.details')).rect,text:(await visible('ai.step.detail')).rect});
const tail=async()=>h.waitFor(async()=>{const g=await geometry(),gap=g.viewport.y+g.viewport.h-g.text.y-g.text.h;return gap>=-.5&&gap<=12?g:null},10000);
const cap=async(name:string)=>{assert((await h.screenshot(join(out,`${name}.png`))).ok);await writeFile(join(out,`${name}.json`),JSON.stringify(await h.query('ai.panel'),null,2))};
let line=0;
const append=(count:number)=>held.write(frame({reasoning_content:Array.from({length:count},()=>`思考第 ${++line} 行：分析请求与流式更新。`).join('\n')+'\n'}));
const grew=async(before:any)=>h.waitFor(async()=>{const g=await geometry();return g.text.h>before.text.h+50?g:null},10000);
const toggle=async()=>{const card=await visible('ai.thinking');assert((await h.clickAt(card.rect.x+90,card.rect.y+16)).ok)};
const report:any={status:'running',binary,isolated,checks:[]};
try{
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1200,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.prompt');await h.type_('检查展开的思考内容自动滚动。');await click('ai.send');await visible('ai.thinking');
 append(30);await h.waitFor(async()=>(await visible('ai.step.projection')).text?.startsWith('思考第 30 行')||null,10000);await toggle();await tail();await cap('01-expanded-tail');
 report.checks.push('Opening long thinking shows the latest lines');
 let before=await geometry();append(10);await grew(before);await tail();await cap('02-streamed-tail');
 report.checks.push('Expanded thinking follows new streamed content across view rebuilds');
 let g=await geometry();await h.scrollAt(g.viewport.x+50,g.viewport.y+g.viewport.h/2,0,80);
 await h.waitFor(async()=>{const v=await geometry();return v.text.y>g.text.y+20?v:null},5000);
 before=await geometry();const offset=before.viewport.y-before.text.y;append(10);await grew(before);g=await geometry();assert(Math.abs(g.viewport.y-g.text.y-offset)<1);await cap('03-reader-paused');
 report.checks.push('Manual upward scroll pauses following and preserves the reading position');
 await h.scrollAt(g.viewport.x+50,g.viewport.y+g.viewport.h/2,0,-100000);report.resumed=await tail();before=await geometry();append(10);await grew(before);await tail();
 report.checks.push('Scrolling to the bottom resumes following');
 await toggle();await h.waitFor(async()=>((await visible('ai.thinking')).rect.h<33)||null,5000);append(10);await h.waitFor(async()=>(await visible('ai.step.projection')).text?.startsWith(`思考第 ${line} 行`)||null,10000);await toggle();await tail();await cap('04-reopened-tail');
 report.checks.push('Collapsing during streaming and reopening retains the latest position');
 held.end(frame({content:'检查完成。'})+'data: [DONE]\n\n');held=null;await visible('ai.turn.complete');await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,15000);await tail();await cap('05-completed-tail');
 report.checks.push('Completing the turn preserves expanded thinking and its scroll position');report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await cap('failure').catch(()=>{});}
finally{if(held)held.end();server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));app.kill('SIGTERM');if(app.exitCode===null&&app.signalCode===null)await new Promise(done=>app.once('close',done));await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
console.log(JSON.stringify(report));
