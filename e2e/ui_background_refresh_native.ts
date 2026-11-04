/** Retained editor backgrounds after real theme settings changes. Offline,
 * isolated data, synthetic input and Metal screenshots; never connects hosts.
 * node e2e/ui_background_refresh_native.ts [build-prefix] [evidence-directory]
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';

const prefix=resolve(process.argv[2]??'zig-out');
const out=resolve(process.argv[3]??'/tmp/zw-ui-background-evidence');
await mkdir(out,{recursive:true});
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const shown=(n:any)=>n.visible!==false&&(n.effective_opacity??n.opacity??1)>.99&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id);await h.sleep(120);};
const cases:any[]=[];

for(const transparency of [0,75]){
 const dir=await mkdtemp('/private/tmp/zw-ui-background-');
 const data=join(dir,'data'),rpc=join(dir,'rpc');await mkdir(data);await mkdir(rpc);
 const wallpaper=join(data,'background.png');
 await writeFile(wallpaper,Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAJ0lEQVR4nGPQcksBoiq3aUCEzGbAKVFVkQJEWhXTgAiZjVuCDnYAAMasS4GfPJd/AAAAAElFTkSuQmCC','base64'));
 await writeFile(join(data,'config.toml'),`[ui]\ntheme="gruvbox-dark"\n[ui.materials]\nblur_px=24\n[ui.materials.background]\nenabled=true\npath="${wallpaper}"\ntransparency=${transparency}\n[updates]\nauto_check=false\n`);
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,`T${transparency}.log`),'w');
 const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_E2E_ISOLATE_KEYBOARD:'1'},stdio:['ignore',log.fd,log.fd]});
 const ended=new Promise<void>(done=>app.once('close',()=>done()));
 const record:any={transparency,status:'running',captures:[]};cases.push(record);
 const capture=async(name:string)=>{
  const nodes={dialog:{rect:await h.screenPos('wizard.dialog')},steps:await visible('wizard.steps')};
  const stem=`T${transparency}-${name}`;
  assert((await h.screenshot(join(out,stem+'.png'))).ok);
  await writeFile(join(out,stem+'.json'),JSON.stringify(nodes,null,2));
  record.captures.push(stem);
 };
 const openEditor=async()=>{
  await h.key('t',{cmd:true});await click('session.menu.new_profile');await visible('wizard.name');
 };
 const changeTheme=async(id:string)=>{
  await click('wizard.close');await click('toolbar.settings');await click('settings.nav.appearance');
  for(let i=0;i<16;i++){
   const strip=await visible('settings.theme.strip');
   const tile=(await h.query('settings.theme.'+id)).find(shown);
   assert(tile,'theme tile '+id);
   if(tile.rect.x>=strip.rect.x&&tile.rect.x+tile.rect.w<=strip.rect.x+strip.rect.w+1)break;
   const delta=tile.rect.x<strip.rect.x?700:-700;
   await h.scrollAt(strip.rect.x+strip.rect.w/2,strip.rect.y+strip.rect.h/2,delta,0);await h.sleep(150);
  }
  await click('settings.theme.'+id);await click('settings.save');
  await h.waitFor(async()=>(await visible('settings.footer.state')).text==='已保存'||null);
  await click('settings.close');await openEditor();
 };
 try{
  await h.waitForServerReady(60000);await h.resizeWindow(1440,900);await openEditor();
  const titleId=(await visible('wizard.title')).id;
  await capture('gruvbox-initial');
  await changeTheme('light');assert.equal((await visible('wizard.title')).id,titleId);
  await capture('light-refreshed');
  await changeTheme('gruvbox-dark');assert.equal((await visible('wizard.title')).id,titleId);
  await capture('gruvbox-refreshed');
  await click('wizard.group.pick');await h.sleep(250);await capture('gruvbox-group-menu');
  await h.key('escape');
  await h.resizeWindow(860,480);await h.sleep(250);await capture('gruvbox-compact');
  await click('wizard.protocol');await click('wizard.protocol.sftp');await visible('wizard.name');
  await capture('sftp-compact');
  await click('wizard.protocol');await click('wizard.protocol.bmc_ikvm');await visible('bmc.editor.name');
  await capture('bmc-compact');
  record.status='passed';
 }catch(error){record.status='failed';record.error=String(error);await h.screenshot(join(out,`T${transparency}-failure.png`)).catch(()=>{});throw error;}
 finally{
  if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;
  if(app.pid)await cleanupOwnedBridgeDirectories(app.pid);
  await log.close();await rm(dir,{recursive:true,force:true});
  await writeFile(join(out,'report.json'),JSON.stringify({cases},null,2));
 }
}
console.log(JSON.stringify({cases}));
