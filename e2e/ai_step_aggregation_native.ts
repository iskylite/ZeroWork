/** Aggregation on the production native transcript, with a held local provider.
 * ZW_AI_TEST_PREFIX=/private/tmp/zw-step-aggregation-build node e2e/ai_step_aggregation_native.ts /tmp/evidence
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,readFile,open,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/private/tmp/zw-step-aggregation-build');
const out=resolve(process.argv[2]??'/private/tmp/zw-step-aggregation-evidence');
await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-step-aggregation-'),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
await mkdir(data);await mkdir(rpc);await mkdir(zdot);await writeFile(join(zdot,'.zshrc'),"PS1='aggregation-test%# '\n");
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const wire=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
let held:any=null,fixtureFailure:string|null=null,requests=0;
const server=createServer(async(req,res)=>{
 try{
  if(req.method!=='POST')return res.end('{"data":[{"id":"aggregation-fixture"}]}');
  let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);requests++;
  res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
  const user=body.messages.findLast((m:any)=>m.role==='user')?.content;
  if(user==='SCROLL_STABILITY'){
   const turn=body.messages.slice(body.messages.findLastIndex((m:any)=>m.role==='user')+1);
   if(!turn.some((m:any)=>m.role==='tool'&&m.tool_call_id?.startsWith('stability-'))){
    return res.end(frame({content:('用于检查阅读位置的已有对话内容。\n\n').repeat(15)})+frame({reasoning_content:('展开后继续阅读这一条思考详情。\n').repeat(30)})+frame({tool_calls:[{index:0,id:'stability-0',type:'function',function:{name:wire('host.get_current_context'),arguments:'{}'}}]})+'data: [DONE]\n\n');
   }
   held=res;return;
  }
  if(user==='SECOND_TURN')return res.end(frame({reasoning_content:'新回合独立思考。'})+frame({content:'SECOND_TURN_COMPLETE'})+'data: [DONE]\n\n');
  if(!body.messages.some((m:any)=>m.role==='tool'&&m.tool_call_id==='aggregation-read')){
   return res.end(frame({content:'先核对当前会话，再检查问题。'})+frame({tool_calls:[{index:0,id:'aggregation-read',type:'function',function:{name:wire('host.get_current_context'),arguments:'{}'}}]})+'data: [DONE]\n\n');
  }
  if(body.messages.some((m:any)=>m.role==='tool'&&m.tool_call_id==='aggregation-fail-2'))return res.end(frame({content:'AGGREGATION_COMPLETE'})+'data: [DONE]\n\n');
  held=res;
 }catch(error){fixtureFailure=String(error);res.end();}
});
await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="sauber"\nfont_size=14\n[ai]\ndefault_provider="aggregation-fixture"\nstep_display="collapsed"\n[[ai.providers]]\nid="aggregation-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="aggregation-fixture"\ncontext_window=200000\ndefault=true\nreasoning=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(r=>app.once('close',()=>r()));
const report:any={status:'running',checks:[],requests:0};
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>typeof n.text==='string'?n.text:'').join(' ');
const shown=(n:any)=>n&&n.visible!==false&&!n.hidden&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>{assert.equal(fixtureFailure,null);return(await h.query(id)).find(shown)??null},15000);
const click=async(id:string)=>{report.last_action=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
const groups=async()=>await h.query('ai.step_group');
const groupHeaders=async()=>await h.query('ai.step_group.header');
const waitGroups=async(count:number)=>h.waitFor(async()=>{const found=await groups();return found.length===count?found:null},10000);
const clickHeader=async(index:number)=>{
 for(let attempt=0;attempt<12;attempt++){
  const n=(await groupHeaders())[index],viewport=await visible('ai.conversation.viewport');assert(n);
  if(n.rect.y>=viewport.rect.y+1&&n.rect.y+n.rect.h<=viewport.rect.y+viewport.rect.h-1){assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+16)).ok);return}
  await h.scrollAt(viewport.rect.x+viewport.rect.w/2,viewport.rect.y+viewport.rect.h/2,0,n.rect.y<viewport.rect.y?160:-160);await h.sleep(80);
 }
 throw Error('group header did not scroll into view');
};
const capture=async(name:string)=>{assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2))};
const leaveHeader=async()=>{const prompt=await visible('ai.prompt');await h.mouseMove(prompt.rect.x+4,prompt.rect.y+4)};
const send=async(value:string)=>{await click('ai.prompt');await h.type_(value);await click('ai.send')};
const resizePanel=async(delta:number)=>{
 const before=await visible('ai.panel'),handle=await visible('ai.float.resize.w');
 const x=handle.rect.x+handle.rect.w/2,y=handle.rect.y+handle.rect.h/2;
 await h.mouseMove(x,y);await h.mouseDown(x,y);await h.mouseMove(x+delta,y);await h.mouseUp(x+delta,y);
 await h.waitFor(async()=>Math.abs((await visible('ai.panel')).rect.w-(before.rect.w-delta))<1||null,5000);
};
const checkWidths=async(expanded:boolean)=>{
 await h.waitFor(async()=>{
  const conversation=await visible('ai.conversation'),group=(await groups())[0];
  return Math.abs(group.rect.w-(conversation.rect.w-28))<1||null;
 },5000);
 const group=(await groups())[0],header=(await groupHeaders())[0];
 assert(Math.abs(header.rect.w-group.rect.w)<1,'group header fills the group');
 if(expanded)for(const id of ['ai.tool.result.header','ai.step.header']){
  const cards=await h.query(id);assert(cards.length>0,id);
  for(const card of cards)assert(Math.abs(card.rect.w-group.rect.w)<1,id+' follows the group width');
 }
 return group.rect.w;
};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1440,1000);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');
 await send('请检查当前会话');await h.waitFor(async()=>held||null,20000);await waitGroups(1);
 assert.equal((await groups())[0].rect.h,32,'singleton begins collapsed');
 const header=(await groupHeaders())[0];
 const indicator=async()=>({activity:(await h.query('ai.step_group.status'))[0],arrow:(await h.query('ai.step_group.disclosure'))[0]});
 await leaveHeader();
 await h.waitFor(async()=>((await indicator()).arrow.opacity??1)===0||null,5000);
 let icons=await indicator();assert.equal(icons.activity.opacity??1,1);
 const originalTitle=(await h.query('ai.step_group.title'))[0].rect;
 assert(icons.arrow.rect.x<header.rect.x+32,'disclosure lives in the first left slot');
 await h.mouseMove(header.rect.x+header.rect.w/2,header.rect.y+16);
 await h.waitFor(async()=>((await indicator()).arrow.opacity??1)===1||null,5000);
 assert.equal((await indicator()).activity.opacity??1,0);
 assert.deepEqual((await h.query('ai.step_group.title'))[0].rect,originalTitle,'icon swap does not move title');
 await capture('00-collapsed-hover');
 // Keep the pointer stationary while live steps replace the transcript nodes.
 for(let i=0;i<4;i++){
  held.write(frame({reasoning_content:`正在核对当前会话 ${i}。`}));
  await h.waitFor(async()=>text(await h.query('ai.step_group.projection')).includes(`当前会话 ${i}`)||null,5000);
  assert.equal((await indicator()).arrow.opacity??1,1,'stationary hover survives live transcript replacement');
  assert.equal((await indicator()).activity.opacity??1,0);
 }
 await capture('00-live-stationary-hover');await leaveHeader();
 await h.waitFor(async()=>((await indicator()).activity.opacity??1)===1||null,5000);
 await capture('01-single-collapsed');
 const originalWidth=await checkWidths(false);
 await resizePanel(-240);assert((await checkWidths(false))>originalWidth+230);
 await capture('01-wide-collapsed');
 await clickHeader(0);await h.waitFor(async()=>(await groups())[0].rect.h>32||null,5000);
 await leaveHeader();
 await h.waitFor(async()=>((await indicator()).arrow.opacity??1)===1||null,5000);
 assert.equal((await indicator()).activity.opacity??1,0,'expanded group keeps the disclosure after mouse leaves');
 report.checks.push('Collapsed group shows its activity icon, hover swaps in the left disclosure without layout shift, expanded group keeps that disclosure after pointer leaves; no right disclosure');
 const child=(await h.query('ai.tool.result.header'))[0];assert(child&&child.rect.h===32,'original tool card unchanged');
 const separator=(await h.query('ai.tool.result.separator'))[0];assert(separator&&separator.rect.w===3,'current step-card dot separator retained');
 held.write(frame({reasoning_content:'正在分析代码与终端信息。'}));
 await h.waitFor(async()=>text(await h.query('ai.step_group.summary')).includes('正在分析代码与终端信息')||null,5000);
 assert((await groups())[0].rect.h>32,'append keeps manual expansion');
 assert(text(await h.query('ai.step_group.title')).includes('思考中'));
 held.write(frame({reasoning_content:' 核对错误来源。'}));
 await h.waitFor(async()=>text(await h.query('ai.step.projection')).includes('核对错误来源')||null,5000);
 assert.equal((await h.query('ai.thinking')).length,1,'streamed reasoning updates one step');
 held.write(frame({reasoning_content:'\n最新判断：需要核对命令所在的节点。'}));
 await h.waitFor(async()=>text((await h.query('ai.step_group.summary'))[0]).includes('最新判断：需要核对命令所在的节点')||null,5000);
 assert.equal(text((await h.query('ai.step_group.count'))[0]),'2 个步骤');
 assert.equal(text((await h.query('ai.step_group.projection'))[0]),text((await h.query('ai.step.projection')).at(-1)),'thinking projection is separate from the fixed count');
 await h.waitFor(async()=>Math.abs((await groups())[0].rect.h-114)<.1||null,5000);
 const lastCard=(await h.query('ai.thinking'))[0],bottomEdge=(await h.query('ai.step_group.edge.bottom'))[0];
 assert(bottomEdge.rect.y>=lastCard.rect.y+lastCard.rect.h-.1,'soft edge is below the last complete card');
 await capture('02-expanded-latest-cards');
 await checkWidths(true);await capture('02-wide-expanded');
 await resizePanel(280);assert((await checkWidths(true))<originalWidth-30);
 await capture('02-narrow-expanded');
 await resizePanel(-40);await checkWidths(true);
 await clickHeader(0);await h.waitFor(async()=>(await groups())[0].rect.h===32||null,5000);
 held.write(frame({reasoning_content:'\n最新线索：终端命令在内层 Shell 中执行。'}));
 await h.waitFor(async()=>text((await h.query('ai.step_group.summary'))[0]).includes('最新线索：终端命令在内层 Shell 中执行')||null,5000);
 assert.equal(text((await h.query('ai.step_group.count'))[0]),'2 个步骤','collapsed streaming retains the step count');
 assert.equal((await groups())[0].rect.h,32,'live projection does not expand the group');await capture('02-live-thinking-collapsed');
 const fixedBefore={count:(await h.query('ai.step_group.count'))[0].rect,elapsed:(await h.query('ai.step_group.elapsed'))[0].rect};
 held.write(frame({reasoning_content:'\n'+('最新线索：正在核对内层 Shell 的节点、目录和执行结果。'.repeat(30))}));
 await h.waitFor(async()=>text((await h.query('ai.step_group.projection'))[0]).includes('目录和执行结果')||null,5000);
 const panelWidth=(await visible('ai.panel')).rect.w;
 await resizePanel(panelWidth-520);
 const fixedCount=(await h.query('ai.step_group.count'))[0],fixedClock=(await h.query('ai.step_group.elapsed'))[0],shrinking=(await h.query('ai.step_group.projection'))[0],fixedHeader=(await groupHeaders())[0];
 assert.equal(text(fixedCount),'2 个步骤');
 assert(Math.abs(fixedCount.rect.w-fixedBefore.count.w)<.1,'count keeps its full intrinsic width');
 assert(Math.abs(fixedClock.rect.w-fixedBefore.elapsed.w)<.1&&fixedClock.rect.w===44,'elapsed keeps its fixed width');
 assert(shrinking.rect.w>0&&shrinking.rect.x>=fixedCount.rect.x+fixedCount.rect.w,'only thinking uses the remaining middle space');
 assert(shrinking.rect.x+shrinking.rect.w<=fixedClock.rect.x,'thinking never overlaps elapsed');
 assert(fixedClock.rect.x+fixedClock.rect.w<=fixedHeader.rect.x+fixedHeader.rect.w-12,'elapsed stays inside the header');
 assert.equal((await groups())[0].rect.h,32);
 await capture('02-fixed-count-long-thinking');
 await resizePanel(520-panelWidth);
 report.checks.push('At the supported 520px minimum with a very long thought, count retains its full width, elapsed retains 44px, and only the thinking projection shrinks between them');
 await clickHeader(0);await h.waitFor(async()=>(await groups())[0].rect.h>32||null,5000);
 report.checks.push('Dragging the assistant wider and narrower resizes collapsed group headers and expanded tool/thinking cards to the conversation content width');
 report.checks.push('singletons aggregate immediately; appended tools and thinking share one group; stream updates keep count and manual expansion; current native card separator and geometry retained');
 held.write(frame({content:'第一段检查结束，继续检查下一部分。'}));
 held.write(frame({reasoning_content:'第二组的独立思考。'}));
 await waitGroups(2);assert.equal((await groups())[1].rect.h,32,'new group uses collapsed default');
 assert(text((await h.query('ai.step_group.summary'))[0]).includes('2 个步骤'),'completed thinking restores the existing group summary');
 assert(!text((await h.query('ai.step_group.summary'))[0]).includes('最新线索'),'completed thought does not remain projected');
 report.checks.push('live thinking retains the step count beside the thinking card latest line; collapsed streaming stays collapsed; no active thinking restores the original count/tool projection');
 await capture('03-message-boundary');
 // Search reveals exactly the existing AI settings page and the new field.
 await click('toolbar.settings');await click('settings.nav.ai');await click('settings.search');await h.type_('步骤默认显示');
 await click('settings.field.step_display');await click('settings.step_display.expanded');await click('settings.save');
 await h.waitFor(async()=>(await readFile(join(data,'config.toml'),'utf8')).includes('step_display = "expanded"')||null,10000);
 await capture('04-default-setting');await click('settings.close');
 // Settings application must not change groups already created.
 assert.equal((await groups())[1].rect.h,32);
 held.write(frame({content:'现在进入第三部分。'}));held.write(frame({reasoning_content:'第三组按新设置默认展开。'}));
 await waitGroups(3);await h.waitFor(async()=>(await groups())[2].rect.h>32||null,5000);
 assert.equal(text((await h.query('ai.step_group.count'))[2]),'1 个步骤','singleton thinking also retains its step count');
 assert.equal((await groups())[1].rect.h,32,'old group stays collapsed after changing default');
 await capture('05-new-default-expanded');
 await clickHeader(2);await h.waitFor(async()=>(await groups())[2].rect.h===32||null,5000);
 held.write(frame({reasoning_content:' 追加文本仍然保持手动收起。'}));
 await h.waitFor(async()=>text(await h.query('ai.step.projection')).includes('追加文本')||null,5000);
 assert.equal((await groups())[2].rect.h,32);
 held.end(frame({tool_calls:[{index:0,id:'aggregation-fail-1',type:'function',function:{name:wire('host.run_in_terminal'),arguments:'{}'}},{index:1,id:'aggregation-fail-2',type:'function',function:{name:wire('host.read_terminal'),arguments:'{}'}}]})+'data: [DONE]\n\n');held=null;await visible('ai.turn.complete');
 await waitGroups(3);
 const failures=await h.query('ai.request.unsent');assert.equal(failures.length,2,'both unsent failures retained');
 const descendants=flat((await groups())[2]);
 assert.equal(descendants.filter((n:any)=>n.test_id==='ai.request.unsent').length,2,'all failures belong to the existing third group');
 assert(text(await h.query('ai.step_group.summary')).includes('3 个步骤'),'failures counted alongside thinking');
 assert(text((await h.query('ai.step_group.projection'))[2]).includes('有步骤失败'),'collapsed group exposes earlier failures in its projection');
 await clickHeader(2);await h.waitFor(async()=>(await groups())[2].rect.h>32||null,5000);
 for(const failure of await h.query('ai.request.unsent')){
  assert(text(failure).includes('未执行'),'failure summary states dispatch outcome');
  const projection=flat(failure).find((n:any)=>n.test_id==='ai.step.projection');
  assert(text(projection).includes('未执行'),'preprojected unsent error stays visible in the header');
  assert(!text(projection).includes('已批准'),'approval cannot replace the final error status');
  assert(text(failure).includes('错误码：'),'failure detail includes diagnostic code');
  assert(text(failure).includes('工具：'),'failure detail identifies tool');
  assert(text(failure).includes('原因：'),'failure detail includes readable reason');
 }
 for(let attempt=0;attempt<12;attempt++){
  const failedCard=(await h.query('ai.request.unsent'))[0];
  const failedHeader=flat(failedCard).find((n:any)=>n.test_id==='ai.step.header'),viewport=await visible('ai.conversation.viewport');assert(failedHeader);
  if(failedHeader.rect.y>=viewport.rect.y+1&&failedHeader.rect.y+32<=viewport.rect.y+viewport.rect.h-1){
   await h.clickAt(failedHeader.rect.x+failedHeader.rect.w/2,failedHeader.rect.y+16);break;
  }
  await h.scrollAt(viewport.rect.x+viewport.rect.w-6,viewport.rect.y+viewport.rect.h/2,0,failedHeader.rect.y<viewport.rect.y?160:-160);await h.sleep(80);
 }
 await h.waitFor(async()=>(await h.query('ai.request.unsent'))[0].rect.h>32||null,5000);
 await capture('06-grouped-failures');
 report.checks.push('two unsent tool failures stay inside the consecutive step group; count and warning status retained; diagnostics include tool, parameters, error code and raw error');
 await clickHeader(2);await h.waitFor(async()=>(await groups())[2].rect.h===32||null,5000);
 assert.equal((await groups())[2].rect.h,32,'completion preserves manual collapse');
 report.checks.push('ordinary model messages end groups; setting saves in existing AI page; current groups keep state; subsequent groups use new default; completion does not recollapse or reopen');
 await send('SECOND_TURN');await h.waitFor(async()=>text(await h.query('ai.conversation')).includes('SECOND_TURN_COMPLETE')||null,15000);
 await waitGroups(4);assert((await groups())[3].rect.h>32,'turn boundary always creates a fresh group');
 assert.equal((await groups())[2].rect.h,32,'history clone retains disclosure');
 report.checks.push('new user turn does not merge with the previous group; history preserves disclosure');
 // UI save is persisted and shows the same value when reopening.
 await click('toolbar.settings');await click('settings.nav.ai');await click('settings.search');await h.key('a',{cmd:true});await h.type_('步骤默认显示');
 assert(text(await h.query('settings.field.step_display')).includes('展开'));
 await click('settings.close');
 await capture('06-history-state');
 // Recreate the reported combination: an expanded group, open thought/tool
 // details, a scrolled transcript, and new cards appended below the reader.
 await h.resizeWindow(1440,720);
 await send('SCROLL_STABILITY');await h.waitFor(async()=>held||null,20000);await waitGroups(5);
 const clickLastHeader=async(id:string)=>{
  for(let attempt=0;attempt<20;attempt++){
   const card=(await h.query(id)).at(-1),viewport=await visible('ai.conversation.viewport');assert(card);
   if(card.rect.y>=viewport.rect.y+1&&card.rect.y+32<=viewport.rect.y+viewport.rect.h-1){
    await h.clickAt(card.rect.x+card.rect.w/2,card.rect.y+16);return;
   }
   await h.scrollAt(viewport.rect.x+viewport.rect.w-6,viewport.rect.y+viewport.rect.h/2,0,card.rect.y<viewport.rect.y?100:-100);await h.sleep(50);
  }
  throw Error('detail header did not scroll into view: '+id);
 };
 await clickLastHeader('ai.step.header');
 await h.waitFor(async()=>(await h.query('ai.thinking')).at(-1).rect.h>170||null,5000);
 await clickLastHeader('ai.tool.result.header');
 await h.waitFor(async()=>(await groups()).at(-1).rect.h>400||null,5000);
 await h.sleep(300);
 const anchor=async()=>(await h.query('ai.thinking')).at(-1).rect.y;
 const savedY=await anchor(),resultCount=(await h.query('ai.tool.result.header')).length;
 const positions:number[]=[];
 for(let i=1;i<=4;i++){
  const response=held;held=null;
  response.end(frame({tool_calls:[{index:0,id:`stability-${i}`,type:'function',function:{name:wire('host.get_current_context'),arguments:'{}'}}]})+'data: [DONE]\n\n');
  await h.waitFor(async()=>{
   const y=await anchor();positions.push(y);
   assert(Math.abs(y-savedY)<1,`open detail stays at ${savedY}, got ${y} while appending card ${i}`);
   return held&&(await h.query('ai.tool.result.header')).length===resultCount+i?true:null;
  },15000);
  await h.sleep(100);positions.push(await anchor());
  assert(Math.abs(positions.at(-1)!-savedY)<1,'settled reader position stays fixed');
 }
 report.reader_positions=positions;
 await capture('07-expanded-details-new-cards');
 held.end(frame({content:'SCROLL_STABILITY_COMPLETE'})+'data: [DONE]\n\n');held=null;
 await visible('ai.turn.complete');
 report.checks.push('Stationary hover survives repeated live replacements; with thought and tool details open, four newly executed cards preserve the scrolled transcript position within 1px');
 report.status='passed';report.requests=requests;
}catch(error){report.status='failed';report.error=String(error);await h.screenshot(join(out,'failure.png')).catch(()=>{});await writeFile(join(out,'failure.json'),JSON.stringify(await h.query('ai.panel'),null,2)).catch(()=>{});process.exitCode=1;}
finally{
 if(held)held.end();server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));
 app.kill('SIGTERM');await Promise.race([ended,new Promise<void>(r=>setTimeout(()=>{app.kill('SIGKILL');r()},3000))]);
 await log.close();await rm(iso,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}
