/** Isolated native child defaults and active-child model handoff. No business shell commands. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,writeFile,readFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-v04-task-build'),binary=join(prefix,'bin/zerowork');
const out=resolve(process.argv[2]??'/tmp/zw-v04-child-handoff-native');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-task-gateway-')),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
for(const dir of [data,rpc,zdot])await mkdir(dir);await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='task-gateway%# '\n");
const requests:any[]=[]; let rootRound=0, childHeld:any=null, childCancelled=false, fixtureError='';
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const finish=(res:any,text:string)=>res.end(frame({content:text})+'data: [DONE]\n\n');
const wire=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
const tool=(res:any,id:string,name:string,args:any)=>res.end(frame({tool_calls:[{index:0,id,type:'function',function:{name:wire(name),arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n');
const bodyOf=(result:any)=>{for(const block of result.content??[])try{return JSON.parse(block.text)}catch{}return result};
const server=createServer(async(req,res)=>{try{
 if(req.method!=='POST'){res.end('{"data":[{"id":"task-gateway"}]}');return}
 let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
 if(!body.tools?.length){finish(res,'交接测试');return}
 requests.push(body);
 if(JSON.stringify(body.messages).includes('CHILD_HELD')&&!JSON.stringify(body.messages).includes('ROOT_HANDOFF')){
  assert(JSON.stringify(body.messages).includes('CHILD_HELD'));assert(!JSON.stringify(body.messages).includes('ROOT_HANDOFF'),'explicit independent overrides inherited default');
  childHeld=res;res.on('close',()=>{childCancelled=true});res.write(frame({content:'CHILD_RUNNING '}));return;
 }
 const results=new Map<string,any>();for(const m of body.messages??[])if(m.role==='tool')results.set(m.tool_call_id,bodyOf(JSON.parse(m.content)));
 rootRound++;
 if(rootRound===1){assert(JSON.stringify(body.messages).includes('prefer_reuse'));tool(res,'context','host.get_current_context',{});return}
 const context=results.get('context');assert(context?.binding_ref);
 if(rootRound===2){tool(res,'child','host.agent_tasks',{action:'create',request_key:'handoff-child',name:'交接前子任务',text:'CHILD_HELD',session_refs:[],context_mode:'independent'});return}
 if(rootRound===3){const start=performance.now();while(!childHeld&&performance.now()-start<10000)await new Promise(r=>setTimeout(r,10));assert(childHeld,'child model must actually be running before handoff');tool(res,'group','host.create_group',{initial_session_ref:context.binding_ref,name:'交接验证',request_key:'handoff-group'});return}
 if(rootRound===4){assert.equal(results.get('group')?.state,'committed',JSON.stringify(results.get('group')));assert(childCancelled,'handoff waited until the actual child HTTP request was cancelled');tool(res,'collect','host.agent_tasks',{action:'wait_events',after_sequence:0,wait_ms:0});return}
 assert(results.has('collect'));finish(res,'HANDOFF_COMPLETE');
 }catch(error){fixtureError=String(error);res.end(frame({content:'FIXTURE_ERROR '+fixtureError})+'data: [DONE]\n\n')}
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="task-gateway"\nfollow_up_mode="queue"\npermission_mode="auto"\n[[ai.providers]]\nid="task-gateway"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="task-gateway"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts'));const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(done=>app.once('close',done)),alive=()=>app.exitCode===null&&app.signalCode===null;
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(nodes:any)=>flat(nodes).map(n=>n.text??'').join(' ');
const visible=(id:string)=>h.waitFor(async()=>{assert(alive());return(await h.query(id)).find(shown)??null},15000);
const report:any={status:'running',isolation:iso,binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],screenshots:[]};
const click=async(id:string)=>{report.last_action=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
const capture=async(name:string)=>{await h.mouseMove(1,1);await h.sleep(200);assert((await h.screenshot(join(out,name+'.png'))).ok);report.screenshots.push(join(out,name+'.png'))};
const journal=async()=>String(await readFile(join(data,'ai-sessions.jsonl'),'utf8')).trim().split('\n').map(row=>JSON.parse(row));
const scrollTo=async(id:string)=>{for(let i=0;i<24;i++){const n=await visible(id),vp=(await visible('settings.viewport')).rect;if(n.rect.y>=vp.y&&n.rect.y+n.rect.h<=vp.y+vp.h)return;const delta=n.rect.y<vp.y?vp.y-n.rect.y+25:vp.y+vp.h-n.rect.y-n.rect.h-25;await h.scrollAt(vp.x+vp.w-4,vp.y+vp.h/2,0,Math.max(-500,Math.min(500,delta)));await h.sleep(70)}throw Error('Cannot reveal '+id)};
const setting=async(id:string)=>{await scrollTo(id);await click(id)};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1280,900);await click('toolbar.settings');await click('settings.nav.ai');await click('settings.search');await h.type_('子 Agent');
 await setting('settings.field.child_context_mode');await click('settings.child_context.inherit');
 await setting('settings.field.child_reuse_policy');await click('settings.child_reuse.prefer_reuse');await capture('01-default-draft');await writeFile(join(out,'settings-geometry.json'),JSON.stringify(await h.query('settings.ai.children'),null,2));await click('settings.save');
 await h.waitFor(async()=>(await readFile(join(data,'config.toml'),'utf8')).includes('child_reuse_policy = "prefer_reuse"')||null,10000);
 const saved=await readFile(join(data,'config.toml'),'utf8');assert(saved.includes('child_context_mode = "inherit"'));
 await setting('settings.field.child_reuse_policy');await click('settings.child_reuse.model');await click('settings.revert');
 await h.resizeWindow(860,480);await scrollTo('settings.field.child_reuse_policy');await capture('02-compact-reverted');assert.equal(await readFile(join(data,'config.toml'),'utf8'),saved);
 await click('settings.close');await h.resizeWindow(1200,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');
 await click('ai.prompt');await h.type_('ROOT_HANDOFF 委派子任务后创建组，保留原根任务');await click('ai.send');
 await h.waitFor(async()=>{if(fixtureError)throw Error(fixtureError);if(text(await h.query('ai.panel')).includes('HANDOFF_COMPLETE'))return true;for(const id of ['ai.interaction.approve','ai.host_approval.accept']){const q=await h.query(id);if(q.some(shown)){await h.clickTestId(id)}}return null},30000);
 await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,15000);assert.equal(rootRound,5);
 const rows=await journal(),launch=rows.find(r=>r.event?.kind==='child_launch')?.event;assert(launch);assert.equal(launch.child_info.context_mode,'independent');assert.equal(launch.child_info.reusable,true);
 const handoff=rows.findIndex(r=>r.event?.kind==='handoff'&&r.event.conversation===launch.parent_binding.conversation),unbind=rows.findIndex(r=>r.event?.kind==='unbind'&&r.event.conversation===launch.conversation);assert(unbind>=0&&handoff>unbind,'child unbind precedes parent binding publication');
 const facts=rows.flatMap(r=>r.event?.task_fact?[r.event.task_fact]:[]),rootFacts=facts.filter(f=>f.task===launch.task_fact.parent);assert.equal(rootFacts.at(-1)?.status,'succeeded');assert(rootFacts.every(f=>f.root===launch.task_fact.root));assert(childCancelled);
 await capture('03-parent-handoff-complete');await writeFile(join(out,'journal.json'),JSON.stringify(rows,null,2));report.requests=requests;report.checks.push('native default context/reuse selects save and revert; compact settings retain the saved draft','explicit independent overrides inherited default; omitted reusable uses captured prefer_reuse','model create_group waits for active child cancellation and local unbind before publishing; parent finishes same Task/root after report collection');report.status='passed';

}catch(error){report.requests=requests;report.status='failed';report.error=fixtureError||String(error);process.exitCode=1;await capture('failure').catch(()=>{});await h.query('settings.panel').then(tree=>writeFile(join(out,'failure-tree.json'),JSON.stringify(tree,null,2))).catch(()=>{})}
finally{
 if(childHeld&&!childCancelled){childHeld.destroy();childHeld=null}
 try{if(alive()){report.quit_response=await h.request('POST','/zerowork/windows',{action:'quit'});const start=performance.now();while(alive()&&performance.now()-start<15000){for(const id of ['settings.confirmation.discard','groups.close.accept','local.close.accept','session.close.accept']){if(!alive())break;try{const q=await h.query(id);if(!Array.isArray(q))break;if(q.some(shown))await h.clickTestId(id)}catch{break}}await Promise.race([ended,h.sleep(80)])}}}catch(error){report.quit_error=String(error)}
 if(alive()){report.forced=true;app.kill('SIGTERM');await ended}report.exit_code=app.exitCode;report.signal=app.signalCode;if(report.forced||app.exitCode!==0){report.status='failed';process.exitCode=1}
 server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));await log.close();const logs=await readFile(join(out,'app.log'),'utf8');if(/leaked \[addr:|panic:|double free/i.test(logs)){report.status='failed';process.exitCode=1}await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}));
}
