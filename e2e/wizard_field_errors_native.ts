/** Whole production wizard flow, isolated config and own delayed SSH handshake peer. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,realpath,open,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,screenPos,sleep,scrollAt} from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]),theme=process.argv[4]??'dark';
assert(['dark','light','sauber'].includes(theme));
await mkdir(out,{recursive:true});
const isolated=await realpath(await mkdtemp(join(tmpdir(),'zw-wizard-fields-'))),data=join(isolated,'data'),rpc=join(isolated,'rpc');
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
async function capture(name:string){await sleep(200);const dialog=await visible('wizard.dialog');await writeFile(join(out,name+'.json'),JSON.stringify(dialog,null,2));assert((await screenshot(join(out,name+'.png'))).ok);report.stages.push({name,rect:dialog.rect});}
try{
 await waitForServerReady(30000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),child.pid);
 await resizeWindow(1440,900);await click('sidebar.empty.new');await capture('01-pristine');
 for(const id of ['name','host','user','port'])assert(!(await current('wizard.'+id+'.error')));
 await click('wizard.name');await click('wizard.host');
 assert.match(text(await visible('wizard.name.error')),/请输入主机名称/);
 assert(!(await current('wizard.user.error')));
 await click('wizard.user');await click('wizard.port');await key('a',{cmd:true});await type_('+22');await click('wizard.group');
 assert.match(text(await visible('wizard.host.error')),/请输入主机地址/);assert.match(text(await visible('wizard.user.error')),/请输入登录用户/);
 assert.match(text(await visible('wizard.port.error')),/1–65535/);assert.match(text(await visible('wizard.port')),/\+22/);
 for(const id of ['name','host','user','port']){
  const input=await visible(`wizard.${id}`),error=await visible(`wizard.${id}.error`);
  assert.equal(input.rect.h,32);assert.equal(error.rect.h,16);assert.equal(error.rect.y-input.rect.y-input.rect.h,4);
 }
 await capture('02-errors-after-blur');
 await fill('wizard.name','DB-Validation');assert(!(await current('wizard.name.error')));
 await fill('wizard.host','127.0.0.1');await fill('wizard.user','fixture');await fill('wizard.port','22');
 for(const id of ['name','host','user','port'])assert(!(await current('wizard.'+id+'.error')));
 await capture('03-corrected');
 await click('wizard.auth');await click('wizard.auth.key');await click('wizard.key_path');await click('wizard.name');await visible('wizard.key_path.error');await capture('04-key-error');
 await click('wizard.auth');await click('wizard.auth.password');assert(!(await current('wizard.key_path.error')));
 await click('wizard.next.identity');await click('wizard.next.route');await capture('05-review-after-recovery');
 await click('wizard.cancel');await click('wizard.discard.confirm');await closed();await click('sidebar.empty.new');
 await resizeWindow(860,480);await click('wizard.name');await key('return');
 await visible('wizard.name.error');await visible('wizard.host.error');await visible('wizard.user.error');await visible('wizard.step.identity.check');await capture('06-errors-compact');
 const dialog=await visible('wizard.dialog'),footer=await visible('wizard.footer');assert(footer.rect.y+footer.rect.h<=480);
 const err=await visible('wizard.name.error');assert(err.rect.y>=dialog.rect.y&&err.rect.y+err.rect.h<=footer.rect.y);
 await fill('wizard.name','Recovered');await fill('wizard.host','127.0.0.1');await fill('wizard.user','fixture');await key('return');
 await visible('wizard.access.direct');await capture('07-route-compact');
 assert.equal((await readFile(join(data,'hosts.toml'),'utf8')).trim(),'');
 report.checks=['No errors before interaction','Blur shows only concrete touched-field errors','Invalid raw +22 retained','Typing valid values clears errors immediately','Private-key error only applies to key authentication','Corrected fields navigate to actual review','Enter reveals required errors and focuses first invalid field','860x480 error text and footer reachable','New draft clears old errors','No hosts saved and no network requests'];report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await screenshot(join(out,'failure.png')).catch(()=>{});throw e;}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));child.kill('SIGTERM');await ended;await log.close();await rm(isolated,{recursive:true,force:true});}
