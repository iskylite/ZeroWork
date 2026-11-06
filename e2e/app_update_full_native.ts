/** Full real-app update: UI check/download -> signed verification -> resource close
 * -> real helper replacement -> automatically launched real app and healthy ACK.
 * Only HTTP response bytes are local fixtures. Never replaces an installed app.
 * Run: node e2e/app_update_full_native.ts <test-prefix> <out>
 */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,copyFile,writeFile,readFile,open,rm,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
const force=process.argv[4]==='force';
const build=resolve(process.argv[2]??'zig-out'),out=resolve(process.argv[3]??'/tmp/zw-full-update');await mkdir(out,{recursive:true});
const h=await import(pathToFileURL(join(build,'share/zenit/harness/client.ts')).href);
const base=await realpath(await mkdtemp('/tmp/zw-full-update-')),data=join(base,'data'),rpc=join(base,'rpc'),target=join(base,'ZeroWork.app'),candidate=join(base,'candidate/ZeroWork.app');
await Promise.all([data,rpc].map(p=>mkdir(p,{recursive:true})));
const identity=execFileSync('python3',['scripts/macos_signing.py','identity'],{encoding:'utf8'}).trim();
const run=(command:string,args:string[])=>execFileSync(command,args,{encoding:'utf8',stdio:['ignore','pipe','pipe']});
const parts=['zw_ipc.so','zw_execution.so','zw_secret_consume.so','zw_execution_guard'];
async function bundle(path:string,version:string,marker:string){
 const mac=join(path,'Contents/MacOS'),helpers=join(path,'Contents/Helpers'),resources=join(path,'Contents/Resources');await Promise.all([mac,helpers,resources].map(p=>mkdir(p,{recursive:true})));
 await copyFile(join(build,'bin/zerowork'),join(mac,'ZeroWork'));
 for(const name of parts){await copyFile(join(build,'bin',name),join(mac,name));run('codesign',['--force','--sign',identity,join(mac,name)]);}
 await copyFile(join(build,'bin/ZeroWorkUpdater'),join(helpers,'ZeroWorkUpdater'));run('codesign',['--force','--sign',identity,'--identifier','com.zerowork.updater',join(helpers,'ZeroWorkUpdater')]);
 await writeFile(join(resources,'update-test-marker.txt'),marker);await copyFile('assets/macos/AppIcon.icns',join(resources,'AppIcon.icns'));
 await writeFile(join(path,'Contents/Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.zerowork.app</string><key>CFBundleName</key><string>ZeroWork isolated update</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleExecutable</key><string>ZeroWork</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>${version.split('-')[0]}</string><key>CFBundleVersion</key><string>${version}</string><key>ZeroWorkReleaseVersion</key><string>${version}</string><key>LSMinimumSystemVersion</key><string>13.0</string></dict></plist>`);
 run('codesign',['--force','--sign',identity,'--identifier','com.zerowork.app',path]);run('codesign',['--verify','--deep','--strict',path]);
}
await bundle(target,'0.3.0-rc1','OLD_SIGNED_APP');await bundle(candidate,'0.3.1','NEW_SIGNED_APP');
const archive=join(base,'ZeroWork-0.3.1-arm64.zip'),envelope=join(base,'update.json');
run('ditto',['-c','-k','--keepParent','--norsrc','--noextattr',candidate,archive]);
run('python3',['scripts/update_manifest.py','manifest',archive,'--version','0.3.1','--output',envelope]);
run('python3',['scripts/update_manifest.py','verify',archive,envelope]);
await writeFile(join(data,'config.toml'),'[updates]\nauto_check = false\n');await writeFile(join(data,'keep-user-data.txt'),'ISOLATED_USER_DATA_MUST_SURVIVE');
const digest=createHash('sha256').update(target+'\n'+data).digest('hex').slice(0,32),root=join(process.env.HOME!,'Library/Application Support/com.zerowork.updater',digest);
const log=await open(join(out,'app.log'),'w');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const app=spawn(join(target,'Contents/MacOS/ZeroWork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_AUTOCONNECT:'0',ZW_UPDATE_HEADLESS:'1',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<any>(done=>app.once('close',(code,signal)=>done({code,signal})));
const route=(action='snapshot',extra={})=>h.request('POST','/zerowork/update',{action,...extra});
const readJSON=async(path:string)=>{try{return JSON.parse(await readFile(path,'utf8'))}catch{return null}};
const shown=(n:any)=>n&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const visible=(id:string)=>h.waitFor(async()=> (await h.query(id)).find(shown)||null,15000);
const flat=(nodes:any[]):any[]=>nodes.flatMap(n=>[n,...flat(n.children??[])]);
const text=async(id:string)=>flat(await h.query(id)).map(n=>n.text??'').join('');
const click=async(id:string)=>{report.last_action=id;await writeFile(join(out,'progress.json'),JSON.stringify(report,null,2));await visible(id);assert((await h.clickTestId(id)).ok,id);};
const cap=async(name:string)=>{await h.mouseMove(1,1);await h.sleep(100);await h.screenshot(join(out,name+'.png'));};
let txn:string|undefined,restarted:any=null,finished=false;
const report:any={status:'running',case:force?'force-with-unsent-input':'delete-all-then-install',scope:'disposable full signed apps; local HTTP fixtures; real signatures, download, helper, replacement and restart',binary_sha256:createHash('sha256').update(await readFile(join(build,'bin/zerowork'))).digest('hex'),old_pid:app.pid,target,data,checks:[],transitions:[]};
async function transaction(){const active=await readJSON(join(root,'active.json'));if(active?.transaction)txn=active.transaction;return txn?readJSON(join(txn,'record.json')):null;}
try{
 await h.waitForServerReady();await h.resizeWindow(1100,800);const initial=await route();assert.equal(initial.pid,app.pid);assert.equal(initial.app_version,'0.3.0-rc1');run('codesign',['--verify','--deep','--strict',target]);report.checks.push('Starting the real signed app and applying its Dock icon leaves the installed bundle signature valid');
 await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.prompt');await h.type_('DRAFT_BEFORE_FULL_UPDATE');
 await route('fixture_feed',{envelope,archive});await route('open');
 await h.waitFor(async()=> (await route()).update_state===2||null,15000);assert((await text('update.primary')).includes('下载更新'));await click('update.primary');
 const download=await h.waitFor(async()=>{const s=await route();assert.notEqual(s.update_state,10,JSON.stringify(s));return s.received>0?s:null;},15000);report.download=download;await cap('01-downloaded-bytes');
 await h.waitFor(async()=>{const s=await route();assert.notEqual(s.update_state,10,JSON.stringify(s));return s.update_state===5?s:null;},30000);await cap('02-verified');
 report.checks.push('UI fetched the signed manifest and streamed the actual ZIP through NSURLSession; size, SHA256, Ed25519 signature, archive and signed app validation passed');
 await click('update.primary');await h.waitFor(async()=> (await route()).can_force||null);
 if(force){await click('update.primary');await h.waitFor(async()=> (await route()).phase==='confirm'||null);assert.equal((await route()).allow_unsaved,true);await cap('03-force-install-confirm');await click('update.primary');}
 else{
 await click('update.cancel');
 await click('ai.session.new');await click('ai.session.close.accept');await h.mouseMove(1,1);await click('ai.sessions');
 const menu=await visible('ai.sessions.menu'),ids=[...new Set(flat([menu]).filter(shown).map(n=>n.test_id??'').filter(id=>/^ai.session.delete.\d+$/.test(id)))];assert(ids.length>0);
 for(const [i,id] of ids.entries()){await click(id);await click('ai.session.close.accept');await h.waitFor(async()=>!(await h.query(id)).some(shown)||null);if(i<ids.length-1){if(!(await h.query('ai.panel')).some(shown))await click('toolbar.ai');await click('ai.sessions');}}
 const drafts=await route('drafts');for(const w of drafts.windows){assert.equal(w.prompt_len,0);assert.equal(w.legacy_reason,null);for(const state of w.states){assert.equal(state.draft_len,0);assert.equal(state.journal_draft_len,0);}}
 await route('open');await visible('update.modal');assert.equal((await route()).message,'');await click('update.primary');await h.waitFor(async()=> (await route()).phase==='confirm'||null);assert.equal((await route()).allow_unsaved,false);await cap('03-install-confirm');await click('update.primary');
 }
 const deadline=Date.now()+90000;let last='';
 while(Date.now()<deadline){
  const r=await transaction();if(r?.stage&&r.stage!==last){last=r.stage;report.transitions.push({stage:r.stage,decision:r.decision,time:new Date().toISOString()});await writeFile(join(out,'progress.json'),JSON.stringify(report,null,2));}
  if(r&&['cancelled','prepare_failed','aborted_before_replace','incompatible_data','restore_failed','old_restored_verified','readiness_unknown'].includes(r.stage))throw new Error('Update failed: '+JSON.stringify(r));
  if(r?.stage==='healthy'){report.record=r;break;}
  await h.sleep(80);
 }
 assert.equal(report.record?.stage,'healthy','installer must receive a real healthy ACK from the restarted main app');
 const oldExit=await Promise.race([ended,h.sleep(5000).then(()=>{throw new Error('old process still running')})]);assert.equal(oldExit.code,0);report.old_exit=oldExit;
 restarted=await h.waitFor(async()=>{try{const s=await route();return s.pid===report.record.new_pid&&s.pid!==app.pid&&s.app_version==='0.3.1'?s:null}catch{return null}},15000);
 const owner=await readJSON(join(rpc,'owner.json'));assert.equal(Number(owner.pid),restarted.pid);assert.equal(await readFile(join(target,'Contents/Resources/update-test-marker.txt'),'utf8'),'NEW_SIGNED_APP');
 assert.equal(await readFile(join(report.record.backup,'Contents/Resources/update-test-marker.txt'),'utf8'),'OLD_SIGNED_APP');run('codesign',['--verify','--deep','--strict',target]);
 const startup=await readJSON(join(txn!,'startup.request')),healthy=await readJSON(join(txn!,'healthy.request'));assert.equal(startup.pid,restarted.pid);assert.equal(healthy.pid,restarted.pid);assert.equal(healthy.version,'0.3.1');
 assert.equal(await readFile(join(data,'keep-user-data.txt'),'utf8'),'ISOLATED_USER_DATA_MUST_SURVIVE');
 const snapshot=await readJSON(join(txn!,'workspace.json'));assert.equal(snapshot.phase,'before-close');assert.equal(snapshot.windows[0].tabs.length,1);assert.equal(report.record.decision,'committed');
 await visible('toolbar.settings');await click('toolbar.settings');await click('settings.nav.updates');assert((await text('settings.updates.version')).includes('0.3.1'));await cap('04-restarted-real-app');
 const windows=await h.request('POST','/zerowork/windows',{action:'snapshot'});assert(windows.windows.length>0);assert(windows.windows[0].frame_count>0);
 report.checks.push(force?'Real unsent AI input triggered the explicit force confirmation; final force action proceeded through the real install coordinator':'Real AI draft was rejected once, then every listed AI conversation was deleted; normal install proceeded without force or stale blockers','Final UI confirmation saved a real one-tab workspace and closed its actual Local session','Independent signed helper committed installation, observed old process exit 0, backed up the old app and replaced the target with the signed 0.3.1 package','Helper automatically launched the full new ZeroWork main app; PID changed and startup/data-access/healthy handshake completed','New app answers file RPC, renders a native window and About page reports 0.3.1; test user data and pre-close snapshot remain intact');
 report.new_process=restarted;report.owner=owner;report.startup=startup;report.healthy=healthy;report.windows=windows;report.status='passed';finished=true;
 await writeFile(join(out,'transaction.json'),JSON.stringify(report.record,null,2));await writeFile(join(out,'startup.json'),JSON.stringify(startup,null,2));await writeFile(join(out,'healthy.json'),JSON.stringify(healthy,null,2));
}catch(error){report.status='failed';report.error=String(error);report.stack=(error as Error).stack;report.record=await transaction();await cap('failure').catch(()=>{});await route().then(s=>report.host_state=s).catch(()=>{});process.exitCode=1;}
finally{
 // Stop only this fixture's processes; installer/startup files are preserved as evidence.
 try{if(restarted||app.exitCode===null){await h.request('POST','/zerowork/windows',{action:'quit'});await h.sleep(300);}}catch{}
 if(app.exitCode===null){app.kill('SIGTERM');await ended;}
 const r=await transaction();for(const role of ['new','helper']){const pid=r?.[role+'_pid'],birth=r?.[role+'_birth'];if(pid&&birth){const actual=Number(run(join(build,'bin/update-fixture'),['--birth',String(pid)]).trim());if(actual===birth)try{process.kill(pid,'SIGTERM')}catch{}}}
 await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out,old_pid:app.pid,new_pid:restarted?.pid,stage:report.record?.stage,checks:report.checks}));
 if(finished){await rm(base,{recursive:true,force:true});await rm(root,{recursive:true,force:true});}
}
