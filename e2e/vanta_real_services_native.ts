/** Read-only acceptance against the user's actual MiMo and SSH/SFTP endpoints.
 * Credentials are read from a private temporary file; never copied to evidence.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,copyFile,open,rm,chmod,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash,randomBytes} from 'node:crypto';
import {query,clickTestId,clickAt,key,type_,resizeWindow,screenshot,waitFor,waitForServerReady,sleep} from '../zig-out/share/zenit/harness/client.ts';
const mode=process.argv[2],out=resolve(process.argv[3]);
assert(['local-ai','key-ai','key-sftp','vm-ssh','vm-sftp'].includes(mode));
const theme=process.env.ZW_ACCEPT_THEME??'dark';assert(['dark','light','sauber'].includes(theme));
const secretPath=process.env.ZEROWORK_ACCEPT_PRIVATE_INPUT;assert(secretPath,'ZEROWORK_ACCEPT_PRIVATE_INPUT must point to a private external JSON file');
const secret=JSON.parse(await readFile(secretPath,'utf8'));
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-r9-real-')));await chmod(iso,0o700);
const data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);await mkdir(out,{recursive:true});
const binary=join(iso,'zerowork');await copyFile('zig-out/bin/zerowork',binary);await copyFile('zig-out/bin/zw_ipc.so',join(iso,'zw_ipc.so'));
assert(secret.config_path,'Private input must specify config_path');
let config=await readFile(secret.config_path,'utf8');config=config.replace(/theme = "dark"/,`theme = "${theme}"`);config+='\n[ssh]\nauto_reconnect = false\nconnect_timeout_sec = 8\n';await writeFile(join(data,'config.toml'),config,{mode:0o600});
const sftp=mode.endsWith('sftp'),keyRoute=mode.startsWith('key');
let hosts='[registry]\nschema_version=2\nrevision=1\nnext_connection_id=3\nnext_group_id=1\n';
if(keyRoute){const identity=join(iso,'identity');await copyFile(secret.key_jump.key_path,identity);await chmod(identity,0o600);hosts+=`[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="private_key"\nname="密钥跳板"\nhost=${JSON.stringify(secret.key_jump.host)}\nport=${secret.key_jump.port}\nuser=${JSON.stringify(secret.key_jump.user)}\nauth={key=${JSON.stringify(identity)}}\n`;}
const target=keyRoute?secret.key_jump.target:secret.direct;
if(mode!=='local-ai')hosts+=`[[hosts]]\nconnection_id=2\nrevision=1\nprotocol="${sftp?'sftp':'ssh'}"\nauth_mode="password"\nname="真实验收目标"\nhost=${JSON.stringify(target.host)}\nport=${target.port}\nuser=${JSON.stringify(target.user)}\n${keyRoute?'route=[1]\n':''}`;
await writeFile(join(data,'hosts.toml'),hosts,{mode:0o600});
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const env={...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_AI_TOOL_TRACE:'1',ZEROWORK_FILE_TRACE:'1'};
for(const k of ['ZEROWORK_AI_MOCK','ZEROWORK_AI_ENDPOINT','ZEROWORK_AI_MODEL','ZEROWORK_AI_PROVIDER'])delete env[k];
const log=await open(join(out,'app.log'),'w'),app=spawn(binary,[],{cwd:process.cwd(),env,stdio:['ignore',log.fd,log.fd]});const ended=new Promise<void>(r=>app.once('close',()=>r()));
const report:any={status:'running',mode,theme,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),provider:{real:true,model:secret.ai.model},remote:mode==='local-ai'?null:{host:target.host,protocol:sftp?'sftp':'ssh',jump:keyRoute?secret.key_jump.host:null},stages:[],authentication:[],checks:[],limits:['Actual external model and SSH/SFTP; synthetic public native Harness input','Read-only terminal output and directory listing; no remote file writes','No forced external rate limiting; 429 only claimed if actually returned']};
const shown=(n:any)=>n?.rect&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const flat=(n:any):any[]=>shown(n)?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(x=>x.text??'').join('\n');
const vis=async(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,20000);
async function click(id:string){const n=await vis(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok,id)}
async function cap(name:string){const ids=['ai.panel','ai.usage.menu','connection.progress','connection.logs','plugin.challenge.title','plugin.challenge.source','files.local','files.remote','workspace.pane','tabs.strip'];const nodes=Object.fromEntries(await Promise.all(ids.map(async id=>[id,await query(id)])));await writeFile(join(out,name+'.json'),JSON.stringify(nodes,null,2));assert((await screenshot(join(out,name+'.png'))).ok);report.stages.push(name);console.log(mode,theme,name)}
const submitted=new Set<number>(),trusted=new Set<number>();
async function auth(){
 const generic=(await query('plugin.challenge.title')).find(shown);
 if(generic){
  const ns=(await Promise.all(['plugin.challenge.title','plugin.challenge.source','plugin.challenge.detail','plugin.challenge.material','plugin.challenge.choice.0','plugin.challenge.answer.0','plugin.challenge.answer.1','plugin.challenge.secret'].map(id=>query(id)))).flat().filter(shown),source=text(ns.find(n=>n.test_id==='plugin.challenge.source'));
  if(!source)return;
  assert(source.includes(target.host)||(keyRoute&&source.includes(secret.key_jump.host)),'Only user-supplied endpoints');
  const title=text(ns.find(n=>n.test_id==='plugin.challenge.title'));
  const detail=text(ns.find(n=>n.test_id==='plugin.challenge.detail'));
  if(detail.includes('认证未通过')){
   report.failure='SSH authentication rejected; stopped without guessing another credential';
   report.status='environment_blocked';await cap('actual-authentication-failed-wide');await resizeWindow(860,480);await cap('actual-authentication-failed-narrow');await click('plugin.challenge.cancel');report.checks.push('Actual failed authentication message, minimum-window layout and cancellation');return;
  }
  const once=ns.find(n=>n.test_id==='plugin.challenge.choice.0'&&text(n).includes('仅本次信任'));
  if(once&&title==='核对主机密钥'){
   assert(title==='核对主机密钥','Never accept a changed key automatically');
   const fingerprint=text(ns.find(n=>n.test_id==='plugin.challenge.material'));assert(fingerprint.includes('SHA256:'));
   assert(report.authentication.filter(x=>x.kind==='trust_once').length<8,'Too many repeated challenges');await click('plugin.challenge.choice.0');report.authentication.push({kind:'trust_once',endpoint:source,fingerprint});return;
  }
  if(title==='核对主机密钥')return;
  assert(title==='SSH 密码认证','Do not guess extra or private-key challenges');
  const fields=ns.filter(n=>/^plugin\.challenge\.answer\.\d+$/.test(n.test_id??'')&&n.focusable);
  const answer=fields[0]??ns.find(n=>n.test_id==='plugin.challenge.secret'&&n.focusable);
  if(answer){
   assert(source.includes(target.host),'Private-key jump must not request a guessed password');assert(fields.length<=1,'Do not guess multi-field challenges');
   assert(report.authentication.filter(x=>x.kind==='password').length<4,'Too many password attempts');await click(answer.test_id);await type_(target.password);await click('plugin.challenge.submit');report.authentication.push({kind:'password',endpoint:source,secret_recorded:false});
  }
  return;
 }
 const modal=(await query('auth.challenge.modal')).find(shown);if(!modal)return;const ns=flat(modal),endpoint=text(ns.find(n=>n.test_id==='auth.challenge.endpoint'));assert(endpoint.includes(target.host)||(keyRoute&&endpoint.includes(secret.key_jump.host)),'Only user-supplied endpoints');const trust=ns.find(n=>n.test_id==='auth.challenge.trust_once'&&n.focusable);if(trust&&!trusted.has(trust.id)){trusted.add(trust.id);const fingerprint=text(ns.find(n=>n.test_id==='auth.challenge.fingerprint'));assert(fingerprint.includes('SHA256:'));await click('auth.challenge.trust_once');report.authentication.push({kind:'trust_once',endpoint,fingerprint});return}const answer=ns.find(n=>n.test_id==='auth.challenge.answer.0'&&n.focusable);if(answer&&!submitted.has(answer.id)){submitted.add(answer.id);assert(endpoint.includes(target.host),'Private-key jump must not request a guessed password');await click('auth.challenge.answer.0');await type_(target.password);await click('auth.challenge.submit');report.authentication.push({kind:'password',endpoint,secret_recorded:false})}}
async function terminal(){return mode==='local-ai'?await vis('terminal.surface'):(await query('terminal.surface')).find(shown)??await vis('workspace.pane')}
async function submit(prompt:string){await click('ai.prompt');await key('a',{cmd:true});await type_(prompt);await click('ai.send')}
async function done(timeout=90000){await waitFor(async()=>{await auth();return !(await query('ai.stop')).some(shown)||null},timeout);const r=(await query('ai.recovery')).find(shown);if(r){report.provider_error=text(r);await cap('actual-provider-error');throw new Error('Real provider error: '+text(r))}return text(await vis('ai.panel'))}
async function events(){const raw=await readFile(join(out,'app.log'),'utf8');return raw.split('\n').flatMap(l=>{const i=l.indexOf('AI_TOOL_TRACE ');try{return i<0?[]:[JSON.parse(l.slice(i+14))]}catch{return[]}})}
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1440,900);
 if(mode==='local-ai')await click('workspace.empty.local');else{
  const row=await waitFor(async()=>(await query('sidebar.host')).find(n=>shown(n)&&text(n).includes('真实验收目标'))??null,15000);await clickAt(row.rect.x+row.rect.w/2,row.rect.y+row.rect.h/2);await click('sidebar.host.connect');
  const result=await waitFor(async()=>{await auth();if(report.status==='environment_blocked')return 'auth_failed';const p=(await query('connection.progress')).find(shown);if(p&&/连接失败|检测失败/.test(text(p)))return 'failed';if(sftp&&(await query('files.workspace')).some(shown))return 'attached';if(!sftp&&text((await query('status.connection.identity')).find(shown)).includes('已连接')&&(await query('workspace.pane')).some(shown)&&!(await query('plugin.challenge.title')).some(shown))return 'attached';return null},60000);
  if(result==='failed'){report.status='environment_blocked';report.failure=text(await vis('connection.progress'));await cap('actual-connect-failure-wide');await resizeWindow(860,480);if((await query('connection.progress.logs.toggle')).some(shown))await click('connection.progress.logs.toggle');await cap('actual-connect-failure-narrow');if((await query('connection.progress.retry')).some(shown)){await click('connection.progress.retry');await cap('real-retry-started');const cancel=(await query('auth.challenge.cancel')).some(shown)?'auth.challenge.cancel':'connection.progress.cancel';await click(cancel);report.checks.push('Real connection failure; retry and cancel actual new attempt')} }
  else if(result==='attached') report.checks.push('Real endpoint authenticated through production connection flow');
 }
 if(report.status==='running'&&sftp){
  await waitFor(async()=>{await auth();const n=(await query('files.remote')).find(shown);return n&&flat(n).some(x=>x.test_id==='files.row')||null},45000);await cap('real-sftp-list-wide');await resizeWindow(860,480);await cap('real-sftp-list-narrow');const pane=await vis('files.remote'),path=flat(pane).find(n=>n.test_id==='files.path');assert(path);await clickAt(path.rect.x+path.rect.w/2,path.rect.y+path.rect.h/2);await key('a',{cmd:true});await type_('/ZW_missing_r9_'+randomBytes(6).toString('hex'));await key('return');await waitFor(async()=>{await auth();return /目录读取失败/.test(text((await query('files.remote')).find(shown)))||null},30000);await cap('real-sftp-missing-error');report.checks.push('Actual SFTP directory list and nonexistent-directory error; no writes');
 }
 if(report.status==='running'&&!sftp){
  const marker='ZW_CONTEXT_R9_'+randomBytes(8).toString('hex');const term=await terminal();await clickAt(term.rect.x+30,term.rect.y+40);await type_("printf '"+marker+"\\n'");await key('return');await sleep(450);await click('toolbar.ai');
  assert(!text(await vis('ai.panel')).includes('模型未就绪'),'Configured real gateway must be enabled in the composer');await click('ai.composer.model');await cap('real-model-menu-wide');assert(text(await vis('ai.model.menu')).includes(secret.ai.model));await key('escape');
  await submit('只根据已经附带的终端上下文，找出以 ZW_CONTEXT_R9_ 开头的完整标记，只回复标记。不要调用工具，不要猜测。');const answer=await done();assert(answer.includes(marker),'Real model must return nonce not supplied in prompt');await cap('real-context-answer-wide');await click('ai.composer.usage');assert(text(await vis('ai.usage.menu')).includes('终端上下文'));await cap('real-context-popover-wide');await key('escape');report.checks.push('Real model identified nonce available only in terminal context');
  await submit('排版验收：不要调用工具。用 Markdown 输出一个三级标题“检查结果”、两项短列表、一个含三行的 sh 代码块和一个两层嵌套 JSON 代码块。内容只使用虚构的 demo 值，保持简短。');await done();await cap('real-markdown-wide');await resizeWindow(860,480);await cap('real-markdown-narrow');assert((await query('ai.message.code.scroll')).some(shown),'Actual model code blocks rendered');
  await submit("只调用一次 run_command，使用当前 assistant_session_id，命令严格为 printf 'ZW_TOOL_R9_OK\\n'。不要调用其他工具，等待真实结果，最后简短回复执行结果。");await waitFor(async()=>{await auth();if((await query('ai.approval.accept')).some(shown)){await cap('real-tool-approval');await click('ai.approval.accept');return true}return !(await query('ai.stop')).some(shown)||null},90000);await done();const trace=await events();const results=trace.filter(e=>e.event==='host_result');assert(results.some(e=>e.result?.stdout?.includes('ZW_TOOL_R9_OK')),'Real attached tool output required');await cap('real-tool-default-collapsed');const disclosure=(await query('ai.tool.result.disclosure')).find(shown);assert(disclosure);await click('ai.tool.result.disclosure');await cap('real-tool-expanded');await click('ai.tool.result.disclosure');report.checks.push('Actual model tool call, real execution and feedback; step disclosure inspected');report.tool_results=results;
 }
 if(report.status==='running')report.status='passed';
}catch(e){report.status='failed';report.error=String(e);try{await cap('failure')}catch{}}
finally{app.kill('SIGTERM');await Promise.race([ended,sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}await log.close();await rm(iso,{recursive:true,force:true});report.private_isolation_removed=true;await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(mode,report.status)}
if(report.status==='failed')process.exitCode=1;
