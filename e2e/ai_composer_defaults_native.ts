/** Persist composer defaults without changing another connection's live agent. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,open,readFile,realpath,rm,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'zig-out');
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-ai-composer-defaults');await mkdir(out,{recursive:true});
const isolated=await realpath(await mkdtemp('/tmp/zw-ai-defaults-'));
const data=join(isolated,'data'),rpc=join(isolated,'rpc');await mkdir(data);await mkdir(rpc);
const configPath=join(data,'config.toml');
const backgrounds=join(data,'backgrounds');await mkdir(backgrounds);
await writeFile(join(backgrounds,'fixture.png'),Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAJ0lEQVR4nGPQcksBoiq3aUCEzGbAKVFVkQJEWhXTgAiZjVuCDnYAAMasS4GfPJd/AAAAAElFTkSuQmCC','base64'));
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
let held:any=null;const continuations:any[]=[];
const server=createServer(async(req,res)=>{
 if(req.method!=='POST'){res.end(JSON.stringify({data:[{id:'defaults-fixture'}]}));return;}
 let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);
 res.writeHead(200,{'content-type':'text/event-stream'});
 if(body.messages.some((m:any)=>m.role==='tool')){continuations.push(body);res.end(frame({content:'Existing agent continued successfully.'})+'data: [DONE]\n\n');return;}
 if(body.messages[0]?.content?.startsWith('将用户的问题概括')){res.end(frame({content:'Default isolation test'})+'data: [DONE]\n\n');return;}
 assert(body.tools.some((t:any)=>t.function.name==='host__get_ucurrent_ucontext'));
 res.flushHeaders();held=res;
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));const port=(server.address() as any).port;
await writeFile(configPath,`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ui.materials.background]\nenabled=true\nsource="directory"\npath="${backgrounds}"\ntransparency=60\n[ai]\ndefault_provider="defaults-fixture"\npermission_mode="confirm"\nexecution_mode="auto"\n[[ai.providers]]\nid="defaults-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="defaults-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const environment={...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''};
for(const name of ['ZEROWORK_AI_MOCK','ZEROWORK_AI_ENDPOINT','ZEROWORK_AI_MODEL','ZEROWORK_AI_PROVIDER'])delete environment[name];
let app:any,ended:Promise<any>;
const launch=async()=>{app=spawn(join(prefix,'bin/zerowork'),[],{env:environment,stdio:['ignore',log.fd,log.fd]});ended=new Promise(done=>app.once('exit',(code:any,signal:any)=>done({code,signal})));await h.waitForServerReady(60000);await h.resizeWindow(1440,900);await visible('appearance.background');await h.waitFor(async()=>!(await h.query('startup.overlay')).some(shown)||null,15000);};
const quit=async()=>{
 let exited=false;const finished=ended.then(result=>{exited=true;return result;});
 assert((await h.request('POST','/zerowork/windows',{action:'quit'})).ok);
 await h.waitFor(async()=>{
  if(exited)return true;
  const nodes=await Promise.race([h.query('local.close.accept').catch(()=>[]),finished.then(()=>[])]);
  // Only the isolated PTYs created by this runner can appear here.
  if(!exited&&nodes.some(shown))assert((await h.clickTestId('local.close.accept')).ok);
  return exited||null;
 },15000);
 assert.deepEqual(await finished,{code:0,signal:null});
};
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id);};
const text=async(id:string)=>flat(await visible(id)).map(n=>n.text??'').join('');
const expectControls=async(permission:string,mode:string)=>{assert((await text('ai.composer.permission')).includes(permission));assert((await text('ai.composer.execution')).includes(mode));};
const newLocal=async()=>{if((await h.query('ai.panel')).some(shown))await click('ai.collapse');await click('toolbar.new_session');await click('session.menu.local');await visible('terminal.surface');await click('toolbar.ai');};
const capture=async(name:string)=>{assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2));};
const report:any={status:'running',checks:[]};
try{
 await launch();await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await expectControls('确认后执行','自行判断');
 const firstTab=flat(await h.query('tabs.strip')).find(n=>/^tabs\.tab\.\d+$/.test(n.test_id??'')).test_id;
 await click('ai.prompt');await h.type_('验证默认值隔离');await click('ai.send');await h.waitFor(()=>held||null,15000);
 await newLocal();await expectControls('确认后执行','自行判断');
 await click('ai.composer.permission');await click('ai.permission.auto');
 await click('ai.composer.execution');await click('ai.execution.new_pty');await expectControls('自动执行','新建 PTY');
 const saved=await readFile(configPath,'utf8');assert(/permission_mode\s*=\s*"auto"/.test(saved));assert(/execution_mode\s*=\s*"new_pty"/.test(saved));
 report.checks.push('With a directory background restored at startup, composer choices immediately persist both defaults to the global config');await capture('01-saved-defaults');
 await click('ai.collapse');await click(firstTab);await click('toolbar.ai');await expectControls('确认后执行','自行判断');await visible('ai.stop');
 held.end(frame({tool_calls:[{index:0,id:'defaults-context',type:'function',function:{name:'host__get_ucurrent_ucontext',arguments:'{}'}}]})+'data: [DONE]\n\n');held=null;
 await h.waitFor(()=>continuations.length>0||null,15000);await visible('ai.turn.complete');await expectControls('确认后执行','自行判断');
 const result=continuations[0].messages.find((m:any)=>m.role==='tool');assert(result);const feedback=JSON.parse(result.content);assert.equal(feedback.status,'succeeded');const context=JSON.parse(feedback.content.find((item:any)=>item.type==='structured').text);assert.equal(context.execution_mode,'auto');assert.equal(context.permission_mode,'confirm');
 report.checks.push('The other running agent retains confirm/auto and successfully executes a context tool after defaults change');await capture('02-existing-agent-unchanged');
 await newLocal();await expectControls('自动执行','新建 PTY');report.checks.push('A new connection initializes from the saved defaults');
 await quit();await launch();
 if((await h.query('workspace.empty.local')).some(shown)){await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');}else await newLocal();
 await expectControls('自动执行','新建 PTY');
 await click('ai.composer.permission');await click('ai.permission.confirm');
 await click('ai.composer.execution');await click('ai.execution.ask');await expectControls('确认后执行','每次询问');
 const restartedSaved=await readFile(configPath,'utf8');assert(/permission_mode\s*=\s*"confirm"/.test(restartedSaved));assert(/execution_mode\s*=\s*"ask"/.test(restartedSaved));
 report.checks.push('After restart, the restored directory background allows both controls to save again');await capture('03-restarted-defaults');report.checks.push('Restarting the application restores both defaults');await quit();report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await capture('failure').catch(()=>{});}
finally{
 if(held)held.end();server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));
 if(app&&app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await ended;}
 await log.close();await rm(isolated,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(JSON.stringify(report,null,2));
