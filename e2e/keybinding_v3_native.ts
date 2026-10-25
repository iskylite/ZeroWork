/** Isolated native V3 shortcut recorder workflow and geometry evidence. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,realpath,open} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,key,resizeWindow,screenshot,sleep,focused} from '../vendor/zenit/e2e/client.ts';
const [binaryArg,outputArg]=process.argv.slice(2);assert(binaryArg&&outputArg);
const binary=resolve(binaryArg),output=resolve(outputArg);await mkdir(output,{recursive:true});
const report:any={runs:[],status:'running'};
const shown=(n:any)=>n.visible!==false&&n.rect.w>0&&n.rect.h>0&&(n.effective_opacity??1)>0;
const text=(n:any):string=>typeof n.text==='string'?n.text:n.text?.content??'';
for(const theme of ['dark','light']){
 const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-keybinding-v3-'))),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(data);
 await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\n`,{mode:0o600});process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(output,theme+'.log'),'w');const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});const ended=new Promise<void>(done=>app.once('close',()=>done()));
 const rec:any={theme,checks:[],captures:[]};report.runs.push(rec);
 const node=async(id:string):Promise<any>=>waitFor(async()=> (await query(id)).find(shown)??null,10000);
 const click=async(id:string)=>{const n=await node(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await sleep(180);};
 const capture=async(name:string)=>{await sleep(220);const path=join(output,theme+'-'+name+'.png');assert((await screenshot(path)).ok);rec.captures.push(path);};
 try{
  await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
  await resizeWindow(1440,900);await click('toolbar.settings');await click('settings.nav.keys');await click('settings.key.new_tab');
  const dialog=await node('settings.keybinding.dialog'),header=await node('settings.keybinding.header'),footer=await node('settings.keybinding.footer'),well=await node('settings.keybinding.capture');
  assert(Math.abs(dialog.rect.w-390)<.6);assert(header.rect.h>=60);assert.equal(Math.round(well.rect.w),350);rec.geometry={dialog:dialog.rect,header:header.rect,footer:footer.rect,well:well.rect};await capture('initial');await click('settings.keybinding.unbind');await node('settings.keybinding.dialog');rec.checks.push('unbound unsupported by runtime and disabled with explanatory tooltip');await click('settings.keybinding.capture');
  await key('x',{cmd:true,ctrl:true});assert(text(await node('settings.keybinding.error')).includes('Command'));await capture('reserved-error');
  await key('c',{cmd:true});assert(text(await node('settings.keybinding.error')).includes('复制'));await capture('conflict-error');
  await key('x',{cmd:true,shift:true});await key('escape');await node('settings.key.new_tab');assert.equal((await query('settings.keybinding.dialog')).filter(shown).length,0);rec.checks.push('Control reserved, duplicate conflict, Escape discards candidate');
  await click('settings.key.new_tab');await click('settings.keybinding.reset');assert.equal(text(await node('settings.keybinding.recorded')),'⌘T');await capture('reset');await click('settings.keybinding.cancel');
  await click('settings.key.new_tab');await key('x',{cmd:true,shift:true});assert.equal(text(await node('settings.keybinding.recorded')),'⌘⇧X');const before=await readFile(join(data,'config.toml'),'utf8');assert(!before.includes('new_tab = "cmd+shift+x"'));await capture('recorded');await click('settings.keybinding.confirm');await node('settings.key.new_tab');assert.equal((await readFile(join(data,'config.toml'),'utf8')),before);await click('settings.save');await waitFor(async()=> (await readFile(join(data,'config.toml'),'utf8')).includes('new_tab = "cmd+shift+x"')?true:null,10000);rec.checks.push('explicit confirmation changes outer draft; outer Save persists');
  await click('settings.key.new_tab');await key('tab');rec.tabFocus=await focused();assert(rec.tabFocus.test_id?.startsWith('settings.keybinding.'));await capture('tab-focus');await key('escape');await click('settings.key.recent_tab');assert.equal((await query('settings.keybinding.dialog')).filter(shown).length,0);rec.checks.push('Tab focus stays inside modal; fixed mouse row does not open recorder');
  await resizeWindow(860,480);await click('settings.key.new_tab');await key('x',{cmd:true,ctrl:true});await capture('compact-error');const compact=await node('settings.keybinding.dialog');assert(compact.rect.y>=23);assert(compact.rect.y+compact.rect.h<=457);rec.compact=compact.rect;await click('settings.keybinding.cancel');await click('settings.close');await click('toolbar.settings');await click('settings.nav.keys');rec.checks.push('compact header/footer and cancel releases focus; settings reopen');
  rec.status='passed_pending_pixel_review';
 }catch(e){rec.status='failed';rec.error=String(e);await capture('failure').catch(()=>{});throw e;}finally{await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));if(app.exitCode===null)app.kill('SIGTERM');await ended;await log.close();}
}
report.status='passed_pending_pixel_review';await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
