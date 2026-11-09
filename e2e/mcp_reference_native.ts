/** Independent official MCP reference servers, exercised through the native app.
 * npm install --prefix /tmp/zw-mcp-reference --registry=https://registry.npmjs.org
 *   @modelcontextprotocol/server-everything@2.2.1 @modelcontextprotocol/sdk@1.32.2
 * No production configuration, account or cloud data is used. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {createServer as tcpServer} from 'node:net';
import {mkdir,mkdtemp,writeFile,readFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-standard-mcp-build'), reference=resolve(process.env.ZW_MCP_REFERENCE??'/tmp/zw-mcp-reference');
const out=resolve(process.argv[2]??'/tmp/zw-mcp-reference-evidence');await mkdir(out,{recursive:true,mode:0o700});
const iso=await realpath(await mkdtemp('/tmp/zw-mcp-ref-')),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
for(const path of [data,rpc,zdot])await mkdir(path);await writeFile(join(zdot,'.zshrc'),"PS1='reference%# '\n");
const freePort=async()=>{const s=tcpServer();await new Promise<void>(d=>s.listen(0,'127.0.0.1',d));const p=(s.address() as any).port;await new Promise<void>(d=>s.close(()=>d()));return p};
const httpPort=await freePort(),oauthPort=await freePort(),authPort=await freePort(),urlPort=await freePort(),urlAuthPort=await freePort();
const everything=join(reference,'node_modules/@modelcontextprotocol/server-everything/dist/index.js'),sdk=join(reference,'node_modules/@modelcontextprotocol/sdk/dist/esm/examples/server/simpleStreamableHttp.js');
const urlExample=join(reference,'node_modules/@modelcontextprotocol/sdk/dist/esm/examples/server/elicitationUrlExample.js');
const logs=await open(join(out,'servers.log'),'w',0o600);
const children=[spawn(process.execPath,[everything,'streamableHttp'],{env:{...process.env,PORT:String(httpPort)},stdio:['ignore',logs.fd,logs.fd]}),spawn(process.execPath,[sdk,'--oauth','--oauth-strict'],{env:{...process.env,MCP_PORT:String(oauthPort),MCP_AUTH_PORT:String(authPort)},stdio:['ignore',logs.fd,logs.fd]}),spawn(process.execPath,[urlExample],{env:{...process.env,MCP_PORT:String(urlPort),MCP_AUTH_PORT:String(urlAuthPort)},stdio:['ignore',logs.fd,logs.fd]})];
for(const port of [httpPort,oauthPort,authPort,urlPort,urlAuthPort])for(let i=0;i<100;i++){try{await fetch(`http://localhost:${port}/.well-known/oauth-authorization-server`);break}catch{await new Promise(d=>setTimeout(d,50));if(i===99)throw Error('Reference server not ready')}}
let phase=0,round=0,error:string|null=null,uri='',refs:any={},sampleRequests=0;
const report:any={status:'running',reference:{everything:JSON.parse(await readFile(join(reference,'node_modules/@modelcontextprotocol/server-everything/package.json'),'utf8')).version,sdk:JSON.parse(await readFile(join(reference,'node_modules/@modelcontextprotocol/sdk/package.json'),'utf8')).version},steps:[],questions:[],reviews:[],screenshots:[],isolation:iso};
const deep=(value:any,test:(o:any)=>boolean):any=>{if(value&&typeof value==='object'){if(test(value))return value;for(const v of Object.values(value)){const f=deep(v,test);if(f)return f}}else if(typeof value==='string'&&value.trimStart().startsWith('{')){try{return deep(JSON.parse(value),test)}catch{}}return null};
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
const provider=createServer(async(req,res)=>{try{if(req.method!=='POST'){res.end('{"data":[{"id":"gpt-4o"}]}');return}let raw='';for await(const p of req)raw+=p;const body=JSON.parse(raw);res.writeHead(200,{'content-type':'text/event-stream'});
 if(!body.tools?.length){sampleRequests++;res.end(frame({content:'REFERENCE_SAMPLING_RESPONSE'})+'data: [DONE]\n\n');return}
 round++;const server=phase===0?'reference-stdio':phase===1?'reference-http':phase===2?'reference-oauth':'reference-url';
 const tool=(name:string,args:any)=>res.end(frame({tool_calls:[{index:0,id:`ref-${phase}-${round}`,type:'function',function:{name,arguments:JSON.stringify(args)}}]})+'data: [DONE]\n\n');
 const request=(method:string,params:any={})=>tool('host__mcp_urequest',{server_id:server,method,params});
 const call=(name:string,args:any={})=>tool('host__mcp_ucall',{capability_ref:refs[name],request_key:`ref-${phase}-${round}`,arguments:args});
 const last=()=>{const m=body.messages.filter((m:any)=>m.role==='tool').at(-1);assert(m);const parsed=JSON.parse(m.content);const failure=deep(parsed,o=>(o.code&&o.retryable!==undefined)||o.error_code);assert(!failure||failure.code==='McpElicitationRequired',JSON.stringify(failure));return parsed};
 const catalog=()=>{const c=deep(last(),o=>Array.isArray(o.tools)&&o.tools.length);assert(c);refs=Object.fromEntries(c.tools.map((t:any)=>[t.remote_name,t.capability_ref]));assert(c.tools.filter((t:any)=>t.available).length>=1);assert.equal(c.protocol,phase<2?'2026-07-28':'2025-11-25');report.steps.push(`${server}: negotiated ${c.protocol}`)};
 const ok=(name:string)=>report.steps.push(`${server}: ${name}`);
 if(phase===0){switch(round){
 case 1:request('resources/list');return;
 case 2:{const r=deep(last(),o=>o.resources?.length);assert(r);uri=r.resources[0].uri;ok('resources/list');request('resources/templates/list');return}
 case 3:assert(deep(last(),o=>o.resourceTemplates?.length));ok('resource templates');request('resources/read',{uri});return;
 case 4:assert(deep(last(),o=>o.contents?.some((x:any)=>typeof x.text==='string')));ok('resources/read');request('prompts/list');return;
 case 5:assert(deep(last(),o=>o.prompts?.some((x:any)=>x.name==='args-prompt')));ok('prompts/list');request('prompts/get',{name:'args-prompt',arguments:{city:'Beijing'}});return;
 case 6:assert(deep(last(),o=>o.messages?.some((m:any)=>m.content?.text?.includes('Beijing'))));ok('prompts/get');request('completion/complete',{ref:{type:'ref/prompt',name:'completable-prompt'},argument:{name:'department',value:'Eng'}});return;
 case 7:assert(deep(last(),o=>o.completion?.values?.includes('Engineering')));ok('completion');tool('host__mcp_ucatalog',{action:'tools',server_id:server});return;
 case 8:catalog();ok('tool catalog with client capabilities');call('echo',{message:'REFERENCE_ECHO'});return;
 case 9:assert(JSON.stringify(last()).includes('REFERENCE_ECHO'));ok('echo');call('get-roots-list');return;
 case 10:assert(JSON.stringify(last()).includes('file:///tmp/zerowork-mcp-reference'));ok('roots/list');call('trigger-sampling-request',{prompt:'Reply with a short test token',maxTokens:100});return;
 case 11:assert(JSON.stringify(last()).includes('REFERENCE_SAMPLING_RESPONSE'));ok('sampling');call('trigger-elicitation-request');return;
 case 12:assert(JSON.stringify(last()).includes('Reference Tester'));ok('form elicitation');call('trigger-multi-step-elicitation');return;
 case 13:assert(JSON.stringify(last()).includes("Reference Tester's favorite color is blue"));ok('multi-round opaque state');call('trigger-url-elicitation',{url:`http://localhost:${httpPort}/`,message:'Open local reference page'});return;
 case 14:assert(JSON.stringify(last()).includes('URL elicitation flow'));ok('modern URL input_required');break;
 }}else if(phase===1){switch(round){
 case 1:tool('host__mcp_ucatalog',{action:'tools',server_id:server});return;
 case 2:catalog();call('get-roots-list');return;
 case 3:assert(JSON.stringify(last()).includes('file:///tmp/zerowork-mcp-reference'));ok('roots via HTTP server request');call('trigger-sampling-request',{prompt:'Reply test',maxTokens:100});return;
 case 4:assert(JSON.stringify(last()).includes('REFERENCE_SAMPLING_RESPONSE'));ok('HTTP sampling');call('trigger-elicitation-request');return;
 case 5:assert(/declin|拒绝/i.test(JSON.stringify(last())));ok('elicitation decline');request('resources/subscribe',{uri:'demo://resource/dynamic/text/1'});return;
 case 6:last();ok('subscribe');request('logging/setLevel',{level:'debug'});return;
 case 7:last();ok('per-request logging');call('get-header-params',{region:'eu-west',repeat:2});return;
 case 8:assert(deep(last(),o=>o.regionHeader==='eu-west'&&o.repeated?.length===2));ok('Mcp-Param header and standard HTTP routing');call('trigger-resource-update',{uri:'demo://resource/dynamic/text/1'});return;
 case 9:last();request('notifications/poll',{timeout_ms:500});return;
 case 10:assert(deep(last(),o=>o.resource_updated==='demo://resource/dynamic/text/1'));ok('subscriptions/listen notification stream');request('resources/unsubscribe',{uri:'demo://resource/dynamic/text/1'});return;
 case 11:last();ok('unsubscribe filter');break;
 }}else if(phase===2){switch(round){case 1:tool('host__mcp_ucatalog',{action:'tools',server_id:server});return;case 2:catalog();call('greet',{name:'ZeroWork OAuth'});return;case 3:assert(JSON.stringify(last()).includes('Hello, ZeroWork OAuth!'));ok('authorized greet');break}}else{switch(round){case 1:tool('host__mcp_ucatalog',{action:'tools',server_id:server});return;case 2:catalog();call('payment-confirm',{cartId:'REFERENCE-LOCAL-DEMO'});return;case 3:assert(deep(last(),o=>o.code==='McpElicitationRequired'&&o.automatically_retried===false));assert(JSON.stringify(last()).includes('accept'));ok('URL-required RPC error handled without replay');break}}
 res.end(frame({content:`MCP_REFERENCE_PHASE_${phase}_PASSED`})+'data: [DONE]\n\n');
 }catch(e){error=String(e);res.end(frame({content:'MCP_REFERENCE_FAILED '+error})+'data: [DONE]\n\n')}});
await new Promise<void>(d=>provider.listen(0,'127.0.0.1',d));
const bindings=['echo','get-roots-list','trigger-sampling-request','trigger-elicitation-request','trigger-multi-step-elicitation','trigger-url-elicitation','get-header-params','trigger-resource-update'].map(name=>({name}));
const servers=[{id:'reference-stdio',name:'Everything · stdio',enabled:true,program:process.execPath,args:[everything],roots:['file:///tmp/zerowork-mcp-reference'],bindings},{id:'reference-http',name:'Everything · HTTP',enabled:true,transport:'http',endpoint:`http://localhost:${httpPort}/mcp`,roots:['file:///tmp/zerowork-mcp-reference'],bindings},{id:'reference-oauth',name:'Official SDK · OAuth',enabled:true,transport:'http',endpoint:`http://localhost:${oauthPort}/mcp`,bindings:[{name:'greet'}]},{id:'reference-url',name:'Official SDK · URL interaction · WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW',enabled:true,transport:'http',endpoint:`http://localhost:${urlPort}/mcp`,bindings:[{name:'payment-confirm'}]}];
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${process.env.ZW_MCP_THEME??'dark'}"\nfont_size=14\n[ai]\ndefault_provider="reference"\npermission_mode="confirm"\nextensions=${JSON.stringify(JSON.stringify({skills:[],servers}))}\n[[ai.providers]]\nid="reference"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(provider.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="gpt-4o"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const log=await open(join(out,'app.log'),'w',0o600);const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_AUTOCONNECT:'0',ZDOTDIR:zdot},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(d=>app.once('close',d));const alive=()=>app.exitCode===null&&app.signalCode===null;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(nodes:any)=>flat(nodes).map(n=>n.text??'').join(' '),shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&n.rect?.w>0&&n.rect?.h>0;
const until=async(fn:()=>Promise<any>,timeout:number)=>{const start=performance.now();while(performance.now()-start<timeout){if(error)throw Error(error);const value=await fn();if(value)return value;await h.sleep(80)}throw Error('Timeout at phase '+phase+' round '+round)};
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const capture=async(name:string)=>{await h.mouseMove(1,1);await h.sleep(400);assert((await h.screenshot(join(out,name+'.png'))).ok);report.screenshots.push(join(out,name+'.png'))};
let lastQuestion='';
const drive=async()=>{if(error)throw Error(error);
 for(const id of ['ai.interaction.approve','ai.host_approval.accept'])if((await h.query(id)).some(shown)){const detail=text(await h.query('ai.interaction.command'));if(!report.reviews.includes(detail))report.reviews.push(detail);if(detail.includes('elicitation/create · 打开网页')){await h.sleep(350);await capture('url-consent');report.steps.push('URL: exact destination consent');if(process.env.ZW_MCP_PAUSE_URL==='1'){await writeFile(join(out,'url-review-pending'),detail);try{await readFile(join(out,'approve-url'))}catch{return}}}await h.clickTestId(id);await h.sleep(150);return}
 if((await h.query('ai.interaction.submit')).some(shown)){
  const q=text(await h.query('ai.interaction.title'));if(q===lastQuestion)return;lastQuestion=q;report.questions.push(q);
  if(q.includes('What is your name?')||q.includes('favorite color')||q.includes('Which color do you like best?')){await click('ai.interaction.option.0')}
  else if(q.includes('Your name')){await click('ai.interaction.option.6');await click('ai.interaction.answer');await h.type_('Reference Tester')}
  else if(q.includes('Your favorite of the three')){await click('ai.interaction.option.6');await click('ai.interaction.answer');await h.type_('blue')}
  else if(q.includes('Please provide inputs')){await click(phase===1?'ai.interaction.option.1':'ai.interaction.option.0')}
  else if(q.includes('\nname\n')||q.includes('Your full, legal name')){await click('ai.interaction.option.6');await click('ai.interaction.answer');await h.type_('Reference Tester');await capture('form-entry')}
  else if(text(await h.query('ai.interaction.panel')).includes('使用默认值'))await click('ai.interaction.option.0');
  else if(text(await h.query('ai.interaction.panel')).includes('跳过'))await click('ai.interaction.option.0');
  else throw Error('Unexpected question '+q);
  await click('ai.interaction.submit');await h.sleep(180);
 }
};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1280,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');
 for(phase=Number(process.env.ZW_MCP_START_PHASE??0);phase<2&&!process.env.ZW_MCP_UI_ONLY;phase++){
  round=0;lastQuestion='';await click('ai.prompt');await h.type_('Run official MCP reference acceptance phase '+phase);await click('ai.send');
  await until(async()=>{await drive();return text(await h.query('ai.response')).includes(`MCP_REFERENCE_PHASE_${phase}_PASSED`)?true:null},180000);await capture(`phase-${phase}-passed`);
 }
 await click('toolbar.settings');await click('settings.nav.ai');await click('settings.ai.mcp.header');await h.sleep(120);
 const reveal=async(id:string)=>{for(let n=0;n<25;n++){const t=(await visible(id)).rect,v=(await visible('settings.viewport')).rect;if(t.y>=v.y&&t.y+t.h<=v.y+v.h)return;await h.scrollAt(v.x+v.w-4,v.y+v.h/2,0,Math.max(-500,Math.min(500,t.y<v.y?v.y-t.y+25:v.y+v.h-t.y-t.h-25)));await h.sleep(80)}throw Error('Cannot reveal '+id)};
 await reveal('settings.mcp.2.test');await click('settings.mcp.2.test');await h.waitFor(async()=>text(await h.query('settings.extensions.status')).includes('网页登录')?true:null,20000);okAuth('401 produces actionable settings error');await capture('oauth-required');
 await reveal('settings.mcp.0.test');await click('settings.mcp.0.test');await h.waitFor(async()=>text(await h.query('settings.mcp.0.metadata')).includes('2026-07-28')?true:null,20000);
 const geometry=[];
 for(const [width,height]of [[1280,900],[860,480]]){
  await h.resizeWindow(width,height);await h.sleep(200);const header=(await visible('settings.ai.mcp.header')).rect,viewport=(await visible('settings.viewport')).rect;await h.scrollAt(viewport.x+viewport.w-4,viewport.y+viewport.h/2,0,viewport.y-header.y);await h.sleep(180);await reveal('settings.mcp.0.row');
  const row=(await visible('settings.mcp.0.row')).rect,name=(await visible('settings.mcp.0.name')).rect,toggle=(await visible('settings.mcp.0.toggle')).rect,test=(await visible('settings.mcp.0.test')).rect,more=(await visible('settings.mcp.0.more')).rect;
  assert(name.w>20&&name.x+name.w<=toggle.x+.5,'identity cannot overlap switch');assert(toggle.x+toggle.w<=test.x+.5&&test.x+test.w<=more.x+.5,'actions cannot overlap');assert(more.x+more.w<=row.x+row.w+.5,'actions remain in row');geometry.push({viewport:[width,height],row,name,toggle,test,more});
  await capture(`services-${width}`);await click('settings.mcp.0.more');await h.sleep(400);await h.tree();await h.sleep(300);await writeFile(join(out,`menu-state-${width}.json`),JSON.stringify(flat(await h.tree()).filter(n=>n.opacity!==undefined&&n.opacity<1).map(n=>({id:n.id,component:n.component,text:n.text,opacity:n.opacity})),null,2));await capture(`services-menu-${width}`);await h.key('escape');
 }
 await reveal('settings.mcp.3.row');const longName=(await visible('settings.mcp.3.name')).rect,longToggle=(await visible('settings.mcp.3.toggle')).rect;assert(longName.x+longName.w<=longToggle.x,'long title stays in identity column');await capture('services-long-name');
 await writeFile(join(out,'services-geometry.json'),JSON.stringify(geometry,null,2));
 await reveal('settings.mcp.0.toggle');await click('settings.mcp.0.toggle');await h.sleep(100);await click('settings.mcp.0.toggle');
 await click('settings.mcp.0.more');await h.key('return');await reveal('settings.mcp.field.name');assert(text(await h.query('settings.mcp.field.name')).includes('Everything'),'edit retains identity');await reveal('settings.mcp.cancel');await click('settings.mcp.cancel');
 await reveal('settings.mcp.add');await click('settings.mcp.add');await visible('settings.mcp.field.name');await reveal('settings.mcp.cancel');await click('settings.mcp.cancel');
 await h.resizeWindow(1280,900);report.steps.push('V4: full/compact geometry, menu, enable switch, edit and add');
 if(process.env.ZW_MCP_UI_ONLY){report.status='passed'}else{
 for(const i of [2,3]){await reveal(`settings.mcp.${i}.more`);await click(`settings.mcp.${i}.more`);await h.sleep(150);await h.key('down');await h.key('return');await until(async()=>text(await h.query(`settings.mcp.${i}.metadata`)).includes('2025-11-25')?true:null,45000);await click(`settings.mcp.${i}.view`);await until(async()=>text(await h.query('settings.extensions.detail')).includes(i===2?'greet':'payment-confirm')?true:null,15000);okAuth(`browser PKCE authorization and reconnect server ${i}`);await capture('oauth-connected-'+i)}await click('settings.close');
 phase=2;round=0;await click('ai.prompt');await h.type_('Verify OAuth protected MCP greeting');await click('ai.send');await until(async()=>{await drive();return text(await h.query('ai.response')).includes('MCP_REFERENCE_PHASE_2_PASSED')?true:null},60000);await capture('oauth-greet-passed');phase=3;round=0;await click('ai.prompt');await h.type_('Verify official SDK local URL interaction demo');await click('ai.send');await until(async()=>{await drive();return text(await h.query('ai.response')).includes('MCP_REFERENCE_PHASE_3_PASSED')?true:null},240000);await capture('url-interaction-passed');assert.equal(sampleRequests,Math.max(0,2-Number(process.env.ZW_MCP_START_PHASE??0)));report.sampling_provider_requests=sampleRequests;report.status='passed';
 }
 function okAuth(s:string){report.steps.push('OAuth: '+s)}
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;await capture('failure').catch(()=>{});await h.query('ai.interaction.panel').then(v=>writeFile(join(out,'failure-interaction.json'),JSON.stringify(v,null,2))).catch(()=>{})}
finally{try{if(alive()){await h.request('POST','/zerowork/windows',{action:'quit'});const start=performance.now();while(alive()&&performance.now()-start<15000){for(const id of ['settings.confirmation.discard','groups.close.accept','local.close.accept','session.close.accept']){if(!alive())break;try{const q=await h.query(id);if(Array.isArray(q)&&q.some(shown))await h.clickTestId(id)}catch{}}await Promise.race([ended,h.sleep(100)])}}}catch{}if(alive()){report.forced=true;app.kill('SIGTERM');await ended}report.exit_code=app.exitCode;if(app.exitCode!==0||report.forced){report.status='failed';process.exitCode=1}provider.closeAllConnections();await new Promise<void>(d=>provider.close(()=>d()));for(const c of children){c.kill('SIGTERM');await new Promise(d=>c.exitCode!==null?d(null):c.once('close',d))}await logs.close();await log.close();const content=await readFile(join(out,'app.log'),'utf8');if(/leaked \[addr:|panic:|double free/i.test(content)){report.status='failed';report.memory_error=true;process.exitCode=1}await writeFile(join(out,'report.json'),JSON.stringify(report,null,2),{mode:0o600});console.log(JSON.stringify({status:report.status,error:report.error,steps:report.steps,out}))}
