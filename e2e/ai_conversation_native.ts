/** Native AI turn UX against an owned local SSE fixture and actual Local tools. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,open,copyFile,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'dist/ui-acceptance/ai-conversation-revision-20261027');await mkdir(out,{recursive:true});
const manifest=process.env.ZW_AI_TEST_BINARY?{binary:resolve(process.env.ZW_AI_TEST_BINARY)}:JSON.parse(await readFile('dist/ui-check-build.json','utf8'));
const binary=manifest.binary??join(manifest.bundle_path,'Contents/MacOS/ZeroWork');
await writeFile(join(out,'build-manifest.json'),JSON.stringify(manifest,null,2));
const isolated=await realpath(await mkdtemp('/tmp/zw-ai-turns-')),data=join(isolated,'data'),rpc=join(isolated,'rpc');await mkdir(data);await mkdir(rpc);
let mode='first',requests:any[]=[],held:any=null,planning:any=null;
let fixtureError: Error | null = null;
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const usage=(input:number,output:number)=>'data: '+JSON.stringify({choices:[],usage:{prompt_tokens:input,completion_tokens:output}})+'\n\n';
const marker='AI_TURN_ACTUAL_OUTPUT';
const command=`sleep 4; printf ${marker}`;
const server=createServer(async(req,res)=>{
 if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'turn-fixture',context_window:200000}]}));return;}
 res.writeHead(200,{'content-type':'text/event-stream'});
 try {
   let bytes = '';
   for await (const chunk of req) bytes += chunk;
   const body = JSON.parse(bytes);
   if (!body.tools?.length) {
     res.end(frame({content:'系统检查'}) + 'data: [DONE]\n\n');
     return;
   }
   requests.push({mode,messages:body.messages});
   const userIndex = body.messages.findLastIndex((message: any) => message.role === 'user');
   const question = body.messages[userIndex]?.content ?? '';
   const results = body.messages.slice(userIndex + 1).filter((message: any) => message.role === 'tool');
   if (mode === 'first') {
     if (results.length === 0) {
       const tool = body.tools.find((entry: any) => entry.function.name === 'run_command');
       assert(tool, 'The provider catalog must advertise run_command');
       const id = tool.function.parameters.properties.session_ids.items.enum?.[0];
       assert(Number.isSafeInteger(id) && id > 0, 'The provider catalog must advertise a valid Local session ID');
       res.flushHeaders();
       planning = {res, args: JSON.stringify({session_ids: [id], command})};
       return;
     }
     const result = results.find((message: any) => message.tool_call_id === 'native-call-first');
     assert(result?.content.includes(marker), 'The approved Local command must return its stdout marker');
     res.write(frame({content:'## 系统检查\n\n| 项目 | 值 |\n| --- | --- |\n| 命令 | **成功** |\n'}));
     held = res;
     return;
   }
   if (mode === 'invalid') {
     if (results.length === 0) {
       res.end(frame({tool_calls:[{index:0,id:'native-invalid-args',type:'function',function:{name:'run_command',arguments:'{}'}}]}) + 'data: [DONE]\n\n');
       return;
     }
     const rejected = results.find((message: any) => message.tool_call_id === 'native-invalid-args');
     assert(rejected, 'The provider must receive the invalid call result');
     assert.equal(JSON.parse(rejected.content).error_code, 'InvalidToolArguments');
     res.write(frame({content:'工具参数无效，继续分析。'}));
     held = res;
     return;
   }
   if (mode === 'second') {
     res.end(frame({content:'第二回合正式输出。'}) + usage(90,10) + 'data: [DONE]\n\n');
     return;
   }
   if (mode === 'rewind') {
     res.end(frame({content:'回退后的正式输出。'}) + usage(110,20) + 'data: [DONE]\n\n');
     return;
   }
   res.end(frame({content:`分叉后的答复：${question}`}) + 'data: [DONE]\n\n');
 } catch (error) {
   fixtureError = error instanceof Error ? error : new Error(String(error));
   res.end('data: [DONE]\n\n');
 }
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="turn-fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="turn-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="turn-fixture"\ncontext_window=200000\ndefault=true\nvision=true\nimage_token_reservation=8192\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const nodeText=(n:any):string=>n?.text??(n?.children??[]).map(nodeText).join('');
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=async(id:string)=>{report.last_query=id;return h.waitFor(async()=>{assert.ifError(fixtureError);return (await h.query(id)).find(shown)??null},15000)};
const absence=async(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,20000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const cap=async(name:string)=>{assert((await h.screenshot(join(out,`${name}.png`))).ok);await writeFile(join(out,`${name}.json`),JSON.stringify(await h.query('ai.panel'),null,2))};
const send=async(text:string)=>{await click('ai.prompt');await h.key('a',{cmd:true});await h.type_(text);assert.equal((await h.inputState('ai.prompt')).buffer,text);await click('ai.send')};
const report:any={status:'running',isolated,binary,checks:[],limits:['Local SSE fixture verifies native event delivery and actual Local tool output; no external model was used.','Synthetic keyboard checks do not establish physical IME behavior.']};
try{
 await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1440,1000);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await visible('ai.prompt');await click('ai.maximize');
 // Attach a real image using the same drop path as the composer.
 const prompt=await visible('ai.prompt'),image=resolve('assets/macos/AppIcon.png');await h.dragAt(prompt.rect.x+20,prompt.rect.y+20,0,image);await h.dragAt(prompt.rect.x+20,prompt.rect.y+20,3,image);await visible('ai.image');
 const beforeSend=new Date();await send('第一回合：检查系统，并保留图片。');const afterSend=new Date();await visible('ai.turn.running');assert.equal(nodeText(await visible('ai.turn.label')),'～大浪淘金中～');
 const waveBefore=await h.query('ai.turn.wave.glyph');assert.equal(waveBefore.length,7);await cap('00-wave-a');
 await h.waitFor(async()=>{const glyphs=await h.query('ai.turn.wave.glyph');return glyphs.some((n:any,i:number)=>Math.abs(n.rect.y-waveBefore[i].rect.y)>.15)||null},3000);await cap('00-wave-b');report.checks.push('Running text has a subtle per-character wave while the 16px logo remains still');
 const firstElapsed=(await visible('ai.turn.elapsed')).text;await h.waitFor(async()=>(await visible('ai.turn.elapsed')).text!==firstElapsed||null,3000);
 assert.equal((await h.query('ai.turn.copy')).filter(shown).length,0);assert(planning);await cap('00-running-before-deltas');
 planning.res.write(frame({reasoning_content:'核对本地时间，并读取受控命令输出。'}));
 await visible('ai.step_group.header');
 assert(!(await h.query('ai.thinking')).some(shown), 'Thinking details start collapsed');
 await click('ai.step_group.header');
 assert(nodeText(await visible('ai.thinking')).includes('核对本地时间'));
 const midpoint=Math.floor(planning.args.length/2);planning.res.write(frame({tool_calls:[{index:0,id:'native-call-first',type:'function',function:{name:'run_command',arguments:planning.args.slice(0,midpoint)}}]}));
 assert.equal((await h.query('ai.interaction.panel')).filter(shown).length,0);await cap('00-tool-assembling');
 planning.res.end(frame({tool_calls:[{index:0,function:{arguments:planning.args.slice(midpoint)}}]})+usage(11,7)+'data: [DONE]\n\n');planning=null;
 report.checks.push('Lifecycle row appears before provider output and advances time; opening the step group reveals the streamed reasoning');
 const clock=(date:Date)=>new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Shanghai',hour:'2-digit',minute:'2-digit',hour12:false}).format(date);
 const timestamp=(await visible('ai.message.timestamp')).text;assert([clock(beforeSend),clock(afterSend)].includes(timestamp));report.checks.push('User timestamp matches the actual submit minute in the system timezone');
 const pending=await visible('ai.interaction.panel'),transcript=await visible('ai.conversation.viewport');
 const attachmentRail=await visible('ai.message.attachments'),sentBubble=await visible('ai.message.user.bubble');assert(attachmentRail.rect.y+attachmentRail.rect.h<=sentBubble.rect.y+.5);assert(sentBubble.rect.y-(attachmentRail.rect.y+attachmentRail.rect.h)<=6);report.checks.push('Sent attachment snapshot is adjacent above its user bubble');
 assert(transcript.rect.y+transcript.rect.h<=pending.rect.y+.5,'Pending approval is below the transcript viewport');
 assert.equal(nodeText(await visible('ai.interaction.command')),command);
 await visible('ai.interaction.target');await visible('ai.interaction.impact.note');
 const accept=await visible('ai.interaction.approve'),reject=await visible('ai.interaction.reject');
 assert.equal(accept.rect.h,reject.rect.h);assert(Math.abs(accept.rect.y-reject.rect.y)<.5);
 await absence('ai.stop');
 report.checks.push('The composer shows the pending command, target, impact notice and aligned approval actions while execution is paused');
 await cap('01-pending-approval');
 await h.resizeWindow(860,480);
 const compactApproval=await visible('ai.interaction.panel'),compactTranscript=await visible('ai.conversation.viewport');
 assert(compactTranscript.rect.y+compactTranscript.rect.h<=compactApproval.rect.y+.5);
 await visible('ai.interaction.approve');await visible('ai.interaction.reject');
 assert.equal(requests.length,1,'The provider does not continue while approval is pending');
 const started='"event":"exec_started"';
 assert(!(await readFile(join(out,'app.log'),'utf8')).includes(started),'No command starts before approval');
 await cap('01-compact-approval');
 await h.resizeWindow(1440,1000);
 await click('ai.interaction.approve');await absence('ai.interaction.panel');await visible('ai.stop');
 await h.waitFor(async()=>(await readFile(join(out,'app.log'),'utf8')).split('\n').some(line=>line.includes(started)&&line.includes('"call_id":"native-call-first"'))||null,5000);
 await cap('02-approved-still-running');report.checks.push('The Local command starts only after composer approval');
 await visible('ai.message.table');await visible('ai.step.tool');assert.equal(nodeText(await visible('ai.turn.label')),'～大浪淘金中～');await cap('03-live-markdown');report.checks.push('Markdown table is present before provider completion and completed tool step remains visible');
 const stableStep=await visible('ai.step.tool');assert((await h.clickAt(stableStep.rect.x+100,stableStep.rect.y+16)).ok);await h.waitFor(async()=>((await visible('ai.step.tool')).rect.h>100)||null,5000);
 const tailViewport=await visible('ai.conversation.viewport');await h.scrollAt(tailViewport.rect.x+tailViewport.rect.w/2,tailViewport.rect.y+tailViewport.rect.h/2,0,-100000);
 assert(held);held.write('data: '+JSON.stringify({choices:[{index:0,delta:{content:'\n\n'+Array.from({length:35},(_,i)=>`- 输出行 ${i+1}：保留完整模型内容。`).join('\n')}}]})+'\n\n');
 await h.waitFor(async()=>{const messages=(await h.query('ai.response')).find(shown),viewport=(await h.query('ai.conversation.viewport')).find(shown);return messages&&viewport?true:null},5000).catch(()=>true);
 await h.waitFor(async()=>{const viewport=await visible('ai.conversation.viewport'),status=(await h.query('ai.turn.running')).find(shown);return status&&Math.abs(status.rect.y+status.rect.h-(viewport.rect.y+viewport.rect.h))<2?true:null},10000);
 assert.equal((await visible('ai.step.tool')).id,stableStep.id,'streamed Markdown must retain the tool step tree');
 report.checks.push('Growing live Markdown follows the tail and preserves the expanded tool step node');await cap('04-live-long-output');
 held.end(usage(23,13)+'data: [DONE]\n\n');held=null;
 await absence('ai.stop');
 const doneRow=await visible('ai.turn.complete'),copyButton=await visible('ai.turn.copy'),forkButton=await visible('ai.turn.fork');
 assert.equal((await visible('ai.turn.label')).text,'～回合结束～');
 assert.equal((await h.query('ai.turn.wave.glyph')).length,0);
 assert.equal(nodeText(await visible('ai.turn.tokens')),'用量明细');
 assert(copyButton.rect.x<doneRow.rect.x+450);assert(forkButton.rect.x<doneRow.rect.x+500);assert(Math.abs(copyButton.rect.y-forkButton.rect.y)<1);assert.equal((await visible('ai.turn.logo')).rect.w,16);
 report.checks.push('Completed lifecycle row uses the latest AI logo, a usage details action and left-aligned dot-separated actions');
 await cap('05-first-complete');await click('ai.turn.tokens');
 assert.equal(nodeText(await visible('ai.turn.usage.total')),'本回合累计用量54 Token');
 assert.equal(nodeText(await visible('ai.turn.usage.input')),'累计输入34');
 assert.equal(nodeText(await visible('ai.turn.usage.output')),'累计输出20');
 assert.equal(nodeText(await visible('ai.turn.usage.requests')),'模型请求2 次');
 report.checks.push('Usage details show 54 tokens across two requests, including 34 input and 20 output tokens');
 await cap('05-usage-details');await h.key('escape');
 await click('ai.turn.copy');await click('ai.prompt');await h.key('a',{cmd:true});await h.key('v',{cmd:true});
 const copiedAnswer=(await h.inputState('ai.prompt')).buffer;assert(copiedAnswer.startsWith('## 系统检查'));assert(copiedAnswer.includes('输出行 35'));assert(!copiedAnswer.includes('sleep 4; printf'));report.checks.push('Turn copy places only the complete formal Markdown output on the clipboard');
 const chips=(await h.query('ai.image')).filter(shown);assert(chips.length>0,'sent image chip remains in user bubble');report.checks.push('Sent user message keeps its captured image chip; completed turn has timestamp, copy and fork actions');
 const completedViewport=await visible('ai.conversation.viewport');
 await h.scrollAt(completedViewport.rect.x+completedViewport.rect.w/2,completedViewport.rect.y+completedViewport.rect.h/2,0,100000);
 await click('ai.turn.process.toggle');
 await h.waitFor(async()=>{
   const details=(await h.query('ai.step.detail')).filter(shown);
   const stdout=(await h.query('ai.tool.result.stdout')).filter(shown);
   return details.some(n=>nodeText(n).includes(`"stdout":"${marker}"`))||stdout.some(n=>nodeText(n).includes(marker))||null;
 },5000);
 report.checks.push('Opening the completed process retains the expanded command output');
 mode='second';await send('第二回合：后续上下文。');await absence('ai.stop');await cap('06-second-complete');
 await click('ai.prompt');await h.type_('尚未发送的草稿');await h.key('up');assert.equal((await h.inputState('ai.prompt')).buffer,'第二回合：后续上下文。');await h.key('down');assert.equal((await h.inputState('ai.prompt')).buffer,'尚未发送的草稿');report.checks.push('Up recalls the last submission; Down restores the unsent draft');
 // Pick the first user edit action by its live node id, so old turns remain addressable.
 const viewport=await visible('ai.conversation.viewport');await h.scrollAt(viewport.rect.x+viewport.rect.w/2,viewport.rect.y+viewport.rect.h/2,0,100000);
 await click('ai.message.copy');await click('ai.prompt');await h.key('a',{cmd:true});await h.key('v',{cmd:true});assert.equal((await h.inputState('ai.prompt')).buffer,'第一回合：检查系统，并保留图片。');report.checks.push('User copy places the exact original message text on the clipboard');
 const edits=(await h.query('ai.message.edit')).filter(shown);assert(edits.length>=1);assert((await h.clickTestId('ai.message.edit')).ok);await visible('ai.message.edit.input');await click('ai.message.edit.input');await h.key('a',{cmd:true});await h.type_('第一回合已编辑');await click('ai.message.edit.save');await absence('ai.message.edit.input');report.checks.push('Inline user editor saves text in place without sending another provider request');
 // Clicking rollback commits deletion before any new request is allowed.
 const requestsBeforeRollback=requests.length;await click('ai.message.rewind');assert.equal((await h.inputState('ai.prompt')).buffer,'第一回合已编辑');
 await absence('ai.message.user.bubble');await absence('ai.turn.complete');await absence('ai.turn.running');await absence('ai.step.tool');await absence('ai.thinking');
 assert.equal(requests.length,requestsBeforeRollback);
 const rollbackLog=await readFile(join(out,'app.log'),'utf8');const rollback=rollbackLog.split('\n').filter(line=>line.includes('"event":"conversation_rollback"')).at(-1);assert(rollback);
 const cleared=JSON.parse(rollback.slice(rollback.indexOf('{')));for(const field of ['history_messages','display_messages','request_history_messages','tool_records','manager_cards','manager_transcript'])assert.equal(cleared[field],0,field);
 const rollbackNotice=await visible('ai.feedback');await visible('ai.feedback.rollback');await absence('ai.feedback.warning');
 await absence('ai.empty.logo');await absence('ai.empty.title');
 assert(nodeText(rollbackNotice).includes('原消息已恢复到输入框'));
 assert(JSON.stringify(await h.query('ai.conversation.viewport')).includes('ai.feedback'),'feedback must belong to transcript scroll');
 await cap('07-rewind-cleared');report.checks.push('Rollback immediately clears transcript, tool records and model context before resubmission; the prompt and image snapshot are restored');
 await h.resizeWindow(860,480);await visible('ai.feedback.dismiss');
 const composerBeforeClose=(await visible('ai.prompt')).rect,sendBeforeClose=(await visible('ai.send')).rect,viewportBeforeClose=(await visible('ai.conversation.viewport')).rect;
 await cap('07-rewind-compact');await click('ai.feedback.dismiss');await absence('ai.feedback');
 assert.deepEqual((await visible('ai.prompt')).rect,composerBeforeClose);assert.deepEqual((await visible('ai.send')).rect,sendBeforeClose);assert.deepEqual((await visible('ai.conversation.viewport')).rect,viewportBeforeClose);
 assert.equal((await h.inputState('ai.prompt')).buffer,'第一回合已编辑');await h.resizeWindow(1440,1000);
 report.checks.push('Rollback uses a neutral dismissible transcript notice; closing it at 860×480 preserves composer, Send and transcript viewport bounds and restored draft');
 mode='rewind';await send('替换首回合');await absence('ai.stop');await visible('ai.turn.complete');
 await absence('ai.feedback');
 const replay=requests.filter(r=>r.mode==='rewind').at(-1);assert(replay);const users=replay.messages.filter((m:any)=>m.role==='user');assert.equal(users.length,1);assert(!JSON.stringify(replay.messages).includes('第二回合'));assert(!replay.messages.some((m:any)=>m.role==='tool'));report.checks.push('Rewind resubmission sends only the replacement first turn; discarded later user/tool context is absent');await cap('08-rewind-replaced');
 await click('ai.turn.fork');
 await visible('ai.session.close.confirmation');
 await click('ai.session.close.accept');
 await absence('ai.session.close.confirmation');
 await visible('ai.turn.complete');
 mode='fork';await send('分叉继续');await absence('ai.stop');
 const branch=requests.filter(r=>r.mode==='fork').at(-1);assert(branch);
 assert(branch.messages.some((m:any)=>m.role==='assistant'&&m.content.includes('回退后的正式输出')));
 report.checks.push('Fork opens a distinct conversation and carries only context through the chosen completed turn');
 await cap('09-fork');
 const usages=(await h.query('ai.turn.tokens')).filter(shown);assert.equal(nodeText(usages.at(-1)),'用量明细');
 const usageTrigger=usages.at(-1).rect;
 assert((await h.clickAt(usageTrigger.x+usageTrigger.w/2,usageTrigger.y+usageTrigger.h/2)).ok);
 assert(nodeText(await visible('ai.turn.usage.details')).includes('服务商未返回完整用量。'));
 await h.key('escape');
 report.checks.push('Missing provider usage is explicitly marked in the details');
 await h.resizeWindow(860,480);const compact=(await h.query('ai.turn.complete')).filter(shown).at(-1),compactFork=(await h.query('ai.turn.fork')).filter(shown).at(-1);assert(compactFork.rect.x>=compact.rect.x&&compactFork.rect.x+compactFork.rect.w<=compact.rect.x+compact.rect.w+.5);await cap('10-compact-status');report.checks.push('Left-aligned lifecycle actions remain inside the status row at 860×480');

 await h.resizeWindow(1440,1000);mode='invalid';await send('检查无效工具参数后的状态');await visible('ai.turn.running');
 await h.waitFor(async()=>{const label=(await h.query('ai.turn.label')).filter(shown).at(-1);return held&&nodeText(label)==='～大浪淘金中～'||null},10000);
 assert.equal((await h.query('ai.interaction.panel')).filter(shown).length,0);assert.equal((await h.query('ai.step.spinner')).filter(shown).length,0);
 await cap('11-invalid-tool-recovered');held.end('data: [DONE]\n\n');held=null;await absence('ai.stop');
 report.checks.push('Invalid tool arguments end the preparing step without executing or requesting approval; the live reply resumes the default activity label');

 assert.ifError(fixtureError);report.viewport={width:1440,height:1000};report.backing_scale=2;report.status='passed';
}catch(error){report.status='failed';report.error=String(error);await cap('failure').catch(()=>{});process.exitCode=1;}
finally{if(planning)planning.res.end();if(held)held.end();server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));app.kill('SIGTERM');if(app.exitCode===null&&app.signalCode===null)await new Promise(done=>app.once('close',done));await log.close();report.requests=requests;await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
console.log(JSON.stringify({status:report.status,error:report.error,checks:report.checks,out}));
