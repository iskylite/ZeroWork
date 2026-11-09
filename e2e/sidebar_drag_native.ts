/** Real pointer drag, atomic saved order/group changes and restart restoration. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,realpath,writeFile,readFile,open} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'/tmp/zerowork-sidebar-drag');await mkdir(out,{recursive:true});
const binary=resolve(process.argv[3]??'zig-out/bin/zerowork');
const isolated=await realpath(await mkdtemp(join(tmpdir(),'zw-sidebar-drag-'))),data=join(isolated,'data');await mkdir(data);
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
const names=['Alpha','Beta','Gamma','Delta','Echo'];
let hosts='[registry]\nschema_version=2\nrevision=1\nnext_connection_id=6\nnext_group_id=4\n';
for(const [id,name,ids,collapsed] of [[1,'Group A',[1,2],false],[2,'Group B',[3],false],[3,'Empty group',[],true]] as const)hosts+=`[[groups]]\ngroup_id=${id}\nrevision=1\nname="${name}"\nordered_connection_ids=[${ids.join(',')}]\ncollapsed=${collapsed}\n`;
for(let i=0;i<names.length;i++)hosts+=`[[hosts]]\nconnection_id=${i+1}\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="${names[i]}"\nhost="192.0.2.${i+10}"\nport=22\nuser="demo"\n${i<3?`asset_group_id=${i<2?1:2}\n`:''}`;
await writeFile(join(data,'hosts.toml'),hosts);
const report:any={checks:[],captures:[],data};
const shown=(n:any)=>n.visible!==false&&n.hidden!==true&&n.rect.w>0&&n.rect.h>0&&(n.effective_opacity??1)>0;
const text=(n:any):string=>(n.text||'')+(n.children||[]).map(text).join('');
const rows=async()=> (await h.query('sidebar.host')).filter(shown);
const row=async(name:string)=> await h.waitFor(async()=> (await rows()).find(n=>text(n).includes(name))??null,10000);
const group=async(name:string)=> await h.waitFor(async()=> (await h.query('sidebar.group')).filter(shown).find(n=>text(n).includes(name))??null,10000);
const order=async()=> (await rows()).map(n=>names.find(name=>text(n).includes(name)));
const expectOrder=async(expected:string[])=>h.waitFor(async()=>JSON.stringify(await order())===JSON.stringify(expected)||null,10000);
const capture=async(name:string)=>{assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.tree(),null,2));report.captures.push(name);};
async function begin(name:string){const n=await row(name),x=n.rect.x+45,y=n.rect.y+n.rect.h/2;assert((await h.mouseDown(x,y)).ok);assert((await h.mouseMove(x+7,y)).ok);}
async function drop(name:string,target:()=>Promise<any>,after=false,cancel=false){
 await begin(name);const n=await target(),x=n.rect.x+55,y=n.rect.y+n.rect.h*(after?.8:.2);assert((await h.mouseMove(x,y)).ok);
 await h.waitFor(async()=>(await h.query('sidebar.drop_hint')).some(shown)||null,10000);
 await capture(cancel?'cancel-drag':'drop-'+name+'-'+report.captures.length);
 if(cancel)await h.key('escape');assert((await h.mouseUp(x,y)).ok);
 await h.waitFor(async()=>!(await h.query('sidebar.drop_hint')).some(shown)||null,10000);
 assert(!(await h.query('tabs.tab')).some(shown),'drag must not create a connection');
}
async function launch(round:number,run:()=>Promise<void>){
 const rpc=join(isolated,'rpc-'+round);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,'app-'+round+'.log'),'w');
 const child=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 const ended=new Promise<void>(done=>child.once('close',()=>done()));
 try{await h.waitForServerReady();await h.resizeWindow(1100,800);await run();assert((await h.request('POST','/zerowork/windows',{action:'quit'})).ok);await Promise.race([ended,new Promise((_,reject)=>setTimeout(()=>reject(Error('quit timeout')),15000))]);assert.equal(child.exitCode,0);}
 finally{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');await ended;await log.close();}
}
try{
 await launch(1,async()=>{
  await expectOrder(['Delta','Echo','Alpha','Beta','Gamma']);await capture('initial');
  await drop('Beta',()=>row('Alpha'));await expectOrder(['Delta','Echo','Beta','Alpha','Gamma']);report.checks.push('same-group pointer reorder');
  await drop('Beta',()=>group('Group B'));await expectOrder(['Delta','Echo','Alpha','Gamma','Beta']);report.checks.push('drop on group header appends to destination');
  await drop('Alpha',()=>group('Empty group'));await expectOrder(['Delta','Echo','Gamma','Beta']);await h.clickAt((await group('Empty group')).rect.x+40,(await group('Empty group')).rect.y+12);await row('Alpha');report.checks.push('drop into an empty collapsed group');
  await drop('Gamma',()=>row('Echo'));await expectOrder(['Delta','Gamma','Echo','Beta','Alpha']);report.checks.push('cross-group insertion into default group');
  await drop('Delta',()=>group('Group B'));await expectOrder(['Gamma','Echo','Beta','Delta','Alpha']);
  await drop('Echo',()=>group('Group B'));await expectOrder(['Gamma','Beta','Delta','Echo','Alpha']);
  await drop('Gamma',()=>group('Group B'));await expectOrder(['Beta','Delta','Echo','Gamma','Alpha']);
  await drop('Beta',()=>group('默认分组'));await expectOrder(['Beta','Delta','Echo','Gamma','Alpha']);report.checks.push('empty default group appears as a drop target while dragging');
  const before=await readFile(join(data,'hosts.toml'),'utf8');
  await drop('Delta',()=>group('Empty group'),false,true);assert.equal(await readFile(join(data,'hosts.toml'),'utf8'),before);report.checks.push('Escape cancels without saving');
  await begin('Echo');await h.mouseMove(1000,700);await h.mouseUp(1000,700);assert.equal(await readFile(join(data,'hosts.toml'),'utf8'),before);report.checks.push('outside drop leaves configuration intact');
  await h.clickTestId('sidebar.search.toggle');await h.waitFor(async()=>(await h.query('sidebar.search')).some(shown)||null);await h.type_('a');
  await expectOrder(['Beta','Delta','Gamma','Alpha']);
  await drop('Gamma',()=>row('Delta'));await expectOrder(['Beta','Gamma','Delta','Alpha']);
  await h.clickTestId('sidebar.search.clear');await expectOrder(['Beta','Gamma','Delta','Echo','Alpha']);
  report.checks.push('filtered drag preserves unseen hosts and restores their relative order when search clears');
  const selected=await row('Alpha');await h.clickAt(selected.rect.x+50,selected.rect.y+18);
  assert((await h.request('POST','/mouse_down',{x:selected.rect.x+50,y:selected.rect.y+18,button:'right'})).ok);
  assert((await h.request('POST','/mouse_up',{x:selected.rect.x+50,y:selected.rect.y+18,button:'right'})).ok);
  await h.waitFor(async()=>(await h.query('context.menu')).some(shown)||null);await h.key('escape');
  report.checks.push('normal click and right-click host menu still work after dragging');
  await capture('saved');await writeFile(join(out,'saved-hosts.toml'),await readFile(join(data,'hosts.toml'),'utf8'));
 });
 await launch(2,async()=>{await expectOrder(['Beta','Gamma','Delta','Echo','Alpha']);await capture('restart');const saved=await readFile(join(data,'hosts.toml'),'utf8');const blocks=saved.split('[[hosts]]').slice(1);assert(!/asset_group_id/.test(blocks.find(b=>/name = "Beta"/.test(b))!));for(const name of ['Delta','Echo','Gamma'])assert(/asset_group_id = 2/.test(blocks.find(b=>b.includes(`name = "${name}"`))!));report.checks.push('restart restores exact order and memberships with original connection IDs');});
 report.ok=true;
}catch(error){report.ok=false;report.error=String(error);throw error;}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
console.log(JSON.stringify(report,null,2));
