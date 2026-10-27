/** Native + menu / original quick-connect acceptance with isolated loopback fixtures. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,realpath,open,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';import {join,resolve} from 'node:path';
import {waitForServerReady,query,clickTestId,clickAt,mouseMove,scrollAt,key,type_,resizeWindow,screenshot,sleep,screenPos} from '../zig-out/share/zenit/harness/client.ts';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
const out=resolve(process.argv[2]||'artifacts/session-menu-review');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-session-menu-'))),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ssh]\nconnect_timeout_sec=1\n');
let hosts='[registry]\nschema_version=2\nrevision=1\nnext_connection_id=15\nnext_group_id=1\n';for(let i=1;i<=14;i++)hosts+=`[[hosts]]\nconnection_id=${i}\nrevision=1\nprotocol="ssh"\nname="review-host-${String(i).padStart(2,'0')}"\nhost="127.0.0.1"\nport=1\nuser="demo"\n`;
await writeFile(join(data,'hosts.toml'),hosts);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w'),child=spawn(resolve('zig-out/bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise<void>(r=>child.once('close',()=>r()));
const shown=(n:any)=>n.visible!==false&&n.rect.w>0&&n.rect.h>0;
const flat=(n:any):any[]=>[n,...(n.children||[]).flatMap(flat)];const text=(n:any)=>flat(n).map(x=>x.text||'').join('');
async function nodes(id:string){const q=await query(id);assert(Array.isArray(q),JSON.stringify(q));return q.filter(shown)}
async function click(id:string){assert((await clickTestId(id)).ok,id);await sleep(120)}
async function cap(n:string){assert((await screenshot(join(out,n+'.png'))).ok);report.captures.push(n)}
async function closeProgress(){await sleep(500);if((await nodes('connection.progress.close')).length)await click('connection.progress.close');await key('escape');await sleep(100)}
const report:any={checks:[],captures:[]};
try{
 await waitForServerReady();await resizeWindow(1440,900);await sleep(250);
 await click('toolbar.quick_connect');assert((await nodes('quick.query')).length);await cap('quick-default');
 await click('quick.query');await type_('review-host-03');await sleep(120);assert.equal((await nodes('quick.saved.row')).length,1);await cap('quick-filtered');await click('quick.close');
 await click('toolbar.new_session');assert.equal((await nodes('session.menu.saved')).length,0);await cap('plus-initial');
 const more=await screenPos('session.menu.more');await mouseMove(more.x+more.w/2,more.y+more.h/2);await sleep(150);assert((await nodes('session.menu.more.host')).length>=8);await cap('plus-more');
 const scroll=await screenPos('session.menu.more.scroll');await mouseMove(scroll.x+scroll.w/2,scroll.y+scroll.h/2);const beforeRows=await nodes('session.menu.more.host');await scrollAt(scroll.x+scroll.w/2,scroll.y+scroll.h/2,0,-300);await sleep(150);const afterRows=await nodes('session.menu.more.host');assert(afterRows.some(n=>text(n).includes('14')&&n.rect.y>=scroll.y&&n.rect.y+n.rect.h<=scroll.y+scroll.h+1),'last host must be reachable by scrolling');await cap('plus-more-scrolled');
 await key('escape');await key('escape');
 report.checks.push('Toolbar lightning opens searchable original quick-connect, never the connection editor; + shows independent scrollable host flyout.');
 for(let i=0;i<4;i++){
  await click('toolbar.new_session');await click('session.menu.more');await sleep(120);
  const rows=await nodes('session.menu.more.host'),row=rows[i];assert(row);await clickAt(row.rect.x+row.rect.w/2,row.rect.y+row.rect.h/2);await closeProgress();
 }
 await click('toolbar.new_session');assert.equal((await nodes('session.menu.more.host')).length,0,'More must reopen collapsed');const recent=await nodes('session.menu.saved');assert.equal(recent.length,3);assert.deepEqual(recent.map(text),['review-host-04','review-host-03','review-host-02']);await cap('plus-recent-three');await key('escape');
 report.checks.push('Flyout clicks each open a new tab; recent list contains the last three real selected host identities in newest-first order.');
 await click('toolbar.new_session');await click('session.menu.new_sftp');assert((await nodes('wizard.cancel')).length);await cap('new-sftp');await key('escape');await sleep(80);
 await resizeWindow(860,480);await click('toolbar.new_session');await click('session.menu.more');await cap('compact-more');await key('escape');await key('escape');
 report.checks.push('Dedicated SFTP creation opens its editor; More remains accessible in 860×480.');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await cap('failure').catch(()=>{});throw e;}
finally{if(child.exitCode===null)child.kill('SIGTERM');await ended;await log.close();await cleanupOwnedBridgeDirectories(child.pid!);await rm(iso,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
console.log(JSON.stringify(report,null,2));
