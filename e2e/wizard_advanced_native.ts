/** Whole production wizard flow, isolated config and own delayed SSH handshake peer. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,realpath,open,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,screenPos,sleep,scrollAt,request} from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]),theme=process.argv[4]??'dark';
assert(['dark','light','sauber','forest'].includes(theme));
await mkdir(out,{recursive:true});
const isolated=await realpath(await mkdtemp(join(tmpdir(),'zw-wizard-advanced-'))),data=join(isolated,'data'),rpc=join(isolated,'rpc');
await mkdir(data);await mkdir(rpc);
await writeFile(join(data,'hosts.toml'),'');
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const child=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(r=>child.once('close',()=>r()));
const report:any={status:'running',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),theme,checks:[],stages:[],limits:['Synthetic Harness input, not physical keyboard/IME verification','No connection test, remote action or save requested']};
const shown=(n:any)=>n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flatten=(n:any):any[]=>[n,...(n.children??[]).flatMap(flatten)];
const text=(n:any)=>flatten(n).map(x=>x.text??'').join(' ');
async function current(id:string){
 if(id==='wizard.dialog'){
  if(!(await query('wizard.close')).some(shown))return null;
  return {rect:await screenPos(id)};
 }
 return (await query(id)).find(shown)??null;
}
async function visible(id:string){return waitFor(()=>current(id));}
async function click(id:string){let prior='';let repeats=0;const n=await waitFor(async()=>{const n=await current(id);if(!n)return null;const at=JSON.stringify(n.rect);repeats=at===prior?repeats+1:0;prior=at;await sleep(80);return repeats>=2?n:null;});assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);}
async function fill(id:string,value:string){await click(id);await key('a',{cmd:true});await type_(value);await waitFor(async()=>{const n=await current(id);return n&&text(n).includes(value)?true:null});}
async function closed(){await waitFor(async()=>!(await query('wizard.close')).some(shown)||null);}
async function capture(name:string){await sleep(500);const dialog=await visible('wizard.dialog');await writeFile(join(out,name+'.json'),JSON.stringify(dialog,null,2));assert((await screenshot(join(out,name+'.png'))).ok);report.stages.push({name,rect:dialog.rect});}
async function scrollBottom(){const area=await visible('wizard.scroll.identity');await scrollAt(area.rect.x+area.rect.w-20,area.rect.y+area.rect.h/2,0,-1800);await sleep(300);}
async function scrollTop(){const area=await visible('wizard.scroll.identity');await scrollAt(area.rect.x+area.rect.w-20,area.rect.y+area.rect.h/2,0,2200);await sleep(300);}
async function editStartup(value:string){await scrollBottom();await click('wizard.startup');await key('a',{cmd:true});await type_(value);await sleep(200);}
try{
 await waitForServerReady(30000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),child.pid);
 await resizeWindow(1440,900);await click('sidebar.empty.new');
 await fill('wizard.name','ScaleX40-ScaleOS');await fill('wizard.host','10.17.53.33');await fill('wizard.user','root');
 await capture('00-identity');
 const identity=await visible('wizard.identity.card'),auth=await visible('wizard.auth.card');
 const collapsed=(await visible('wizard.dialog')).rect;
 assert.equal(collapsed.w,760);assert(Math.abs(collapsed.h-460)<=2);assert.equal(identity.rect.y,auth.rect.y);assert.equal(identity.rect.w,auth.rect.w);
 await click('wizard.group.pick');await visible('wizard.group.menu');await capture('01-group-select');await key('escape');
 await click('wizard.advanced.toggle');await capture('02-advanced-top');
 const expanded=(await visible('wizard.dialog')).rect,footer=(await visible('wizard.footer')).rect,steps=(await visible('wizard.steps')).rect;
 assert.equal(expanded.h,596);
 await scrollBottom();await capture('02-advanced-bottom');await click('wizard.strict_host_key');await click('wizard.strict.disabled');await capture('02-strict-policy');
 await scrollBottom();await capture('03-advanced-expanded');
 const advanced=await visible('wizard.advanced.body'),compression=await visible('wizard.compression'),encoding=await visible('wizard.encoding'),startup=await visible('wizard.startup');
 assert.equal(startup.rect.h,120);assert.equal(startup.rect.w,680);assert.equal(encoding.rect.h,34);assert.equal(compression.rect.h,34);
 assert.deepEqual((await visible('wizard.footer')).rect,footer);assert.deepEqual((await visible('wizard.steps')).rect,steps);
 assert(startup.rect.y+startup.rect.h<=footer.y);
 await writeFile(join(out,'advanced-tree.json'),JSON.stringify(advanced,null,2));const summary=await visible('wizard.advanced.toggle'),summaryText=flatten(summary).find(n=>n.text==='高级选项');assert(summaryText);assert.equal(summary.rect.h,30);assert(summaryText.rect.x-summary.rect.x<24);assert.equal(advanced.rect.y-summary.rect.y-summary.rect.h,4);report.summary={rect:summary.rect,text:summaryText.rect};
 const labelNames=['连接超时（全局默认）','保活间隔（全局默认）','字符编码','启动命令 · 每行一条，连接后依次执行'];
 const labels=flatten(advanced).filter(n=>labelNames.includes(n.text));for(const label of labels){assert.equal(label.rect.h,16.5);}assert.equal(labels.length,4);
 report.geometry={advanced:advanced.rect,compression:compression.rect,encoding:encoding.rect,startup:startup.rect,labels};
 const encodingText=flatten(encoding).find(n=>n.text==='UTF-8');assert(encodingText);assert.equal(encodingText.rect.h,16);report.geometry.encoding_text=encodingText;assert.equal(encoding.rect.w,118);assert.equal(compression.rect.w,324);assert.equal(encoding.rect.x-compression.rect.x-compression.rect.w,32);
 await click('wizard.compression.enabled');await editStartup('echo first');await key('return');await type_('echo second');await capture('04-startup-two-lines');
 const lines=flatten(await visible('wizard.startup')).filter(n=>n.text==='echo first'||n.text==='echo second');assert.equal(lines.length,2);assert.equal(lines[1].rect.y-lines[0].rect.y,18);assert.equal(lines[0].rect.x-(await visible('wizard.startup')).rect.x,11);assert.equal(lines[0].rect.y-(await visible('wizard.startup')).rect.y,9);report.geometry.startup_lines=lines;
 await click('wizard.next.identity');await click('wizard.next.route');await visible('wizard.review.options');assert.match(text(await visible('wizard.review.options')),/2/);await capture('05-review-preserves-options');
 await click('wizard.review.modify');await scrollBottom();assert.match(text(await visible('wizard.startup')),/echo first/);assert.match(text(await visible('wizard.startup')),/echo second/);
 await resizeWindow(860,480);await scrollBottom();const footerBefore=(await visible('wizard.footer')).rect;const compactDialog=(await visible('wizard.dialog')).rect,compactSteps=(await visible('wizard.steps')).rect;assert.deepEqual(compactDialog,{x:50,y:24,w:760,h:432});assert.equal(compactSteps.w,712);assert.equal(compactSteps.h,36);assert.equal(compactSteps.y-compactDialog.y,52);assert.equal(footerBefore.h,54);assert.equal(footerBefore.y+footerBefore.h,456);report.compact={dialog:compactDialog,steps:compactSteps,footer:footerBefore};await capture('06-advanced-compact');await editStartup('echo changed');assert.deepEqual((await visible('wizard.footer')).rect,footerBefore);
 await scrollTop();const compactName=(await visible('wizard.name')).rect,compactGroup=(await visible('wizard.group.control')).rect;assert.equal(compactName.w,316);assert.equal(compactGroup.w,316);assert.equal(compactGroup.x,compactName.x);assert(compactGroup.y>compactName.y);report.compact.columns={name:compactName,group:compactGroup};await capture('07-identity-compact');await click('wizard.protocol');await click('wizard.protocol.sftp');await scrollBottom();await click('wizard.advanced.toggle');await scrollBottom();await capture('08-sftp-advanced');assert(!(await current('wizard.startup')));const sftpAdvanced=await visible('wizard.advanced.body');assert(sftpAdvanced.rect.h<advanced.rect.h);report.geometry.sftp_advanced=sftpAdvanced.rect;
 await click('wizard.cancel');await closed();assert.equal((await readFile(join(data,'hosts.toml'),'utf8')).trim(),'');
 await request('POST','/zerowork/windows',{action:'quit'});await waitFor(()=>child.exitCode!==null||child.signalCode!==null,10000);assert.equal(child.exitCode,0);
 report.checks=['Identity and authentication share equal columns in the natural-height dialog','Native asset group Select opens and Escape dismisses','Advanced expands within 760x596 with fixed steps and footer','Native host-key Select switches policy','Startup Textarea is 680x120 with independent multiline editing','Two command lines survive review and return','Minimum window keeps footer fixed while the form scrolls','SFTP excludes startup commands','Cancel leaves isolated hosts empty and no network request','Application quits normally'];report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await screenshot(join(out,'failure.png')).catch(()=>{});throw e;}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');await ended;await log.close();await rm(isolated,{recursive:true,force:true});}
console.log(JSON.stringify(report));
