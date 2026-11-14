/** Isolated native settings + local skill + actual MCP tool chain. No shell business commands. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,writeFile,readFile,open,realpath,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-v04-extensions-build'),binary=resolve(process.env.ZW_SKILLS_BINARY??join(prefix,'bin/zerowork'));
const out=resolve(process.argv[2]??'/tmp/zw-v04-extensions-native');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-extensions-')),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot'),source=join(iso,'skill');
for(const dir of [data,rpc,zdot,source])await mkdir(dir);await writeFile(join(zdot,'.zshrc'),"PS1='extensions%# '\n");
await mkdir(join(source,'native-material'));await mkdir(join(source,'z-companion'));await writeFile(join(source,'z-companion','SKILL.md'),'---\nname: companion\ndescription: Summarize supplied connection logs. WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW\n---\nCOMPANION_SKILL_EVIDENCE. Summarize only the supplied log.\n');await writeFile(join(source,'native-material','SKILL.md'),'---\nname: native-material\ndescription: Inspect supplied material only\n---\nNATIVE_SKILL_EVIDENCE. Read only supplied material.\n');
const oversized=join(iso,'oversized');await mkdir(oversized);await writeFile(join(oversized,'SKILL.md'),'---\nname: oversized\ndescription: Invalid reference test\n---\n[missing](references/missing.txt)\n');
const tracePath=join(iso,'mcp-trace.jsonl'),scriptPath=join(iso,'mcp.py');
await writeFile(scriptPath,`import sys,json,os\nwith open(${JSON.stringify(tracePath)},'a') as f:f.write(json.dumps({'started':True})+'\\n')\nfor line in sys.stdin:\n r=json.loads(line);m=r.get('method');i=r.get('id')\n with open(${JSON.stringify(tracePath)},'a') as f:f.write(json.dumps({'method':m})+'\\n')\n if i is None:continue\n if m=='initialize':out={'protocolVersion':'2025-11-25','capabilities':{'tools':{}}}\n elif m=='tools/list':out={'tools':[{'name':'material','inputSchema':{'type':'object','additionalProperties':False,'properties':{'query':{'type':'string'},'limit':{'type':'integer','minimum':1}},'required':['query','limit']}},{'name':'shell','inputSchema':{'type':'object','properties':{'command':{'type':'string'}},'required':['command']}}]}\n elif m=='tools/call':out={'content':[{'type':'text','text':'NATIVE_MCP_EVIDENCE '+r['params']['arguments']['query']}]}\n print(json.dumps({'jsonrpc':'2.0','id':i,'result':out}),flush=True)\n`);
const httpCalls:any[]=[];
const mcpHttp=createServer(async(req,res)=>{if(req.method==='DELETE'){res.writeHead(204);res.end();return}if(req.method==='GET'){res.writeHead(405);res.end();return}let raw='';for await(const part of req)raw+=part;const r=JSON.parse(raw);httpCalls.push(r);if(r.method==='server/discover'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({jsonrpc:'2.0',id:r.id,error:{code:-32601,message:'Legacy reference server'}}));return}if(r.id==null){res.writeHead(202);res.end();return}res.writeHead(200,{'content-type':'application/json','Mcp-Session-Id':'native-http'});res.end(JSON.stringify({jsonrpc:'2.0',id:r.id,result:r.method==='initialize'?{protocolVersion:'2025-11-25',capabilities:{tools:{}}}:{tools:[{name:'material',inputSchema:{type:'object',additionalProperties:false,properties:{text:{type:'string'}},required:['text']}}]}}))});await new Promise<void>(done=>mcpHttp.listen(0,'127.0.0.1',done));
const requests:any[]=[];let fixtureError:string|null=null;let round=0;let skill:any;let capability:string='';let summaryCount=0;let selectedSkill:any;
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const finish=(res:any,text:string)=>res.end(frame({content:text})+'data: '+JSON.stringify({choices:[],usage:{prompt_tokens:12,completion_tokens:3}})+'\n\ndata: [DONE]\n\n');
const tool=(res:any,name:string,args:any)=>res.end(frame({tool_calls:[{index:0,id:'ext-'+round,type:'function',function:{name,arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n');
const provider=createServer(async(req,res)=>{try{if(req.method!=='POST'){res.end('{"data":[{"id":"extensions"}]}');return}let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);res.writeHead(200,{'content-type':'text/event-stream'});
 const system=body.messages.find((m:any)=>m.role==='system')?.content??'';
 if(system.includes('Create concise conversation memory')){
  summaryCount++;
  assert(!system.includes('user-selected local skill'));
  finish(res,'SKILL_COMPACTION_MEMORY. Continue inspecting the same supplied material.');return
 }
 if(!body.tools?.length){finish(res,'扩展测试');return}requests.push(body);await writeFile(join(out,'requests.json'),JSON.stringify(requests,null,2));round++;
 if(round===11){
  const user=body.messages.filter((message:any)=>message.role==='user').at(-1);
  assert.equal(user.content,'继续');
  assert(!system.includes('"name":"native-material"'));
  assert(!JSON.stringify(body.messages).includes('NATIVE_SKILL_EVIDENCE'));
  finish(res,'EXPLICIT_SKILL_DONE_'+round);return
 }
 if(round>=7){
  const firstCatalogEntry=system.split('\n').filter((line:string)=>line.startsWith('{"name":')).map((line:string)=>JSON.parse(line)).find((entry:any)=>entry.name==='native-material'&&entry.description);
  const user=body.messages.filter((message:any)=>message.role==='user').at(-1);
  const blocks=String(user.content).split('\n').filter((line:string)=>line.startsWith('{"name":"native-material"')&&line.includes('"content":'));
  assert.equal(blocks.length,1,'exactly one loaded skill on the outgoing request');
  const loaded=JSON.parse(blocks[0]);
  if(round===7)selectedSkill=firstCatalogEntry;
  assert.equal(loaded.skill_id,selectedSkill.skill_id);
  assert.equal(loaded.revision,selectedSkill.revision);
  assert.match(loaded.content,/NATIVE_SKILL_EVIDENCE|REIMPORTED_SKILL_EVIDENCE/);
  assert.equal(loaded.next_offset,null);
  assert.match(user.content,round===7?/^\/skill native-material/:/^继续\n/);
  if(round===10){
   assert(JSON.stringify(body.messages).includes('SKILL_COMPACTION_MEMORY'));
   assert(!body.messages.some((message:any)=>message.role==='user'&&String(message.content).includes('/skill native-material')));
  }
  finish(res,'EXPLICIT_SKILL_DONE_'+round);return
 }
 const result=(id:string)=>{const item=body.messages.filter((m:any)=>m.role==='tool'&&String(m.content).includes(id)).at(-1);assert(item,'missing tool result '+id);const wire=String(item.content);const start=wire.indexOf('{');const parsed=JSON.parse(wire.slice(start));const find=(o:any):any=>{if(o&&typeof o==='object'){if(o.skills||o.tools)return o;for(const v of Object.values(o)){const found=find(v);if(found)return found}}else if(typeof o==='string'&&o.startsWith('{')){try{return find(JSON.parse(o))}catch{}}return null};return find(parsed)??parsed;};
 if(round===1||round===5){
  const system=body.messages.find((m:any)=>m.role==='system').content;
  assert.match(system,/When the user explicitly names a skill to use, or the task clearly matches an available skill's description, call host__skills with action=read/);
  assert(!system.includes('NATIVE_SKILL_EVIDENCE')&&!system.includes('REIMPORTED_SKILL_EVIDENCE')&&!system.includes('COMPANION_SKILL_EVIDENCE'));
  skill=system.split('\n').filter((line:string)=>line.startsWith('{"name":')).map((line:string)=>JSON.parse(line)).find((entry:any)=>entry.name===(round===1?'native-material':'companion'));
  if(round===1)assert.equal(skill.description,'Inspect supplied material only');
  else assert.match(skill.description,/^Summarize supplied connection logs/);
  assert(body.tools.some((t:any)=>t.function?.name==='host__skills'));
  const user=body.messages.filter((m:any)=>m.role==='user').at(-1);
  assert.equal(JSON.stringify(user.content).includes('native-material'),round===1);
  assert(!JSON.stringify(user.content).includes('companion'));
  tool(res,'host__skills',{action:'read',skill_id:skill.skill_id,revision:skill.revision});return
 }
 if(round===2||round===6){
  const evidence=round===6?'COMPANION_SKILL_EVIDENCE':process.env.ZW_SKILLS_PICKER_HANDOFF?'REIMPORTED_SKILL_EVIDENCE':'NATIVE_SKILL_EVIDENCE';
  assert(String(body.messages.at(-1).content).includes(evidence));
  if(round===6){finish(res,'IMPLICIT_SKILL_DONE');return}
  tool(res,'host__mcp_ucatalog',{action:'tools',server_id:configuredServerId});return
 }
 if(round===3){const catalog=result('capability_ref');assert(catalog.tools.some((t:any)=>t.remote_name==='shell'&&!t.available));capability=catalog.tools.find((t:any)=>t.remote_name==='material').capability_ref;tool(res,'host__mcp_ucall',{capability_ref:capability,request_key:'native-once',arguments:{query:'explicit supplied text',limit:3}});return}
 assert(JSON.stringify(body.messages).includes('NATIVE_MCP_EVIDENCE'));finish(res,'EXTENSIONS_NATIVE_DONE');
}catch(error){fixtureError=String(error);finish(res,'FIXTURE_FAILED')} });await new Promise<void>(done=>provider.listen(0,'127.0.0.1',done));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${process.env.ZW_SKILLS_THEME??'dark'}"\nfont_size=14\n[ai]\ndefault_provider="extensions"\npermission_mode="confirm"\n[[ai.providers]]\nid="extensions"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(provider.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="extensions"\ncontext_window=200000\ndefault=true\n`);
let configuredServerId='';process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts'));const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(done=>app.once('close',done)),alive=()=>app.exitCode===null&&app.signalCode===null;
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(nodes:any)=>flat(nodes).map(n=>n.text??'').join(' ');
const visible=(id:string)=>h.waitFor(async()=>{assert(alive());return(await h.query(id)).find(shown)??null},15000);
const report:any={status:'running',isolation:iso,binary,checks:[],screenshots:[]};
const scrollTo=async(id:string)=>{for(let i=0;i<24;i++){const n=await visible(id),vp=(await visible('settings.viewport')).rect;if(n.rect.y>=vp.y&&n.rect.y+n.rect.h<=vp.y+vp.h)return n;const delta=n.rect.y<vp.y?vp.y-n.rect.y+25:vp.y+vp.h-n.rect.y-n.rect.h-25;await h.scrollAt(vp.x+vp.w-4,vp.y+vp.h/2,0,Math.max(-500,Math.min(500,delta)));await h.sleep(90)}throw Error('Cannot reveal '+id)};
const click=async(id:string,settings=false)=>{report.last_action=id;if(settings)await scrollTo(id);else await visible(id);assert((await h.clickTestId(id)).ok,id)};
const fill=async(id:string,value:string)=>{await click(id,true);await h.key('a',{cmd:true});await h.type_(value)};
const capture=async(name:string)=>{await h.mouseMove(1,1);await h.sleep(400);assert((await h.screenshot(join(out,name+'.png'))).ok);report.screenshots.push(join(out,name+'.png'))};
const dropSkill=async(path:string)=>{const n=await scrollTo('settings.skills.toolbar');await h.dragAt(n.rect.x+20,n.rect.y+n.rect.h/2,0,path);await h.dragAt(n.rect.x+20,n.rect.y+n.rect.h/2,3,path)};
// Optional real NSOpenPanel acceptance: a UI driver reads picker-handoff.json.
const picker=async(phase:string,path:string,action:()=>Promise<void>)=>{const done=join(out,`picker-${phase}.done`);await rm(done,{force:true});await writeFile(join(out,'picker-handoff.json'),JSON.stringify({phase,path,done}));await action();await h.waitFor(async()=>{try{return(await readFile(done,'utf8')).trim()==='done'||null}catch{return null}},300000);await rm(join(out,'picker-handoff.json'),{force:true})};
const trace=async()=>{try{return (await readFile(tracePath,'utf8')).trim().split('\n').map(x=>JSON.parse(x))}catch{return []}};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1280,900);await click('toolbar.settings');await click('settings.nav.ai');await visible('settings.ai.extensions');await capture('01-extensions-empty');await click('settings.ai.skills.header',true);await h.sleep(250);await click('settings.ai.mcp.header',true);await h.sleep(250);
 assert(text(await h.query('settings.skills.summary')).includes('0 个技能 · 0 个启用'));
 for(const id of ['settings.skills.path','settings.skills.import','settings.skills.file','settings.skills.folder'])assert.equal((await h.query(id)).length,0,'redundant control removed: '+id);
 if(process.env.ZW_SKILLS_PICKER_HANDOFF){await scrollTo('settings.skills.add');await picker('cancel','',()=>click('settings.skills.add'));assert(text(await h.query('settings.skills.summary')).includes('0 个技能 · 0 个启用'));assert.equal((await h.query('settings.extensions.cancel')).length,0,'cancellation starts no import');report.checks.push('Real system picker cancellation leaves skills unchanged')}
 await dropSkill(oversized);await h.waitFor(async()=>text(await h.query('settings.ai.extensions')).includes('缺失的文件')||null,15000);await scrollTo('settings.extensions.status');await capture('01b-import-error');
 if(process.env.ZW_SKILLS_PICKER_HANDOFF){await scrollTo('settings.skills.add');await picker('collection',source,()=>click('settings.skills.add'))}else await dropSkill(source);await h.waitFor(async()=>text(await h.query('settings.ai.skills')).includes('native-material')||null,15000);assert(!(await readFile(join(data,'config.toml'),'utf8')).includes('native-material'));
 assert(text(await h.query('settings.skills.summary')).includes('2 个技能 · 2 个启用'));await click('settings.skill.0.toggle',true);await h.waitFor(async()=>text(await h.query('settings.skills.summary')).includes('2 个技能 · 1 个启用')||null,15000);await click('settings.skill.0.toggle',true);await h.waitFor(async()=>text(await h.query('settings.skills.summary')).includes('2 个技能 · 2 个启用')||null,15000);
 for(const [width,height]of [[1280,900],[860,480]]){
  await h.resizeWindow(width,height);const header=(await visible('settings.ai.skills.header')).rect,vp=(await visible('settings.viewport')).rect;await h.scrollAt(vp.x+vp.w-4,vp.y+vp.h/2,0,vp.y-header.y);await h.sleep(150);await scrollTo('settings.skill.0.row');
  const name=(await visible('settings.skill.0.name')).rect,toggle=(await visible('settings.skill.0.toggle')).rect,view=(await visible('settings.skill.0.view')).rect,more=(await visible('settings.skill.0.more')).rect,row=(await visible('settings.skill.0.row')).rect;
  const toolbar=(await visible('settings.skills.toolbar')).rect,summary=(await visible('settings.skills.summary')).rect,add=(await visible('settings.skills.add')).rect;assert.equal(toolbar.h,28);assert(summary.x+summary.w<=add.x+.5&&Math.abs(summary.y+summary.h/2-add.y-add.h/2)<1&&add.x+add.w<=toolbar.x+toolbar.w+.5,'count left and add right stay on one line');
  assert(name.w>20&&name.x+name.w<=toggle.x+.5&&toggle.x+toggle.w<=view.x+.5&&view.x+view.w<=more.x+.5&&more.x+more.w<=row.x+row.w+.5,'skill controls remain separated');await capture('skills-'+width);
  await click('settings.skill.0.more');await h.tree();await h.sleep(300);await h.tree();await capture('skills-menu-'+width);await h.key('escape');
 }
 await h.resizeWindow(1280,900);
 await writeFile(join(source,'native-material','SKILL.md'),'---\nname: native-material\ndescription: Inspect supplied material only\n---\nNATIVE_SKILL_EVIDENCE. REIMPORTED_SKILL_EVIDENCE. Read only supplied material.\n');
 if(process.env.ZW_SKILLS_PICKER_HANDOFF){await click('settings.skill.0.more',true);await picker('reimport',join(source,'native-material','SKILL.md'),()=>h.key('return').then(()=>{}));await h.waitFor(async()=>(await h.query('settings.skill.0.view')).some(n=>n.focusable)&&!(await h.query('settings.extensions.cancel')).length?true:null,15000);assert.equal((await h.query('settings.extensions.status')).length,0,'successful import has no status footer');report.checks.push('The same real system picker imports a collection directory and reimports a single SKILL.md file automatically')}else report.checks.push('Native system picker/reimport not exercised; imports use the native file-drop handler');
 assert.equal((await h.query('settings.extensions.detail')).length,0,'skill starts collapsed');await click('settings.skill.0.view',true);await visible('settings.extensions.detail');assert.equal((await h.query('settings.extensions.status')).length,0,'skill view has no status footer');await h.waitFor(async()=>text(await h.query('settings.skill.0.row')).includes(process.env.ZW_SKILLS_PICKER_HANDOFF?'REIMPORTED_SKILL_EVIDENCE':'NATIVE_SKILL_EVIDENCE')||null,15000);await scrollTo('settings.extensions.detail');await capture('02-imported-skill');await click('settings.skill.0.view',true);await h.waitFor(async()=>(await h.query('settings.extensions.detail')).length===0?true:null,15000);assert(text(await h.query('settings.skill.0.view')).includes('查看'));await capture('02a-skill-collapsed');await click('settings.skill.0.view',true);await h.waitFor(async()=>text(await h.query('settings.skill.0.view')).includes('收起')||null,15000);
 if(process.env.ZW_SKILLS_UI_ONLY){await click('settings.skill.0.more',true);await h.key('down');await h.key('return');await h.waitFor(async()=>(await h.query('settings.extensions.detail')).length===0?true:null,15000);assert(text(await h.query('settings.skill.0.name')).includes('companion'));assert(text(await h.query('settings.skills.summary')).includes('1 个技能 · 1 个启用'));report.checks.push('Single-line toolbar, live total/enabled counts, file-drop import, error, view/menu and removal in both window sizes');report.status='passed'}else{
 await click('settings.skill.0.view',true);await h.waitFor(async()=>(await h.query('settings.extensions.detail')).length===0?true:null,15000);
 await click('settings.mcp.add',true);await fill('settings.mcp.field.name','原生材料服务');await fill('settings.mcp.field.program','/usr/bin/python3');await fill('settings.mcp.field.arguments',scriptPath);await fill('settings.mcp.field.environment','MATERIAL_TOKEN=native-credential-secret');await fill('settings.mcp.field.bindings','material');await click('settings.mcp.apply',true);
 assert.equal((await trace()).length,0,'applying config never starts process');await click('settings.mcp.0.test',true);await h.waitFor(async()=>text(await h.query('settings.mcp.0.metadata')).includes('2025-11-25')||null,15000);assert.equal((await h.query('settings.extensions.detail')).length,0,'connection test stays collapsed');assert.equal((await h.query('settings.extensions.status')).length,0,'successful connection has no status footer');await capture('03a-mcp-default-collapsed');await click('settings.mcp.0.view',true);await h.waitFor(async()=>text(await h.query('settings.extensions.detail')).includes('可用')||null,15000);assert(text(await h.query('settings.mcp.0.view')).includes('收起'));await click('settings.mcp.0.view',true);await h.waitFor(async()=>(await h.query('settings.extensions.detail')).length===0?true:null,15000);assert(text(await h.query('settings.mcp.0.view')).includes('查看'));await click('settings.mcp.0.view',true);await visible('settings.extensions.detail');assert(!(await trace()).some(r=>r.method==='tools/call'),'connection test sends no business tool call');assert(text(await h.query('settings.mcp.0.row')).includes('可用'),'MCP detail stays inside its server row');await capture('03-tested-stdio');
 await click('settings.mcp.add',true);await click('settings.mcp.http',true);await fill('settings.mcp.field.name','HTTP 材料服务');await fill('settings.mcp.field.endpoint',`http://127.0.0.1:${(mcpHttp.address()as any).port}/mcp`);await fill('settings.mcp.field.headers','X-Fixture:native-http-secret');await fill('settings.mcp.field.bindings','material');await capture('03b-http-form');await click('settings.mcp.apply',true);await click('settings.mcp.1.test',true);await h.waitFor(async()=>text(await h.query('settings.mcp.1.metadata')).includes('2025-11-25')||null,15000);assert(!text(await h.query('settings.mcp.1.row')).includes('可用'),'second test does not expand itself');await click('settings.mcp.1.view',true);await h.waitFor(async()=>text(await h.query('settings.extensions.detail')).includes('HTTP 材料服务')||null,15000);await click('settings.mcp.1.view',true);await h.waitFor(async()=>(await h.query('settings.extensions.detail')).length===0?true:null,15000);await click('settings.mcp.0.view',true);await h.waitFor(async()=>text(await h.query('settings.extensions.detail')).includes('原生材料服务')||null,15000);assert(!httpCalls.some(r=>r.method==='tools/call'));await capture('03c-http-tested');
 await click('settings.mcp.0.toggle',true);await click('settings.save');await h.waitFor(async()=>(await readFile(join(data,'config.toml'),'utf8')).includes('zw1_')||null,15000);const saved=await readFile(join(data,'config.toml'),'utf8');assert(!saved.includes('native-credential-secret'));assert(!saved.includes('native-http-secret'));const encoded=JSON.parse(/^extensions = (.+)$/m.exec(saved)![1]);const config=JSON.parse(encoded);configuredServerId=config.servers[0].id;assert(config.servers[0].enabled);assert.equal(config.servers[1].transport,'http');assert.equal(config.servers[1].headers[0].value,'');assert(config.servers[1].headers[0].secret_ref);assert(config.skills[0].enabled);assert.equal(config.servers[0].environment[0].value,'');
 await click('settings.skill.0.toggle',true);await click('settings.revert');await h.waitFor(async()=>{const n=(await h.query('settings.skill.0.toggle'))[0];const thumb=n?.children?.[0]?.children?.[0];return thumb&&thumb.rect.x>n.rect.x+10?true:null},15000);assert.equal(await readFile(join(data,'config.toml'),'utf8'),saved);await h.resizeWindow(860,480);await capture('04-compact-restored');await click('settings.close');
 await rm(source,{recursive:true});await h.resizeWindow(1280,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.prompt');await h.type_('使用 native-material 技能，再验证显式 MCP 材料调用');await click('ai.send');await h.waitFor(async()=>{if(fixtureError)throw Error(fixtureError);if(text(await h.query('ai.panel')).includes('EXTENSIONS_NATIVE_DONE'))return true;const approvals=await h.query('ai.interaction.approve');if(approvals.some(shown)){await capture('approval-'+round);await h.clickTestId('ai.interaction.approve')}return null},30000);assert.equal(round,4);await click('ai.prompt');await h.type_('请总结这两条连接日志：SSH 握手成功，SFTP 子系统启动失败。');await click('ai.send');await h.waitFor(async()=>{if(fixtureError)throw Error(fixtureError);return text(await h.query('ai.panel')).includes('IMPLICIT_SKILL_DONE')||null},30000);assert.equal(round,6);assert.equal((await trace()).filter(r=>r.method==='tools/call').length,1);await capture('05-tools-completed');report.checks.push('native batch import/view uses managed packages after source removal; import failure is shown inside the skill settings card','stdio and HTTP forms test and save through existing settings transaction and Keychain refs; config contains no plaintext secrets','explicit connection test discovers callable and unavailable tools without business calls','mock provider reads the pinned skill directly for named and clearly matching turns, and calls the selected MCP capability once');
 const sendSkill=async(message:string,expected:number)=>{
  if(message){await click('ai.prompt');assert((await h.type_(message)).ok);}
  await click('ai.send');
  await h.waitFor(async()=>{
   if(fixtureError)throw Error(fixtureError);
   return text(await h.query('ai.panel')).includes('EXPLICIT_SKILL_DONE_'+expected)&&!(await h.query('ai.stop')).some(shown)||null;
  },30000);
  assert.equal(round,expected);
 };
 const skillRows=()=>h.query('ai.skill_picker.skill');
 const clearPrompt=async()=>{await click('ai.prompt');await h.key('a',{cmd:true});await h.key('backspace');};
 const assertSendDisabled=async(command:string)=>{
  const send=await visible('ai.send');
  assert(!send.focusable,command+' disables the native send button');
  assert((await h.clickAt(send.rect.x+send.rect.w/2,send.rect.y+send.rect.h/2)).ok);
  assert.equal((await h.inputState('ai.prompt')).buffer,command);
  assert.equal(round,6,command+' does not send a model request');
 };
 await click('ai.prompt');assert((await h.type_('/')).ok);
 await visible('ai.skill_picker.command');
 assert(!(await skillRows()).some(shown));
 await capture('06-command-menu');
 assert(!(await visible('ai.send')).focusable,'/ disables the native send button');
 await h.key('return');await visible('ai.skill_picker.skill');
 assert.equal((await h.inputState('ai.prompt')).buffer,'/skill');
 assert(!(await visible('ai.send')).focusable,'/skill disables the native send button');
 assert.equal((await skillRows()).filter(shown).length,2);
 await h.resizeWindow(860,480);
 const menu=await visible('ai.skill_picker');
 assert(menu.rect.x>=0&&menu.rect.y>=0&&menu.rect.x+menu.rect.w<=860&&menu.rect.y+menu.rect.h<=480);
 await capture('07-skill-menu-compact');
 await h.key('down');await h.key('return');
 assert.equal((await h.inputState('ai.prompt')).buffer,'/skill companion\n');
 assert.equal(round,6,'selecting a skill only edits the draft');
 await clearPrompt();
 assert((await h.type_('/skill')).ok);
 await visible('ai.skill_picker.skill');
 await h.key('escape');
 await h.waitFor(async()=>!(await h.query('ai.skill_picker')).some(shown)||null,5000);
 assert.equal((await h.inputState('ai.prompt')).buffer,'/skill');
 await assertSendDisabled('/skill');
 await clearPrompt();
 assert((await h.type_('/')).ok);await visible('ai.skill_picker.command');
 await h.key('escape');
 await h.waitFor(async()=>!(await h.query('ai.skill_picker')).some(shown)||null,5000);
 await assertSendDisabled('/');
 await clearPrompt();
 assert((await h.type_('/skill mater')).ok);
 const nativeRow=(await h.waitFor(async()=>(await skillRows()).find(row=>shown(row)&&text(row).includes('native-material'))??null,5000));
 assert.equal((await skillRows()).filter(shown).length,1);
 assert((await h.clickAt(nativeRow.rect.x+30,nativeRow.rect.y+16)).ok);
 assert.equal((await h.inputState('ai.prompt')).buffer,'/skill native-material\n');
 assert((await h.type_('检查给定材料并记录当前进度。')).ok);
 await h.resizeWindow(1280,900);
 assert.equal((await visible('ai.send')).focusable,true,'selected skill and task enable sending');
 await sendSkill('',7);
 await sendSkill('继续',8);
 await sendSkill('继续',9);
 await click('ai.composer.usage');await click('ai.usage.compaction.start');
 await h.waitFor(async()=>summaryCount>0&&text(await h.query('ai.transcript.compaction')).includes('上下文已压缩')||null,30000);
 await sendSkill('继续',10);
 await capture('06-skill-after-compaction');
 await click('toolbar.settings');await click('settings.nav.ai');
 if(!(await h.query('settings.skill.0.toggle')).some(shown))await click('settings.ai.skills.header',true);
 await click('settings.skill.0.toggle',true);await click('settings.save');
 await h.waitFor(async()=>JSON.parse(JSON.parse(/^extensions = (.+)$/m.exec(await readFile(join(data,'config.toml'),'utf8'))![1])).skills.find((entry:any)=>entry.name==='native-material').enabled===false||null,15000);
 await click('settings.close');
 if(!(await h.query('ai.prompt')).some(shown))await click('toolbar.ai');
 await click('ai.prompt');assert((await h.type_('/skill')).ok);
 await visible('ai.skill_picker.skill');
 assert.deepEqual((await skillRows()).filter(shown).map(row=>text(row).trim()),['companion']);
 await clearPrompt();
 await sendSkill('继续',11);
 await click('ai.prompt');assert((await h.type_('/skill native-material\n检查材料')).ok);await click('ai.send');
 await h.waitFor(async()=>text(await h.query('notifications.toast.0')).includes('指定技能已停用')||null,15000);
 assert.equal(round,11,'selecting a disabled skill never calls the provider');
 await click('ai.prompt');await h.key('a',{cmd:true});await h.key('backspace');
 report.checks.push('explicit skill arrives before the first model call and stays pinned through continue and real compaction');
 report.checks.push('two-level slash picker supports keyboard and click selection, Escape, compact layout and enabled-only catalog; no request on selection');
 report.checks.push('bare / and /skill disable the native send button and cannot submit; selecting a skill and entering a task enables sending');
 report.checks.push('disabling the selected skill suppresses restoration and rejects explicit selection locally');
 report.summary_requests=summaryCount;
 report.status='passed';report.requests=requests;}
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await capture('failure').catch(()=>{});await h.query('settings.panel').then(tree=>writeFile(join(out,'failure-tree.json'),JSON.stringify(tree,null,2))).catch(()=>{})}
finally{
 // The app may exit between shutdown queries; do not retain the picker handoff timeout.
 process.env.ZENIT_E2E_TIMEOUT_MS='2000';
 try{if(alive()){await h.request('POST','/zerowork/windows',{action:'quit'});const start=performance.now();while(alive()&&performance.now()-start<15000){for(const id of ['settings.confirmation.discard','groups.close.accept','local.close.accept','session.close.accept']){if(!alive())break;try{const q=await h.query(id);if(!Array.isArray(q))break;if(q.some(shown))await h.clickTestId(id)}catch{break}}await Promise.race([ended,h.sleep(80)])}}}catch(error){report.quit_error=String(error)}
 if(alive()){report.forced=true;app.kill('SIGTERM');await ended}report.exit_code=app.exitCode;report.signal=app.signalCode;if(report.forced||app.exitCode!==0){report.status='failed';process.exitCode=1}
 mcpHttp.closeAllConnections();await new Promise<void>(done=>mcpHttp.close(()=>done()));provider.closeAllConnections();await new Promise<void>(done=>provider.close(()=>done()));await log.close();const logs=await readFile(join(out,'app.log'),'utf8');if(/leaked \[addr:|panic:|double free/i.test(logs)){report.status='failed';process.exitCode=1}await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}));
}
