/** Native production composer, isolated Local PTY and deterministic provider. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,writeFile,readFile,open} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-composer-native');
const out=resolve(process.argv[2]??'/tmp/zw-composer-native-acceptance');await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-composer-app-'),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');for(const d of [data,rpc,zdot])await mkdir(d);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='composer-test%# '\n");
const marker=join(iso,'executed-once');
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const wire=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
const payload=(envelope:any)=>{for(const b of envelope.content??[])try{return JSON.parse(b.text)}catch{}return envelope};
const requests:any[]=[];let serverError:unknown=null;
const server=createServer(async(req,res)=>{try{
 if(req.method!=='POST')return res.end('{"data":[{"id":"composer-fixture"}]}');
 let raw='';for await(const b of req)raw+=b;const body=JSON.parse(raw);requests.push(body);
 res.writeHead(200,{'content-type':'text/event-stream'});
 if(!body.tools?.length)return res.end(frame({content:'Composer interaction acceptance'})+'data: [DONE]\n\n');
 const scenario=body.messages.filter((m:any)=>m.role==='user').at(-1)?.content?.includes('拒绝')?'reject':body.messages.filter((m:any)=>m.role==='user').at(-1)?.content?.includes('停止')?'stop':'approve';
 const results=new Map(body.messages.filter((m:any)=>m.role==='tool').map((m:any)=>[m.tool_call_id,payload(JSON.parse(m.content))]));
 const emit=(id:string,name:string,args:any)=>res.end(frame({tool_calls:[{index:0,id,type:'function',function:{name:name==='run_command'?name:wire(name),arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n');
 if(scenario!=='reject'&&!results.has('q-'+scenario)){
  assert(body.tools.some((t:any)=>t.function?.name===wire('host.request_user_input')),'question tool must be in the actual provider catalog');
  return emit('q-'+scenario,'host.request_user_input',{question:'你希望如何处理 Nginx？',options:[{id:'reload',label:'平滑重载配置',description:'不中断现有连接'},{id:'restart',label:'重启服务',description:'可能短暂中断连接'}]});
 }
 if(scenario==='approve')assert(JSON.stringify(results.get('q-approve')).includes('reload'),'explicit selected answer reaches provider');
 const context:any=results.get('ctx-'+scenario);if(!context)return emit('ctx-'+scenario,'host.get_current_context',{});
 let ready=false;for(let i=0;i<10;i++){
  const facts:any=results.get(`ready-${scenario}-${i}`);
  if(!facts){if(i)await new Promise(r=>setTimeout(r,200));return emit(`ready-${scenario}-${i}`,'host.get_session',{session_ref:context.binding_ref});}
  if(facts.session?.capabilities?.trusted_pty_execution){ready=true;break;}
 }
 assert(ready,'Local PTY not ready');
 if(!results.has('run-'+scenario))return emit('run-'+scenario,'run_command',{session_ids:[context.current_binding.session],command:`printf COMPOSER_NATIVE_OK; printf once >> '${marker}'`});
 return res.end(frame({content:'COMPOSER_FINISHED_'+scenario})+'data: [DONE]\n\n');
}catch(err){serverError=String(err);res.end(frame({content:'FIXTURE_ERROR '+String(err)})+'data: [DONE]\n\n');}});
await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="composer-fixture"\npermission_mode="confirm"\nexecution_mode="isolated_exec"\n[[ai.providers]]\nid="composer-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="composer-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts'));const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join(' ');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,20000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok);};
const report:any={checks:[],geometry:{},status:'running',scope:'Isolated native App, production composer and brokers, deterministic local provider, real Local PTY.'};
const capture=async(name:string)=>{
 await h.mouseMove(20,42);await h.sleep(80);
 const nodes=await h.query('ai.panel');const root=nodes.find(shown);assert(root,'assistant panel is visible');
 const all=flat(nodes);const parent=all.find((n:any)=>(n.children??[]).some((c:any)=>c.test_id==='ai.interaction.panel'));
 assert(parent,'interaction is mounted directly in the original composer');
 const ids=['ai.interaction.panel','ai.interaction.actions','ai.interaction.pending','ai.interaction.title','ai.interaction.option.0','ai.interaction.option.1','ai.interaction.option.6','ai.interaction.answer','ai.stop','ai.prompt','ai.conversation.viewport'];
 const relative=(r:any)=>({x:r.x-root.rect.x,y:r.y-root.rect.y,w:r.w,h:r.h});
 const geometry:any={panel:root.rect,composer:relative(parent.rect)};
 for(const id of ids){const n=(await h.query(id)).find(shown);if(n)geometry[id]=relative(n.rect);}
 report.geometry[name]=geometry;
 await writeFile(join(out,name+'.tree.json'),JSON.stringify(nodes,null,2));
 if(name.startsWith('question')||name.startsWith('approval')){const body=geometry['ai.interaction.panel'];assert(body.h>0&&body.h<=180,'interaction content is capped at 180px');assert(parent.rect.h<224,'short content does not reserve the full maximum');assert(Math.abs(parent.rect.h-body.h-44)<.6,'composer hugs its content and fixed action row');assert(parent.rect.y+parent.rect.h<=root.rect.y+root.rect.h+.6,'composer remains inside the assistant panel');}else assert.equal(parent.rect.h,90);
 if(geometry['ai.interaction.pending']){
  const badge=geometry['ai.interaction.pending'];assert.equal(badge.h,26);assert(Math.abs(geometry.composer.y-badge.y-badge.h-8)<.6,'floating capsule gap is 8px');
 }
 assert(!text(nodes).includes('存为复盘笔记'));
 if(geometry['ai.interaction.actions']){
  for(const id of ['ai.interaction.postpone',...(name.startsWith('question')?['ai.interaction.submit']:['ai.interaction.reject','ai.interaction.approve'])]){
   const button=await visible(id);assert(button.rect.x>=parent.rect.x&&button.rect.x+button.rect.w<=parent.rect.x+parent.rect.w+.5,'action stays within composer');
   assert(button.rect.y>=parent.rect.y&&button.rect.y+button.rect.h<=parent.rect.y+parent.rect.h+.5,'action stays outside scrolling content');
  }
 }
 if(name.startsWith('question')||name.startsWith('approval')){assert(!geometry['ai.stop']);const later=await visible('ai.interaction.postpone');const primary=await visible(name.startsWith('question')?'ai.interaction.submit':'ai.interaction.approve');assert.equal(later.rect.h,primary.rect.h);assert(Math.abs(primary.rect.y-later.rect.y)<.5);const previous=name.startsWith('question')?later:await visible('ai.interaction.reject');assert(Math.abs(primary.rect.x-previous.rect.x-previous.rect.w-8)<.6);}
 await h.screenshot(join(out,name+'.png'));
};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1200,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.prompt');await h.type_('验证 composer 交互');await click('ai.send');
 await visible('ai.interaction.option.0');assert((await visible('ai.interaction.title')).text.includes('如何处理'));
 assert(!(await h.query('ai.host_approval')).some(shown));assert(!(await h.query('ai.prompt')).some(shown));
 assert(!(await h.query('ai.stop')).some(shown));assert(!(await h.query('ai.send')).some(shown));const panel=await visible('ai.interaction.panel');assert(!flat(await h.query('ai.conversation')).some((n:any)=>n.test_id==='ai.interaction.panel'));
 await capture('question');await h.resizeWindow(860,480);await capture('question-compact');await h.resizeWindow(1200,900);await h.sleep(100);const beforeEmpty=requests.length;await click('ai.interaction.submit');await visible('ai.interaction.error');assert.equal(requests.length,beforeEmpty);report.checks.push('empty answer is rejected without leaving the question');report.checks.push('real question tool replaces composer input; transcript has no approval card');
 const questionRequests=requests.length;assert(!(await h.query('ai.interaction.answer')).some(shown));await visible('ai.interaction.other');await click('ai.interaction.option.1');await click('ai.interaction.option.6');await visible('ai.interaction.answer');assert(!(await h.query('ai.interaction.other')).some(shown));await h.type_('保留自定义答案');assert.equal((await h.inputState('ai.interaction.answer')).buffer,'保留自定义答案');await capture('question-custom');await click('ai.interaction.option.1');assert(!(await h.query('ai.interaction.answer')).some(shown));await click('ai.interaction.option.6');assert.equal((await h.inputState('ai.interaction.answer')).buffer,'保留自定义答案');await click('ai.interaction.postpone');await visible('ai.interaction.pending');await click('ai.prompt');await h.type_('保留这条草稿');const draft=(await h.inputState('ai.prompt')).buffer;assert.equal(draft,'保留这条草稿');
 await h.sleep(200);assert.equal(requests.length,questionRequests,'postpone must not answer');
 await capture('pending-question');await click('ai.interaction.pending');await visible('ai.interaction.option.1');assert.equal((await h.inputState('ai.interaction.answer')).buffer,'保留自定义答案');
 report.checks.push('postpone leaves provider waiting and restores ordinary input');
 await click('ai.interaction.option.0');await click('ai.interaction.submit');
 await visible('ai.interaction.approve');assert.equal(await readFile(marker,'utf8').catch(()=>null),null,'zero execution before approval');
 assert(!(await h.query('ai.stop')).some(shown));assert(!(await h.query('ai.send')).some(shown));
 await capture('approval');
 const content=await visible('ai.interaction.panel');const beforeScroll=await visible('ai.interaction.approve');await h.scrollAt(content.rect.x+content.rect.w/2,content.rect.y+content.rect.h/2,0,600);await h.sleep(120);const afterScroll=await visible('ai.interaction.approve');assert.deepEqual(afterScroll.rect,beforeScroll.rect,'decision row stays fixed while request scrolls');
 await h.resizeWindow(860,480);await capture('approval-compact');await h.resizeWindow(1200,900);await h.sleep(100);report.checks.push('compact window retains every action; request scrolling leaves decisions fixed');await click('ai.interaction.postpone');await visible('ai.prompt');assert.equal((await h.inputState('ai.prompt')).buffer,draft);
 const capsule=await visible('ai.interaction.pending');const prompt=await visible('ai.prompt');assert(capsule.rect.y+capsule.rect.h<prompt.rect.y,'pending is above ordinary composer');
 await capture('pending-approval');await click('ai.interaction.pending');await click('ai.interaction.approve');
 await h.waitFor(async()=>text(await h.query('ai.panel')).includes('COMPOSER_FINISHED_approve')||null,30000);assert.equal(await readFile(marker,'utf8'),'once');report.checks.push('exact command approval executes once and continues provider');
 await click('ai.prompt');await h.key('a',{cmd:true});await h.type_('验证拒绝');await click('ai.send');await visible('ai.interaction.reject');await click('ai.interaction.reject');await h.waitFor(async()=>text(await h.query('ai.panel')).includes('COMPOSER_FINISHED_reject')||null,30000);assert.equal(await readFile(marker,'utf8'),'once');report.checks.push('reject resumes provider with zero additional execution');
 await click('ai.prompt');await h.key('a',{cmd:true});await h.type_('验证停止');await click('ai.send');await visible('ai.interaction.submit');await click('ai.interaction.postpone');await visible('ai.interaction.pending');await click('ai.stop');await h.waitFor(async()=>!(await h.query('ai.interaction.pending')).some(shown)||null,15000);await visible('ai.send');assert.equal(await readFile(marker,'utf8'),'once');report.checks.push('original Stop cancels postponed question and removes pending capsule');
 assert.equal(serverError,null);report.status='passed';await h.screenshot(join(out,'finished.png'));console.log(JSON.stringify(report));
}catch(err){report.status='failed';report.error=String(err);await h.screenshot(join(out,'failure.png')).catch(()=>{});await writeFile(join(out,'failure.tree.json'),JSON.stringify(await h.query('ai.panel').catch(()=>[]),null,2));throw err;
}finally{await writeFile(join(out,'report.json'),JSON.stringify({...report,serverError},null,2));await writeFile(join(out,'requests.json'),JSON.stringify(requests,null,2));app.kill();await ended;await log.close();await new Promise<void>(r=>server.close(()=>r()));}
