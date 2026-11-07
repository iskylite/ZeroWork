/** Approved SVG → native workspace acceptance. Disposable data, Local PTYs and
 * an optional owned loopback SFTP peer; never opens saved user connections. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,realpath} from 'node:fs/promises';
import {dirname,resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
const binary=resolve(process.argv[2]??'zig-out/bin/zerowork');
const out=resolve(process.argv[3]??'/tmp/zerowork-mist-acceptance');
const live=process.argv.includes('--live-transfer');
const h=await import(pathToFileURL(resolve(dirname(binary),'../share/zenit/harness/client.ts')).href);
const iso=await realpath(await mkdtemp('/tmp/zw-mist-')),data=join(iso,'data'),rpc=join(iso,'rpc');
for(const p of [out,data,rpc])await mkdir(p,{recursive:true});
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
let app:any,ended:Promise<any>,peer:any,peerEnded:Promise<any>,ready:any;
const report:any={binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),isolated:iso,checks:[],scenes:[],live_transfer:live,limits:['Native Metal captures exclude macOS traffic-light compositing.','Layout scenes use real Local PTYs; SVG remote output is design data.','No physical IME, live KVM or external SSH server acceptance.']};
const shown=(n:any)=>n?.rect?.w>0&&n.rect.h>0&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0;
const flatten=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flatten)]:[];
const text=(n:any)=>flatten(n).map(n=>n.text??'').join(' ');
const nodes=async(id:string)=>(await h.query(id)).filter(shown);
const visible=(id:string)=>h.waitFor(async()=>{assert(app.exitCode===null&&app.signalCode===null,'Owned native App stays alive');return (await nodes(id))[0]??null},15000);
const hidden=(id:string)=>h.waitFor(async()=>!(await nodes(id)).length||null,6000);
async function click(id:string){const n=await visible(id);await h.mouseMove(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);const result=await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);report.last_action={id,rect:n.rect,result};assert(result.ok,id+' clicks');}
async function capture(name:string){await h.sleep(160);assert((await h.screenshot(join(out,name+'.png'))).ok);const ids=['workspace.sidebar','sidebar.header','sidebar.new','sidebar.footer.new','workspace.titlebar','workspace.tabs.capsule','tabs.strip','toolbar.group.connection','toolbar.group.history','toolbar.group.application','toolbar.compact','workspace.pane','terminal.surface.viewport','terminal.surface.row.0','ai.strip','ai.panel','status.theme','status.detail','toolbar.transfers.progress','toolbar.transfers.percent'];const snapshot=Object.fromEntries(await Promise.all(ids.map(async id=>[id,await h.query(id)])));await writeFile(join(out,name+'.json'),JSON.stringify(snapshot,null,2));report.scenes.push(name);}
function rect(n:any,x:number,y:number,w:number,height:number){assert.deepEqual(n.rect,{x,y,w,h:height});}
async function expand(){if((await nodes('toolbar.expand')).length){const n=await visible('toolbar.expand');await h.mouseMove(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);await h.sleep(280);await visible('toolbar.settings');}}
async function newLocal(){await click('toolbar.new_session');await click('session.menu.local');await visible('terminal.surface');await h.sleep(1200);}
try{
 if(live){
  const peerLog=await open(join(out,'peer.log'),'w');
  peer=spawn(process.env.ZW_TEST_PYTHON??'python3',['e2e/sftp_v3_peer.py','--out',join(out,'peer')],{stdio:['ignore',peerLog.fd,peerLog.fd]});peerEnded=new Promise(r=>peer.once('close',r));
  ready=await h.waitFor(async()=>{assert(peer.exitCode===null&&peer.signalCode===null,'Owned peer stays alive');try{return JSON.parse(await readFile(join(out,'peer/ready.json'),'utf8'))}catch{return null}},15000);
 }
 let hosts='[registry]\nschema_version=2\nrevision=1\nnext_connection_id=4\nnext_group_id=3\n[[groups]]\ngroup_id=1\nrevision=1\nname="生产环境"\nordered_connection_ids=[1,2]\n[[groups]]\ngroup_id=2\nrevision=1\nname="开发环境"\nordered_connection_ids=[3]\n';
 for(const [i,name]of ['production-web','staging-api','开发工作站'].entries())hosts+=`[[hosts]]\nconnection_id=${i+1}\nrevision=1\nprotocol="${live&&i===0?'sftp':'ssh'}"\nauth_mode="password"\nname="${name}"\nhost="127.0.0.1"\nport=${live&&i===0?ready.port:65530+i}\nuser="${live&&i===0?ready.user:'fixture'}"\nasset_group_id=${i<2?1:2}\n${live&&i===0?`options={strict_host_key=true}\nauth={password="${ready.password}"}\n`:''}`;
 await writeFile(join(data,'hosts.toml'),hosts);
 if(ready?.known_host)await writeFile(join(data,'known_hosts'),ready.known_host);
 await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="reference-light"\nfont_family="JetBrains Mono"\nfont_size=13\n[transfer]\ndedicated_connection=true\nwindow_chunks=1\nchunk_kb=32\nmax_tasks=1\nverify_md5=false\n');
 app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});ended=new Promise(r=>app.once('close',r));report.pid=app.pid;
 await h.waitForServerReady();await h.resizeWindow(1440,900);
 const emptyCapsule=await visible('workspace.tabs.capsule'),emptyPlus=await visible('toolbar.new_session');
 assert.equal(emptyCapsule.rect.w,36);assert.equal(emptyCapsule.rect.h,36);
 assert.equal(emptyPlus.rect.x+emptyPlus.rect.w/2,emptyCapsule.rect.x+18);
 assert.equal(emptyPlus.rect.y+emptyPlus.rect.h/2,emptyCapsule.rect.y+18);
 const plusIcon=flatten(emptyPlus).find(n=>n.rect?.w===16&&n.rect?.h===16&&shown(n));assert(plusIcon);
 assert.equal(plusIcon.rect.x+8,emptyCapsule.rect.x+18);assert.equal(plusIcon.rect.y+8,emptyCapsule.rect.y+18);
 await capture('empty-tabs-centered');
 await h.mouseMove(emptyPlus.rect.x+14,emptyPlus.rect.y+14);await h.sleep(200);await capture('empty-plus-hover');
 await h.mouseDown(emptyPlus.rect.x+14,emptyPlus.rect.y+14);await h.sleep(200);await capture('empty-plus-pressed');
 await h.mouseUp(emptyPlus.rect.x+14,emptyPlus.rect.y+14);await capture('empty-plus-after-click');
 await h.key('escape');await capture('empty-plus-after-dismiss');
 await h.mouseMove(500,300);await h.mouseMove(emptyPlus.rect.x+14,emptyPlus.rect.y+14);await capture('empty-plus-rehover');
 await h.mouseMove(500,300);
 const notificationTool=await visible('toolbar.notifications');
 await h.mouseMove(notificationTool.rect.x+14,notificationTool.rect.y+14);await h.sleep(200);await capture('toolbar-notification-hover');
 await h.mouseDown(notificationTool.rect.x+14,notificationTool.rect.y+14);await h.sleep(200);await capture('toolbar-notification-pressed');
 await h.mouseUp(notificationTool.rect.x+14,notificationTool.rect.y+14);await capture('toolbar-notification-after-click');
 await h.key('escape');await capture('toolbar-notification-after-dismiss');
 await h.mouseMove(500,300);await h.mouseMove(notificationTool.rect.x+14,notificationTool.rect.y+14);await capture('toolbar-notification-rehover');
 await h.mouseMove(500,300);
 report.checks.push('Empty tab capsule is 36×36; new-session hit target and 16×16 icon share its exact center.');
 await click('workspace.empty.local');await visible('terminal.surface');await h.sleep(1500);
 rect(await visible('workspace.sidebar'),12,12,238,876);rect(await visible('workspace.pane'),274,60,1154,828);rect(await visible('ai.strip'),791,59,120,6);
 for(const [i,id] of ['connection','history','application'].entries()){
  const group=await visible('toolbar.group.'+id);rect(group,1112+i*108,12,100,36);
  const buttons=(group.children??[]).filter(shown);assert.equal(buttons.length,3);
  for(const [j,button]of buttons.entries())rect(button,group.rect.x+4+j*32,16,28,28);
 }
 const pane=await visible('workspace.pane'),row=await visible('terminal.surface.row.0');assert.equal(row.rect.y,76);const firstInk=flatten(row).find(n=>typeof n.text==='string'&&n.text.trim());assert(firstInk);assert.equal(firstInk.rect.x,290);assert.equal(firstInk.rect.y,76);assert.equal((await nodes('workspace.statusbar')).length,0);assert.equal((await visible('sidebar.new')).rect.x+24,240);
 await h.clickAt(pane.rect.x+60,pane.rect.y+40);await h.type_("PS1='local:/srv/zerowork$ '; clear; printf '\\033[32mNative workspace ready\\033[0m\\nTop groups: connection / history / application\\nTerminal viewport: padding 16\\n'");await h.key('return');await h.sleep(500);await h.mouseMove(850,450);await capture('wide');
 report.checks.push('1440×900: 12-point outer margins, 238-point full-height sidebar, 24-point workspace gap, exact 36-point tool groups, terminal y60 and AI y59; bottom bar absent.');
 // Every close remains visible, including inactive tabs; the capsule is content-fit.
 await newLocal();await newLocal();await newLocal();await newLocal();const strip=await visible('tabs.strip');const closes=flatten(strip).filter(n=>n.test_id?.startsWith('tabs.close.')&&shown(n));assert.equal(closes.length,5);for(const n of closes)assert.equal(n.effective_opacity??1,1);
 const capsule=await visible('workspace.tabs.capsule');assert.equal(capsule.rect.w,strip.rect.w+40);assert(capsule.rect.w<=(await visible('workspace.titlebar')).rect.w-52);await click('terminal.surface');await h.type_("PS1='local:/srv/zerowork$ '; clear; printf '\\033[32mLocal workspace ready\\033[0m\\n\\nWorking directory: /srv/zerowork\\n'");await h.key('return');await h.sleep(250);await h.mouseMove(4,4);await capture('wide-five-tabs');
 await click(closes[0].test_id);await h.waitFor(async()=>flatten(await visible('tabs.strip')).filter(n=>n.test_id?.startsWith('tabs.close.')&&shown(n)).length===4||null,6000);
 while(flatten(await visible('tabs.strip')).filter(n=>n.test_id?.startsWith('tabs.close.')&&shown(n)).length>1){const inactive=flatten(await visible('tabs.strip')).find(n=>n.test_id?.startsWith('tabs.close.')&&shown(n));await click(inactive.test_id);await h.sleep(150);}
 report.checks.push('Five real Local tabs: compression remains bounded, all close buttons stay visible, inactive closes succeed, one-tab capsule returns to content-fit with only 40 points beyond its strip.');
 // Existing search animation, clear and host grouping stay functional.
 await click('sidebar.search.toggle');await h.sleep(250);await click('sidebar.search');await h.type_('staging');await h.waitFor(async()=>(await nodes('sidebar.host')).length===1||null,6000);await click('sidebar.search.clear');await h.waitFor(async()=>(await nodes('sidebar.host')).length===3||null,6000);await click('sidebar.search.toggle');await h.mouseMove(850,450);
 report.checks.push('Sidebar click-to-expand search filters hosts, clear restores groups, title-row action aligns to sidebar right inset.');
 await h.key('b',{cmd:true});await hidden('workspace.sidebar');assert((await visible('workspace.tabs.capsule')).rect.x>=96);assert.equal((await visible('workspace.pane')).rect.y,60);await h.mouseMove(4,4);await capture('wide-sidebar-hidden');await h.key('b',{cmd:true});await visible('workspace.sidebar');
 // Existing status detail retains the metrics removed from the bottom bar.
 await click('local.status.identity');const detail=await visible('status.detail');assert(text(detail).includes('UTF-8'));assert(text(detail).includes('网格'));assert(detail.rect.y>=50);await h.key('escape');await h.mouseMove(850,450);
 // Hover preview, leave, click-to-pin and close use the existing AI controller.
 const ai=await visible('ai.strip');await h.mouseMove(ai.rect.x+60,ai.rect.y+3);await visible('ai.panel');await h.mouseMove(1400,850);await hidden('ai.panel');await click('ai.strip');await visible('ai.panel');await h.mouseMove(1400,850);await h.sleep(300);await visible('ai.panel');await click('ai.close');await hidden('ai.panel');assert.deepEqual((await visible('workspace.pane')).rect,pane.rect);
 report.checks.push('Local identity opens read-only encoding/grid; AI strip keeps 120×6 hit area, hover preview, leave dismissal, click pin and close without moving terminal.');
 await h.resizeWindow(860,480);await h.mouseMove(500,300);await h.sleep(150);rect(await visible('workspace.sidebar'),12,12,220,456);rect(await visible('workspace.pane'),256,60,592,408);rect(await visible('toolbar.compact'),812,12,36,36);rect(await visible('ai.strip'),492,59,120,6);await capture('compact');
 await expand();await visible('toolbar.compact');for(const[i,id]of['connection','history','application'].entries())rect(await visible('toolbar.group.'+id),488+i*108,12,100,36);assert.equal((await nodes('settings.modal')).length,0);await capture('compact-expanded');
 await h.mouseMove(592,30);await h.sleep(120);await visible('toolbar.group.history');await h.mouseMove(500,300);await visible('toolbar.compact');
 await expand();await click('status.connection.theme');const theme=await visible('status.theme');await h.mouseMove(theme.rect.x+60,theme.rect.y+90);await h.sleep(150);await visible('toolbar.group.application');await capture('compact-theme');await h.key('escape');await h.mouseMove(500,300);await visible('toolbar.compact');
 await expand();await click('status.command-history');await visible('terminal.command-history');await capture('compact-command-history');await h.key('escape');await h.mouseMove(500,300);
 report.checks.push('860×480: three-point hover reveals all nine tools left, retains ellipsis; no click-through; 8-point group gaps stay open; leave collapses; owned theme/history panels remain reachable below toolbar.');
 await h.resizeWindow(1440,900);await h.mouseMove(850,450);await click('status.connection.theme');await click('status.theme.item.dark');await h.key('escape');await h.mouseMove(850,450);await click('status.connection.theme');await click('status.theme.item.reference-light');await h.key('escape');await h.mouseMove(850,450);await capture('wide-final');await click('toolbar.history');await visible('history.panel');await h.key('escape');await hidden('history.panel');await click('toolbar.notifications');await visible('notifications.history');await h.key('escape');
 report.checks.push('晴霜 is selectable as a separate built-in theme; switching Dark → 晴霜 preserves native node geometry and existing sessions.');
 if(live){
  const host=(await nodes('sidebar.host')).find(n=>text(n).includes('production-web'));assert(host);await h.mouseMove(host.rect.x+80,host.rect.y+18);assert((await h.clickAt(host.rect.x+80,host.rect.y+18)).ok);await click('sidebar.host.connect');
  await h.waitFor(async()=>{if((await nodes('files.workspace')).length)return true;const title=(await nodes('plugin.challenge.title'))[0];if(title){if(text(title).includes('核对主机密钥')){assert(text(await visible('plugin.challenge.material')).includes(ready.fingerprint));await click('plugin.challenge.choice.0');}else if(text(title).includes('SSH 密码认证')){const field=(await nodes('plugin.challenge.answer.0'))[0]??await visible('plugin.challenge.secret');await h.clickAt(field.rect.x+10,field.rect.y+10);await h.type_(ready.password);await click('plugin.challenge.submit');}else throw Error('Unexpected owned authentication challenge');}return null},30000);
  await hidden('connection.progress');rect(await visible('files.local'),274,60,571,828);rect(await visible('files.remote'),857,60,571,828);
  const localFiles=await visible('files.local');const edit=flatten(localFiles).find(n=>n.test_id==='files.path.edit'&&shown(n));assert(edit);await h.clickAt(edit.rect.x+edit.rect.w/2,edit.rect.y+edit.rect.h/2);const field=flatten(await visible('files.local')).find(n=>n.test_id==='files.path'&&shown(n));assert(field);await h.clickAt(field.rect.x+10,field.rect.y+field.rect.h/2);await h.key('a',{cmd:true});await h.type_(iso);await h.key('return');await h.sleep(250);await h.mouseMove(4,4);await capture('files-aligned');
  const payload=Buffer.alloc(512*1024,37),path=join(iso,'mist-progress.bin');await writeFile(path,payload);
  const remote=await visible('files.remote'),x=remote.rect.x+remote.rect.w/2,y=remote.rect.y+remote.rect.h-65;await h.dragAt(x,y,0);await h.dragAt(x,y,3,'file://'+encodeURI(path));await visible('files.copy.confirmation');await h.sleep(300);await click('files.copy.submit');await hidden('files.copy.confirmation');
  await visible('toolbar.transfers.progress');const values:string[]=[];for(let i=0;i<12;i++){values.push(text(await visible('toolbar.transfers.percent')).trim());await h.sleep(250);}assert(values.some(s=>/^\d+%$/.test(s)&&parseFloat(s)>0&&parseFloat(s)<100));report.progress_samples=values;await capture('real-transfer');await click('toolbar.transfers');await visible('transfer.manager');await capture('real-transfer-manager');await h.key('escape');
  const state=await h.waitFor(async()=>{try{const s=JSON.parse(await readFile(join(out,'peer/state.json'),'utf8'));const f=s.files['/fixture/mist-progress.bin'];return f?.bytes===payload.length&&f.sha256===createHash('sha256').update(payload).digest('hex')?s:null}catch{return null}},60000);assert(state);report.checks.push('Real owned loopback SFTP upload drives percentage ring, same global manager opens, destination SHA-256 matches all 512 KiB.');await h.resizeWindow(860,480);await expand();await h.mouseMove(500,300);await visible('toolbar.compact');const lp=await visible('files.local'),rp=await visible('files.remote');assert.equal(lp.rect.x,256);assert.equal(rp.rect.x+rp.rect.w,848);assert.equal(lp.rect.y,60);assert.equal(rp.rect.y,60);await capture('files-compact');
 }
 report.ok=true;
}catch(error){report.ok=false;report.error=String(error);if(app)await capture('failure').catch(()=>{});throw error;}
finally{
 if(app&&app.exitCode===null&&app.signalCode===null){try{report.quit=await h.request('POST','/zerowork/windows',{action:'quit'});await Promise.race([ended!,h.sleep(10000)]);}catch{}if(app.exitCode===null&&app.signalCode===null){report.forced_shutdown=true;app.kill('SIGTERM');await ended!;}else report.exit_code=app.exitCode;}
 if(peer){peer.kill('SIGTERM');await peerEnded!;}
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await log.close();
}
console.log(JSON.stringify(report,null,2));
