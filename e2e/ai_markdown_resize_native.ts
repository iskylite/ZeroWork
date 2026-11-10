/** Retained Markdown geometry through float drag, maximize and window resize.
 * Build: zig build -Dtest-mode=true --prefix /tmp/zw-markdown-resize-build -j2
 * Run: ZW_AI_TEST_PREFIX=/tmp/zw-markdown-resize-build node e2e/ai_markdown_resize_native.ts <out>
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-markdown-resize-build');
const binary=join(prefix,'bin/zerowork');
const out=resolve(process.argv[2]??'/tmp/zw-markdown-resize-evidence');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-markdown-resize-'));
const data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
const frame=(content:string)=>'data: '+JSON.stringify({choices:[{index:0,delta:{content}}]})+'\n\n';
const answer='## 本轮实际发生了什么\n\n| # | 动作 | 回执 | 结论 |\n| --- | --- | --- | --- |\n'+
 '| 1 | 只读检查：pwd/ls、KVM、libvirt、磁盘与网络 | `cancelled_unsent,error_code=requires_plan_change,side_effect_started=false` | 未派发，保留完整回执以便核对。 |\n'+
 '| 2 | 通过终端执行同一段探查 | `status=outcome_unknown,error_code=TargetNotAuthorized,side_effect_started=true` | 结果未知，需要核对执行状态。 |\n\n'+
 '窗口尺寸变化后，**表格列宽**、正文换行和后续内容位置应立即更新。\n';
let held:any=null,requests=0;
const server=createServer(async(req,res)=>{
 let raw='';for await(const part of req)raw+=part;
 if(req.method!=='POST')return res.end('{"data":[{"id":"resize-fixture"}]}');
 res.writeHead(200,{'content-type':'text/event-stream'});
 if(!JSON.parse(raw).tools?.length)return res.end(frame('Markdown 缩放检查')+'data: [DONE]\n\n');
 requests++;res.write(frame(answer));held=res;
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="light"\n[ai]\ndefault_provider="fixture"\n[[ai.providers]]\nid="fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="resize-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const alive=()=>app.exitCode===null&&app.signalCode===null;
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const report:any={status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),isolation:iso,checks:[],geometry:[]};
const geometry=async(name:string,expectedId?:number)=>{
 const table=await h.waitFor(async()=>{
  const table=(await h.query('ai.message.table')).find(shown);if(!table)return null;
  const content=table.children[0];return Math.abs(content.rect.w-Math.max(400,table.rect.w))<.5?table:null;
 },10000);
 if(expectedId!==undefined)assert.equal(table.id,expectedId,'Resize must retain the table tree');
 const widths=table.children[0].children[0].children.map((cell:any)=>cell.rect.w);
 assert(widths[0]<=60,'Number column should stay compact');
 assert(widths[2]>widths[1]&&widths[2]>widths[3],'Long receipt column should receive more space');
 for(const row of table.children[0].children)for(const [column,cell] of row.children.entries()){
  assert(Math.abs(cell.rect.w-widths[column])<.5,'Columns must align across rows');
  assert(Math.abs(cell.rect.h-row.rect.h)<.5,'Cell borders must share the row height');
 }
 report.geometry.push({name,id:table.id,viewport:table.rect,content:table.children[0].rect,widths});
 assert((await h.screenshot(join(out,name+'.png'))).ok);
 await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2));
 return table;
};
try{
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1440,1000);await click('workspace.empty.local');await click('toolbar.ai');
 await click('ai.prompt');await h.type_('检查 Markdown 窗口缩放');await click('ai.send');
 const initial=await geometry('01-streaming-small');
 const edge=await visible('ai.float.resize.e'),x=edge.rect.x+edge.rect.w/2,y=edge.rect.y+edge.rect.h/2;
 await h.mouseDown(x,y);await h.mouseMove(x+260,y);await h.mouseUp(x+260,y);
 await h.waitFor(async()=>(await visible('ai.panel')).rect.w>800||null,5000);
 const dragged=await geometry('02-streaming-dragged',initial.id);assert(dragged.rect.w>initial.rect.w+200);
 held.end(frame('\n```sh\nprintf "'+ 'long_argument_'.repeat(18)+'"\n```\n\n后续正文。')+'data: [DONE]\n\n');held=null;
 await visible('ai.turn.complete');
 const complete=await geometry('03-completed');
 await click('ai.maximize');const wide=await geometry('04-maximized');assert(wide.rect.w>dragged.rect.w);
 await h.resizeWindow(860,600);const compact=await geometry('05-window-compact');assert(compact.rect.w<wide.rect.w);
 await h.resizeWindow(1440,1000);await geometry('06-window-restored');
 await click('ai.maximize');await geometry('07-float-restored');
 await click('ai.collapse');await click('toolbar.ai');await geometry('08-reopened');
 assert.equal(requests,1);report.checks.push('Streaming and completed tables follow actual width through edge drag, maximize, host window resize, restore and reopen without additional provider requests');
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await h.screenshot(join(out,'failure.png')).catch(()=>{});}
finally{
 if(held){held.end('data: [DONE]\n\n');held=null;}
 try{if(alive()){
  await h.request('POST','/zerowork/windows',{action:'quit'});
  await Promise.race([ended,h.sleep(1000)]);
  const start=performance.now();while(alive()&&performance.now()-start<15000){
   for(const id of ['groups.close.accept','local.close.accept','session.close.accept'])try{if(!alive())break;if((await h.query(id)).some(shown))await h.clickTestId(id)}catch{}
   await Promise.race([ended,h.sleep(80)]);
  }
 }}catch(error){report.quit_error=String(error);}
 if(alive()){report.forced=true;app.kill('SIGTERM');await ended;}
 report.exit_code=app.exitCode;if(report.forced||app.exitCode!==0){report.status='failed';process.exitCode=1;}
 server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();
 if(/leaked \[addr:|panic:|double free|use.after.free/i.test(await readFile(join(out,'app.log'),'utf8'))){report.status='failed';report.memory_error=true;process.exitCode=1;}
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}));
}
