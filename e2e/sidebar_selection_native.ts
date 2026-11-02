/** Product wiring regression: selecting a saved host must never create a session. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
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
const server=createServer(socket=>{connections++;socket.end();});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),'[updates]\nauto_check=false\n[ssh]\nreconnect_max=0\nconnect_timeout_sec=2\n');
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="Selection only"\nhost="127.0.0.1"\nport=${port}\nuser="fixture"\n`);
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(resolve=>app.once('close',resolve));
const shown=(n:any)=>n.visible!==false&&n.rect.w>0&&n.rect.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null);
const tabs=async()=>(await h.query('tabs.strip')).flatMap(function flat(n:any):any[]{return [n,...(n.children??[]).flatMap(flat)];}).filter((n:any)=>/^tabs\.tab\.\d+$/.test(n.test_id??'')&&shown(n));
try{
 await h.waitForServerReady();await h.resizeWindow(1000,700);
 const name=await visible('sidebar.host.name');
 for(const count of [1,2,1]){
  assert((await h.clickAt(name.rect.x+10,name.rect.y+name.rect.h/2,count)).ok);
  await h.sleep(250);
  assert.equal((await tabs()).length,0,'row selection must not create a Tab');
  assert.equal(connections,0,'row selection must not open a transport');
 }
 await h.screenshot(join(out,'selected-without-connection.png'));
 const row=await visible('sidebar.host');await h.mouseMove(row.rect.x+20,row.rect.y+18);
 await visible('sidebar.host.connect');assert((await h.clickTestId('sidebar.host.connect')).ok);
 await h.waitFor(async()=>connections>0&&(await tabs()).length===1||null);
 await h.screenshot(join(out,'explicit-connection.png'));
 await writeFile(join(out,'report.json'),JSON.stringify({status:'passed',checks:['single/repeated/double row clicks create no Tab and no TCP connection','explicit connect button creates one Tab and opens loopback transport']},null,2));
 console.log('passed: '+out);
}finally{
 if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');
 await ended;server.close();await log.close();await rm(base,{recursive:true,force:true});
}
