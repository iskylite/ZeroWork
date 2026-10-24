/** Real production group-close path. Own background App/RPC/data and own Local
 * subprocesses only. No injected session/result/product-state fixtures.
 * node e2e/group_close_native.ts --binary PATH --expected-sha SHA --out EMPTY_DIR
 */
import assert from 'node:assert/strict';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
import {spawn,execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {copyFile,mkdir,mkdtemp,open,readFile,readdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname,join,resolve} from 'node:path';
import {waitForServerReady,waitFor,query as rawQuery,clickAt,key,type_,screenshot,sleep,resizeWindow,screenPos,focused,mouseMove,scrollAt} from '../zig-out/share/zenit/harness/client.ts';
async function query(id:string):Promise<any[]> { const value=await rawQuery(id);return Array.isArray(value)?value:value?[value]:[]; }
const args:Record<string,string>={};for(let i=2;i<process.argv.length;i+=2){assert(['--binary','--expected-sha','--out','--local-count','--ssh','--confirm-only','--config'].includes(process.argv[i])&&process.argv[i+1]);args[process.argv[i]]=process.argv[i+1]}
assert(args['--binary']&&args['--out']&&/^[a-f0-9]{64}$/.test(args['--expected-sha']??''));
const localCount=Number(args['--local-count']??4);assert(Number.isInteger(localCount)&&localCount>=2&&localCount<=4);const sshEnabled=args['--ssh']!=='0';const totalCount=localCount+(sshEnabled?1:0);
const output=resolve(args['--out']);await mkdir(output,{recursive:true});assert.equal((await readdir(output)).length,0);
const binary=join(output,'zerowork-frozen');await copyFile(resolve(args['--binary']),binary);await copyFile(join(dirname(resolve(args['--binary'])),'zw_ipc.so'),join(output,'zw_ipc.so'));assert.equal(createHash('sha256').update(await readFile(binary)).digest('hex'),args['--expected-sha']);
const isolated=await mkdtemp(join(tmpdir(),'zw-group-close-')),rpc=join(isolated,'rpc'),data=join(isolated,'data');await Promise.all([mkdir(rpc),mkdir(data)]);const shellConfig=join(isolated,'shell-config');await mkdir(shellConfig);await writeFile(join(shellConfig,'.zshrc'),"bindkey -e\nPS1='ZeroWork-acceptance%# '\n");
const privateConfig=sshEnabled?JSON.parse(await readFile(args['--config']??'/tmp/zerowork-next-acceptance-20261021.json','utf8')).direct:{host:'local-only.invalid',port:22,user:'tester',password:''};
const q=(x:any)=>JSON.stringify(x);
await writeFile(join(data,'hosts.toml'),`[[hosts]]\nname = "Close acceptance SSH"\nhost = ${q(privateConfig.host)}\nport = ${privateConfig.port}\nuser = ${q(privateConfig.user)}\nauth_mode = "password"\nauth = { password = ${q(privateConfig.password)} }\noptions = { strict_host_key = true }\n`,{mode:0o600});
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Menlo"\nfont_size = 14\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(output,'app.log'),'w');
const app=spawn(binary,[],{cwd:process.cwd(),env:{...process.env,ZDOTDIR:shellConfig,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const report:any={status:'running',pid:app.pid,binary,sha256:args['--expected-sha'],isolated,checks:[],screenshots:[],limits:['Synthetic public Harness input and real Metal captures; physical input, IME, VoiceOver not verified','Only this run\'s Local subprocesses and authenticated SSH connection are affected','Local real zsh uses an owned minimal ZDOTDIR to isolate user startup; user dotfiles are untouched','App SIGTERM at runner cleanup is not a normal shutdown receipt']};
const save=()=>writeFile(join(output,'report.json'),JSON.stringify(report,null,2));
const shown=(n:any)=>n?.rect&&!n.hidden&&n.visible!==false&&n.rect.w>0&&n.rect.h>0&&(n.effective_opacity??1)>0;
const flat=(n:any):any[]=>shown(n)?[n,...(n.children??[]).flatMap(flat)]:[];
const visible=async(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,20000);
const hidden=async(id:string)=>waitFor(async()=>!(await query(id)).some(shown)||null,20000);
const clickNode=async(n:any)=>{assert(shown(n));assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)};
const click=async(id:string)=>{if(id.startsWith('tabs.close.')){const tab=await visible(`tabs.tab.${id.split('.').at(-1)}`);await mouseMove(tab.rect.x+tab.rect.w/2,tab.rect.y+tab.rect.h/2);await sleep(100)}report.last_action={kind:'click',id};await save();await clickNode(await visible(id))};
const press=async(name:string,mods?:any)=>{assert((await key(name,mods)).ok)};
const type=async(text:string)=>{assert((await type_(text)).ok)};
const tabNodes=async()=>{const result=await query('tabs.strip');const strip=Array.isArray(result)?result.find(shown):null;return strip?flat(strip).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??'')):[]};
const sessionIds=async()=>{const ids:string[]=[];for(let candidate=1;candidate<=localCount+(sshEnabled?2:0);candidate++){const r=await screenPos(`groups.pane.${candidate}`);if(r.w>0&&r.h>0)ids.push(String(candidate))}return ids};
const groupVisible=async()=>waitFor(async()=>{const r=await screenPos('groups.workspace');return r.w>0&&r.h>0?r:null},15000);
const capture=async(name:string)=>{await sleep(120);assert((await screenshot(join(output,`${name}.png`))).ok);const observations:any={};for(const id of ['tabs.strip','groups.workspace','groups.close.confirm','groups.close.partial','local.close.confirmation','status.connection.identity','status.connection.chain','status.connection.forward','status.transfer','transfer.session']) observations[id]=await query(id);await writeFile(join(output,`${name}.queries.json`),JSON.stringify(observations,null,2));report.screenshots.push(name);await save()};
const check=(name:string,detail:any={})=>report.checks.push({name,status:'passed',detail});
async function checkPaneHeaders(stage:string){
 if(args['--confirm-only']==='1')return;
 const panes=(await query('groups.workspace')).filter(shown).flatMap(flat).filter(n=>/^groups\.pane\.\d+$/.test(n.test_id??''));assert.equal(panes.length,totalCount);
 const geometry=panes.map(pane=>{
  const header=pane.children?.find(shown);assert(header,'Group pane header must be visible');
  const nodes=flat(header),title=nodes.find(n=>n.test_id==='groups.pane.title'),status=nodes.find(n=>n.test_id==='groups.pane.status');assert(title&&status,'Actual pane title and status must be queryable');
  const id=pane.test_id.split('.').at(-1),pin=nodes.find(n=>n.test_id===`groups.pin.${id}`),menu=nodes.find(n=>n.test_id===`groups.menu.${id}`),grip=header.children?.find(shown);assert(pin&&menu&&grip,'All pane header controls must be visible');
  const within=(r:any)=>r.x>=header.rect.x-.5&&r.y>=header.rect.y-.5&&r.x+r.w<=header.rect.x+header.rect.w+.5&&r.y+r.h<=header.rect.y+header.rect.h+.5;
  for(const node of [title,status,grip,pin,menu])assert(within(node.rect),`${stage}: ${node.test_id??'grip'} must stay inside pane header`);
  assert(title.rect.x+title.rect.w<=status.rect.x-4+.5,`${stage}: pane title must leave the 4px gap before status`);
  assert(status.rect.x+status.rect.w<=pin.rect.x-4+.5,`${stage}: status must leave the 4px gap before pin`);
  assert(pin.rect.x+pin.rect.w<=menu.rect.x-4+.5,`${stage}: controls must not overlap`);
  return {pane:pane.test_id,header:header.rect,title:{text:title.text,rect:title.rect},status:{text:status.text,rect:status.rect},grip:grip.rect,pin:pin.rect,menu:menu.rect};
 });
 check(`real group pane headers stay bounded without title/status overlap (${stage})`,geometry);await save();
}
function noEstablishedSsh(stage:string){
 if(!sshEnabled)return;
 let listing='';try{listing=execFileSync('/usr/sbin/lsof',['-nP','-a','-p',String(app.pid),'-iTCP','-sTCP:ESTABLISHED'],{encoding:'utf8',stdio:['ignore','pipe','pipe']})}catch(error:any){assert.equal(error.status,1);listing=String(error.stdout??'')}
 assert.equal(listing.trim(),'','This owned app must release its real SSH TCP connections before runner cleanup');check(`real SSH sockets released before app teardown (${stage})`);
}

const file=async(path:string)=>{try{return await readFile(path,'utf8')}catch{return ''}};
async function command(cmd:string){await type(cmd);await press('return')}
async function trusted(cmd:string){
 let ok=false;for(let n=0;n<4;n++){await type('@');try{await waitFor(async()=>(await query('terminal.commands')).some(shown)||null,3000);ok=true;break}catch{await press('c',{ctrl:true});await sleep(300)}}
 assert(ok,'Production trusted command editor must open');await type(cmd);await press('right');await hidden('terminal.commands');await press('return');
}
async function focusSession(id:string){const r=await screenPos(`groups.pane.${id}`);assert(r.w>0&&r.h>0);assert((await clickAt(r.x+r.w/2,r.y+Math.max(60,r.h/2))).ok)}
const localOwners:{id:string,pid:number,tab:string}[]=[];const ownedShells:number[]=[];
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1440,900);
 let sshTab:string|undefined;let sshId:string|undefined;let groupName='CloseAcceptance';
 async function authenticateUntil(done:()=>Promise<boolean>){
  await waitFor(async()=>{
   if(await done())return true;
   if((await query('auth.challenge.trust_once')).some(shown)){await click('auth.challenge.trust_once');return null}
   if((await query('auth.challenge.answer.0')).some(shown)){await click('auth.challenge.answer.0');await type(privateConfig.password);await click('auth.challenge.submit');return null}
   return null;
  },45000);
 }
 if(sshEnabled){
  // Real SSH -> production Cmd+D -> group + actual duplicate SSH. The
  // duplicate is closed normally; the original live SSH remains in its group.
  await click('sidebar.host');await click('sidebar.host.connect');
  await authenticateUntil(async()=>{return (await query('status.connection.identity')).some(shown)&&!(await query('connection.progress')).some(shown)});
  sshTab=(await tabNodes())[0].test_id;await press('d',{cmd:true});await press('modifiers_released');await groupVisible();
  await authenticateUntil(async()=>(await sessionIds()).length===2);
  const holder=await visible('groups.tab');const title=flat(holder).map(n=>n.text??'').find(t=>t.startsWith('组 · '));assert(title);groupName=title.slice('组 · '.length);assert(groupName.length>0);
  const duplicate=(await tabNodes()).at(-1)!.test_id;assert.notEqual(duplicate,sshTab);await click(`tabs.close.${duplicate.split('.').at(-1)}`);
  await waitFor(async()=>!(await tabNodes()).some(n=>n.test_id===duplicate)||null,20000);await click('groups.tab');await groupVisible();
  const left=await sessionIds();assert.equal(left.length,1);sshId=left[0];check('production SSH Cmd+D group keeps original owner after normal duplicate close',{sshTab,sshId,groupName});
 }
 for(let i=0;i<localCount;i++){
  if(i===0&&!sshEnabled)await click('workspace.empty.local');else{await click('toolbar.new_session');await click('session.menu.local')}
  await sleep(1600);const marker=join(isolated,`local-${i}.pid`);await command(`printf '%s' "$$" > ${q(marker)}`);const pid=Number(await waitFor(async()=>/^\d+$/.test(await file(marker))?file(marker):null,15000));assert(pid>1);ownedShells.push(pid);report.owned_shell_pids=[...ownedShells];await save();
  const tab=(await tabNodes()).at(-1)!.test_id;assert(tab);
  await trusted(`grp ${groupName}`);await groupVisible();await sleep(180);const ids=await sessionIds();const id=ids.find(x=>x!==sshId&&!localOwners.some(y=>y.id===x));assert(id);localOwners.push({id,pid,tab});
 }
 await waitFor(async()=>(await sessionIds()).length===totalCount||null,15000);
 check('real Local sessions joined through production trusted command flow',{localOwners});
 const original=await sessionIds();check(sshEnabled?'mixed group includes live Local processes and one real authenticated SSH owner':'real Local group ready',{sessions:original});
 await checkPaneHeaders('initial-real-members');
 if(sshEnabled){
  await focusSession(sshId!);await visible('status.connection.identity');await visible('status.connection.chain');await visible('status.connection.forward');await visible('status.transfer');
  await click('status.transfer');const scoped=flat(await visible('transfer.session')).map(n=>n.text??'').join('\n');assert(scoped.includes('本组传输')&&scoped.includes('所选组暂无传输任务'),scoped);await capture('00-group-ssh-status-and-transfer-scope');
  await click(localOwners[0].tab);await hidden('transfer.session');await hidden('groups.workspace');check('leaving actual group dismisses frozen group transfer popover');
  await click('groups.tab');await groupVisible();await focusSession(localOwners[0].id);await visible('status.transfer');await hidden('status.connection.chain');await hidden('status.connection.forward');
  const rawIdentity=await query('status.connection.identity');const localIdentity=(Array.isArray(rawIdentity)?rawIdentity:[]).filter(shown);assert(!localIdentity.some(n=>flat(n).some(v=>v.text==='已连接')),'Local pane must not retain previous SSH connection state');
  await click('status.transfer');const localScope=flat(await visible('transfer.session')).map(n=>n.text??'').join('\n');assert(localScope.includes('本组传输')&&localScope.includes('所选组暂无传输任务'),localScope);await capture('00-group-local-status-keeps-transfer-scope');await click('status.transfer');await hidden('transfer.session');
  await focusSession(sshId!);await visible('status.connection.chain');await visible('status.connection.forward');await capture('00-group-original-ssh-status-restored');check('mixed group bottom bar follows real focused session while transfer scope remains all frozen group members');
 }
 // Mandatory group cancellation must not terminate anything.
 await click('groups.close');const confirm=await visible('groups.close.confirm');assert(Math.abs(confirm.rect.w-480)<1&&confirm.rect.h<=294);assert.equal((await focused()).test_id,'groups.close.cancel');await capture('01-confirm-mixed');await press('escape');await hidden('groups.close.confirm');await click('groups.close');await visible('groups.close.confirm');await click('groups.close.cancel');await hidden('groups.close.confirm');assert.deepEqual(await sessionIds(),original);for(const owner of localOwners)process.kill(owner.pid,0);check('cancel preserves group members and every original Local process');
 await press('w',{cmd:true});await visible('groups.close.confirm');await press('modifiers_released');await click('groups.close.cancel');await hidden('groups.close.confirm');assert.deepEqual(await sessionIds(),original);check('Command-W routes actual group owner through mandatory frozen confirmation');
 // The same real frozen membership is rendered under each persisted theme
 // at standard and minimum window sizes. No design/demo state is injected.
 for(const theme of ['light','sauber','dark']){
  await click(localOwners[0].tab);await click('local.status.theme');await visible('status.theme');await click(`status.theme.item.${theme}`);await waitFor(async()=>new RegExp(`theme\\s*=\\s*"${theme}"`).test(await readFile(join(data,'config.toml'),'utf8'))||null,10000);await click('status.theme.close');await click('groups.tab');
  for(const [size,w,h] of [['standard',1440,900],['minimum',860,480]] as const){await resizeWindow(w,h);await checkPaneHeaders(`${theme}-${size}`);await capture(`headers-${theme}-${size}`);await click('groups.close');const panel=await visible('groups.close.confirm');assert(Math.abs(panel.rect.w-480)<1&&panel.rect.h<=294);await capture(`confirm-${theme}-${size}`);await click('groups.close.cancel');await hidden('groups.close.confirm')}
 }
 if(args['--confirm-only']==='1'){report.status='passed';report.mode='confirmation_visual_only';}
 else {
 await resizeWindow(1440,900);
 // A foreground transition after capture changes the actual Local impact,
 // while the same boolean risk remains true: this must force reconfirmation.
 await focusSession(localOwners[sshEnabled?1:0].id);await command('sleep 2; sleep 45');await sleep(350);await click('groups.close');await visible('groups.close.confirm');await sleep(2500);await click('groups.close.accept');await visible('groups.close.confirm');for(const owner of localOwners)process.kill(owner.pid,0);check('same-kind foreground PID change invalidates approval before any close');await capture('02-reconfirm-new-foreground');await click('groups.close.cancel');await hidden('groups.close.confirm');
 // This run owns the second Local foreground process. Ignoring HUP/TERM
 // forces the real V0.1.1 Local cleanup to wait for its existing KILL deadline,
 // giving the UI a deterministic interval to stop only unstarted members.
 await focusSession(localOwners[sshEnabled?0:1].id);await command("python3 -c 'import signal,time;signal.signal(signal.SIGHUP,signal.SIG_IGN);signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(45)'");await sleep(400);
 // Begin actual closes and stop the unstarted remainder after observing a
 // real standalone tab disappear. No product results are set by this driver.
 await click('groups.close');await visible('groups.close.confirm');await click('groups.close.accept');
 await waitFor(async()=>{const tabs=await tabNodes();return tabs.some(n=>n.test_id===(sshEnabled?sshTab:localOwners[0].tab))?null:true},20000);
 await click('groups.close.cancel');await visible('groups.close.partial');await sleep(4800);await capture('03-real-partial-stop');
 const partial=await visible('groups.close.partial');const text=flat(partial).map(n=>n.text??'').join('\n');assert(/已关闭 [1-9]/.test(text),text);assert(/未关闭 [1-9]/.test(text),text);assert(/已取消|未关闭|等待/.test(text),text);assert(Math.abs(partial.rect.w-480)<1&&Math.abs(partial.rect.h-280)<1);
 await click('groups.close.cancel');await hidden('groups.close.partial');await click('groups.close');await visible('groups.close.partial');check('dismissing and reopening partial results preserves original receipt ledger');
 const remaining=await sessionIds();assert(remaining.length>0&&remaining.length<totalCount);const closed=original.filter(id=>!remaining.includes(id));assert(closed.length>0);for(const owner of localOwners.filter(x=>remaining.includes(x.id)))process.kill(owner.pid,0);check('partial preserves real closed receipts and healthy unstarted remainder',{closed,remaining,text});noEstablishedSsh('partial');
 // Reopen the retained partial ledger under all three persisted themes,
 // including the minimum native window. Closed identities remain read-only.
 for(const theme of ['light','sauber','dark']){
  await click('groups.close.cancel');await hidden('groups.close.partial');
  const healthy=localOwners.find(x=>remaining.includes(x.id));
  await click((healthy?.tab??sshTab)!);await click(healthy?'local.status.theme':'status.connection.theme');await visible('status.theme');await click(`status.theme.item.${theme}`);await waitFor(async()=>new RegExp(`theme\\s*=\\s*"${theme}"`).test(await readFile(join(data,'config.toml'),'utf8'))||null,10000);await click('status.theme.close');await click('groups.tab');
  for(const [size,w,h] of [['standard',1440,900],['minimum',860,480]] as const){
   await resizeWindow(w,h);await click('groups.close');const panel=await visible('groups.close.partial');assert(Math.abs(panel.rect.w-480)<1&&Math.abs(panel.rect.h-280)<1);await capture(`partial-${theme}-${size}`);await click('groups.close.cancel');await hidden('groups.close.partial');
  }
  await click('groups.close');await visible('groups.close.partial');
 }
 await resizeWindow(1440,900);
 // Retry prepares only original remainder; approval is explicit again. Native
 // close completion leaves no writable original session or group presentation.
 await click('groups.close.accept');await visible('groups.close.confirm');const retryText=flat(await visible('groups.close.confirm')).map(n=>n.text??'').join('\n');for(const id of closed)assert(!new RegExp(`#${id} · 确认关闭`).test(retryText));await capture('04-retry-original-remainder');
 const scroll=flat(await visible('groups.close.confirm')).find(n=>n.test_id==='groups.close.members');assert(scroll);const fixedAccept=(await visible('groups.close.accept')).rect,fixedCancel=(await visible('groups.close.cancel')).rect;
 assert((await scrollAt(scroll.rect.x+scroll.rect.w/2,scroll.rect.y+scroll.rect.h/2,0,-2000)).ok);
 const notes=await waitFor(async()=>{const current=flat(await visible('groups.close.confirm'));const effect=current.find(n=>n.text==='停止命令、AI 与 SOCKS；传输暂停并保留。'),cancel=current.find(n=>n.text==='取消不会断开；已关闭的成员不能自动恢复。');return effect&&cancel&&[effect,cancel].every(n=>n.rect.y>=scroll.rect.y-.5&&n.rect.y+n.rect.h<=scroll.rect.y+scroll.rect.h+.5)?{effect:effect.rect,cancel:cancel.rect}:null},10000);
 const acceptButton=await visible('groups.close.accept'),cancelButton=await visible('groups.close.cancel');assert.deepEqual(acceptButton.rect,fixedAccept);assert.deepEqual(cancelButton.rect,fixedCancel);assert(acceptButton.focusable&&cancelButton.focusable);check('public group-close ScrollArea reveals complete effect and cancel notes while fixed actions remain enabled',{scroll:scroll.rect,notes,accept:acceptButton.rect,cancel:cancelButton.rect});await capture('04b-retry-notes-scrolled-fixed-actions');await click('groups.close.accept');
 await waitFor(async()=>{if((await query('local.close.confirmation')).some(shown)){await click('local.close.accept');return null}return (await tabNodes()).length===0||null},30000);await hidden('groups.workspace');for(const owner of localOwners){assert.throws(()=>process.kill(owner.pid,0))}check('retry closes only remaining original handles and releases all original Local processes');noEstablishedSsh('complete');await capture('05-all-original-handles-released');
 report.status='passed';
 }
}catch(error){report.status='failed';report.error=String(error);await capture('failed').catch(()=>{});process.exitCode=1}
finally{
 await save();if(app.exitCode===null)app.kill('SIGTERM');await Promise.race([ended,sleep(5000)]);
 if(app.exitCode===null){app.kill('SIGKILL');await Promise.race([ended,sleep(2000)])}
 await log.close();
 for(const pid of ownedShells){try{process.kill(pid,'SIGHUP')}catch{}}
 const matches:string[]=[];for(const name of await readdir(output)){if(/\.(?:json|log|txt)$/.test(name)){const bytes=await readFile(join(output,name));if(privateConfig.password&&bytes.includes(Buffer.from(privateConfig.password)))matches.push(name)}}
 report.secret_scan={files_matching:matches};report.cleanup={app_exited:app.exitCode!==null||app.signalCode!==null,isolated_removed:false,private_bridge_directories_removed:await cleanupOwnedBridgeDirectories(app.pid!)};
 await rm(isolated,{recursive:true,force:true});report.cleanup.isolated_removed=true;await save();assert.equal(matches.length,0,'Evidence must not contain user secrets');
}
