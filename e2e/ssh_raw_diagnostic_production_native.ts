/** Full application: real loopback SSH failure -> actual controller journal -> hovered UI row. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {mkdtemp,mkdir,writeFile,open,rm,readFile,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';
const executable=resolve(process.argv[2]??'/tmp/zerowork-ssh-hover-production/bin/zerowork');
const out=resolve(process.argv[3]??'artifacts/ssh-raw-diagnostic/production');
await mkdir(out,{recursive:true});
const temp=await realpath(await mkdtemp(join(tmpdir(),'zw-ssh-hover-production-')));
const data=join(temp,'data'),rpc=join(temp,'rpc');await mkdir(data);await mkdir(rpc);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
let connections=0,clientBanners=0;
const peers=new Set<any>();
const server=createServer(socket=>{connections++;peers.add(socket);socket.once('data',bytes=>{assert(bytes.toString().startsWith('SSH-2.0-'));clientBanners++;socket.end();});socket.on('error',()=>{});socket.on('close',()=>peers.delete(socket));});
await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));const port=(server.address() as any).port;
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="SSH 日志验证"\nhost="127.0.0.1"\nport=${port}\nuser="fixture"\n`);
await writeFile(join(data,'config.toml'),'[ui]\ntheme="dark"\n[ssh]\nconnect_timeout_sec=8\n');
const log=await open(join(out,'app.log'),'w');
const app=spawn(executable,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>.9&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
const report:any={status:'running',entry:'src/main.zig',executable,checks:[],connections:0};
try{
 await h.waitForServerReady();
 assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1280,800);
 await visible('workspace.titlebar');await visible('sidebar.host');
 await h.clickTestId('sidebar.host');
 await h.waitFor(async()=>text(await visible('connection.progress.state'))==='连接失败'||null,30000);
 assert(clientBanners>0,'actual libssh2 client sent its SSH identification');
 assert.equal((await h.query('connection.progress.logs.raw')).length,0,'no separate raw-log button in main application');
 await h.clickTestId('connection.progress.logs.toggle');await h.sleep(250);
 for(const [width,height] of [[1280,800],[860,480]]){
  await h.resizeWindow(width,height);await h.sleep(250);
  const well=await visible('connection.progress.logs');
  const failures=(await h.query('connection.progress.logs.failure')).filter(shown);
  assert(failures.length>0,'controller delivered original handshake diagnostics to production UI');
  const row=failures.find((n:any)=>n.rect.y>=well.rect.y&&n.rect.y+8<well.rect.y+well.rect.h);
  assert(row,'one failed row is within the real scroll viewport');
  await h.mouseMove(row.rect.x+40,row.rect.y+8);
  const bubble=await visible('connection.progress.logs.raw-popover');
  const raw=text(await visible('connection.progress.logs.raw-text'));
  assert(raw.includes('handshake transport host=127.0.0.1:')&&raw.includes('rc='));
  assert(/\d{2}:\d{2}:\d{2}\.\d{3} - handshake/.test(raw));
  assert(bubble.rect.x>=0&&bubble.rect.y>=0&&bubble.rect.x+bubble.rect.w<=width+1&&bubble.rect.y+bubble.rect.h<=height+1);
  assert((await h.screenshot(join(out,`main-app-${width}.png`))).ok);
  await writeFile(join(out,`main-app-${width}.json`),JSON.stringify({progress:await h.query('connection.progress'),raw:await h.query('connection.progress.logs.raw-text'),bubble:await h.query('connection.progress.logs.raw-popover')},null,2));
  await h.mouseMove(20,80);await absent('connection.progress.logs.raw-popover');
 }
 report.connections=connections;report.clientBanners=clientBanners;
 report.checks=['real libssh2 handshake failure through full production controller','failure-row hover displays native raw diagnostic','no separate raw-log button','timestamp-message-duration retained','main app 1280/860 screenshot and viewport bounds','pointer leave closes popup'];
 report.status='passed';console.log('PASS: full ZeroWork main application, real SSH failure, row-hover raw log');
}catch(error){report.status='failed';report.error=String(error);await h.screenshot(join(out,'failure.png')).catch(()=>{});throw error;}
finally{
 if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;
 for(const socket of peers)socket.destroy();await new Promise<void>(r=>server.close(()=>r()));
 await log.close();await writeFile(join(out,'result.json'),JSON.stringify(report,null,2));await rm(temp,{recursive:true,force:true});
}
