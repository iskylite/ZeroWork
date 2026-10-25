/** Production V3 creation menu and its existing quick-connect/wizard destinations. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,realpath,copyFile,readFile,writeFile,open} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import net from 'node:net';
import {waitForServerReady,waitFor,query,clickAt,mouseMove,key,type_,resizeWindow,screenshot,sleep,focused} from '../zig-out/share/zenit/harness/client.ts';
const themeCycle=process.argv[4]==='--theme-cycle',menuOnly=process.argv[4]==='--menu-only'||themeCycle;assert(!process.argv[4]||menuOnly);
const out=resolve(process.argv[2]),theme=process.argv[3]??'dark';assert(['dark','light'].includes(theme));await mkdir(out,{recursive:false});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-v3-creation-'))),data=join(iso,'data'),rpc=join(iso,'rpc'),shell=join(iso,'shell');await Promise.all([mkdir(data),mkdir(rpc),mkdir(shell)]);
await writeFile(join(shell,'.zshrc'),"bindkey -e\nPS1='V3-create%# '\n");
const reserve=net.createServer();await new Promise<void>(r=>reserve.listen(0,'127.0.0.1',r));const port=(reserve.address() as net.AddressInfo).port;await new Promise<void>(r=>reserve.close(()=>r()));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`);
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=3\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="Owned SSH search"\nhost="127.0.0.1"\nport=${port}\nuser="fixture"\n[[hosts]]\nconnection_id=2\nrevision=1\nprotocol="sftp"\nauth_mode="password"\nname="Owned SFTP search"\nhost="127.0.0.1"\nport=${port}\nuser="fixture"\n`);
await copyFile('zig-out/bin/zerowork',join(iso,'zerowork'));await copyFile('zig-out/bin/zw_ipc.so',join(iso,'zw_ipc.so'));
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');const app=spawn(join(iso,'zerowork'),[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const report:any={status:'running',theme,pid:app.pid,isolated:iso,sha256:createHash('sha256').update(await readFile(join(iso,'zerowork'))).digest('hex'),checks:[],captures:[],limits:['Actual native Metal window with public Harness input.','Own loopback refusal only; no external authentication.']};
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>[n,...(n.children??[]).flatMap(flat)];const text=(n:any)=>flat(n).map(x=>x.text??'').join(' ');
const vis=(id:string)=>{report.awaiting='visible '+id;return waitFor(async()=>(await query(id)).find(shown)??null,12000)};const hidden=(id:string)=>{report.awaiting='hidden '+id;return waitFor(async()=>!(await query(id)).some(shown)||null,12000)};
async function click(id:string){await vis(id);await sleep(180);const n=await vis(id);await mouseMove(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)}
async function edit(id:string,value:string){await click(id);await key('a',{cmd:true});await type_(value)}
async function count(){const strips=await query('tabs.strip');return strips.filter(shown).flatMap(flat).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??'')).length}
async function capture(name:string){await mouseMove(20,80);await sleep(180);assert((await screenshot(join(out,name+'.png'))).ok);const observed:any={};for(const id of ['workspace.empty','workspace.empty.icon','workspace.empty.local','workspace.empty.choose','workspace.titlebar','workspace.pane','session.menu','session.menu.local','session.menu.quick','session.menu.new_profile','quick.query','quick.saved.row','wizard.close'])observed[id]=await query(id);await writeFile(join(out,name+'.json'),JSON.stringify(observed,null,2));report.captures.push(name)}
async function menu(width:number,height:number){await resizeWindow(width,height);await click('toolbar.new_session');const m=await vis('session.menu'),bar=await vis('workspace.titlebar');await sleep(180);const fresh=await vis('session.menu');assert.equal(fresh.rect.w,210);assert.equal(fresh.rect.h,120);assert(Math.abs(fresh.rect.y-(bar.rect.y+bar.rect.h))<.5);assert(fresh.rect.x>=8&&fresh.rect.x+fresh.rect.w<=width-8);
 if(await count()===0){
  const icon=await vis('workspace.empty.icon'),primary=await vis('workspace.empty.local'),secondary=await vis('workspace.empty.choose'),guide=await vis('workspace.empty'),pane=await vis('workspace.pane');
  assert.deepEqual([icon.rect.w,icon.rect.h],[56,56]);assert.deepEqual([primary.rect.w,primary.rect.h],[100,35]);assert.deepEqual([secondary.rect.w,secondary.rect.h],[76,35]);
  assert(Math.abs((primary.rect.x+primary.rect.w+8)-secondary.rect.x)<.5);assert(Math.abs(guide.rect.x+guide.rect.w/2-pane.rect.x-pane.rect.w/2)<.5);assert(Math.abs(guide.rect.y+guide.rect.h/2-pane.rect.y-pane.rect.h/2)<.5);
  const ids={local:primary.id,choose:secondary.id,icon:icon.id};if(report.empty_ids)assert.deepEqual(ids,report.empty_ids);else report.empty_ids=ids;
 }
 for(const id of ['local','quick','new_profile'])assert.equal((await vis('session.menu.'+id)).rect.h,33);return m}
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await menu(1440,900);assert.equal(await count(),0);await capture('01-menu-default');await key('escape');await hidden('session.menu');assert.equal(await count(),0);
 await menu(860,480);await capture('02-menu-minimum');if(!menuOnly){await key('escape');await hidden('session.menu');await click('workspace.empty.choose');await vis('quick.query');assert.equal(await count(),0);await click('quick.close');await hidden('quick.connect');report.checks.push('empty workspace choose-connection opens the same quick selector directly');await menu(860,480);await click('session.menu.quick');await hidden('session.menu');await vis('quick.query');assert.equal(await count(),0);await edit('quick.query','SFTP');await waitFor(async()=>{const rows=(await query('quick.saved.row')).filter(shown);return rows.length===1&&text(rows[0]).includes('Owned SFTP search')?true:null});await capture('03-existing-sftp-search');await click('quick.close');await hidden('quick.connect');assert.equal(await count(),0);report.checks.push('quick entry reuses actual saved SFTP search without creating a connection');
 await menu(1440,900);await click('session.menu.new_profile');await hidden('session.menu');await vis('wizard.close');assert.equal(await count(),0);await capture('04-existing-wizard');await click('wizard.close');await hidden('wizard.close');report.checks.push('new saved connection opens existing wizard and cancel creates no session');
 await menu(860,480);await key('down');await key('return');await vis('quick.query');await hidden('session.menu');await sleep(350);report.quick_focus=await focused();assert(flat(await vis('quick.query')).some(n=>n.id===report.quick_focus.id),'quick selector lost keyboard focus after menu exit');await edit('quick.query','SSH');await waitFor(async()=>{const rows=(await query('quick.saved.row')).filter(shown);return rows.length===1&&text(rows[0]).includes('Owned SSH search')?true:null});assert.equal(await count(),0);await click('quick.submit');await waitFor(async()=>await count()===1||null,12000);await waitFor(async()=>{const n=(await query('connection.progress.summary.detail')).find(shown);return n&&text(n).includes('无法建立 TCP')?true:null},45000);await click('connection.progress.close');await hidden('connection.progress');report.checks.push('keyboard quick selection and explicit saved submit create exactly one owned SSH attempt');
 await menu(860,480);await click('session.menu.local');await hidden('session.menu');await waitFor(async()=>await count()===2||null,12000);await vis('terminal.surface');report.checks.push('local creation opens real PTY in one new tab');
 await menu(860,480);await key('up');await key('return');await hidden('session.menu');await vis('wizard.close');assert.equal(await count(),2);await click('wizard.close');await hidden('wizard.close');report.checks.push('keyboard wraps to new-profile action and cancels without duplicate sessions');
 await menu(860,480);await mouseMove(450,300);assert((await clickAt(450,300)).ok);await hidden('session.menu');assert.equal(await count(),2);report.checks.push('outside dismissal preserves sessions');
 await menu(860,480);await key('return');await hidden('session.menu');await waitFor(async()=>await count()===3||null,12000);await capture('05-created-local');report.checks.push('default Enter creates one local session');
 }else{report.checks.push('standard and minimum menu geometry, labels and native icon screenshot');}
 if(themeCycle){
  await key('escape');await hidden('session.menu');
  for(const target of ['light','sauber','dark']){
   await click('toolbar.settings');await click('settings.nav.appearance');await click('settings.theme.'+target);await click('settings.save');
   await waitFor(async()=>new RegExp('theme\\s*=\\s*"'+target+'"').test(await readFile(join(data,'config.toml'),'utf8'))||null,12000);
   await click('settings.close');await hidden('settings.close');await menu(860,480);await capture('03-live-theme-'+target);await key('escape');await hidden('session.menu');
  }
  report.checks.push('same running application saves light, Sauber and dark through real settings and reopens creation menu');
 }
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);report.failed_await=report.awaiting;await capture('failure').catch(()=>{});process.exitCode=1}
finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}))}
