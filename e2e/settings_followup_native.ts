/** Latest V3 settings/themes, real isolated native application and file RPC. */
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,realpath,open} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {waitForServerReady,waitFor,query,clickTestId,resizeWindow,screenshot,sleep,scrollAt} from '../vendor/zenit/e2e/client.ts';
const [argBinary,argOutput]=process.argv.slice(2);assert(argBinary&&argOutput);
const binary=resolve(argBinary),output=resolve(argOutput);await mkdir(output,{recursive:true});
const root=await realpath(await mkdtemp(join(tmpdir(),'zw-settings-followup-'))),rpc=join(root,'rpc'),data=join(root,'data');await mkdir(rpc);await mkdir(data);
await writeFile(join(data,'config.toml'),'[ui]\ntheme = "dark"\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(output,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_E2E_BACKGROUND:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const report:any={status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),pid:app.pid,checks:[],captures:[],limits:['Harness interactions do not verify physical keyboard/IME or native OS pickers.','ANSI mapping is validated by theme registry test; these screenshots verify application of UI palettes.']};
const shown=(n:any)=>n.visible!==false&&n.hidden!==true&&n.rect.w>0&&n.rect.h>0&&(n.effective_opacity??1)>0;
const node=async(id:string)=>waitFor(async()=> (await query(id)).find(shown)??null);
const click=async(id:string)=>{
 if(id.startsWith('settings.theme.')&&!['settings.theme.remove.current'].includes(id)){
  for(let i=0;i<12;i++){const n=await node(id),v=await node('settings.theme.strip');if(n.rect.x>=v.rect.x&&n.rect.x+n.rect.w<=v.rect.x+v.rect.w)break;await scrollAt(v.rect.x+v.rect.w/2,v.rect.y+v.rect.h/2,n.rect.x<v.rect.x?400:-400,0);await sleep(100);}
 }
 await node(id);assert((await clickTestId(id)).ok,id);
};
const capture=async(name:string)=>{await sleep(250);await screenshot(join(output,name+'.png'));report.captures.push(name);};
try{
 await waitForServerReady();await click('toolbar.settings');await click('settings.nav.appearance');
 const preset=JSON.parse(await readFile('docs/UI_V3/theme-presets.json','utf8'));
 for(const id of Object.keys(preset.themes)){
  await click('settings.theme.'+id);await click('settings.save');
  await waitFor(async()=> (await readFile(join(data,'config.toml'),'utf8')).includes('theme = "'+id+'"')?true:null,10000);
  const remove=await node('settings.theme.remove.current');assert.notEqual(remove.focusable,true,'builtin remove disabled');
  await capture('theme-'+id);report.checks.push('select/save/protected '+id);
 }
 await click('settings.close');await click('toolbar.settings');await click('settings.nav.appearance');await node('settings.theme.ice');report.checks.push('saved ice theme reopens');
 await click('settings.nav.data');assert.equal((await query('settings.data.open_config_dir')).filter(shown).length,0);await capture('data-readonly');report.checks.push('configuration directory action removed');
 await resizeWindow(860,480);await click('settings.nav.appearance');await capture('appearance-compact');
 await click('settings.nav.data');await capture('data-compact');report.checks.push('860x480 appearance/data visible');
 for(const [width,height] of [[860,480],[1440,900]]){
  await resizeWindow(width,height);await click('settings.nav.appearance');
  if(!(await query('settings.materials.preview.open')).some(shown))await click('settings.materials.header');
  await click('settings.materials.preview.open');const save=await node('settings.materials.preview.save'),bar=await node('settings.materials.preview.actions');
  assert.equal(save.rect.w,128);assert(save.rect.x+save.rect.w<=bar.rect.x+bar.rect.w,'save label fits preview bar');await capture('preview-save-'+width);await click('settings.materials.preview.return');
 }
 report.checks.push('preview save 128px and inside bar at860/1440');
 report.status='passed_pending_pixel_review';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});throw e;}
finally{await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));if(app.exitCode===null)app.kill('SIGTERM');await ended;await log.close();}
