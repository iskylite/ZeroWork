/** Production Local file tools + native transcript images, with an owned HTTP
 * model fixture. No external model, user configuration, credentials or SFTP.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,writeFile,readFile,copyFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';

const out=resolve(process.argv[2]??'/tmp/zerowork-terminal-files-verification/native');
const binary=resolve(process.argv[3]??'zig-out/bin/zerowork');
const ssh=process.argv[4]==='ssh';
const fault=process.argv[5]??'none';assert(fault==='none'||ssh);
await mkdir(out,{recursive:true});
const isolated=await realpath(await mkdtemp('/tmp/zw-terminal-files-native-'));
const data=join(isolated,'data'),rpc=join(isolated,'rpc');await mkdir(data);await mkdir(rpc);
const target=join(isolated,"config 'quoted'.toml"),largeTarget=join(isolated,'full-size.txt'),picture=join(isolated,'report.png');
await copyFile('assets/macos/AiAssistant.png',picture);
let peer:any=null,peerLog:any=null;
const peerDir=ssh?await mkdtemp(join(out,'peer-')):null;
if(ssh){
 peerLog=await open(join(out,'peer.log'),'w');
 peer=spawn(process.env.ZW_TEST_PYTHON??'python3',['e2e/terminal_files_ssh_peer.py','--out',peerDir!,'--root',isolated,'--fault',fault],{stdio:['ignore',peerLog.fd,peerLog.fd]});
 const ready=await h.waitFor(async()=>{try{return JSON.parse(await readFile(join(peerDir!,'ready.json'),'utf8'))}catch{return null}},15000);
 await writeFile(join(data,'known_hosts'),ready.known_host);
 await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="Terminal files SSH"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\noptions={strict_host_key=true}\n`);
}
const requests:any[]=[];let turn=0,step=0;
const frame=(delta:any,finish:any=null)=>'data: '+JSON.stringify({choices:[{index:0,delta,finish_reason:finish}]})+'\n\n';
function findVersion(value:any):string|null {
 if(typeof value==='string'){try{return findVersion(JSON.parse(value))}catch{return null}}
 if(!value||typeof value!=='object')return null;
 if(typeof value.version==='string'&&value.version.length===64&&value.text==='port=8080\n')return value.version;
 for(const child of Object.values(value)){const found=findVersion(child);if(found)return found}return null;
}
const server=createServer(async(req,res)=>{
 try{
  if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'terminal-file-fixture',context_window:200000}]}));return}
  let raw='';for await(const chunk of req)raw+=chunk;const body=JSON.parse(raw);requests.push(body);
  assert(!raw.includes('data:image/'),'UI pixels must never enter model input');
  for(const message of body.messages) if(Array.isArray(message.content)) assert(message.content.every((block:any)=>!['image_url','input_image','image'].includes(block.type)));
  res.writeHead(200,{'content-type':'text/event-stream'});
  if(!body.tools?.length){res.end(frame({content:'终端文件验收'},'stop')+'data: [DONE]\n\n');return}
  const lastUser=body.messages.filter((m:any)=>m.role==='user').at(-1)?.content;
  if(lastUser==='继续验证上下文'){turn=2;res.end(frame({content:'上下文仍然只包含文字与图片路径。'},'stop')+'data: [DONE]\n\n');return}
  turn=1;
  if(fault!=='none'&&step>0){res.end(frame({content:'已保留本次调用的实际结果，不重试写入。'},'stop')+'data: [DONE]\n\n');return}
  const functions=body.tools.map((t:any)=>t.function);
  const name=step===0||step===3?'file__write_utext':step===1?'file__read_utext':step===2?'file__edit_utext':null;
  if(name){
   const tool=functions.find((f:any)=>f.name===name);assert(tool,`Missing ${name}`);
   const ids=tool.parameters.properties.session_ids.items.enum;assert(ids?.length===1);
   const args:any={session_ids:ids,path:target};
   if(step===0)args.text='port=8080\n';
   if(step===3){args.path=largeTarget;args.text='"'.repeat(65536);assert(JSON.stringify(args).length>65536)}
   if(step===2){args.expected_version=findVersion(body.messages.filter((m:any)=>m.role==='tool').at(-1));assert(args.expected_version);args.edits=[{old_text:'8080',new_text:'9090'}]}
   const id=`file-fixture-${++step}`;
   res.end(frame({tool_calls:[{index:0,id,type:'function',function:{name,arguments:JSON.stringify(args)}}]},'tool_calls')+'data: [DONE]\n\n');
  }else{
   const toolResult=JSON.stringify(body.messages.filter((m:any)=>m.role==='tool').at(-1));assert(toolResult.includes('committed'));
   res.end(frame({content:`文件已更新。\n\n![诊断图片](<${picture}>)\n\n\`\`\`md\n![代码中的引用不加载](/missing.png)\n\`\`\``},'stop')+'data: [DONE]\n\n');
  }
 }catch(error){res.destroy(error as Error)}
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ssh]\nauto_shell_integration=false\n[ai]\ndefault_provider="terminal-files"\npermission_mode="confirm"\n[[ai.providers]]\nid="terminal-files"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="terminal-file-fixture"\ncontext_window=200000\ndefault=true\nreasoning=false\nvision=${process.env.ZW_TEST_VISION==='1'}\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{cwd:process.cwd(),env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,20000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const capture=async(name:string)=>{assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2))};
const submit=async(text:string)=>{await click('ai.prompt');await h.type_(text);await click('ai.send')};
const report:any={status:'running',binary,isolated,transport:ssh?'ssh-exec':'local',fault,vision:process.env.ZW_TEST_VISION==='1',checks:[],input:'synthetic public Harness; screenshots are actual native Metal pixels'};
try{
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1200,1000);await click(ssh?'sidebar.host':'workspace.empty.local');if(ssh)await click('sidebar.host.connect');await visible('terminal.surface');await h.sleep(1500);await click('toolbar.ai');
 await submit('执行文件与图片展示验收');
 await visible('ai.approval');await assert.rejects(readFile(target));await capture('01-create-approval');await click('ai.approval.accept');
 if(fault!=='none'){
  if(fault.startsWith('cancel-')){
   await h.waitFor(async()=>{try{return JSON.parse(await readFile(join(peerDir!,'audit.json'),'utf8')).write_waiting>0||null}catch{return null}},15000);
   await click('ai.stop');
  }
  const facts=await h.waitFor(async()=>{const lines=(await readFile(join(out,'app.log'),'utf8')).split('\n');for(const line of lines){const prefix='AI_TOOL_TRACE ';const pos=line.indexOf(prefix);if(pos<0)continue;try{const event=JSON.parse(line.slice(pos+prefix.length));if(event.event!=='tool_feedback'||event.call_id!=='file-fixture-1')continue;const feedback=JSON.parse(event.content);for(const item of feedback.targets??[])for(const block of item.content??[]){if(block.type!=='structured')continue;const v=JSON.parse(block.text);if(v.path===target)return v}}catch{}}return null},20000);
  const known=fault==='cancel-after-commit';assert.equal(facts.committed,known);assert.equal(facts.verified,false);assert.equal(facts.outcome_unknown,!known);assert.equal(facts.version,null);
  if(fault==='cancel-before-commit')await assert.rejects(readFile(target));else assert.equal(await readFile(target,'utf8'),'port=8080\n');
  const audit=JSON.parse(await readFile(join(peerDir!,'audit.json'),'utf8'));assert.equal(audit.exec_writes,1,'uncertain writes must never be retried');assert.equal(audit.shell_input_bytes,0);assert.equal(audit.sftp_requests,0);assert.deepEqual(audit.errors,[]);
  report.facts=facts;report.ssh_audit=audit;report.checks.push('Actual SSH fault preserves commit evidence/unknown outcome, performs no automatic retry, and injects no PTY input');await capture('02-fault-result');
 }else{
 await h.waitFor(async()=>step===3||null,15000);await visible('ai.approval');
 assert.equal(await readFile(target,'utf8'),'port=8080\n');
 const diff=await visible('ai.approval.command');assert(diff.text.includes('− 8080')&&diff.text.includes('+ 9090'));
 const diffViewport=await visible('ai.approval.command_scroll');assert(diff.rect.h<=diffViewport.rect.h,'short edit must show both old and new text without scrolling');
 await capture('02-edit-approval');await click('ai.approval.accept');
 await h.waitFor(async()=>step===4||null,15000);await visible('ai.approval');await assert.rejects(readFile(largeTarget));await click('ai.approval.accept');
 await visible('ai.transcript.image.raster');assert.equal(await readFile(target,'utf8'),'port=9090\n');
 assert.equal((await readFile(largeTarget)).length,65536,'full file passes streaming and subsequent provider serialization limits');
 assert.equal(await readFile(largeTarget,'utf8'),'"'.repeat(65536),'JSON escaping preserves every file byte');
 const fileTargets=await h.query('ai.tool.result.command');assert(fileTargets.length>=4);assert(fileTargets.every((n:any)=>n.text===target||n.text===largeTarget),'file history renders target paths while retaining original arguments');
 assert.equal((await h.query('ai.transcript.image')).length,1,'fenced Markdown does not load an image');
 const raster=await visible('ai.transcript.image.raster');assert(Math.abs(raster.rect.w-raster.rect.h)<1);assert(raster.rect.h<=240.5);
 await click('ai.maximize');await h.sleep(250);await capture('03-image-ready');report.checks.push(`Create/read/edit and a full 65536-byte file use actual approved ${ssh?'SSH exec':'Local'} tools; PNG renders with preserved aspect ratio in a text-only model conversation`);
 const before=requests.length;await click('ai.transcript.image.open');await visible('ai.image.preview.panel');await capture('04-image-preview');await h.key('escape');assert.equal(requests.length,before);
 await writeFile(picture,'invalid image');await click('ai.transcript.image.reload');
 await h.waitFor(async()=>{const n=(await h.query('ai.transcript.image.status')).find(shown);return n?.text==='不支持此图片格式或动画'?n:null},15000);await capture('05-image-failure');
 await copyFile('assets/macos/AiAssistant.png',picture);await click('ai.transcript.image.reload');await visible('ai.transcript.image.raster');assert.equal(requests.length,before);report.checks.push('Open/reload/error/retry perform no model requests');
 await submit('继续验证上下文');await h.waitFor(async()=>turn===2&&!(await h.query('ai.stop')).some(shown)||null,15000);
 assert(requests.length>before);assert(JSON.stringify(requests.at(-1).messages).includes(picture));await capture('06-text-only-followup');report.checks.push('Subsequent provider request contains the path and no image payload');
 if(ssh){const audit=JSON.parse(await readFile(join(peerDir!,'audit.json'),'utf8'));assert(audit.exec_reads>=7&&audit.exec_writes===3);assert(audit.stdin_bytes>=65536);assert.equal(audit.sftp_requests,0);assert.equal(audit.shell_input_bytes,0);assert.deepEqual(audit.errors,[]);report.ssh_audit=audit}
 }
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await capture('failure').catch(()=>{});}
finally{
 server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));
 app.kill('SIGTERM');await Promise.race([new Promise(done=>app.once('close',done)),h.sleep(3000)]);if(app.exitCode===null&&app.signalCode===null)app.kill('SIGKILL');
 if(peer){peer.kill('SIGTERM');await Promise.race([new Promise(done=>peer.once('close',done)),h.sleep(3000)]);if(peer.exitCode===null&&peer.signalCode===null)peer.kill('SIGKILL');await peerLog.close()}
 await log.close();await writeFile(join(out,'requests.json'),JSON.stringify(requests,null,2));await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(JSON.stringify(report));
