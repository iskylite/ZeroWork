import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {mkdtemp,mkdir,writeFile,open,rm} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {tmpdir} from 'node:os';
import {realpath} from 'node:fs/promises';
import {waitForServerReady,waitFor,query,clickAt,clickTestId,screenshot,resizeWindow,sleep} from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[3]??'dist/ui-acceptance/connection-progress-v3');await mkdir(out,{recursive:true});
const temp=await mkdtemp(join(await realpath(tmpdir()),'zw-progress-v3-'));const data=join(temp,'data'),rpc=join(temp,'rpc');await mkdir(data);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
let closedSockets=0;const peerEvents:any[]=[];const sockets:any[]=[];const server=createServer(s=>{sockets.push(s);peerEvents.push({event:'accept',at:Date.now()});s.on('data',d=>peerEvents.push({event:'data',bytes:d.length,at:Date.now()}));s.on('end',()=>peerEvents.push({event:'end',at:Date.now()}));s.on('error',e=>peerEvents.push({event:'error',message:e.message,at:Date.now()}));s.resume();s.on('close',()=>{closedSockets++;peerEvents.push({event:'close',at:Date.now()});});});await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));const port=(server.address() as any).port;
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Progress V3 Loopback"\nhost="127.0.0.1"\nport=${port}\nuser="fixture"\n`);
await writeFile(join(data,'config.toml'),'[ui]\ntheme="dark"\n[ssh]\nconnect_timeout_sec=120\n');
const log=await open(join(out,'app.log'),'w');const app=spawn(resolve(process.argv[2]??'zig-out/bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
app.on('exit',(code,signal)=>console.log('app exit',code,signal));app.on('error',e=>console.log('app error',e));
const shown=(n:any)=>!n.hidden&&n.visible!==false&&n.rect?.w>0&&n.rect?.h>0;
try {await waitForServerReady();await resizeWindow(1440,900);const row=await waitFor(async()=>(await query('sidebar.host')).find(shown)??null,15000);assert((await clickAt(row.rect.x+60,row.rect.y+row.rect.h/2,1)).ok);assert((await clickTestId('sidebar.host.connect')).ok);await waitFor(async()=>(await query('connection.progress')).find(shown)??null,15000);
for(const [w,h] of [[1440,900],[860,480]]){await resizeWindow(w,h);await sleep(400);const panel=(await query('connection.progress')).find(shown);const actions=(await query('connection.progress.actions')).find(shown);assert(panel&&actions);assert.equal(actions.rect.h,54);assert(panel.rect.x>=0&&panel.rect.y>=0);assert(panel.rect.w<=w&&panel.rect.h<=h);assert(actions.rect.y+actions.rect.h<=panel.rect.y+panel.rect.h+1);assert((await screenshot(join(out,`progress-${w}.png`))).ok);await writeFile(join(out,`progress-${w}.json`),JSON.stringify(await query('connection.progress'),null,2));}
assert((await clickTestId('connection.progress.hop.1')).ok);await sleep(100);assert(JSON.stringify(await query('connection.progress')).includes('第 1 跳'));await sleep(250);assert((await query('connection.progress.logs')).some(shown));assert((await screenshot(join(out,'progress-logs-860.png'))).ok);assert((await clickTestId('connection.progress.cancel')).ok);await sleep(400);await screenshot(join(out,'after-production-cancel.png'));await writeFile(join(out,'after-production-cancel.json'),JSON.stringify(await query('connection.progress'),null,2));await waitFor(async()=>closedSockets===sockets.length&&closedSockets>0||null,20000);await writeFile(join(out,'cancel-release.json'),JSON.stringify({status:'passed',pid:app.pid,accepted_sockets:sockets.length,closed_sockets:closedSockets,proof:'production Cancel released exact accepted TCP socket before runner cleanup'},null,2));await waitFor(async()=>(await query('connection.progress.dismiss')).find(n=>shown(n)&&!n.disabled)??null,20000);
assert((await clickTestId('connection.progress.dismiss')).ok);
await waitFor(async()=>!(await query('connection.progress')).some(shown)||null);
for(const [w,h] of [[1440,900],[860,480]]){
 await resizeWindow(w,h);
 const bar=await waitFor(async()=>(await query('remote.notice')).find(shown)??null);
 assert.equal((await query('remote.notice.title')).find(shown)?.text,'连接已取消');
 assert.equal((await query('remote.notice.detail')).find(shown)?.text,'尚未建立远程会话，可重新连接或关闭此页签');
 assert(!(await query('terminal.row')).filter(shown).some(n=>n.text?.includes('连接已取消')));
 const close=(await query('remote.notice.close')).find(shown),retry=(await query('remote.notice.reconnect')).find(shown);
 assert(close&&retry);assert(close.rect.x+close.rect.w<=retry.rect.x);assert(retry.rect.x+retry.rect.w<=bar.rect.x+bar.rect.w);
 assert.equal(bar.rect.h,64);assert((await screenshot(join(out,`cancelled-notice-${w}.png`))).ok);
}
const previousConnections=sockets.length;
assert((await clickTestId('remote.notice.reconnect')).ok);
await waitFor(async()=>(await query('connection.progress')).find(shown)??null);
await waitFor(async()=>sockets.length>previousConnections||null,20000);
assert(!(await query('remote.notice')).some(shown),'cancelled banner hides during a new attempt');
assert((await clickTestId('connection.progress.cancel')).ok);
await waitFor(async()=>closedSockets===sockets.length||null,20000);
await waitFor(async()=>(await query('connection.progress.dismiss')).find(n=>shown(n)&&!n.disabled)??null,20000);
assert((await clickTestId('connection.progress.dismiss')).ok);
await waitFor(async()=>!(await query('connection.progress')).some(shown)||null);
await waitFor(async()=>(await query('remote.notice.close')).find(shown)??null);
assert((await clickTestId('remote.notice.close')).ok);
await waitFor(async()=>!(await query('remote.notice')).some(shown)||null);
console.log('PASS: production cancel releases sockets; cancelled notice fits 1440/860; reconnect starts a new attempt; close removes the cancelled tab');
}finally{await writeFile(join(out,'peer-events.json'),JSON.stringify({accepted:sockets.length,closed:closedSockets,events:peerEvents},null,2));app.kill('SIGTERM');for(const s of sockets)s.destroy();server.close();await new Promise<void>(r=>app.once('exit',()=>r()));await log.close();await rm(temp,{recursive:true,force:true});}
