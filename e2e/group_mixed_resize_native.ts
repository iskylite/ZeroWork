/** Real native group membership + both splitter directions + disk restore.
 * Owned Local PTY and loopback SSH/SFTP; KVM exercises its retained offline
 * renderer, not a live BMC. Synthetic public Harness input only.
 * node e2e/group_mixed_resize_native.ts BINARY OUTPUT PYTHON_WITH_PARAMIKO
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,readdir,writeFile,copyFile} from 'node:fs/promises';
import {dirname,join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
const sourceBinary=resolve(process.argv[2]), out=resolve(process.argv[3]), python=process.argv[4]??'python3';
await mkdir(out,{recursive:true});
const binary=join(out,'zerowork-frozen');await copyFile(sourceBinary,binary);
for(const name of ['zw_ipc.so','zw_execution.so','zw_secret_consume.so','zw_execution_guard'])await copyFile(join(dirname(sourceBinary),name),join(out,name));
const iso=await mkdtemp('/private/tmp/zw-mixed-group-'), data=join(iso,'data'), rpc=join(iso,'rpc'), zdot=join(iso,'shell'), local=join(iso,'local-files');
for(const path of [data,rpc,zdot,local])await mkdir(path);
for(const [name,content]of [['README.md','# Local fixture\n'],['deployment.json','{"status":"ready"}\n'],['app.log','Local log fixture\n']])await writeFile(join(local,name),content);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='mixed%# '\n");
const h=await import(pathToFileURL(join(dirname(dirname(sourceBinary)),'share/zenit/harness/client.ts')).href);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const report:any={status:'running',binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],captures:[],isolated:iso,limits:['Synthetic public Harness input; physical pointer, IME and VoiceOver not verified','KVM retained offline renderer only; live framebuffer/device input not exercised','Restart restores layout preferences; sessions are explicitly reopened']};
const save=()=>writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
const peerLog=await open(join(out,'peer.log'),'w');
const peer=spawn(python,[resolve('e2e/group_mixed_peer.py'),'--out',join(out,'peer')],{stdio:['ignore',peerLog.fd,peerLog.fd]});
let peerError:any;peer.once('error',error=>{peerError=error});
let app:any,log:any;
const shown=(n:any)=>n?.visible!==false&&!n?.hidden&&n?.rect?.w>0&&n?.rect?.h>0&&(n.effective_opacity??1)>0;
const flat=(n:any):any[]=>shown(n)?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join(' ');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const clickNode=async(n:any)=>{assert(shown(n));assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)};
const click=async(id:string)=>{report.stage=id;await save();await clickNode(await visible(id));await h.sleep(160)};
const panes=async()=>flat(await visible('groups.workspace')).filter(n=>/^groups\.pane\.\d+$/.test(n.test_id??''));
const tabNodes=async()=>flat(await visible('tabs.strip')).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??''));
const capture=async(name:string)=>{await h.sleep(160);assert((await h.screenshot(join(out,name+'.png'))).ok);report.captures.push(name);await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('groups.workspace'),null,2));await save()};
async function joinActive(existing:boolean){
 const tabs=await tabNodes(),tab=tabs[tabs.length-1];
 const x=tab.rect.x+tab.rect.w/2,y=tab.rect.y+tab.rect.h/2;
 assert((await h.request('POST','/mouse_down',{x,y,button:'right'})).ok);await h.request('POST','/mouse_up',{x,y,button:'right'});
 await click('context.menu.join_session_group');await visible('groups.join.dialog');
 if(existing)await click('groups.join.existing');else{await click('groups.join.name');await h.type_('Mixed Native');await click('groups.join.accept')}
 await visible('groups.workspace');await h.waitFor(async()=>!(await h.query('groups.join.dialog')).some(shown)||null,10000);
}
async function launch(label:string){
 log=await open(join(out,'app-'+label+'.log'),'w');
 app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 await h.waitForServerReady(60000);await h.resizeWindow(1440,900);await h.sleep(200);
}
async function stop(){
 const owned=app;app=null;
 if(owned&&owned.exitCode===null){owned.kill('SIGTERM');await new Promise<void>(r=>{const timer=setTimeout(()=>{if(owned.exitCode===null)owned.kill('SIGKILL');r()},3000);owned.once('close',()=>{clearTimeout(timer);r()})})}
 if(owned?.pid)await cleanupOwnedBridgeDirectories(owned.pid);await log?.close();log=null;
}
async function settleRemote(ready:any){
 for(let i=0;i<150;i++){
  const progress=(await h.query('connection.progress.close')).find(shown);
  const choice=(await h.query('plugin.challenge.choice.0')).find(shown);
  if(choice&&text(choice).includes('仅本次信任')){const material=await visible('plugin.challenge.material');assert(text(material).includes(ready.fingerprint));await clickNode(choice)}
  const trust=(await h.query('auth.challenge.trust_once')).find(shown);if(trust)await clickNode(trust);
  const title=(await h.query('plugin.challenge.title')).find(shown);
  if(title&&text(title)==='SSH 密码认证'){
   const answer=(await h.query('plugin.challenge.answer.0')).find(shown)??(await h.query('plugin.challenge.secret')).find(shown);assert(answer);await clickNode(answer);await h.type_(ready.password);await click('plugin.challenge.submit');
  }
  const answer=(await h.query('auth.challenge.answer.0')).find(shown);if(answer){await clickNode(answer);await h.type_(ready.password);await click('auth.challenge.submit')}
  if((await h.query('files.workspace')).some(shown))return;
  const terminal=(await h.query('terminal.surface')).find(shown);if(terminal&&!progress&&!title)return;
  await h.sleep(120);
 }
 throw Error('remote did not attach');
}
async function savedHost(name:string){
 const rows=(await h.query('sidebar.host')).filter(shown);const row=rows.find(n=>text(n).includes(name));
 assert(row, 'Saved fixture '+name);await h.clickAt(row.rect.x+65,row.rect.y+row.rect.h/2);
}
async function switchLayout(label:string){
 const p=(await panes())[0],id=p.test_id.split('.').at(-1);await click('groups.menu.'+id);
 const menu=await visible('groups.member_menu'),item=flat(menu).find(n=>n.text===label||n.text===(label==='全部改为上下排列'?'切换上下布局':label));assert(item);await clickNode(item);await h.sleep(180);
}
async function resizeDivider(divider:any,dx:number,dy:number){
 const x=divider.rect.x+divider.rect.w/2,y=divider.rect.y+divider.rect.h/2;
 await h.mouseDown(x,y);await h.mouseMove(x+(dx?Math.sign(dx)*8:0),y+(dy?Math.sign(dy)*8:0));await h.mouseMove(x+dx,y+dy);await h.mouseUp(x+dx,y+dy);await h.sleep(180);
}
async function dock(source:any,target:any,edge:'top'|'bottom'|'left'|'right'){
 const x=source.rect.x+15,y=source.rect.y+18;
 const tx=edge==='left'?target.rect.x+7:edge==='right'?target.rect.x+target.rect.w-7:target.rect.x+target.rect.w/2;
 const ty=edge==='top'?target.rect.y+7:edge==='bottom'?target.rect.y+target.rect.h-7:target.rect.y+target.rect.h/2;
 await h.mouseDown(x,y);await h.mouseMove(x+9,y);await h.mouseMove(tx,ty);await h.sleep(80);await h.mouseUp(tx,ty);await h.sleep(220);
}
async function navigateLocal(){
 const pane=await visible('files.local');const edit=flat(pane).find(n=>n.test_id==='files.path.edit');assert(edit);await clickNode(edit);await h.sleep(100);
 const input=flat(await visible('files.local')).find(n=>n.test_id==='files.path');assert(input);await clickNode(input);await h.key('a',{cmd:true});await h.type_(local);await h.key('return');await h.sleep(180);
}
async function openKvm(){
 await savedHost('Group KVM');await visible('bmc.content');
 for(let i=0;i<40;i++){
  const title=(await h.query('plugin.challenge.title')).find(shown);
  if(title&&text(title)==='BMC · 本次连接密码'){
   const answer=(await h.query('plugin.challenge.answer.0')).find(shown)??(await h.query('plugin.challenge.secret')).find(shown);assert(answer);await clickNode(answer);await h.type_('fixture-only');await click('plugin.challenge.submit');
  }
  if((await h.query('bmc.progress')).some(n=>shown(n)&&/失败|拒绝/.test(text(n))))break;
  await h.sleep(100);
 }
 await h.key('escape');await joinActive(true);
}
async function openAll(ready:any,run:string){
 await launch(run);await click('workspace.empty.local');await visible('terminal.surface');await joinActive(false);
 await savedHost('Group SSH');await settleRemote(ready);await joinActive(true);
 await savedHost('Group SFTP');await settleRemote(ready);await navigateLocal();await joinActive(true);
 await openKvm();assert.equal((await panes()).length,4);
}
function byName(ps:any[],name:string){const pane=ps.find(n=>text(n).includes(name));assert(pane,'Pane '+name);return pane}
function geometry(ps:any[]){return Object.fromEntries(['Local Terminal','Group SSH','Group SFTP','Group KVM'].map(name=>[name,byName(ps,name).rect]))}
try{
 const ready=await h.waitFor(async()=>{if(peerError)throw peerError;try{return JSON.parse(await readFile(join(out,'peer/ready.json'),'utf8'))}catch{return null}},15000);
 const kvm={endpoint:{host:'127.0.0.1',https_port:1},username:'fixture',display:{scale:'fit',read_only_requested:true}};
 let hosts='[registry]\nschema_version=2\nrevision=1\nnext_connection_id=4\nnext_group_id=1\n';
 for(const [id,protocol,name]of [[1,'ssh','Group SSH'],[2,'sftp','Group SFTP']] as const)hosts+=`[[hosts]]\nconnection_id=${id}\nrevision=1\nprotocol="${protocol}"\nname="${name}"\nhost="127.0.0.1"\nport=${ready.port}\nuser="fixture"\nauth_mode="password"\nauth={password="fixture-only"}\nauto_shell_integration=false\noptions={strict_host_key=true}\n`;
 hosts+=`[[hosts]]\nconnection_id=3\nrevision=1\nprotocol="bmc_ikvm"\nname="Group KVM"\npayload=${JSON.stringify(JSON.stringify(kvm))}\n`;
 await writeFile(join(data,'hosts.toml'),hosts);await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ssh]\nconnect_timeout_sec=1\n');
 if(process.argv[5]==='preview'){
  await launch('preview');await savedHost('Group SFTP');await settleRemote(ready);await navigateLocal();await joinActive(false);
  await click('toolbar.new_session');await click('session.menu.local');await visible('terminal.surface');
  await click('terminal.surface');await h.type_("printf 'Local terminal ready\\n'");await h.key('return');await joinActive(true);
  await savedHost('Group SSH');await settleRemote(ready);await joinActive(true);
  await switchLayout('全部改为上下排列');let ps=await panes();
  await dock(byName(ps,'Local Terminal'),byName(ps,'Group SSH'),'left');ps=await panes();
  let all=flat(await visible('groups.workspace')),horizontal=all.find(n=>/^groups\.separator\./.test(n.test_id??'')&&n.rect.w>n.rect.h);assert(horizontal);await resizeDivider(horizontal,0,-90);
  all=flat(await visible('groups.workspace'));const vertical=all.find(n=>/^groups\.separator\./.test(n.test_id??'')&&n.rect.h>n.rect.w);assert(vertical);await resizeDivider(vertical,90,0);
  ps=await panes();const f=byName(ps,'Group SFTP').rect,l=byName(ps,'Local Terminal').rect,r=byName(ps,'Group SSH').rect;
  assert.equal(ps.length,3);assert(f.y<l.y&&f.y<r.y);assert(Math.abs(l.y-r.y)<2);assert(f.w>l.w+r.w-2);assert(l.w>r.w+100);
  report.checks.push('requested actual layout: SFTP spans top; Local left and SSH right below with unequal widths');
  report.geometry={sftp:f,local:l,ssh:r};await capture('requested-sftp-top-local-ssh-bottom');
 }else{
 await openAll(ready,'first');let ps=await panes();await capture('01-four-existing-cards');
 await dock(byName(ps,'Local Terminal'),byName(ps,'Group SSH'),'top');ps=await panes();
 await dock(byName(ps,'Group SFTP'),byName(ps,'Group KVM'),'top');ps=await panes();
 let g=geometry(ps);assert(Math.abs(g['Local Terminal'].x-g['Group SSH'].x)<1);assert(Math.abs(g['Group SFTP'].x-g['Group KVM'].x)<1);assert(g['Group SFTP'].x>g['Local Terminal'].x+100);
 const dividers=flat(await visible('groups.workspace')).filter(n=>/^groups\.separator\./.test(n.test_id??''));
 const left=dividers.find(n=>n.rect.w>n.rect.h&&n.rect.x<g['Group SFTP'].x-5),right=dividers.find(n=>n.rect.w>n.rect.h&&n.rect.x>g['Local Terminal'].x+g['Local Terminal'].w);
 assert(left&&right,'Independent horizontal dividers in both columns');
 await resizeDivider(left,0,85);ps=await panes();g=geometry(ps);
 assert(Math.abs(g['Group SSH'].y-g['Group KVM'].y)>60,'Four unequal tiles with offset horizontal boundaries');
 report.checks.push('header edge docking combines horizontal and vertical native splits; independent separator produces offset boundaries');
 await capture('02-four-mixed-offset');
 const vertical=flat(await visible('groups.workspace')).find(n=>/^groups\.separator\./.test(n.test_id??'')&&n.rect.h>n.rect.w);assert(vertical);
 const before=g['Local Terminal'].w;await resizeDivider(vertical,-70,0);ps=await panes();g=geometry(ps);assert(g['Local Terminal'].w<before-45);
 await capture('03-four-mixed-resized');
 const files=await readdir(join(data,'session-group-layouts'));assert.equal(files.length,1);const snapshot=JSON.parse(await readFile(join(data,'session-group-layouts',files[0]),'utf8'));assert.equal(snapshot.version,2);report.saved=snapshot;
 const savedGeometry=geometry(ps),bounds=(await visible('groups.workspace')).rect;
 await click('groups.close');await visible('groups.close.confirm');await click('groups.close.cancel');assert.equal((await panes()).length,4);report.checks.push('mixed group-close cancel retains all original sessions');
 await stop();await openAll(ready,'restored');ps=await panes();g=geometry(ps);
 for(const name of Object.keys(g))for(const key of ['x','y','w','h'])assert(Math.abs(g[name][key]-savedGeometry[name][key])<3,'restored '+name+' '+key);
 report.checks.push('restart and explicitly reopen original ordered members: full mixed split structure and all ratios restore');await capture('04-restored-four-mixed');
 await h.resizeWindow(1280,800);await h.sleep(200);ps=await panes();g=geometry(ps);assert(Math.abs(g['Local Terminal'].x-g['Group SSH'].x)<1);assert(Math.abs(g['Group SSH'].y-g['Group KVM'].y)>40);await capture('05-mixed-window-resized');report.checks.push('window resizing preserves mixed split proportions');
 const filePane=byName(ps,'Group SFTP');await click('groups.menu.'+filePane.test_id.split('.').at(-1));const menu=await visible('groups.member_menu');await clickNode(flat(menu).find(n=>n.text==='移出组，保留会话'));await h.sleep(180);assert.equal((await panes()).length,3);
 const fileTab=(await tabNodes()).find(n=>text(n).includes('Group SFTP'));assert(fileTab);await click(fileTab.test_id);await visible('files.workspace');report.checks.push('removing a nested SFTP leaf collapses only its branch and retains original file session');
 }
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);await h.screenshot(join(out,'failure.png')).catch(()=>{});process.exitCode=1}
finally{await save();await stop();peer.kill('SIGTERM');await new Promise<void>(r=>{if(peer.exitCode!==null)return r();peer.once('close',()=>r());setTimeout(()=>{peer.kill('SIGKILL');r()},2000)});await peerLog.close();await save();console.log(JSON.stringify(report,null,2))}
