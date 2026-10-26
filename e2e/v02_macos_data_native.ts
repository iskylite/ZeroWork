/** Frozen real App acceptance with canonical disposable instance storage.
 * Isolated 0600 reference persistence, same-App native credential reuse, VM/Grok consumption,
 * cleanup cancel/current and sibling session gates, erase and reset recovery.
 * Only the App accesses Keychain. No external observer or permission change is used.
 */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {createHash,randomUUID,randomBytes} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,rm,chmod,stat,readdir,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {request,waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep,mouseMove,scrollAt} from '../vendor/zenit/e2e/client.ts';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';

const opts:Record<string,string>={};
for(let i=2;i<process.argv.length;i+=2){
 assert(['--binary','--sha','--out','--private-config','--app','--resume','--prior-report'].includes(process.argv[i])&&process.argv[i+1]);
 opts[process.argv[i]]=process.argv[i+1];
}
for(const k of ['--binary','--sha','--out','--private-config','--app'])assert(opts[k],`Required ${k}`);
const source=resolve(opts['--binary']),out=resolve(opts['--out']);
const sha=(value:string|Buffer)=>createHash('sha256').update(value).digest('hex');
assert.equal(sha(await readFile(source)),opts['--sha']);
assert.equal((await stat(opts['--private-config'])).mode&0o777,0o600,'Private input must be 0600');
const privateConfig=JSON.parse(await readFile(opts['--private-config'],'utf8'));
const direct=privateConfig.direct,ai=privateConfig.ai;
assert.equal(ai.model,'grok/grok-4.7');
assert(ai.endpoint.endsWith('/chat/completions'),'Supply an explicit private provider endpoint');
const secrets=[direct.password,ai.api_key,'OWNED-PASSPHRASE-'+randomUUID(),Array.from(randomBytes(32),v=>'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'[v&31]).join('')];
assert(secrets.every(v=>typeof v==='string'&&v.length>0));
const redact=(value:string)=>{for(const s of secrets)value=value.split(s).join('[REDACTED]');return value;};
const resuming=!!opts['--resume'];
const iso=await realpath(resuming?resolve(opts['--resume']):await mkdtemp(join(tmpdir(),'zw-macos-data-')));
assert(iso.includes('/T/zw-macos-data-')||iso.startsWith('/private/tmp/zw-macos-data-'),'Only an owned instance fixture may be resumed');
await chmod(iso,0o700);
await mkdir(out,{recursive:true});
assert.equal((await readdir(out)).length,0,'Use a fresh evidence directory');
const home=join(iso,'fake-home'),legacy=join(home,'.zerowork');
const data=join(iso,'data'),cache=join(data,'cache'),diagnostics=join(data,'logs');
const service='com.zerowork.app.credentials.instance.'+sha(data);
const bundle=resolve(opts['--app']);
const bundleExecutable=execFileSync('/usr/bin/plutil',['-extract','CFBundleExecutable','raw','-o','-',join(bundle,'Contents','Info.plist')],{encoding:'utf8'}).trim();
const binary=join(bundle,'Contents','MacOS',bundleExecutable);
assert.equal(sha(await readFile(binary)),opts['--sha']);
const bundleId=execFileSync('/usr/bin/plutil',['-extract','CFBundleIdentifier','raw','-o','-',join(bundle,'Contents','Info.plist')],{encoding:'utf8'}).trim();
execFileSync('/usr/bin/codesign',['--verify','--deep','--strict',bundle],{stdio:['ignore','pipe','pipe']});
const preserved=[join(home,'.ssh','known_hosts'),join(home,'.ssh','external-key'),join(home,'Downloads','exported.txt')];
if(!resuming){
await mkdir(data,{recursive:true,mode:0o700});
await mkdir(join(data,'logs'),{mode:0o700});
await mkdir(join(home,'.ssh'),{recursive:true,mode:0o700});
await mkdir(join(home,'Downloads'),{mode:0o700});
const external='external-'+randomUUID();
for(const file of preserved)await writeFile(file,file.endsWith('known_hosts')?'# '+external+'\n':external,{mode:0o600});
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=41\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ssh]\nauto_reconnect=false\nconnect_timeout_sec=8\n[ai]\ndefault_provider="native-grok"\nprovider_count=1\n[[ai.providers]]\nid="native-grok"\nkind="openai_compat"\nendpoint=${JSON.stringify(ai.endpoint)}\napi_key=${JSON.stringify(ai.api_key)}\nenabled=true\n[[ai.providers.models]]\nname=${JSON.stringify(ai.model)}\ndefault=true\ncontext_window=200000\nreasoning=false\nvision=false\nefforts=[]\n`,{mode:0o600});
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=8\nnext_connection_id=3\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=5\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Native Saved VM"\nhost=${JSON.stringify(direct.host)}\nport=${direct.port}\nuser=${JSON.stringify(direct.user)}\nauth={password=${JSON.stringify(direct.password)}}\nfuture="preserve"\n[[hosts]]\nconnection_id=2\nrevision=1\nprotocol="ssh"\nauth_mode="private_key"\nname="Owned offline saved credentials"\nhost="synthetic.invalid"\nuser="fixture"\nauth={key=${JSON.stringify(preserved[1])},passphrase=${JSON.stringify(secrets[2])}}\ntotp_secret=${JSON.stringify(secrets[3])}\n`,{mode:0o600});
await writeFile(join(data,'logs','app-owned.log'),'owned diagnostic\n',{mode:0o600});
await writeFile(join(data,'logs','terminal-owned.zwlog'),'owned recording\n',{mode:0o600});
await writeFile(join(data,'unknown-owned.txt'),'retained unknown file\n',{mode:0o600});
}
const preservedBytes=await Promise.all(preserved.map(file=>readFile(file)));
let savedConfig:Buffer|undefined,savedHosts:Buffer|undefined;
const report:any={status:'running',binary_sha256:opts['--sha'],started_at:new Date().toISOString(),checks:[],stages:[],runs:[],host_key_decisions:[],scope:{external_fixture_home:home,data,cache,diagnostics,legacy,standard_paths:false,service,keychain_access:'App only; no external reads/deletes',synthetic_public_harness:true,actual_home_environment_unchanged:true,actual_user_home_deleted:false},limits:['Real native Metal pixels with synthetic public Harness input; no physical input or IME claim.','Standard legacy relocation is covered by filesystem integration tests. This native run uses a canonical instance override and a fixed signed App path.']};
if(resuming){assert(opts['--prior-report']);report.prior_attempt=JSON.parse(await readFile(opts['--prior-report'],'utf8'));assert.equal(report.prior_attempt.scope.data,data);assert.equal(report.prior_attempt.binary_sha256,opts['--sha']);}
const previousRunNumbers=(await readdir(iso)).flatMap(name=>/^rpc-(\d+)$/.test(name)?[Number(name.slice(4))]:[]);
let app:any,ended:Promise<void>,log:any,rpc='',logPath='',run=resuming?Math.max(0,...previousRunNumbers):0,failure:any,harnessReady=false;
const shown=(n:any)=>n?.rect&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).filter(shown).map(n=>n.text??'').join(' ');
async function vis(id:string,timeout=20000){return waitFor(async()=>(await query(id)).find(shown)??null,timeout);}
async function clickNode(n:any){assert(shown(n));assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await sleep(100);}
async function click(id:string){await clickNode(await vis(id));}
async function absent(id:string){await waitFor(async()=>!(await query(id)).some(shown)||null,15000);}
async function snapshot(){const s=await request('POST','/zerowork/windows',{action:'snapshot'});assert(s.ok);return s;}
async function waitExit(timeout:number){
 let timer:ReturnType<typeof setTimeout>|undefined;
 await Promise.race([ended,new Promise<void>(done=>{timer=setTimeout(done,timeout);})]);
 if(timer)clearTimeout(timer);
}
async function capture(name:string){
 await sleep(220);
 const ids=['workspace.shell','settings.panel','settings.content','settings.data.clear_all','data.cleanup.modal','data.cleanup.message','data.cleanup.confirm','data.cleanup.cancel','tabs.strip','auth.challenge.modal','plugin.challenge.modal','plugin.challenge.source','plugin.challenge.material','ai.panel','ai.response'];
 const state=Object.fromEntries(await Promise.all(ids.map(async id=>[id,await query(id)])));
 await writeFile(join(out,name+'.json'),redact(JSON.stringify(state,null,2)));
 assert((await screenshot(join(out,name+'.png'))).ok);
 report.stages.push(name);console.log(name);
}
async function launch(label:string,ready=true){
 harnessReady=false;run++;rpc=join(iso,'rpc-'+run);await mkdir(rpc,{mode:0o700});
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 logPath=join(iso,'app-'+run+'.log');log=await open(logPath,'w',0o600);
 const env:NodeJS.ProcessEnv={...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''};
 delete env.ZEROWORK_AI_MOCK;env.ZEROWORK_DATA_DIR=data;
 app=spawn(binary,[],{env,stdio:['ignore',log.fd,log.fd]});
 ended=new Promise<void>(done=>app.once('close',()=>done()));
 const rec={label,pid:app.pid,fixed_app_path:bundle,started_at:new Date().toISOString(),ready_after_ms:0,ready_without_tester_credential_input:false};report.runs.push(rec);
 const starting=Date.now();
 if(ready){await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1440,900);rec.ready_after_ms=Date.now()-starting;rec.ready_without_tester_credential_input=true;harnessReady=true;}
}
async function archiveLog(){
 if(!log)return;await log.close();log=null;
 const raw=await readFile(logPath,'utf8');
 for(const s of secrets)assert(!raw.includes(s),'App logs contain no credential plaintext');
 await writeFile(join(out,'app-'+run+'.log'),raw);
 await cleanupOwnedBridgeDirectories(app.pid);
}
async function exitNormal(){
 assert((await request('POST','/zerowork/windows',{action:'quit'})).ok);
 await waitExit(15000);assert.equal(app.exitCode,0);assert.equal(app.signalCode,null);await archiveLog();
}
async function connect(){
 const row=(await query('sidebar.host')).find(n=>shown(n)&&text(n).includes('Native Saved VM'));assert(row);await clickNode(row);
 const fresh=(await query('sidebar.host')).find(n=>shown(n)&&text(n).includes('Native Saved VM'));
 await clickNode(flat(fresh).find(n=>n.test_id==='sidebar.host.connect'));
}
async function attach(){
 const until=Date.now()+50000;
 while(Date.now()<until){
  const s=await snapshot(),ssh=s.sessions.find((v:any)=>v.plugin==='ssh'&&v.lifecycle==='attached');
  if(ssh&&(await query('terminal.input')).some(shown))return ssh;
  assert(!(await query('auth.challenge.answer.0')).some(shown),'Saved password loads without re-entry');
  assert(!(await query('plugin.challenge.answer.0')).some(shown),'Saved password loads through shared presenter without re-entry');
  const shared=(await query('plugin.challenge.modal')).find(shown);
  if(shared&&text(shared).includes('核对主机密钥')){
   assert(text(shared).includes(`${direct.user}@${direct.host}:${direct.port}`));
   const once=flat(shared).find(n=>n.test_id==='plugin.challenge.choice.0'&&text(n).includes('仅本次信任'));
   assert(once,'Use only the actual trust-once choice for this VM endpoint');
   const material=text(flat(shared).find(n=>n.test_id==='plugin.challenge.material'));assert(material.includes('SHA256:'));
   report.host_key_decisions.push({source:text(flat(shared).find(n=>n.test_id==='plugin.challenge.source')),material,choice:'trust_once'});await clickNode(once);
  }
  const trust=(await query('auth.challenge.trust_once')).find(shown);
  if(trust){const modal=(await query('auth.challenge.modal')).find(shown);assert(text(modal).includes(direct.host));await clickNode(trust);}
  await sleep(150);
 }
 throw Error('VM did not attach');
}
async function shell(command:string,expected:string){
 await click('terminal.input');assert((await type_(command)).ok);await key('enter');
 await waitFor(async()=>text((await query('workspace.pane')).find(shown)).includes(expected)||null,20000);
}
async function settings(){
 if(!(await query('settings.panel')).some(shown))await click('toolbar.settings');
 await click('settings.nav.data');
 const viewport=await vis('settings.viewport');
 await scrollAt(viewport.rect.x+viewport.rect.w/2,viewport.rect.y+viewport.rect.h/2,0,-1600);await sleep(120);
 if(!(await query('settings.data.clear_all')).some(shown))await click('settings.data.actions.header');
 await scrollAt(viewport.rect.x+viewport.rect.w/2,viewport.rect.y+viewport.rect.h/2,0,-1600);await sleep(120);
 await vis('settings.data.clear_all');
}
async function clearAllowed(){
 const button=await waitFor(async()=>(await query('settings.data.clear_all')).find(n=>shown(n)&&n.focusable)??null,20000);
 await clickNode(button);await vis('data.cleanup.modal');
}
async function persisted(){
 assert.equal((await stat(data)).mode&0o777,0o700);
 for(const name of ['config.toml','hosts.toml'])assert.equal((await stat(join(data,name))).mode&0o777,0o600);
 const currentConfig=await readFile(join(data,'config.toml')),currentHosts=await readFile(join(data,'hosts.toml'));
 const combined=currentConfig.toString()+'\n'+currentHosts.toString();
 for(const secret of secrets)assert(!combined.includes(secret),'Secret plaintext is absent from persisted files');
 const refs=[...combined.matchAll(/(?:password_ref|passphrase_ref|totp_secret_ref|api_key_ref)\s*=\s*"(zw1_[a-f0-9]{64})"/g)].map(m=>m[1]);
 assert.equal(new Set(refs).size,4);assert(combined.includes('future = "preserve"'));
 if(savedConfig){assert.deepEqual(currentConfig,savedConfig);assert.deepEqual(currentHosts,savedHosts);}else{savedConfig=currentConfig;savedHosts=currentHosts;report.credential_reference_count=4;}
 return [currentConfig,currentHosts];
}
async function preservedExternal(){assert.deepEqual(await Promise.all(preserved.map(file=>readFile(file))),preservedBytes);}
async function closeTab(tab:number){
 await click('tabs.close.'+tab);
 for(const id of ['session.close.accept','local.close.accept'])if((await query(id)).some(shown))await click(id);
 await absent('tabs.tab.'+tab);
}
async function emptyRestart(name:string){
 await launch(name);assert.equal((await query('sidebar.host')).filter(shown).length,0);assert.equal((await snapshot()).sessions.length,0);
 const hosts=await readFile(join(data,'hosts.toml'),'utf8').catch(e=>{if(e.code==='ENOENT')return '';throw e;});
 assert(!hosts.includes('Native Saved VM'));await preservedExternal();
}
try{
 if(!resuming){
 await launch('first-native-credential-migration');
 await persisted();
 assert.equal(await readFile(join(data,'unknown-owned.txt'),'utf8'),'retained unknown file\n');
 assert.equal(await readFile(join(diagnostics,'app-owned.log'),'utf8'),'owned diagnostic\n');
 assert.equal(await readFile(join(data,'logs','terminal-owned.zwlog'),'utf8'),'owned recording\n');
 for(const directory of [data,cache,diagnostics])assert.equal((await stat(directory)).mode&0o777,0o700);
 await preservedExternal();
 report.checks.push('The actual App migrates four plaintext secret fields into references in its own scoped native credential store, retains unknown files/recordings and enforces 0700/0600. No external credential process is used.');
 await capture('01-native-credential-migration');
 await click('toolbar.settings');await click('settings.nav.data');await click('settings.data.location.header');
 await vis('settings.data.open_config_dir');
 const locationText=text((await query('settings.data.location')).find(shown));
 for(const path of [data,cache,diagnostics])assert(locationText.includes(path),'Settings location reflects the exact runtime Paths');
 await capture('01b-data-location-paths');await key('escape');await exitNormal();
 }
 if(!report.prior_attempt?.grok?.token_returned){
 await launch('first-restart-same-app-credential-recovery');await persisted();await connect();const ssh=await attach();
 const token='SAVED_VM_'+randomUUID().replaceAll('-','');await shell(`printf '%s\\n' '${token}'`,token);
 report.checks.push('Restart reads the saved password through its native credential store and authenticates the actual VM without password entry.');await capture('02-restart-vm-authenticated');
 await click('toolbar.ai');await vis('ai.prompt');
 const aiToken='SAVED_GROK_'+randomUUID().replaceAll('-','');await click('ai.prompt');
 await type_('Reply with exactly this token and nothing else. Use no tools: '+aiToken);await click('ai.send');
 await waitFor(async()=>{const raw=await readFile(logPath,'utf8');return !(await query('ai.stop')).some(shown)&&raw.includes('provider_response_finish')||null;},150000);
 const aiLog=await readFile(logPath,'utf8');
 const events=aiLog.split('\n').flatMap(line=>{const at=line.indexOf('AI_TOOL_TRACE ');if(at<0)return [];try{return[JSON.parse(line.slice(at+14))]}catch{return[]}});
 assert(events.some(e=>e.event==='provider_http_response'&&e.status===200));
 assert((await query('ai.response')).some(n=>shown(n)&&text(n).includes(aiToken)));
 assert(!events.some(e=>e.event==='dynamic_invocation'));
 report.grok={model:ai.model,http_200:true,token_returned:true,tool_invocations:0};
 report.checks.push('One actual Grok request after restart reads the saved API key through its native credential store and returns the nonce.');
 await capture('03-restart-grok-saved-key');await key('escape');if((await query('ai.panel')).some(shown))await click('toolbar.ai');
 await settings();const gate=await vis('settings.data.clear_all');await capture('04-active-session-cleanup-gate');await clickNode(gate);
 assert(!(await query('data.cleanup.modal')).some(shown),'Active session blocks cleanup entry');assert.equal(app.exitCode,null);await persisted();
 await key('escape');await closeTab(ssh.tab);
 const firstWindow=(await snapshot()).windows[0].window;
 const row=(await query('sidebar.host')).find(n=>shown(n)&&text(n).includes('Native Saved VM'));assert(row);
 await mouseMove(row.rect.x+row.rect.w/2,row.rect.y+row.rect.h/2);await clickNode(row);await click('sidebar.host.more');await click('context.menu.new_window');
 await waitFor(async()=>(await snapshot()).windows.length===2||null);
 const second=(await snapshot()).windows.find((w:any)=>w.window!==firstWindow).window;
 await request('POST','/zerowork/windows',{action:'select',window:second});const secondSsh=await attach();
 await request('POST','/zerowork/windows',{action:'select',window:firstWindow});await settings();await click('settings.data.clear_all');
 assert(!(await query('data.cleanup.modal')).some(shown),'A session in another native window blocks cleanup');
 await capture('05-cross-window-cleanup-gate');
 report.checks.push('Actual SSH sessions block cleanup both in the current window and from a different native window.');
 await key('escape');await request('POST','/zerowork/windows',{action:'select',window:second});await closeTab(secondSsh.tab);
 await request('POST','/zerowork/windows',{action:'close',window:second});await request('POST','/zerowork/windows',{action:'select',window:firstWindow});
 }else{report.grok=report.prior_attempt.grok;report.checks.push('Prior same-scope actual VM/Grok and both activity gates retained; no repeated model request.');await launch('continue-cancel-and-clear-after-runner-failure');await persisted();}
 await settings();await clearAllowed();await capture('06-idle-clear-confirmation');
 const beforeCancel=await persisted();await click('data.cleanup.cancel');await absent('data.cleanup.modal');assert.deepEqual(await persisted(),beforeCancel);
 assert.equal(app.exitCode,null);await preservedExternal();
 report.checks.push('Cancel preserves config and hosts bytes, all external sentinels and the running App.');await capture('07-cancel-preserved');
 await exitNormal();await launch('second-restart-same-app-credential-recovery');await persisted();await connect();const thirdSsh=await attach();
 const thirdToken='RESTART_SAVED_VM_'+randomUUID().replaceAll('-','');await shell(`printf '%s\\n' '${thirdToken}'`,thirdToken);
 await capture('07b-second-restart-same-app');await closeTab(thirdSsh.tab);await settings();
 report.checks.push('The same fixed App path restarts a second time and authenticates the VM again without credential entry or external Keychain access.');
 await writeFile(join(cache,'owned-cache'),'owned');await writeFile(join(diagnostics,'owned-diagnostic'),'owned');
 await clearAllowed();await capture('08-final-confirmation');await click('data.cleanup.confirm');
 await waitExit(20000);assert.equal(app.exitCode,0,'Successful clear exits normally');assert.equal(app.signalCode,null);await archiveLog();
 for(const directory of [data,cache,diagnostics,legacy])await assert.rejects(stat(directory),{code:'ENOENT'});
 await preservedExternal();report.checks.push('Confirmed clear exits 0 and removes the complete isolated data/cache/diagnostic roots while shared SSH, private-key and downloaded/exported sentinels survive.');
 await emptyRestart('restart-after-clear');await capture('09-clean-restart-no-resurrection');
 report.checks.push('Restart after clear has no saved hosts or sessions and no legacy resurrection.');
 const unreadable=join(data,'owned-unreadable');await mkdir(unreadable,{mode:0o700});await writeFile(join(unreadable,'owned-child'),'owned');await chmod(unreadable,0o000);
 await settings();await clearAllowed();await click('data.cleanup.confirm');
 await waitFor(async()=>text((await query('data.cleanup.modal')).find(shown)).includes('清除未完成')||null,15000);
 assert.equal(app.exitCode,null);assert((await stat(join(data,'.reset-pending'))).isFile());await capture('10-partial-delete-failure-marker');
 await exitNormal();assert((await stat(join(data,'.reset-pending'))).isFile());
 assert.equal(await readFile(join(unreadable,'owned-child'),'utf8').catch(e=>e.code),'EACCES');
 await chmod(unreadable,0o700);
 report.checks.push('An owned 000 directory causes a truthful partial-delete failure; the App stays alive and .reset-pending survives normal exit.');
 await launch('startup-reset-recovery-alert',false);
 await writeFile(join(out,'recovery-handoff.json'),JSON.stringify({pid:app.pid,bundle_id:bundleId,app_path:bundle,marker:join(data,'.reset-pending'),expected_alert:'应用数据清除尚未完成',expected_action:'继续清除并退出'},null,2));
 console.log('RECOVERY_CUA_HANDOFF '+join(out,'recovery-handoff.json'));
 await waitExit(180000);
 assert.equal(app.exitCode,0,'Native recovery confirmation completes and exits 0');assert.equal(app.signalCode,null);await archiveLog();
 for(const directory of [data,cache,diagnostics,legacy])await assert.rejects(stat(directory),{code:'ENOENT'});
 await preservedExternal();report.checks.push('Native startup recovery alert resumes the incomplete reset before loading config and exits 0; external sentinels still survive.');
 await emptyRestart('restart-after-recovered-reset');await capture('11-recovered-clean-restart');await exitNormal();
 report.status='passed_pending_pixel_review';
}catch(e){failure=e;report.status='failed';report.error=redact(String(e));report.error_stack=redact(e instanceof Error?e.stack??String(e):String(e));try{if(app?.exitCode===null&&harnessReady)await capture('failure-live');}catch{}}
finally{
 if(app?.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await waitExit(3000);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended!;}}
 try{await archiveLog();}catch(e){report.log_cleanup_error=redact(String(e));failure??=e;report.status='failed';}
 try{await chmod(join(data,'owned-unreadable'),0o700);}catch{}
 if(!failure){await rm(iso,{recursive:true,force:true});report.cleanup={private_directory_removed:true,external_keychain_operations:false};}
 else report.cleanup={private_directory_removed:false,retained_private_directory:iso,retained_creator_app:bundle,service,reason:'Retain original creator identity for App-owned credential cleanup; no external credential deletion attempted.'};
 report.finished_at=new Date().toISOString();await writeFile(join(out,'report.json'),redact(JSON.stringify(report,null,2)));
}
console.log(report.status);if(failure)throw Error(redact(String(failure)));
