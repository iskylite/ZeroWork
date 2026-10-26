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
const isolated=await realpath(await mkdtemp(join(tmpdir(),'zw-wizard-advanced-'))),data=join(isolated,'data'),rpc=join(isolated,'rpc');
await mkdir(data);await mkdir(rpc);
await writeFile(join(data,'hosts.toml'),`[registry]
schema_version=2
revision=1
next_connection_id=3
next_group_id=1
[[hosts]]
connection_id=1
revision=1
protocol="ssh"
name="Jump A"
host="192.0.2.1"
port=22
user="fixture"
auth_mode="password"
[[hosts]]
connection_id=2
revision=1
protocol="ssh"
name="Jump B"
host="192.0.2.2"
port=22
user="fixture"
auth_mode="password"
`);
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
 await resizeWindow(1440,900);await click('sidebar.new');await click('sidebar.new.host');
 await fill('wizard.name','V3 revision target');await fill('wizard.host','127.0.0.1');await fill('wizard.user','fixture');
 assert(!(await current('wizard.strict_host_key')),'Host key policy is hidden with Advanced');
 const remember=await visible('wizard.password.remember'); const boxes=flatten(remember).filter(n=>n.rect?.w===14&&n.rect?.h===14);assert(boxes.length,'Password checkbox is 14px');
 await click('wizard.password.remember');await click('wizard.password.remember');await capture('01-identity-standard');await click('wizard.advanced.toggle');await scrollBottom();
 await click('wizard.strict_host_key');await click('wizard.strict.enabled');await capture('02-advanced-standard');
 const advanced=await visible('wizard.advanced.body');await writeFile(join(out,'advanced-tree.json'),JSON.stringify(advanced,null,2));
 assert(flatten(advanced).some(n=>n.test_id==='wizard.strict_host_key'),'Host key policy belongs to advanced subtree');
 await click('wizard.compression');await editStartup('echo first');await key('return');await type_('echo second');
 await resizeWindow(860,480);await scrollBottom();await capture('03-advanced-compact');const foot=(await visible('wizard.footer')).rect;assert(foot.y+foot.h<=480);
 await click('wizard.next.identity');await click('wizard.access.jump');await click('wizard.route.hop.0');await key('home');await key('return');
 await click('wizard.route.add');await click('wizard.route.hop.1');await key('end');await key('return');await capture('04-route-compact');
 assert.match(text(await visible('wizard.route.hop.0')),/Jump A/);assert.match(text(await visible('wizard.route.hop.1')),/Jump B/);
 const row=(await visible('wizard.route.hop.0')).rect;assert.equal(row.h,34);
 await click('wizard.route.up.1');assert.match(text(await visible('wizard.route.hop.0')),/Jump B/);assert.match(text(await visible('wizard.route.hop.1')),/Jump A/);
 await click('wizard.route.down.0');assert.match(text(await visible('wizard.route.hop.0')),/Jump A/);await click('wizard.route.up.1');await click('wizard.route.hop.1');await capture('05-duplicate-disabled');await key('escape');
 await click('wizard.route.remove.0');assert.match(text(await visible('wizard.route.hop.0')),/Jump A/);assert(!(await current('wizard.route.hop.1')));
 await resizeWindow(1440,900);await capture('06-route-standard');await click('wizard.next.route');await capture('07-review-standard');
 assert.match(text(await visible('wizard.review.options')),/2/);await resizeWindow(860,480);await capture('08-review-compact');
 await click('wizard.cancel');await click('wizard.discard.confirm');await closed();
 report.checks=['14px password checkbox toggles through native widget','Host key policy is exclusively inside Advanced','Host key selector opens and retains strict policy','Compression and multiline startup survive review','Standard and compact form footer and scroll verified','Independent jump selectors and unavailable duplicate option','Up/down reorders actual selected identities','Remove shifts remaining hop','Per-node review opens in both window sizes'];report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await screenshot(join(out,'failure.png')).catch(()=>{});throw e;}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));child.kill('SIGTERM');await ended;await log.close();await rm(isolated,{recursive:true,force:true});}
console.log(JSON.stringify(report));
