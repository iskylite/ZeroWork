/** Real production main / two native Metal windows. Creates the fixture through
 * its public editor and the second window through the ordinary asset menu.
 * Transfer is dispatched through the generic test route to ContentContext;
 * no registry, workspace, renderer or provider model is mutated by this runner.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash,randomUUID} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,rm,chmod} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
import {request,waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep,focused} from '../vendor/zenit/e2e/client.ts';

const opts:Record<string,string>={};
for(let i=2;i<process.argv.length;i+=2){assert(['--binary','--sha','--out','--skip-fullscreen','--foreground','--second-window-ssh','--desktop-pause'].includes(process.argv[i])&&process.argv[i+1]);opts[process.argv[i]]=process.argv[i+1];}
assert(opts['--binary']&&opts['--sha']&&opts['--out']);
const binary=resolve(opts['--binary']),out=resolve(opts['--out']);
assert.equal(createHash('sha256').update(await readFile(binary)).digest('hex'),opts['--sha']);
await mkdir(out,{recursive:true});
const iso=await mkdtemp(join(tmpdir(),'zw-v02-window-transfer-')),rpc=join(iso,'rpc'),data=join(iso,'data');
await chmod(iso,0o700);await mkdir(rpc);await mkdir(data);
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="sauber"\nfont_family="Menlo"\nfont_size=14\n[ssh]\nauto_reconnect=false\nconnect_timeout_sec=5\n',{mode:0o600});
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const logPath=join(out,'app.log'),log=await open(logPath,'w');
const environment={...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:opts['--foreground']==='1'?'0':'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_FSH_TRACE_FILE:join(out,'native-fullscreen.jsonl'),ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''};
for(const variable of Object.keys(environment))if(variable.startsWith('ZENIT_E2E_')&&/(?:BG|BACKGROUND|ACTIVATION)/.test(variable)&&variable!=='ZENIT_E2E_BACKGROUND')delete environment[variable];
const app=spawn(binary,[],{cwd:process.cwd(),env:environment,stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
let launchError:Error|undefined;app.once('error',error=>{launchError=error});
const secret='v02-transfer-'+randomUUID();
const redact=(value:string)=>value.replaceAll(secret,'[REDACTED]');
const report:any={status:'running',binary,binary_sha256:opts['--sha'],pid:app.pid,started_at:new Date().toISOString(),mode:opts['--foreground']==='1'?'native_foreground':'background',checks:[],stages:[],limits:['Two actual native Metal windows owned by one isolated production main process.','Public synthetic Harness input is not physical keyboard, pointer or IME acceptance.','Generic test action invokes the owner ContentContext facade; it does not fabricate transfer state.','No remote endpoint or AI provider is used.']};
function shown(n:any){return n?.rect&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;}
function nodes(n:any):any[]{return !n?[]:[n,...(n.children??[]).flatMap(nodes)];}
function text(n:any){return nodes(n).filter(shown).map(n=>n.text??'').join('');}
function alive(){assert(!launchError,launchError?.message);assert(app.exitCode===null&&app.signalCode===null,'Owned App remains alive');}
async function visible(id:string){return waitFor(async()=>{alive();return(await query(id)).findLast(shown)??null;},20000);}
async function clickNode(n:any){assert(shown(n));assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await sleep(100);}
async function click(id:string){await clickNode(await visible(id));}
async function set(id:string,value:string){await click(id);await key('a',{cmd:true});assert((await type_(value)).ok);}
async function absent(id:string){await waitFor(async()=>!(await query(id)).some(shown)||null,15000);}
async function state(){const value=await request('POST','/zerowork/windows',{action:'snapshot'});assert(value.ok);return value;}
async function select(window:number){assert((await request('POST','/zerowork/windows',{action:'select',window})).ok);await sleep(180);}
async function capture(name:string){await sleep(200);const snapshot=await state();const tree=Object.fromEntries(await Promise.all(['workspace.shell','workspace.titlebar','sidebar.host','tabs.strip','fixture.canvas','fixture.rgba','plugin.challenge.modal','workspace.empty'].map(async id=>[id,await query(id)])));await writeFile(join(out,name+'.json'),redact(JSON.stringify({snapshot,tree},null,2)));assert((await screenshot(join(out,name+'.png'))).ok);report.stages.push({name,snapshot});await writeFile(join(out,'report.in-progress.json'),redact(JSON.stringify(report,null,2)));console.log(name);if(opts['--desktop-pause']==='1'&&['01-source-owner-ready','01b-native-fullscreen-on','01c-native-fullscreen-off-geometry-restored'].includes(name)){await writeFile(join(out,'desktop-stage.json'),JSON.stringify({name,pid:app.pid}));await waitFor(async()=>{try{await readFile(join(out,name+'.continue'));return true;}catch{return null;}},120000);}}
const assetName='V02 native two-window transfer';
async function assetRow(name=assetName){return waitFor(async()=>(await query('sidebar.host')).find(n=>shown(n)&&text(n).includes(name))??null);}
async function assetAction(id:string,name=assetName){await clickNode(await assetRow(name));const target=nodes(await assetRow(name)).find(n=>shown(n)&&n.test_id===id);assert(target);await clickNode(target);}
async function cancelExtraOwner(){
 if(opts['--second-window-ssh']==='1'){await visible('connection.progress.close');await click('connection.progress.close');}else{await visible('plugin.challenge.modal');assert.equal((await query('plugin.challenge.modal')).length,1);await click('plugin.challenge.cancel');await absent('plugin.challenge.modal');}
 const tab=(await query('tabs.strip')).flatMap(nodes).find(n=>shown(n)&&/^tabs\.tab\.\d+$/.test(n.test_id??''));if(tab){await click(tab.test_id);await click(tab.test_id.replace('tabs.tab.','tabs.close.'));if((await query('session.close.accept')).some(shown))await click('session.close.accept');await absent(tab.test_id);}await absent('fixture.canvas');
}

try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1440,900);
 const initial=await state();assert.equal(initial.windows.length,1);const source=initial.windows[0];report.source=source;
 await click('sidebar.empty.new');await click('wizard.protocol');await click('wizard.protocol.fixture_probe');await visible('fixture.editor');await set('fixture.name',assetName);await set('fixture.destination','synthetic.invalid');await click('wizard.save_only');await absent('fixture.editor');
 await assetAction('sidebar.host.connect');await visible('plugin.challenge.secret');assert.equal((await query('plugin.challenge.modal')).length,1);assert.equal((await query('auth.challenge.modal')).length,0);await capture('00-source-shared-challenge-before-answer');await click('plugin.challenge.secret');await type_(secret);await click('plugin.challenge.submit');await visible('fixture.canvas');await visible('fixture.rgba');
 const ready=await waitFor(async()=>{const s=await state();return s.sessions.find((v:any)=>v.window===source.window&&v.plugin==='external'&&v.lifecycle==='attached')??null;});report.original_owner=ready;await capture('01-source-owner-ready');
 if(opts['--skip-fullscreen']==='1'){report.fullscreen={status:'skipped_partial_diagnostic'};report.limits.push('Partial diagnostic skips fullscreen after a separately preserved failure; cannot pass complete WindowFacade acceptance.');}else{
 await select(source.window);const normalRect=(await visible('workspace.shell')).rect;const normalTabs=await visible('tabs.strip'),normalTitle=await visible('workspace.titlebar'),normalFocus=await focused();assert.equal(ready.fullscreen,false);assert.equal(normalTabs.rect.x,90);report.fullscreen_titlebar={normal:{tabs:normalTabs,titlebar:normalTitle,focus:normalFocus}};
 assert((await request('POST','/zerowork/windows',{action:'fullscreen_content',window:source.window,session:ready.session,generation:ready.generation,enabled:true})).ok);
 const fullscreenOn=await waitFor(async()=>{const owner=(await state()).sessions.find((v:any)=>v.session===ready.session&&v.generation===ready.generation);return owner?.fullscreen===true?owner:null;},20000);await waitFor(async()=>Math.abs((await visible('tabs.strip')).rect.x-18)<0.6||null,15000);await waitFor(async()=>{try{return(await readFile(join(out,'native-fullscreen.jsonl'),'utf8')).includes('windowDidEnterFullScreen')||null;}catch{return null;}},20000);const onTabs=await visible('tabs.strip'),onTitle=await visible('workspace.titlebar');report.fullscreen_titlebar.strip_id_changed_on=onTabs.id!==normalTabs.id;assert.equal(onTitle.id,normalTitle.id);assert.equal(normalTabs.rect.x-onTabs.rect.x,72);report.fullscreen_titlebar.on={tabs:onTabs,titlebar:onTitle,focus:await focused()};await capture('01b-native-fullscreen-on');
 assert((await request('POST','/zerowork/windows',{action:'fullscreen_content',window:source.window,session:ready.session,generation:ready.generation,enabled:false})).ok);
 const fullscreenOff=await waitFor(async()=>{const owner=(await state()).sessions.find((v:any)=>v.session===ready.session&&v.generation===ready.generation),rect=(await query('workspace.shell')).find(shown)?.rect;return owner?.fullscreen===false&&rect&&Math.abs(rect.w-normalRect.w)<1&&Math.abs(rect.h-normalRect.h)<1?{owner,rect}:null;},20000);await waitFor(async()=>Math.abs((await visible('tabs.strip')).rect.x-90)<0.6||null,15000);await waitFor(async()=>{try{return(await readFile(join(out,'native-fullscreen.jsonl'),'utf8')).includes('windowDidExitFullScreen')||null;}catch{return null;}},20000);const offTabs=await visible('tabs.strip'),offTitle=await visible('workspace.titlebar');report.fullscreen_titlebar.strip_id_changed_off=offTabs.id!==normalTabs.id;assert.equal(offTitle.id,normalTitle.id);report.fullscreen_titlebar.off={tabs:offTabs,titlebar:offTitle,focus:await focused()};report.fullscreen={status:'passed',normal_rect:normalRect,on:fullscreenOn,off:fullscreenOff};await capture('01c-native-fullscreen-off-geometry-restored');report.checks.push('ContentContext.requestFullscreen toggles actual native chromeState on/off and restores the original logical window geometry.');
 }
 let secondWindowAsset=assetName;
 if(opts['--second-window-ssh']==='1'){
  secondWindowAsset='V02 diagnostic loopback refused SSH';report.limits.push('Partial diagnostic obtains the second window from a separately saved ordinary SSH asset at 127.0.0.1:1; the fixture asset new-window failure is preserved separately and is not passed here.');
  await click('sidebar.new');await click('sidebar.new.host');await click('wizard.protocol');await click('wizard.protocol.ssh');await visible('wizard.name');await set('wizard.name',secondWindowAsset);await set('wizard.host','127.0.0.1');await set('wizard.user','v02-owned');await set('wizard.port','1');await click('wizard.next.identity');await click('wizard.next.route');await click('wizard.save_only');await absent('wizard.name');
 }
 await assetAction('sidebar.host.more',secondWindowAsset);await capture('01d-new-window-asset-menu');await click('context.menu.new_window');
 const two=await waitFor(async()=>{const s=await state();return s.windows.length===2?s:null;},20000);assert.equal(two.native_count,2);const target=two.windows.find((w:any)=>w.window!==source.window);assert(target);assert.notEqual(source.workspace,target.workspace);assert.notEqual(source.native_window,target.native_window);report.target=target;
 await select(target.window);await cancelExtraOwner();assert.equal((await visible('workspace.titlebar')).rect.x,8);report.target_window_titlebar=await visible('workspace.titlebar');await capture('02-target-window-empty-after-extra-attempt-cancel');await select(source.window);await visible('fixture.canvas');
 const requested=await request('POST','/zerowork/windows',{action:'transfer_content',window:source.window,session:ready.session,generation:ready.generation,destination:target.window});assert(requested.ok,JSON.stringify(requested));
 const moved=await waitFor(async()=>{const s=await state(),receipt=(s.transfers??[]).find((v:any)=>v.session===ready.session&&v.generation===ready.generation&&v.destination===target.window),owner=s.sessions.find((v:any)=>v.session===ready.session&&v.generation===ready.generation);return receipt&&owner?.window===target.window&&owner.lifecycle==='attached'?{snapshot:s,receipt,owner}:null;},20000);
 report.transfer=moved;
 assert.equal(moved.owner.create_operation,ready.create_operation);assert.equal(moved.owner.attempt,ready.attempt);assert.equal(moved.owner.generation,ready.generation);assert.equal(moved.owner.workspace,target.workspace);
 const receipt=moved.receipt;assert.equal(receipt.source,source.window);assert.equal(receipt.operation,ready.create_operation);assert.equal(receipt.attempt,ready.attempt);assert.notEqual(receipt.old_context_instance,receipt.new_context_instance);assert(receipt.old_context_instance>0&&receipt.new_context_instance>0);assert.equal(receipt.old_lease_rejected,true);assert.equal(receipt.source_input_closed,true);assert.equal(receipt.source_frame_closed,true);assert(receipt.old_texture!==null&&receipt.new_texture!==null);assert.notEqual(receipt.old_texture,receipt.new_texture);assert(receipt.new_frame_revision>0);
 await absent('fixture.canvas');await absent(`tabs.tab.${ready.tab}`);await capture('03-source-content-removed-after-transfer');
 await select(target.window);await visible('fixture.canvas');await visible('fixture.rgba');await visible(`tabs.tab.${moved.owner.tab}`);await capture('04-target-new-renderer-same-owner');
 report.checks.push('Public ContentContext.transferWindow moves the existing session/generation/create operation/attempt into a second actual native window without reconnecting.','Actual completion receipt rejects the old live lease, closes the source input/frame sink and creates a different target context/texture; source content and tab disappear.');
 async function targetInput(x:number,y:number,name:string){
  const before=(await state()).sessions.find((v:any)=>v.session===ready.session&&v.generation===ready.generation);assert(before);
  const dispatched=await request('POST','/zerowork/windows',{action:'input_content',window:target.window,session:ready.session,generation:ready.generation,x,y});assert(dispatched.ok,JSON.stringify(dispatched));
  const after=await waitFor(async()=>{const owner=(await state()).sessions.find((v:any)=>v.session===ready.session&&v.generation===ready.generation);return owner?.frame_revision>before.frame_revision?owner:null;},15000);
  assert.equal(after.input_instance,receipt.new_context_instance);assert.equal(after.create_operation,ready.create_operation);assert.equal(after.attempt,ready.attempt);assert.equal(after.window,target.window);assert.equal(after.lifecycle,'attached');report[name]={before,after};await capture(name);
 }
 await targetInput(12,8,'05-target-facade-pointer-new-frame');
 assert((await request('POST','/zerowork/windows',{action:'close',window:source.window})).ok);
 const survivor=await waitFor(async()=>{const s=await state();return s.windows.length===1&&s.windows[0].window===target.window?s:null;},20000);assert.equal(survivor.native_count,1);report.source_close=survivor;await select(target.window);await visible('fixture.canvas');
 await targetInput(30,20,'06-source-closed-target-new-input-still-renders');
 report.checks.push('Target ContentContext routes the generic Harness pointer through acquire/route and produces a newer frame, including after normal source native window closure; original session/generation/operation/attempt remain attached.');
 await click(`tabs.tab.${moved.owner.tab}`);await click(`tabs.close.${moved.owner.tab}`);await sleep(150);if((await query('session.close.accept')).some(shown))await click('session.close.accept');await absent('fixture.canvas');await absent(`tabs.tab.${moved.owner.tab}`);
 const released=await waitFor(async()=>{const s=await state(),owner=s.sessions.find((v:any)=>v.session===ready.session&&v.generation===ready.generation),tombstone=(s.content_states??[]).find((v:any)=>v.context_instance===receipt.new_context_instance&&v.window===target.window);return owner?.lifecycle==='closed'&&owner.close_cleanup_released===true&&tombstone?.retired&&tombstone.input_closed&&tombstone.frame_closed&&tombstone.texture===null?{snapshot:s,owner,tombstone}:null;},20000);assert(released.owner.close_operation>0);assert.equal(released.owner.create_operation,ready.create_operation);report.final_release=released;await capture('07-target-normal-owner-close-released');
 report.checks.push('Normal target owner close reaches the actual journal released receipt and target context tombstone is retired, input closed, frame sink closed and texture null while the same App remains alive.');
 assert((await request('POST','/zerowork/windows',{action:'close',window:target.window})).ok);await Promise.race([ended,sleep(15000)]);assert.equal(app.exitCode,0,'Final native window close exits normally');assert.equal(app.signalCode,null);report.normal_native_close=true;report.checks.push('Normal final native target window closure exits the owned App with code zero.');report.status=opts['--skip-fullscreen']==='1'?'partial_diagnostic_fullscreen_skipped':opts['--second-window-ssh']==='1'?'partial_diagnostic_second_window_from_ssh':'passed';
}catch(error){report.status='failed';report.error=String(error);report.error_stack=(error as Error).stack;try{alive();await capture('failure');}catch{}}
finally{
 if(app.exitCode===null&&app.signalCode===null){report.forced_cleanup=true;app.kill('SIGTERM');await Promise.race([ended,sleep(2500)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}}
 await log.close();await writeFile(logPath,redact(await readFile(logPath,'utf8')));const bridges=await cleanupOwnedBridgeDirectories(app.pid!);await rm(iso,{recursive:true,force:true});report.cleanup={isolated_removed:true,private_configuration_removed:true,owned_process_exited:true,private_bridge_directories_removed:bridges};report.process_exit={exit_code:app.exitCode,signal:app.signalCode};report.finished_at=new Date().toISOString();await writeFile(join(out,'report.json'),redact(JSON.stringify(report,null,2)));console.log(report.status+' '+join(out,'report.json'));if(report.status!=='passed')process.exitCode=1;
}
