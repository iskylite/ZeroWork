/** Saved-host clicks select the row, while a double-click starts one new session. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer,type Socket} from 'node:net';
import {mkdir,mkdtemp,open,writeFile,rm,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.argv[2]??'zig-out');
const out=resolve(process.argv[3]??'/tmp/zerowork-sidebar-selection');
await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp('/tmp/zw-sidebar-selection-'));
const data=join(base,'data'),rpc=join(base,'rpc');
await Promise.all([mkdir(data),mkdir(rpc)]);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
let connections=0;
const sockets=new Set<Socket>();
// Hold each handshake open so the client's startup retries cannot affect the count.
const server=createServer(socket=>{
 connections++;
 sockets.add(socket);
 socket.once('close',()=>sockets.delete(socket));
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),'[updates]\nauto_check=false\n[ssh]\nreconnect_max=0\nconnect_timeout_sec=15\n');
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="Loopback host"\nhost="127.0.0.1"\nport=${port}\nuser="fixture"\n`);
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(resolve=>app.once('close',resolve));
const shown=(n:any)=>n.visible!==false&&n.rect.w>0&&n.rect.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null);
const tabs=async()=>(await h.query('tabs.strip')).flatMap(function flat(n:any):any[]{return [n,...(n.children??[]).flatMap(flat)];}).filter((n:any)=>/^tabs\.tab\.\d+$/.test(n.test_id??'')&&shown(n));
const state=()=>h.request('POST','/zerowork/windows',{action:'snapshot'});
async function expectSessions(count:number):Promise<void>{
 if(count>0)await h.waitFor(async()=>connections>=count&&(await tabs()).length>=count||null);
 await h.sleep(500);
 assert.equal((await tabs()).length,count,'session tab count');
 assert.equal(connections,count,'loopback transport count');
}
try{
 await h.waitForServerReady();await h.resizeWindow(1000,700);
 const name=await visible('sidebar.host.name');
 const x=name.rect.x+10,y=name.rect.y+name.rect.h/2;
 assert((await h.clickAt(x,y)).ok);
 await expectSessions(0);
 assert.equal((await state()).windows[0].selected_connection,1);
 assert((await h.screenshot(join(out,'selected-without-connection.png'))).ok);
 const row=await visible('sidebar.host');await h.mouseMove(row.rect.x+20,row.rect.y+18);
 const route=await visible('sidebar.host.route');
 assert((await h.clickAt(route.rect.x+route.rect.w/2,route.rect.y+route.rect.h/2,2)).ok);
 await expectSessions(0);
 let activeTab=0;
 for(const count of [1,2]){
  assert((await h.clickAt(x,y,2)).ok);
  await expectSessions(count);
  const snapshot=await state();
  const nextTab=snapshot.windows[0].active_tab;
  assert(nextTab>0&&nextTab!==activeTab,'double-click activates the new tab');
  activeTab=nextTab;
 }
 assert((await h.screenshot(join(out,'double-click-connection.png'))).ok);
 await h.mouseMove(row.rect.x+20,row.rect.y+18);
 await visible('sidebar.host.connect');assert((await h.clickTestId('sidebar.host.connect')).ok);
 await expectSessions(3);
 await writeFile(join(out,'report.json'),JSON.stringify({status:'passed',checks:['a single row click and a double-click on the route marker create no session','each row double-click creates one new Tab and opens one loopback transport','the connect button still creates one Tab and opens one loopback transport']},null,2));
 console.log('passed: '+out);
}finally{
 server.close();
 for(const socket of sockets)socket.destroy();
 if(app.exitCode===null&&app.signalCode===null){
  await h.request('POST','/zerowork/windows',{action:'quit'}).catch(()=>{});
  await Promise.race([ended,h.sleep(5000)]);
  if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');
 }
 await ended;await log.close();await rm(base,{recursive:true,force:true});
}
