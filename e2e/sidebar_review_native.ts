/** Confirmed sidebar/home design: isolated native app, no remote connections. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile,rm,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {waitForServerReady,query,tree,clickTestId,clickAt,mouseMove,key,resizeWindow,screenshot,sleep} from '../zig-out/share/zenit/harness/client.ts';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
const output=resolve(process.argv[2]||'artifacts/sidebar-review');
await mkdir(output,{recursive:true});
const shown=(n:any)=>n.visible!==false&&n.rect.w>0&&n.rect.h>0;
const flat=(n:any):any[]=>[n,...(n.children||[]).flatMap(flat)];
const label=(n:any)=>flat(n).map(x=>x.text||'').join('');
const hashes=['a5c5b0e542d38da7','8ce54dc4a087ff84','88d4d1363bbdb547','19e1705ea4cea828','16e5c76afcf3423c'];
const names=['prod-web-01','prod-db-02','assets','dev-api-02','dev-build-01'];
const os=['ubuntu','debian',process.env.ZW_REVIEW_OS||'linux','fedora','arch'];
const report:any={checks:[],captures:[],limitations:['Isolated fixtures; no real remote connection or physical keyboard/IME testing.']};
for(const theme of ['dark','light','empty']){
 const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-sidebar-review-'))),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(join(data,'cache'),{recursive:true});
 await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme==='empty'?'dark':theme}"\nfont_family="Menlo"\nfont_size=14\n`);
 let hosts='[registry]\nschema_version=2\nrevision=1\nnext_connection_id=6\nnext_group_id=3\n';
 if(theme!=='empty'){
  hosts+='[[groups]]\ngroup_id=1\nrevision=1\nname="Production"\nordered_connection_ids=[1,2,3]\n[[groups]]\ngroup_id=2\nrevision=1\nname="Development"\nordered_connection_ids=[4,5]\n';
  for(let i=0;i<5;i++){
   hosts+=`[[hosts]]\nconnection_id=${i+1}\nrevision=1\nprotocol="${i===2?'sftp':'ssh'}"\nauth_mode="password"\nname="${names[i]}"\nhost="192.0.2.${10+i}"\nport=22\nuser="demo"\nasset_group_id=${i<3?1:2}\nroute=${i===1?'[1]':i===2?'[1,2]':'[]'}\n`;
   await writeFile(join(data,'cache',`os-${hashes[i]}.txt`),os[i]);
  }
 }
 await writeFile(join(data,'hosts.toml'),hosts);
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(output,`${theme}.log`),'w');const child=spawn(resolve('zig-out/bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 const ended=new Promise<void>(done=>child.once('close',()=>done()));
 async function visible(id:string){const n=(await query(id)).find(shown);assert(n,`${theme}: ${id} visible`);return n;}
 async function capture(name:string){await sleep(200);await screenshot(join(output,name+'.png'));await writeFile(join(output,name+'.json'),JSON.stringify(Object.fromEntries(await Promise.all(['workspace.sidebar','sidebar.group.card','sidebar.host','sidebar.host.icon','sidebar.host.hops','workspace.empty.local','workspace.empty.choose'].map(async id=>[id,await query(id)]))),null,2));report.captures.push(name);}
 try{
  await waitForServerReady(15000);await resizeWindow(1440,900);await sleep(300);
  const local=await visible('workspace.empty.local'),connect=await visible('workspace.empty.choose');
  assert.equal(local.rect.w,156);assert.equal(connect.rect.w,156);assert.equal(local.rect.h,38);assert.equal(connect.rect.h,38);
  assert(label(local).includes('本地终端'));assert(label(connect).includes(theme==='empty'?'新建连接':'快速连接'));
  assert(!(await query('sidebar.local')).some(shown));
  await capture(`${theme}-home`);report.checks.push(`${theme}: equal 156×38 home buttons and correct action label; duplicate sidebar local removed`);
  await clickTestId('workspace.empty.choose');await sleep(250);await visible(theme==='empty'?'wizard.cancel':'quick.connect');await key('escape');await sleep(100);
  report.checks.push(`${theme}: home action opens ${theme==='empty'?'new connection':'original quick connection'}`);
  if(theme==='empty')continue;
  const side=await visible('workspace.sidebar');assert.equal(side.rect.w,300);assert.equal((await query('sidebar.host')).filter(shown).length,5);
  const row=(await query('sidebar.host')).filter(shown)[1];await mouseMove(row.rect.x+40,row.rect.y+18);await sleep(100);await visible('sidebar.host.copy');await visible('sidebar.host.edit');assert.deepEqual((await query('sidebar.host.hops')).filter(shown).map(n=>n.text),['0','1','2','0','0']);await capture(`${theme}-hover`);
  const copy=(await query('sidebar.host.copy')).find(shown)!;await clickAt(copy.rect.x+12,copy.rect.y+12);await sleep(200);assert.equal((await query('sidebar.host')).filter(shown).length,6);
  await mouseMove(row.rect.x+40,row.rect.y+18);await sleep(100);const edit=(await query('sidebar.host.edit')).find(shown)!;await clickAt(edit.rect.x+12,edit.rect.y+12);await sleep(200);await visible('wizard.cancel');await key('escape');await sleep(100);
  await clickTestId('sidebar.group');await sleep(200);assert.equal((await query('sidebar.host')).filter(shown).length,2);await clickTestId('sidebar.group');
  await clickTestId('workspace.empty.local');await sleep(600);await visible('workspace.sidebar');await capture(`${theme}-local`);
  await clickTestId('sidebar.collapse');await sleep(150);assert(!(await query('workspace.sidebar')).some(shown));await clickTestId('sidebar.restore');await sleep(150);await visible('workspace.sidebar');
  report.checks.push(`${theme}: colour host fixtures, hover actions, copy persisted and edit dialog, independent groups, local session keeps sidebar, manual sidebar toggle`);
 }catch(e){await writeFile(join(output,'fixture-hosts.toml'),hosts);report.error=String(e);report.process={exitCode:child.exitCode,signal:child.signalCode,pid:child.pid};await capture(`${theme}-failure`).catch(()=>{});throw e;}
 finally{if(child.exitCode===null)child.kill('SIGTERM');await ended;await log.close();await cleanupOwnedBridgeDirectories(child.pid!);await rm(iso,{recursive:true,force:true});await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));}
}
report.status='passed';await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
