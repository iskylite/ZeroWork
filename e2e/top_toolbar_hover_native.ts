/** Right toolbar sizing and hover behavior, using isolated data and real Local tabs. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile,realpath,rm} from 'node:fs/promises';
import {dirname,resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);
const h=await import(pathToFileURL(resolve(dirname(binary),'../share/zenit/harness/client.ts')).href);
const iso=await realpath(await mkdtemp('/tmp/zw-toolbar-hover-')),data=join(iso,'data'),rpc=join(iso,'rpc');
for(const p of [out,data,rpc])await mkdir(p,{recursive:true});
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="reference-light"\n');
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r)),report:any={checks:[],captures:[]};
const shown=(n:any)=>n?.rect?.w>0&&n.rect.h>0&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0.01;
const nodes=async(id:string)=>{assert(app.exitCode===null&&app.signalCode===null,'Native app stays alive');const result=await h.query(id);assert(Array.isArray(result),id+': '+JSON.stringify(result));return result.filter(shown);};
const visible=(id:string)=>h.waitFor(async()=>(await nodes(id))[0]??null,10000);
const hidden=(id:string)=>h.waitFor(async()=>!(await nodes(id)).length||null,5000);
async function hover(id:string){const n=await visible(id);await h.mouseMove(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);}
async function click(id:string){await hover(id);const n=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);}
async function capture(name:string){await h.sleep(280);assert((await h.screenshot(join(out,name+'.png'))).ok);report.captures.push(name);}
async function leave(){await h.mouseMove(450,300);await hidden('toolbar.group.application');await visible('toolbar.compact');}
async function expand(){await hover('toolbar.expand');await visible('toolbar.group.application');await h.sleep(280);}
try{
 await h.waitForServerReady();await h.resizeWindow(1440,900);await h.mouseMove(450,300);
 await visible('toolbar.group.application');await hidden('toolbar.compact');
 await click('workspace.empty.local');await visible('terminal.surface');await capture('wide-default');
 report.checks.push('Wide window shows the complete toolbar by default.');
 const pane=await h.screenPos('workspace.pane');
 await h.resizeWindow(860,480);await leave();await capture('compact');
 const narrowPane=await h.screenPos('workspace.pane'),tabs=(await visible('workspace.tabs.capsule')).rect;
 await hover('toolbar.expand');
 const samples=[];for(let i=0;i<6;i++){const n=(await h.query('toolbar.group.application'))[0];samples.push(n?.effective_opacity??0);await h.sleep(25);}
 report.animation_opacity=samples;assert(samples.some(x=>x>0&&x<1),'Reveal contains intermediate animation frames');
 await h.sleep(100);await visible('toolbar.compact');await hidden('settings.modal');
 const groups=await Promise.all(['connection','history','application'].map(id=>visible('toolbar.group.'+id)));
 const more=await visible('toolbar.compact');
 assert.equal(groups[2].rect.x+groups[2].rect.w+8,more.rect.x);
 assert.deepEqual(await h.screenPos('workspace.pane'),narrowPane);
 assert.deepEqual((await visible('workspace.tabs.capsule')).rect,tabs);
 await capture('hover-expanded');
 for(let i=0;i<2;i++){const r=groups[i].rect;await h.mouseMove(r.x+r.w+4,r.y+18);await h.sleep(150);await visible('toolbar.group.application');}
 await hover('toolbar.expand');await h.sleep(150);await visible('toolbar.group.application');
 await leave();
 report.checks.push('Hover expands to the left of the retained ellipsis; group gaps and anchor stay open; leaving collapses without moving the terminal.');
 await expand();await click('status.connection.theme');const theme=await visible('status.theme');
 await h.mouseMove(theme.rect.x+40,theme.rect.y+60);await h.sleep(150);await visible('toolbar.group.application');
 await h.key('escape');await leave();
 report.checks.push('Clicked theme panel remains reachable below the expanded toolbar.');
 await h.resizeWindow(1440,900);await h.mouseMove(450,300);await hidden('toolbar.compact');await visible('toolbar.group.application');
 assert.deepEqual(await h.screenPos('workspace.pane'),pane);
 for(let i=0;i<9;i++){
  await click('toolbar.new_session');await click('session.menu.local');await h.sleep(120);
 }
 await leave();await capture('wide-many-tabs');
 const before=(await visible('workspace.tabs.capsule')).rect;
 await click('toolbar.expand');await h.sleep(280);
 const after=(await visible('workspace.tabs.capsule')).rect,tools=(await visible('toolbar.group.connection')).rect;
 assert(after.w<before.w,'Expanded toolbar shrinks the tab capsule');
 assert(after.x+after.w+16<=tools.x+0.5,'Tabs stay entirely left of the toolbar');
 assert.deepEqual(await h.screenPos('workspace.pane'),pane);
 const active=(await visible('tabs.tab.10')).rect,viewport=await h.screenPos('tabs.viewport');
 assert(active.x+active.w>viewport.x&&active.x<viewport.x+viewport.w,'Active tab remains in the visible viewport');
 const plus=(await visible('toolbar.new_session')).rect;
 assert(plus.x+plus.w<=tools.x-16,'New-tab button stays outside the tool region');
 await capture('wide-many-tabs-hover');await leave();
 assert.deepEqual((await visible('workspace.tabs.capsule')).rect,before);
 report.checks.push('Clicking ellipsis with many tabs shrinks the capsule to leave a 16-point gap; leaving restores its width.');
 // Verify the same space reservation in the minimum window.
 await h.resizeWindow(860,480);await leave();
 const narrowBefore=(await visible('workspace.tabs.capsule')).rect;
 await expand();
 const narrowAfter=(await visible('workspace.tabs.capsule')).rect,narrowTools=(await visible('toolbar.group.connection')).rect;
 assert(narrowAfter.w<narrowBefore.w);
 assert(narrowAfter.x+narrowAfter.w+16<=narrowTools.x+0.5);
 assert.deepEqual(await h.screenPos('workspace.pane'),narrowPane);
 await capture('narrow-many-tabs-expanded');await leave();
 assert.deepEqual((await visible('workspace.tabs.capsule')).rect,narrowBefore);
 await h.resizeWindow(1440,900);await leave();
 report.checks.push('Adding real Local tabs collapses the toolbar even in a wide window; hover still expands.');
 for(let i=0;i<9;i++){
  const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
  const target=flat(await visible('tabs.strip')).find(n=>n.test_id?.startsWith('tabs.close.')&&shown(n));assert(target);
  await click(target.test_id);await h.sleep(120);
 }
 await visible('toolbar.group.application');await hidden('toolbar.compact');await capture('wide-restored');
 report.checks.push('Removing excess tabs restores the complete default toolbar.');report.status='passed';
}catch(error){report.status='failed';report.error=String(error);if(app.exitCode===null&&app.signalCode===null)await capture('failure').catch(()=>{});process.exitCode=1;}
finally{
 if(app.exitCode===null&&app.signalCode===null){await h.request('POST','/zerowork/windows',{action:'quit'}).catch(()=>{});await Promise.race([ended,h.sleep(8000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await ended;report.forced_shutdown=true;}else report.exit_code=app.exitCode;}
 await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(iso,{recursive:true,force:true});
}
console.log(JSON.stringify(report,null,2));
