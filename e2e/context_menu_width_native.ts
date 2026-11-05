/** Saved-host right-click width regression, using an isolated native window.
 * zig build -Dtest-mode=true
 * node e2e/context_menu_width_native.ts /absolute/bin/zerowork /tmp/menu-evidence
 * --all checks tab, terminal, asset-group and session-group menus too.
 * --local-only omits saved-host/asset-group native checks (other menus remain).
 * --baseline verifies the old full-width failure instead of expecting the fix.
 * A custom install prefix can set ZW_HARNESS_CLIENT to its installed client.ts.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,rm} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';

const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);
const all=process.argv.includes('--all');
const localOnly=process.argv.includes('--local-only');
const baseline=process.argv.includes('--baseline');
const h=await import(pathToFileURL(resolve(process.env.ZW_HARNESS_CLIENT??'zig-out/share/zenit/harness/client.ts')).href);
await mkdir(out,{recursive:true});
const isolated=await mkdtemp('/private/tmp/zw-menu-width-'),data=join(isolated,'data'),rpc=join(isolated,'rpc');
await mkdir(data);await mkdir(rpc);
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n');
if(!localOnly)await writeFile(join(data,'hosts.toml'),'[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nname="Menu width fixture"\nhost="127.0.0.1"\nport=65530\nuser="fixture"\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>.999&&n.rect?.w>0&&n.rect?.h>0;
const node=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null);
const report:any={all,localOnly,binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),baseline,status:'running',captures:[],limits:['Public Harness right-click on a saved fixture; no SSH connection or physical input verification.']};
async function openHost(){
 const host=await node('sidebar.host');
 await h.mouseMove(host.rect.x+10,host.rect.y+host.rect.h/2);
 const point={x:host.rect.x+10,y:host.rect.y+host.rect.h/2,button:'right'};
 assert((await h.request('POST','/mouse_down',point)).ok);assert((await h.request('POST','/mouse_up',point)).ok);
 await node('context.menu');await h.sleep(250);
 return node('context.menu');
}
async function capture(name:string,width:number,height:number){
 const menu=await node('context.menu');
 if(!baseline){
  assert(Math.abs(menu.rect.w-258)<.5,JSON.stringify(menu.rect));
  assert(menu.rect.x>=7.5&&menu.rect.x+menu.rect.w<=width-7.5,'Menu stays within horizontal viewport bounds');
  assert(menu.rect.y>=7.5&&menu.rect.y+menu.rect.h<=height-7.5,'Menu stays within vertical viewport bounds');
  for(const id of ['new_tab','new_window','edit_host','history','move_group','delete_host']){
   const row=await node('context.menu.'+id);
   assert(row.rect.w<menu.rect.w&&row.rect.x>=menu.rect.x&&row.rect.x+row.rect.w<=menu.rect.x+menu.rect.w+.5,id+' must fit the menu');
  }
 }
 await h.mouseMove(width-30,30);await h.sleep(150);
 const png=join(out,name+'.png');assert((await h.screenshot(png)).ok);
 await writeFile(join(out,name+'.json'),JSON.stringify(menu,null,2));
 report.captures.push({name,viewport:{width,height},menu:menu.rect,screenshot:png});
}
async function audit(trigger:()=>Promise<void>,id:string,expected:number,label:string){
 for(const [width,height] of [[1440,900],[860,480]]){
  await h.resizeWindow(width,height);await h.sleep(200);
  for(const stage of ['first','retargeted','reopened']){
   await trigger();await h.sleep(250);
   const menu=await node(id);assert(Math.abs(menu.rect.w-expected)<.5,label+' '+stage+' '+JSON.stringify(menu.rect));
   assert(menu.rect.x>=7.5&&menu.rect.x+menu.rect.w<=width-7.5,label+' horizontal bounds');
   if(stage==='retargeted'){
    const name=label+'-'+width;const png=join(out,name+'.png');await h.mouseMove(width/2,25);await h.screenshot(png);
    await writeFile(join(out,name+'.json'),JSON.stringify(menu,null,2));
    report.captures.push({name,viewport:{width,height},menu:menu.rect,screenshot:png});
   }
   if(stage!=='first'){await h.key('escape');await h.waitFor(async()=>!(await h.query(id)).some(shown)||null);}
  }
 }
}
async function button(id:string,which='right'){
 const n=await node(id),point={x:n.rect.x+10,y:n.rect.y+n.rect.h/2,button:which};
 await h.request('POST','/mouse_down',point);await h.request('POST','/mouse_up',point);
}
async function dismiss(){
 assert((await h.key('escape')).ok);
 await h.waitFor(async()=>!(await h.query('context.menu')).some(shown)||null);
}
try{
 await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 for(const [width,height] of localOnly?[]:baseline?[[1440,900]]:[[1440,900],[860,480]]){
  assert((await h.resizeWindow(width,height)).ok);await h.sleep(200);
  await openHost();await capture('host-'+width,width,height);
  // Re-target an already visible menu, so an unchanged open signal cannot
  // hide an overwritten width by reapplying Popover's initial sizing.
  await openHost();await capture('host-'+width+'-retargeted',width,height);await dismiss();
  if(!baseline){await openHost();await capture('host-'+width+'-reopened',width,height);await dismiss();}
 }
 if(all&&!baseline){
  if(!localOnly)await audit(()=>button('sidebar.group'),'sidebar.group.menu',258,'asset-group');
  await h.clickTestId('workspace.empty.local');await node('terminal.surface');
  await audit(()=>button('tabs.tab.1'),'context.menu',284,'local-tab');
  await audit(async()=>{
   const n=await node('terminal.input'),point={x:n.rect.x+20,y:n.rect.y+30,button:'middle'};
   await h.request('POST','/mouse_down',point);await h.request('POST','/mouse_up',point);
  },'context.menu',280,'local-terminal');
  await button('tabs.tab.1');await node('context.menu.join_session_group');await h.clickTestId('context.menu.join_session_group');
  await node('groups.join.name');await h.clickTestId('groups.join.name');await h.type_('Menu audit group');await h.clickTestId('groups.join.accept');
  await h.waitFor(async()=>!(await h.query('groups.join.dialog')).some(shown)||null);
  const strip=await node('tabs.strip');
  const flatten=(n:any):any[]=>[n,...(n.children??[]).flatMap(flatten)];
  const tab=flatten(strip).find((n:any)=>/^tabs\.tab\.\d+$/.test(n.test_id??'')&&flatten(n).some((c:any)=>c.text?.includes('Menu audit group')));assert(tab);
  await audit(()=>button(tab.test_id),'groups.tab.menu',208,'session-group');
 }
 if(baseline)assert(report.captures.some((c:any)=>c.menu.w>c.viewport.width*.7),'Must reproduce the full-width menu');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;await h.screenshot(join(out,'failure.png')).catch(()=>{});}
finally{
 if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,h.sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}}
 await log.close();await rm(isolated,{recursive:true,force:true});
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(report.status+': '+join(out,'report.json'));
}
