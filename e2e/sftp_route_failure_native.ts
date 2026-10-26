/** Production saved-route SFTP rejection must be visible before a tab exists.
 * Endpoints use reserved invalid names: the supported failure occurs before network I/O.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,copyFile,open,rm,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {query,clickAt,resizeWindow,screenshot,waitFor,waitForServerReady,sleep} from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.env.ZW_ROUTE_BINARY!),out=resolve(process.argv[2]??'/tmp/zw-sftp-route-failure');
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-route-rejection-')));
const data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);await mkdir(out,{recursive:true});
const executable=join(iso,'zerowork');await copyFile(binary,executable);await copyFile(join(binary,'..','zw_ipc.so'),join(iso,'zw_ipc.so'));
await writeFile(join(data,'hosts.toml'),`[registry]
schema_version=2
revision=1
next_connection_id=3
next_group_id=1
[[hosts]]
connection_id=1
revision=1
protocol="ssh"
auth_mode="password"
name="Fixture jump"
host="jump.invalid"
port=22
user="fixture"
[[hosts]]
connection_id=2
revision=1
protocol="sftp"
auth_mode="password"
name="Route SFTP rejection"
host="target.invalid"
port=22
user="fixture"
route=[1]
`,{mode:0o600});
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const env={...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'};
const log=await open(join(out,'app.log'),'w'),app=spawn(executable,[],{cwd:process.cwd(),env,stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(r=>app.once('close',()=>r()));
const report:any={status:'running',binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],screenshots:[]};
const shown=(n:any)=>n?.rect&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const flat=(n:any):any[]=>shown(n)?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(x=>x.text??'').join('\n');
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await resizeWindow(1440,900);
 const row=await waitFor(async()=>(await query('sidebar.host')).find(n=>shown(n)&&text(n).includes('Route SFTP rejection'))??null,15000);
 assert((await clickAt(row.rect.x+row.rect.w/2,row.rect.y+row.rect.h/2)).ok);
 const notice=await waitFor(async()=>(await query('notifications.presenter')).find(n=>shown(n)&&text(n).includes('独立 SFTP 会话暂不支持跳板链'))??null,15000);
 assert(text(notice).includes('ProxyJumpTransportUnavailable'));
 assert(!(await query('files.workspace')).some(shown));assert(!(await query('plugin.challenge.title')).some(shown));
 report.checks.push('Production saved SFTP route rejected visibly without a file tab or network authentication; explicit unsupported-route reason');
 for(const [w,h]of[[1440,900],[860,480]]){await resizeWindow(w,h);const nodes=await query('notifications.presenter');await writeFile(join(out,`error-${w}.json`),JSON.stringify(nodes,null,2));assert((await screenshot(join(out,`error-${w}.png`))).ok);report.screenshots.push(`error-${w}.png`);}
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);try{await writeFile(join(out,'failure-tree.json'),JSON.stringify(await query('sidebar.host'),null,2));await screenshot(join(out,'failure.png'));}catch{}}
finally{app.kill('SIGTERM');await Promise.race([ended,sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}await log.close();await rm(iso,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));}
if(report.status!=='passed')process.exitCode=1;
