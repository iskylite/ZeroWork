/** Complete built-in palette acceptance through production UI; only isolated local fixtures. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,writeFile,readFile,open,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);await mkdir(out,{recursive:true});
const themes=(process.argv[4]??'dark,light,sauber,midnight,forest,ocean,plum,ember,graphite,paper,sand,ice,catppuccin-mocha,dracula,dark-pro,solarized-dark,nord').split(',');
const report:any={status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),cases:[],limits:['Production native components with synthetic Harness input; physical IME and VoiceOver not covered.','No saved configuration, remote connection or notification permission action. The local PTY writes runner-owned readiness data and runs a bounded sleep to exercise busy-process close confirmation; cancellation preserves the session and Ctrl+C stops the fixture.']};
const shown=(n:any)=>n?.rect&&n.visible!==false&&n.hidden!==true&&n.rect.w>0&&n.rect.h>0;
const vis=async(id:string)=>h.waitFor(async()=>{const a=await h.query(id);return Array.isArray(a)?a.find(shown)??null:null},10000);
const click=async(id:string)=>{await vis(id);assert((await h.clickTestId(id)).ok,id)};
try{for(const theme of themes){
 const iso=await mkdtemp('/private/tmp/zw-theme-components-'),data=join(iso,'data'),rpc=join(iso,'rpc'),shell=join(iso,'shell');for(const p of [data,rpc,shell])await mkdir(p);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 await writeFile(join(shell,'.zshrc'),"bindkey -e\nPS1='audit%# '\n");
 await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\n[ui.materials]\nblur_px=0\n[ui.materials.background]\ntransparency=100\n`);
 await writeFile(join(data,'hosts.toml'),'[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="agent"\nname="Audit database"\nhost="192.0.2.20"\nport=22\nuser="deploy"\n');
 const log=await open(join(out,theme+'.log'),'w');const app=spawn(binary,[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));const item:any={theme,captures:[]};report.cases.push(item);
 const nodes=async(id:string):Promise<any[]>=>id==='wizard.dialog'?[{rect:await h.screenPos(id)}]:await h.query(id);
 const capture=async(name:string,id:string)=>{const n=await h.waitFor(async()=>{const a=await nodes(id);const v=Array.isArray(a)?a.find(shown)as any:null;return v&&(v.effective_opacity??1)===1&&(v.scale_x??1)===1&&(v.scale_y??1)===1?v:null},15000);await h.sleep(300);await h.screenshot(join(out,theme+'-'+name+'.png'));await writeFile(join(out,theme+'-'+name+'.json'),JSON.stringify(await nodes(id),null,2));item.captures.push({name,id,rect:n.rect})};
 try{await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1440,900);
 const host=await vis('sidebar.host'),resting=(await vis('sidebar.host.name')).rect;await h.mouseMove(host.rect.x+100,host.rect.y+20);await capture('sidebar-hover','workspace.sidebar');const hover=(await vis('sidebar.host.name')).rect;assert(Math.abs(hover.w-resting.w)<.5,'hover must preserve identity width');assert(hover.w>=80,'identity needs readable width');assert.equal((await h.query('sidebar.host.protocol')).filter(shown).length,0);assert.equal((await h.query('sidebar.host.hops')).filter(shown).length,0);await h.mouseMove(700,800);
 await click('sidebar.new');await click('sidebar.new.host');await vis('wizard.close');await capture('wizard','wizard.dialog');await click('wizard.name');await click('wizard.host');await vis('wizard.name.error');await capture('wizard-error','wizard.dialog');await click('wizard.cancel');
 await click('toolbar.settings');for(const page of ['ssh','transfer','keys','notifications']){await click('settings.nav.'+page);await capture('settings-'+page,'settings.panel')};await click('settings.close');
 await click('workspace.empty.local');const surface=await vis('terminal.surface');await h.clickAt(surface.rect.x+40,surface.rect.y+surface.rect.h-40);
 const ready=join(iso,'ready');await h.type_(`printf ready > '${ready}'`);await h.key('return');await h.waitFor(async()=>{try{return await readFile(ready,'utf8')==='ready'||null}catch{return null}},15000);
 await h.sleep(350);await h.type_('@');await capture('commands','terminal.commands');await h.key('escape');await h.key('u',{ctrl:true});await h.sleep(100);await h.type_('/bin/sleep 20');await h.key('return');await h.sleep(350);
 await h.key('w',{cmd:true});await capture('danger-confirmation','local.close.confirmation');await click('local.close.cancel');await h.key('c',{ctrl:true});item.status='passed';console.log(theme+' passed: '+item.captures.length+' states');
 }catch(e){item.error=String(e);item.status='failed';await h.screenshot(join(out,theme+'-failure.png')).catch(()=>{});await writeFile(join(out,theme+'-failure-tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{});throw e;}
 finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;await log.close();await rm(iso,{recursive:true,force:true});}
}report.status='passed';}catch(e){report.status='failed';report.error=String(e);console.error(e);process.exitCode=1;}finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2))}
