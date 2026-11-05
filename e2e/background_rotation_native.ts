/** Disposable local directory; native settings, real one-minute rotation and restart. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,realpath,open,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';
const binary=resolve(process.argv[2]??'zig-out/bin/zerowork'),out=resolve(process.argv[3]??'/tmp/zw-background-rotation-native');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/private/tmp/zw-background-rotation-')),data=join(iso,'data'),images=join(iso,'images');await mkdir(data);await mkdir(images);await mkdir(join(images,'nested'));
const black='iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAADElEQVR4nGNgGB4AAADIAAGtQHYiAAAAAElFTkSuQmCC',white='iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFUlEQVR4nGP8//8/AzbAhFV00EoAAFbUAw037MyjAAAAAElFTkSuQmCC';
await writeFile(join(images,'2.png'),Buffer.from(white,'base64'));await writeFile(join(images,'10.png'),Buffer.from(black,'base64'));await writeFile(join(images,'bad.png'),'invalid');await writeFile(join(images,'nested','1.png'),Buffer.from(white,'base64'));
await writeFile(join(data,'config.toml'),`[ui]\ntheme="dark"\n[ui.materials.background]\nenabled=true\nsource="directory"\npath=${JSON.stringify(images)}\norder="sequential"\ninterval_minutes=${process.env.ZW_BACKGROUND_PICKER_ONLY==='1'||process.env.ZW_BACKGROUND_LAYOUT_ONLY==='1'?5:1}\ntransparency=60\n`);
let appPid=0;
const os=(code:string)=>execFileSync('osascript',['-e',code],{encoding:'utf8',timeout:10000}).trim();
const report:any={status:'running',binary,iso,checks:[]};
const shown=(n:any)=>n?.rect?.w>0&&n.rect.h>0&&n.visible!==false&&n.hidden!==true;
const vis=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
async function reveal(id:string){for(let i=0;i<35;i++){const n=await vis(id),v=(await vis('settings.viewport')).rect;if(n.rect.y>=v.y&&n.rect.y+n.rect.h<=v.y+v.h)return n;await h.scrollAt(v.x+v.w-5,v.y+v.h/2,0,n.rect.y<v.y?150:-150);await h.sleep(70)}throw Error('Cannot reveal '+id)}
async function click(id:string){const n=await vis(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok,id);await h.sleep(100)}
async function checkPairs(paired:boolean){const [order,interval,fit,alignment]=await Promise.all(['order','interval_minutes','fit','alignment'].map(k=>vis('settings.field.'+k)));if(paired){assert(Math.abs(order.rect.y-interval.rect.y)<1);assert(Math.abs(fit.rect.y-alignment.rect.y)<1);assert(order.rect.x+order.rect.w<=interval.rect.x+1)}else{assert(interval.rect.y>order.rect.y);assert(alignment.rect.y>fit.rect.y)}}
async function choose(key:string,value:string){await reveal('settings.field.'+key);await click('settings.field.'+key);await click('settings.option.'+key+'.'+value)}
async function save(){await click('settings.save');await h.waitFor(async()=>(await vis('settings.footer.state')).text==='已保存'||null,15000)}
async function launch(round:number,run:()=>Promise<void>){const rpc=join(iso,'rpc-'+round);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app-'+round+'.log'),'w');const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'0',ZENIT_E2E_REAL_ACTIVATION:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});appPid=app.pid!;const ended=new Promise(r=>app.once('close',r));try{await h.waitForServerReady();await h.resizeWindow(1440,900);await run()}finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;await log.close()}}
async function openSettings(){await click('toolbar.settings');await click('settings.nav.appearance');await reveal('settings.materials.header');await click('settings.materials.header');await reveal('settings.background.state');await h.waitFor(async()=>(await vis('settings.background.state')).text?.includes('目录轮播')||null,15000)}
async function pick(path?:string){
 await reveal('settings.background.choose');const n=await vis('settings.background.choose');const clicked=h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);clicked.catch(()=>{});
 await h.waitFor(async()=>{try{return os(`tell application "System Events" to tell (first process whose unix id is ${appPid}) to get name of every window`).includes('选择背景图片或目录')||null}catch{return null}},10000);
 if(path){
  os(`tell application "System Events" to tell (first process whose unix id is ${appPid}) to set frontmost to true`);
  await h.waitFor(async()=>os(`tell application "System Events" to tell (first process whose unix id is ${appPid}) to get frontmost`)==='true'||null,5000);
  os(`tell application "System Events" to tell (first process whose unix id is ${appPid}) to keystroke "g" using {command down, shift down}`);
  await h.waitFor(async()=>{try{return Number(os(`tell application "System Events" to tell (first process whose unix id is ${appPid}) to count sheets of window "选择背景图片或目录"`))>0||null}catch{return null}},5000);
  os(`tell application "System Events"
 tell (first process whose unix id is ${appPid})
 set value of text field 1 of sheet 1 of window "选择背景图片或目录" to ${JSON.stringify(path)}
 key code 36
 end tell
end tell`);
  await h.waitFor(async()=>{try{return Number(os(`tell application "System Events" to tell (first process whose unix id is ${appPid}) to count sheets of window "选择背景图片或目录"`))===0||null}catch{return true}},5000);
  os(`tell application "System Events" to tell (first process whose unix id is ${appPid}) to click button "选择" of splitter group 1 of window "选择背景图片或目录"`);
 }
 else os(`tell application "System Events"
 tell (first process whose unix id is ${appPid})
 tell splitter group 1 of window "选择背景图片或目录"
 if exists button "Cancel" then
 click button "Cancel"
 else
 click button "取消"
 end if
 end tell
 end tell
end tell`);
 assert((await clicked).ok);await h.waitFor(async()=>{const state=(await vis('settings.background.state')).text??'';return !state.includes('正在')||null},15000);
}
try{
 await launch(1,async()=>{
  await openSettings();await checkPairs(true);
  if(process.env.ZW_BACKGROUND_LAYOUT_ONLY==='1'){
   await choose('order','random');await save();await choose('interval_minutes','15');await save();await choose('fit','fit');await save();await reveal('settings.field.alignment');await click('settings.field.alignment');await click('settings.alignment.顶部居中');await save();await checkPairs(true);await h.mouseMove(3,3);await h.screenshot(join(out,'paired-settings-1440.png'));await writeFile(join(out,'paired-geometry.json'),JSON.stringify(await h.query('settings.appearance.materials'),null,2));
   await h.resizeWindow(860,480);await h.sleep(350);await reveal('settings.field.interval_minutes');await h.mouseMove(3,3);await h.screenshot(join(out,'paired-settings-860.png'));await writeFile(join(out,'paired-geometry-860.json'),JSON.stringify(await h.query('settings.appearance.materials'),null,2));await checkPairs((await vis('settings.background.rotation_fields')).rect.w>=576);report.checks.push('two settings per row at 1440; adaptive layout without clipping at 860; all four controls remain clickable and save');await h.resizeWindow(1440,900);await choose('interval_minutes','5');await save();return;
  }
  if(process.env.ZW_BACKGROUND_PICKER_ONLY==='1'){
   assert(!(await h.query('settings.field.source')).some(shown));
   await pick(join(images,'2.png'));assert((await vis('settings.background.filename')).text==='2.png');assert(!(await h.query('settings.field.order')).some(shown));report.checks.push('same real native chooser accepts a file and hides rotation controls');
   await pick(images);await h.waitFor(async()=>(await vis('settings.background.state')).text?.includes('目录轮播')||null,15000);assert((await vis('settings.background.filename')).text==='images');assert((await vis('settings.background.state')).text?.includes('2.png'));await save();report.checks.push('same real native chooser accepts a directory, reveals rotation controls and refreshes the saved source');
   const before=await readFile(join(data,'config.toml'),'utf8');await pick();assert.equal(await readFile(join(data,'config.toml'),'utf8'),before);assert.equal((await vis('settings.footer.state')).text,'已保存');report.checks.push('native chooser cancellation preserves source and settings');await h.screenshot(join(out,'unified-picker-settings.png'));await h.resizeWindow(860,480);await h.sleep(350);await reveal('settings.field.interval_minutes');await checkPairs((await vis('settings.background.rotation_fields')).rect.w>=576);await h.screenshot(join(out,'paired-settings-860.png'));report.checks.push('two fields per row at standard size; one per row in compact window');return;
  }
  assert((await vis('settings.background.state')).text?.includes('2.png'));report.checks.push('natural sort; direct-child discovery; deferred image validation');
  await choose('order','random');await save();assert((await readFile(join(data,'config.toml'),'utf8')).includes('order = "random"'));
  await choose('order','sequential');await choose('interval_minutes','5');await save();assert((await readFile(join(data,'config.toml'),'utf8')).includes('interval_minutes = 5'));report.checks.push('native order and five-minute interval save');
  assert(!(await h.query('settings.field.source')).some(shown));await reveal('settings.background.identity');await h.screenshot(join(out,'directory-settings-1440.png'));await writeFile(join(out,'directory-geometry.json'),JSON.stringify(await h.query('settings.appearance.materials'),null,2));
  await h.resizeWindow(860,480);await h.sleep(350);await reveal('settings.field.interval_minutes');await checkPairs((await vis('settings.background.rotation_fields')).rect.w>=576);const control=await vis('settings.field.interval_minutes'),viewport=await vis('settings.viewport');assert(control.rect.x>=viewport.rect.x&&control.rect.x+control.rect.w<=viewport.rect.x+viewport.rect.w+1);await h.screenshot(join(out,'directory-settings-860.png'));report.checks.push('compact interval control remains in viewport');
  await h.resizeWindow(1440,900);await choose('interval_minutes','1');await save();const before=await readFile(join(data,'config.toml'),'utf8');await click('settings.close');await h.screenshot(join(out,'before-rotation.png'));
  console.log('Waiting for real one-minute rotation with settings closed');await h.sleep(32000);await h.health();await h.sleep(31000);await h.screenshot(join(out,'after-rotation.png'));
  await click('toolbar.settings');await reveal('settings.background.state');assert((await vis('settings.background.state')).text?.includes('10.png'));assert.equal((await vis('settings.footer.state')).text,'已保存');assert.equal(await readFile(join(data,'config.toml'),'utf8'),before);report.checks.push('real timed switch while settings closed; settings remain clean; config bytes unchanged');
  await choose('interval_minutes','5');await save();await pick(join(images,'2.png'));assert(!(await h.query('settings.field.order')).some(shown));assert(!(await h.query('settings.field.source')).some(shown));report.checks.push('one native chooser accepts an image and hides rotation controls automatically');await pick(images);await h.waitFor(async()=>(await vis('settings.background.state')).text?.includes('目录轮播')||null,15000);await save();report.checks.push('same native chooser accepts a directory and reveals rotation controls automatically');const saved=await readFile(join(data,'config.toml'),'utf8');await pick();assert.equal(await readFile(join(data,'config.toml'),'utf8'),saved);assert.equal((await vis('settings.footer.state')).text,'已保存');report.checks.push('cancelling unified chooser preserves source and saved configuration');await h.screenshot(join(out,'restored-directory.png'));
 });
 await launch(2,async()=>{await openSettings();await reveal('settings.field.interval_minutes');assert(/interval_minutes\s*=\s*5\b/.test(await readFile(join(data,'config.toml'),'utf8')));await h.screenshot(join(out,'directory-restarted.png'));report.checks.push('directory settings and five-minute interval survive restart')});
 report.status='passed';console.log(JSON.stringify(report));
}catch(error){report.status='failed';report.error=String(error);console.error(error);process.exitCode=1}finally{try{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2))}finally{await rm(iso,{recursive:true,force:true})}}
