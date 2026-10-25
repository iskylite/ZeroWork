/** Native V3 tabs: actual hover geometry, menus, closed-loop failure and overflow. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,realpath,copyFile,open,readFile,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import net from 'node:net';
import {waitForServerReady,waitFor,query,clickAt,mouseMove,key,type_,resizeWindow,screenshot,sleep,scrollAt} from '../zig-out/share/zenit/harness/client.ts';
const pointerChecks=process.argv[4]==='--pointer-checks',layoutOnly=process.argv[4]==='--layout-only';
assert(!process.argv[4]||pointerChecks||layoutOnly);
const out=resolve(process.argv[2]),theme=process.argv[3]??'dark';assert(['dark','light'].includes(theme));await mkdir(out,{recursive:false});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-v3-tabs-'))),rpc=join(iso,'rpc'),data=join(iso,'data'),shell=join(iso,'shell');await Promise.all([mkdir(rpc),mkdir(data),mkdir(shell)]);
await writeFile(join(shell,'.zshrc'),"bindkey -e\nPS1='V3-tabs%# '\n");
// Reserve then release an owned loopback port; connection refusal is intentional.
const reservation=net.createServer();await new Promise<void>(r=>reservation.listen(0,'127.0.0.1',r));const port=(reservation.address() as net.AddressInfo).port;await new Promise<void>(r=>reservation.close(()=>r()));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`);
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="Owned unavailable SSH"\nhost="127.0.0.1"\nport=${port}\nuser="fixture"\n`);
const appBundle=join(iso,'ZeroWork V3 Tabs.app'),binary=pointerChecks?join(appBundle,'Contents/MacOS/ZeroWork V3 Tabs'):join(iso,'ZeroWork V3 Tabs');
if(pointerChecks){await mkdir(join(appBundle,'Contents/MacOS'),{recursive:true});await writeFile(join(appBundle,'Contents/Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.zerowork.v3tabs.${process.pid}</string><key>CFBundleExecutable</key><string>ZeroWork V3 Tabs</string><key>CFBundleName</key><string>ZeroWork V3 Tabs</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`)}
const testPrefix=process.env.ZW_TEST_PREFIX??'zig-out';await copyFile(join(testPrefix,'bin/zerowork'),binary);await copyFile(join(testPrefix,'bin/zw_ipc.so'),join(pointerChecks?join(appBundle,'Contents/MacOS'):iso,'zw_ipc.so'));
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:pointerChecks?'0':'1',ZENIT_E2E_ISOLATE_POINTER:pointerChecks?'0':'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const report:any={status:'running',theme,pid:app.pid,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],captures:[],isolated:iso,limits:[pointerChecks?'Actual native Metal window; public Harness plus explicit CUA right/middle checkpoints.':'Actual native Metal window; public Harness only, no right/middle input claimed.','Owned loopback connection refusal; no external credentials or hosts.']};
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>[n,...(n.children??[]).flatMap(flat)];const text=(n:any)=>flat(n).map(x=>x.text??'').join(' ');
const vis=(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,12000);
const hidden=(id:string)=>waitFor(async()=>!(await query(id)).some(shown)||null,12000);
let handoff=0;
async function clickNode(n:any,button=0,count=1){
 const x=n.rect.x+n.rect.w/2,y=n.rect.y+n.rect.h/2;
 if(button!==0){
  const marker=join(out,'cua-'+(++handoff)+'.done');
  const pending={stage:handoff,app:appBundle,pid:app.pid,button:button===1?'right':'middle',x,y,coordinate_space:'window logical points; CUA screenshot coordinates may use backing pixels: inspect a fresh screenshot before clicking',test_id:n.test_id,marker};
  await writeFile(join(out,'pending.json'),JSON.stringify(pending,null,2));console.log(JSON.stringify({cua:pending}));
  await waitFor(async()=>{try{return await readFile(marker,'utf8')==='done'||null}catch{return null}},180000);
 }else{await mouseMove(x,y);assert((await clickAt(x,y,count)).ok)}
}
async function click(id:string){await vis(id);await sleep(200);await clickNode(await vis(id))}
async function tabs(){const n=await vis('tabs.strip');return flat(n).filter(x=>/^tabs\.tab\.\d+$/.test(x.test_id??''))}
async function capture(name:string){assert((await screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify({tabs:await tabs(),tooltip:await query('tabs.tooltip'),menu:await query('context.menu'),picker:await query('tabs.picker')},null,2));report.captures.push(name)}
async function newLocal(){await click('toolbar.new_session');await vis('session.menu');await click('session.menu.local');await hidden('session.menu');await sleep(180);assert(!(await query('session.menu.local_tooltip')).some(shown))}
async function hoverTab(id:string){await mouseMove(30,80);await sleep(150);const before=(await tabs()).map(n=>({id:n.test_id,rect:n.rect})),n=await vis(id);await mouseMove(n.rect.x+36,n.rect.y+16);await sleep(700);const tip=await vis('tabs.tooltip');assert(tip.rect.w<=300.5);assert(tip.rect.x>=0&&tip.rect.y>=0);assert.deepEqual((await tabs()).map(n=>({id:n.test_id,rect:n.rect})),before);return tip}
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1440,900);await click('workspace.empty.local');await vis('terminal.surface');await newLocal();
 let all=await tabs();const first=all[0].test_id;assert.equal(all.length,2);for(const n of all)assert.equal(n.rect.h,38);
 await click(first);await clickNode(await vis(first),0,2);await vis('tabs.rename');await sleep(200);await click('tabs.rename.input');await key('a',{cmd:true});await type_('Local-long-name-0123456789012345678901234567890123456789');assert(text(await vis('tabs.rename.input')).includes('Local-long-name-'));await click('tabs.rename.save');await hidden('tabs.rename');assert(text(await vis(first)).includes('Local-long-name-'));
 const tip=await hoverTab(first);assert(text(tip).includes('Local-long-name-')&&text(tip).includes('/bin/zsh')&&text(tip).includes('在线'));await capture('01-hover-long-name');report.checks.push('hover does not resize or overlap neighboring tabs; complete local metadata');
 if(pointerChecks){await mouseMove(30,80);await clickNode(await vis(first),1);await vis('context.menu.new_tab');await vis('context.menu.clone_session');await capture('02-local-tab-menu');await key('escape');await hidden('context.menu');
 await click(first);const terminal=await vis('terminal.surface');await clickNode(terminal,2);await vis('context.menu.toggle_timestamp');assert(!(await query('context.menu.new_tab')).some(shown));await capture('03-terminal-middle-menu');await key('escape');report.checks.push('tab right-click and terminal middle-click expose distinct actual menus');}
 for(const close of (layoutOnly?[]:pointerChecks?['x','menu','middle']:['x'])){
  const count=(await tabs()).length;const host=await vis('sidebar.host');await clickNode(host,0,2);await waitFor(async()=>(await tabs()).length===count+1||null,12000);const failed=(await tabs()).at(-1)!;
  await waitFor(async()=>{const n=(await query('connection.progress.summary.detail')).find(shown);return n&&text(n).includes('无法建立 TCP')?true:null},45000);await click('connection.progress.close');await hidden('connection.progress');await sleep(200);const failedTip=await hoverTab(failed.test_id);assert(text(failedTip).includes('离线'));await capture('04-failed-'+close);
  if(close==='x')await click(failed.test_id.replace('tabs.tab.','tabs.close.'));else if(close==='menu'){await clickNode(await vis(failed.test_id),1);await click('context.menu.close_session')}else await clickNode(await vis(failed.test_id),2);
  await waitFor(async()=>(await tabs()).length===count||null,12000);report.checks.push('failed SSH closes via '+close);
 }
 for(let i=0;i<8;i++)await newLocal();await resizeWindow(860,480);await vis('tabs.all');await mouseMove(30,80);await capture('05-overflow-minimum');const minimumTip=await hoverTab((await tabs()).at(-1).test_id);assert(minimumTip.rect.x+minimumTip.rect.w<=860&&minimumTip.rect.y+minimumTip.rect.h<=480);await capture('05b-hover-minimum');await mouseMove(30,80);
 const stripBefore=(await vis('tabs.strip')).rect,viewport=await vis('tabs.viewport');await scrollAt(viewport.rect.x+40,viewport.rect.y+12,0,-200);await sleep(150);assert.deepEqual((await vis('tabs.strip')).rect,stripBefore);report.checks.push('vertical wheel does not turn the tab strip into a vertical scroller');
 await click('tabs.all');const picker=await vis('tabs.picker');assert(picker.rect.x>=8&&picker.rect.y>=8&&picker.rect.x+picker.rect.w<=852&&picker.rect.y+picker.rect.h<=472);await click('tabs.picker.query');await type_('Local-long-name-');await sleep(180);await capture('06-picker-minimum');await key('return');await hidden('tabs.picker');assert((await vis(first)).rect.x>=viewport.rect.x);report.checks.push('overflow picker filters and activates original renamed local session within minimum window');
 report.status='passed';report.pointer_menus=pointerChecks?'verified':'not_run_requires_cua';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});process.exitCode=1}
finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}))}
