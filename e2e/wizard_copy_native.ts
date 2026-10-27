/** Whole production wizard flow, isolated config and own delayed SSH handshake peer. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,realpath,open,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,screenPos,sleep,scrollAt,mouseMove} from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]),theme=process.argv[4]??'dark';
assert(['dark','light','sauber'].includes(theme));
await mkdir(out,{recursive:true});
const isolated=await realpath(await mkdtemp(join(tmpdir(),'zw-wizard-advanced-'))),data=join(isolated,'data'),rpc=join(isolated,'rpc');
await mkdir(data);await mkdir(rpc);
await writeFile(join(data,'hosts.toml'),`[registry]
schema_version=2
revision=1
next_connection_id=2
next_group_id=3
[[groups]]
group_id=1
revision=1
name="Source group"
[[groups]]
group_id=2
revision=1
name="Empty group"
[[hosts]]
connection_id=1
revision=1
protocol="ssh"
name="Copy source"
host="192.0.2.1"
port=2222
user="fixture"
asset_group_id=1
auth_mode="password"
startup_commands=["echo fixture"]
`);
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const child=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(r=>child.once('close',()=>r()));
const report:any={status:'running',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),theme,checks:[],stages:[],limits:['Synthetic Harness input, not physical keyboard/IME verification','Only Save writes the isolated fixture registry; no network or remote action']};
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
async function capture(name:string){await sleep(500);const dialog=await current('wizard.dialog')??{rect:null};await writeFile(join(out,name+'.json'),JSON.stringify(dialog,null,2));assert((await screenshot(join(out,name+'.png'))).ok);report.stages.push({name,rect:dialog.rect});}
async function chooseSource(){await click('wizard.copy.source');await key('down');await key('return');await sleep(300);}
try{
 await waitForServerReady(30000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),child.pid);
 await resizeWindow(1440,900);await click('sidebar.new');await click('sidebar.new.host');assert.match(text(await visible('wizard.title')),/新建连接/);await fill('wizard.name','Original draft');await fill('wizard.host','127.0.0.1');await fill('wizard.user','unchanged');
 const originalNameId=(await visible('wizard.name')).id;await click('wizard.copy.open');assert(!(await current('wizard.close')),'Parent dialog stays visible under copy child');const modal=await visible('wizard.copy.dialog');assert.equal(modal.rect.w,440);await capture('01-copy-modal');
 await chooseSource();await click('wizard.copy.cancel');await waitFor(async()=>!(await current('wizard.copy.dialog'))||null);assert.equal((await visible('wizard.name')).id,originalNameId);assert.match(text(await visible('wizard.name')),/Original draft/);assert.match(text(await visible('wizard.user')),/unchanged/);await capture('02-copy-cancel');
 await click('wizard.copy.open');await chooseSource();await key('escape');await waitFor(async()=>!(await current('wizard.copy.dialog'))||null);assert.match(text(await visible('wizard.name')),/Original draft/);
 await click('wizard.copy.open');await chooseSource();await click('wizard.copy.apply');await waitFor(async()=>!(await current('wizard.copy.dialog'))||null);assert.match(text(await visible('wizard.name')),/Copy source/);assert.match(text(await visible('wizard.host')),/192.0.2.1/);assert.match(text(await visible('wizard.port')),/2222/);assert.match(text(await visible('wizard.user')),/fixture/);await capture('03-copy-applied');
 await click('wizard.group');await key('end');await key('return');assert.match(text(await visible('wizard.group')),/Empty group/);await capture('04-group-selected');
 await click('wizard.advanced.toggle');const area=await visible('wizard.scroll.identity');await scrollAt(area.rect.x+area.rect.w-20,area.rect.y+area.rect.h/2,0,-1600);await sleep(250);await click('wizard.compression');await click('wizard.startup');await key('a',{cmd:true});await type_('echo saved first');await key('return');await type_('echo saved second');
 await click('wizard.next.identity');await click('wizard.next.route');await capture('05-copy-review');await click('wizard.save_only');await closed();
 const saved=await readFile(join(data,'hosts.toml'),'utf8');assert.equal((saved.match(/\[\[hosts\]\]/g)??[]).length,2);assert(saved.includes('Copy source-副本'));assert(saved.includes('echo saved first'));assert(saved.includes('echo saved second'));assert(saved.includes('compression = true'));assert.match(saved.slice(saved.lastIndexOf('[[hosts]]')),/asset_group_id\s*=\s*2/);await capture('06-copy-saved');
 const host=(await query('sidebar.host')).find(n=>shown(n)&&text(n).includes('副本'));assert(host);await mouseMove(host.rect.x+host.rect.w-18,host.rect.y+host.rect.h/2);await click('sidebar.host.more');await click('context.menu.edit_host');await visible('wizard.name');assert.match(text(await visible('wizard.name')),/副本/);assert.match(text(await visible('wizard.group')),/Empty group/);await click('wizard.advanced.toggle');const reopened=await visible('wizard.scroll.identity');await scrollAt(reopened.rect.x+reopened.rect.w-20,reopened.rect.y+reopened.rect.h/2,0,-1600);await sleep(250);assert.match(text(await visible('wizard.startup')),/echo saved first/);assert.match(text(await visible('wizard.startup')),/echo saved second/);await capture('06b-copy-reloaded');await click('wizard.cancel');await closed();
 await click('sidebar.new');await click('sidebar.new.host');assert.match(text(await visible('wizard.title')),/新建连接/);await resizeWindow(860,480);await click('wizard.copy.open');const compact=await visible('wizard.copy.dialog');assert.equal(compact.rect.w,440);assert(compact.rect.y>=16&&compact.rect.y+compact.rect.h<=464);await capture('07-copy-compact');await click('wizard.copy.close');await click('wizard.cancel');
 report.checks=['Copy dialog opens at 440px','Selection then cancel preserves current draft','Escape dismisses only child','Explicit apply copies source fields and resets identity','Actual Textarea and compression edits persist only on Save and read back through Edit','Empty registry group selects, persists durable group identity and reads back','Minimum window keeps child centered and within bounds'];report.geometry={copy:modal.rect,compact:compact.rect};report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await screenshot(join(out,'failure.png')).catch(()=>{});throw e;}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));child.kill('SIGTERM');await ended;await log.close();await rm(isolated,{recursive:true,force:true});}
console.log(JSON.stringify(report));
