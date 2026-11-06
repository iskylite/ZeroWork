/** Native regression: fail preflight once, dismiss, delete all listed AI sessions,
 * then reopen and install with the original AI guard enabled. Drafts and error
 * cache are observed separately; no force install, installer or real user data.
 * Run: node e2e/app_update_deleted_drafts_native.ts <test-prefix> <out>
 * EXPECT_STALE=1 verifies the unfixed build as a negative control. */
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,copyFile,writeFile,readFile,open,rm,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
const build=resolve(process.argv[2]??'zig-out');
const out=resolve(process.argv[3]??'/tmp/zw-update-feedback');await mkdir(out,{recursive:true});
const h=await import(pathToFileURL(join(build,'share/zenit/harness/client.ts')).href);
const base=await realpath(await mkdtemp('/tmp/zw-update-feedback-')),rpc=join(base,'rpc'),data=join(base,'data'),bundle=join(base,'ZeroWork.app'),mac=join(bundle,'Contents/MacOS');
await Promise.all([rpc,data,mac].map(p=>mkdir(p,{recursive:true})));
for(const name of ['zerowork','zw_ipc.so','zw_execution.so','zw_secret_consume.so','zw_execution_guard'])await copyFile(join(build,'bin',name),join(mac,name==='zerowork'?'ZeroWork':name));
const frame=(content:string)=>'data: '+JSON.stringify({choices:[{index:0,delta:{content}}]})+'\n\n';
let held:any=null;
const server=createServer(async(req,res)=>{if(req.method!=='POST'){res.end('{"data":[{"id":"deletion-fixture"}]}');return}let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);res.writeHead(200,{'content-type':'text/event-stream'});const last=String(body.messages.filter((m:any)=>m.role==='user').at(-1)?.content??'');if(body.tools?.length&&last.includes('HOLD')){held=res;res.write(frame('ISOLATED_HOLD'));return}res.end(frame(body.tools?.length?'ISOLATED_ANSWER':'删除验证')+'data: [DONE]\n\n');});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
await writeFile(join(data,'config.toml'),`[updates]\nauto_check=false\n[ai]\ndefault_provider="deletion-fixture"\n[[ai.providers]]\nid="deletion-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="deletion-fixture"\ncontext_window=200000\ndefault=true\n`);
await writeFile(join(bundle,'Contents/Info.plist'),'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.zerowork.app</string><key>CFBundleExecutable</key><string>ZeroWork</string><key>CFBundlePackageType</key><string>APPL</string><key>ZeroWorkReleaseVersion</key><string>0.3.0-rc1</string></dict></plist>');
const identity=execFileSync('python3',['scripts/macos_signing.py','identity'],{encoding:'utf8'}).trim();execFileSync('codesign',['--force','--deep','--sign',identity,'--identifier','com.zerowork.app',bundle]);
const root=join(process.env.HOME!,'Library/Application Support/com.zerowork.updater',createHash('sha256').update(bundle+'\n'+data).digest('hex').slice(0,32));
if(process.argv[4]==='restore'){assert(process.env.ZW_UPDATE_HISTORY_FIXTURE,'restore requires an explicitly supplied synthetic history');await copyFile(process.env.ZW_UPDATE_HISTORY_FIXTURE!,join(data,'ai-sessions.jsonl'));}
const log=await open(join(out,'app.log'),'w');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const app=spawn(join(mac,'ZeroWork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',(code,signal)=>r({code,signal})));
const checks:string[]=[];
const route=(action='snapshot',extra={})=>h.request('POST','/zerowork/update',{action,...extra});
const shown=(n:any)=>n&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const visible=(id:string)=>h.waitFor(async()=> (await h.query(id)).find(shown)||null,12000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id);};
const flat=(nodes:any[]):any[]=>nodes.flatMap(n=>[n,...flat(n.children??[])]);
const text=async(id:string)=>flat(await h.query(id)).map(n=>n.text??'').join('');
const cap=(name:string)=>h.screenshot(join(out,name+'.png'));
const mode=process.argv[4]??'stale';
const snapshots:any[]=[];
const snap=async(label:string)=>{const state=await route('drafts');snapshots.push({label,...state});await writeFile(join(out,'states.json'),JSON.stringify(snapshots,null,2));return state;};
const input=async(value:string)=>{await click('ai.prompt');await h.key('a',{cmd:true});await h.type_(value);};
const panel=async()=>{if(!(await h.query('ai.panel')).some(shown))await click('toolbar.ai');await visible('ai.prompt');};
const end=async()=>{await click('ai.close');await h.waitFor(async()=>{if((await h.query('ai.close.confirmation.confirm')).some(shown))await click('ai.close.confirmation.confirm');return !(await h.query('ai.panel')).some(shown)||null;},15000);};
try{
 await h.waitForServerReady();await h.resizeWindow(1100,800);await route('legacy_preflight',{legacy:true});
 await click('workspace.empty.local');await visible('terminal.surface');await panel();
 if(mode!=='restore'){
 await input(mode==='active'?'SENT_HOLD_A':'SENT_A');await click('ai.send');
 if(mode==='active')await visible('ai.stop');else await h.waitFor(async()=> (await text('ai.panel')).includes('ISOLATED_ANSWER')&&!(await h.query('ai.stop')).some(shown)||null);
 await input('DELETE_DRAFT_A');await snap('A-before-end');
 if(mode==='tabs'){
  await click('ai.collapse');await h.key('t',{cmd:true});await click('session.menu.local');await panel();await input('SENT_B');await click('ai.send');
  await h.waitFor(async()=> (await text('ai.panel')).includes('ISOLATED_ANSWER')&&!(await h.query('ai.stop')).some(shown)||null);await input('DELETE_DRAFT_B');await snap('B-before-end');await end();
  const tabs=flat(await h.query('tabs.strip')).filter(n=>shown(n)&&/^tabs.tab.\d+$/.test(n.test_id??''));await click(tabs[0].test_id);await panel();
 }
 await end();await snap('after-end');
 if(mode==='stale'){
  await route('ready');await visible('update.modal');await click('update.primary');await h.sleep(100);
  const initial=await route();assert(initial.message.includes('其他 AI 会话有未发送的输入'));await writeFile(join(out,'initial-blocker.json'),JSON.stringify(initial,null,2));await cap('initial-blocker');await click('update.cancel');
 }
 await panel();
 }
 await click('ai.sessions');
 const menu=await visible('ai.sessions.menu');const ids=[...new Set(flat([menu]).filter(shown).map(n=>n.test_id??'').filter(id=>/^ai.session.delete.\d+$/.test(id)))];assert(ids.length>0);await writeFile(join(out,'deleted-ids.json'),JSON.stringify(ids));
 for(const [i,id] of ids.entries()){
  await click(id);await visible('ai.session.close.accept');await click('ai.session.close.accept');await h.waitFor(async()=>!(await h.query(id)).some(shown)||null);await snap('after-'+id);
  if(i<ids.length-1){await panel();if(!(await h.query('ai.sessions.menu')).some(shown))await click('ai.sessions');}
 }
 const final=await snap('all-listed-deleted');
 for(const window of final.windows){assert.equal(window.prompt_len,0);assert.equal(window.controller_input_len,0);assert.equal(window.controller_model_prompt_len,0);assert.equal(window.legacy_reason,null);for(const state of window.states){assert.equal(state.draft_len,0);assert.equal(state.journal_draft_len,0);assert(!ids.includes('ai.session.delete.'+state.id));}}
 await route('ready');await visible('update.modal');const reopened=await route();await writeFile(join(out,'reopened.json'),JSON.stringify(reopened,null,2));await cap('reopened-after-delete');await click('update.primary');await h.sleep(100);const install=await route();await cap('install-after-delete');
 const report={binary:join(build,'bin/zerowork'),binary_sha256:createHash('sha256').update(await readFile(join(build,'bin/zerowork'))).digest('hex'),legacy_preflight:true,reopened,status:install.message?'reproduced_stale_blocker':install.phase==='confirm'?'clean':'reproduced',mode,deleted:ids,install,final};
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
 if(process.env.EXPECT_STALE==='1'){assert.equal(reopened.message,'其他 AI 会话有未发送的输入，请先保存或清空后再更新');assert.equal(install.phase,'confirm');assert.equal(install.message,reopened.message);}else{assert.equal(reopened.message,'','dismissed blocker must not survive deleting all conversations and reopening');assert.equal(install.phase,'confirm');assert.equal(install.message,'');if('allow_unsaved' in install)assert.equal(install.allow_unsaved,false);}
 await click('update.cancel');
}catch(error){await snap('failure').catch(()=>{});await cap('failure').catch(()=>{});throw error;}
finally{
 if(held)held.destroy();
 try{await h.request('POST','/zerowork/windows',{action:'quit'});await h.waitFor(async()=>app.exitCode!==null||null,12000);}catch{if(app.exitCode===null)app.kill('SIGTERM');}
 await ended;await log.close();server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));
 // Preserve only synthetic journal and diagnostic evidence before cleanup.
 await readFile(join(data,'ai-sessions.jsonl'),'utf8').then(j=>writeFile(join(out,'journal.jsonl'),j)).catch(()=>{});
 await rm(base,{recursive:true,force:true});await rm(root,{recursive:true,force:true});
}
