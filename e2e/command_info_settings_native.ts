/** Command metadata settings: isolated production settings/editor, no SSH connection. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,open,realpath,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]),binary=resolve(process.argv[3]);await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp(join(tmpdir(),'zw-command-info-native-'))),data=join(base,'data'),rpc=join(base,'rpc');await mkdir(data);await mkdir(rpc);
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\ncommand_info=true\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const report:any={status:'running',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],geometry:[],captures:[],limits:['Uses actual native controls in an isolated test-mode App; no external connection or production user data.','Metadata renderer live effect is validated by the integration owner after the shared setter is connected.']};
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');
async function vis(id:string){return h.waitFor(async()=>(await h.query(id)).find(shown)??null,12000)}
async function click(id:string){const n=await vis(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok,id);await h.sleep(120)}
async function edit(id:string,value:string){await click(id);await h.key('a',{cmd:true});await h.type_(value);await h.sleep(100)}
async function capture(name:string){await h.sleep(180);assert((await h.screenshot(join(out,name+'.png'))).ok);report.captures.push(name)}
async function scrollBottom(){const n=await vis('wizard.scroll.identity');await h.scrollAt(n.rect.x+n.rect.w-8,n.rect.y+n.rect.h/2,0,-1800);await h.sleep(220)}
async function settings(){await click('toolbar.settings');await edit('settings.search','command_info');await vis('settings.toggle.command_info')}
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1440,900);
 await settings();await click('settings.toggle.command_info');await click('settings.save');await h.waitFor(async()=>/command_info = false/.test(await readFile(join(data,'config.toml'),'utf8'))||null,10000);await capture('global-hidden');report.checks.push('Global command_info is edited and saved through the actual native Settings transaction');await click('settings.close');
 await settings();await capture('global-hidden-reopened');await click('settings.close');report.checks.push('The saved global setting is retained after closing and reopening Settings');
 await click('workspace.empty.choose');await edit('wizard.name','Command info QA');await edit('wizard.host','annotation.invalid');await edit('wizard.user','ops');await click('wizard.advanced.toggle');await scrollBottom();
 for(const [w,height] of [[1440,900],[860,480]]){
  await h.resizeWindow(w,height);await scrollBottom();const info=await vis('wizard.command_info'),shell=await vis('wizard.shell_integration'),viewport=await vis('wizard.scroll.identity');
  assert(Math.abs(info.rect.y-shell.rect.y)<.5);assert(Math.abs(info.rect.w-shell.rect.w)<.5);assert.equal(info.rect.h,34);assert.equal(shell.rect.h,34);assert(shell.rect.x>=info.rect.x+info.rect.w+15);assert(info.rect.y>=viewport.rect.y-.5&&info.rect.y+info.rect.h<=viewport.rect.y+viewport.rect.h+.5);
  assert(text(info).includes('继承全局设置'));assert(text(shell).includes('继承全局设置'));
  report.geometry.push({viewport:[w,height],info:info.rect,shell:shell.rect});await capture('host-inherit-'+w);
 }
 await h.resizeWindow(1440,900);await scrollBottom();await click('wizard.command_info');await click('wizard.command_info.off');assert(text(await vis('wizard.command_info')).includes('隐藏'));assert(text(await vis('wizard.shell_integration')).includes('继承全局设置'));await capture('host-hidden');
 await click('wizard.next.identity');await click('wizard.next.route');await click('wizard.save_only');await h.waitFor(async()=>/command_info = false/.test(await readFile(join(data,'hosts.toml'),'utf8'))||null,10000);report.checks.push('Host override saves false without modifying the independent shell-initialization inheritance');
 const host=await vis('sidebar.host');await h.mouseMove(host.rect.x+host.rect.w-18,host.rect.y+host.rect.h/2);await click('sidebar.host.edit');await click('wizard.advanced.toggle');await scrollBottom();assert(text(await vis('wizard.command_info')).includes('隐藏'));await capture('host-hidden-reloaded');
 await click('wizard.command_info');await click('wizard.command_info.inherit');await click('wizard.next.identity');await click('wizard.next.route');await click('wizard.save_only');await h.waitFor(async()=>!(await readFile(join(data,'hosts.toml'),'utf8')).includes('command_info')||null,10000);report.checks.push('Reopening the saved host restores Hide; saving Inherit removes the host override instead of freezing the current global value');
 await settings();await click('settings.toggle.command_info');await click('settings.save');await h.waitFor(async()=>/command_info = true/.test(await readFile(join(data,'config.toml'),'utf8'))||null,10000);await capture('global-shown');await click('settings.close');
 report.checks.push('Global display can be restored without touching execution or recording configuration');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await writeFile(join(out,'failure-tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{});await capture('failure').catch(()=>{});process.exitCode=1}
finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,h.sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(base,{recursive:true,force:true})}
console.log(JSON.stringify({status:report.status,error:report.error,out}));
