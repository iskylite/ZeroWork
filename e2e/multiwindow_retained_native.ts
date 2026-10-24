/** Own immutable loopback peer + own isolated native app. Requires root's
 * frozen test binary. Writes only the fresh local test target and fixtures. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFile, mkdir, mkdtemp, open, readFile, realpath, writeFile, rm } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { waitForServerReady, waitFor, query, clickAt, mouseMove, key, type_, request, sleep, screenshot } from '../zig-out/share/zenit/harness/client.ts';
import { exerciseRetainedTransfer, resourceSnapshot, selectResourceWindow } from './multiwindow_tasks_native.ts';
const opts:Record<string,string>={};for(let i=2;i<process.argv.length;i+=2){assert(['--binary','--expected-sha','--out','--python'].includes(process.argv[i])&&process.argv[i+1]);opts[process.argv[i]]=process.argv[i+1]}
assert(opts['--binary']&&opts['--expected-sha']&&opts['--out']);
const output=resolve(opts['--out']);await mkdir(output,{recursive:true});
const isolated=await mkdtemp(join(tmpdir(),'zerowork-multiwindow-retained-')),rpc=join(isolated,'rpc'),data=join(isolated,'data'),target=join(isolated,'downloads');await Promise.all([mkdir(rpc),mkdir(data),mkdir(target)]);
const binary=join(output,'zerowork-frozen');await copyFile(resolve(opts['--binary']),binary);await copyFile(join(dirname(resolve(opts['--binary'])),'zw_ipc.so'),join(output,'zw_ipc.so'));
assert.equal(createHash('sha256').update(await readFile(binary)).digest('hex'),opts['--expected-sha']);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const peerLog=await open(join(output,'peer.log'),'w'),appLog=await open(join(output,'app.log'),'w');
const peerOut=join(output,'peer'),peer=spawn(opts['--python']??'python3',[resolve('e2e/multiwindow_task_peer.py'),'--out',peerOut],{stdio:['ignore',peerLog.fd,peerLog.fd]});
let app:ReturnType<typeof spawn>|undefined;
let appEnded:Promise<void>|undefined;
const peerEnded=new Promise<void>(done=>peer.once('close',()=>done()));
const report:any={status:'running',isolated,output,binary_sha256:opts['--expected-sha'],scope:'Actual retained native checkpoint crosses source-window close and resumes in sibling with identical JobId and SHA256',remote_mutations:false};
const shown=(n:any)=>!!n?.rect&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??n.opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const flat=(n:any):any[]=>shown(n)?[n,...(n.children??[]).flatMap(flat)]:[];
async function clickNode(n:any){assert(shown(n));assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)}
async function click(id:string){report.phase='click-'+id;await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));await clickNode(await waitFor(async()=>(await query(id)).find(shown)??null,20000))}
let ready:any;
async function authenticate(){
 const modal=(await query('auth.challenge.modal')).find((n:any)=>shown(n)&&(n.effective_opacity??n.opacity??1)>.99);if(!modal)return;
 const trust=flat(modal).find(n=>n.test_id==='auth.challenge.trust_once');if(trust?.focusable){const endpoint=flat(modal).find(n=>n.test_id==='auth.challenge.endpoint');assert(flat(endpoint).map(n=>n.text??'').join(' ').includes('127.0.0.1'));await clickNode(trust);return}
 const field=flat(modal).find(n=>n.test_id==='auth.challenge.answer.0');if(field?.focusable){await clickNode(field);await key('a',{cmd:true});await type_(ready.password);await click('auth.challenge.submit')}
}
async function settle(){await waitFor(async()=>{await authenticate();return(await query('files.workspace')).some(shown)||null},90000)}
try{
 ready=await waitFor(async()=>{if(peer.exitCode!==null)throw Error('Owned peer exited');try{return JSON.parse(await readFile(join(peerOut,'ready.json'),'utf8'))}catch(e:any){if(e.code==='ENOENT')return null;throw e}},20000);
 assert.equal(ready.host,'127.0.0.1');
 await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="sftp"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Owned retained peer"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
 await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[transfer]\nchunk_kb=8\nwindow_chunks=3\nmax_tasks=2\nresume=true\nverify_md5=false\nconflict_policy="ask"\n');
 app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZEROWORK_FILE_TRACE:'1',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',appLog.fd,appLog.fd]});
 report.pid=app.pid;
 appEnded=new Promise<void>(done=>app!.once('close',()=>done()));
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 const firstWindow=(await resourceSnapshot()).windows[0].window;
 await click('sidebar.host');await click('sidebar.host.connect');await settle();
 const host=(await query('sidebar.host')).find(shown);assert(host);await mouseMove(host.rect.x+host.rect.w/2,host.rect.y+host.rect.h/2);await sleep(150);await click('sidebar.host.more');await click('context.menu.new_window');
 const second=await waitFor(async()=>{const s=await resourceSnapshot();return s.windows.find((w:any)=>w.window!==firstWindow)??null},20000);await selectResourceWindow(second.window);await settle();
 const result=await exerciseRetainedTransfer({firstWindow,secondWindow:second.window,sourceName:'release.txt',targetDirectory:await realpath(target),expectedSha256:ready.sha256,output,authenticate});
 report.retained=result;
 assert((await request('POST','/zerowork/windows',{action:'quit'})).ok);
 await waitFor(async()=>{await authenticate().catch(()=>{});for(const id of ['groups.close.accept','local.close.accept']){const values=await query(id).catch(()=>[]);const n=Array.isArray(values)?values.find(shown):null;if(n)await clickNode(n)}return app!.exitCode!==null||app!.signalCode!==null||null},60000);
 await appEnded;assert.equal(app.exitCode,0,'Application Quit must complete normally');assert.equal(app.signalCode,null);
 const peerState=await waitFor(async()=>{const state=JSON.parse(await readFile(join(peerOut,'state.json'),'utf8'));return state.active_connections===0?state:null},15000);
 assert.deepEqual(peerState.forbidden_operations,[]);assert.deepEqual([...peerState.read_handles_opened].sort(),[...peerState.read_handles_closed].sort());report.peer_cleanup={active_connections:peerState.active_connections,all_read_handles_closed:true,forbidden_operations:peerState.forbidden_operations,remote_bytes_mutated:peerState.remote_bytes_mutated};
 report.status='passed';report.normal_quit=true;
}catch(error){report.status='failed';report.error=String(error);report.error_stack=(error as Error).stack;process.exitCode=1;if(app&&app.exitCode===null&&app.signalCode===null){await screenshot(join(output,'failure.png')).catch(()=>{});await writeFile(join(output,'failure-sidebar.json'),JSON.stringify(await query('sidebar.host').catch(()=>[]),null,2))}throw error}
finally{
 if(app&&app.exitCode===null&&app.signalCode===null){report.forced_cleanup=true;app.kill('SIGTERM');await Promise.race([appEnded,sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await appEnded}}
 peer.kill('SIGTERM');await Promise.race([peerEnded,sleep(3000)]);if(peer.exitCode===null&&peer.signalCode===null){peer.kill('SIGKILL');await peerEnded}
 await rm(isolated,{recursive:true,force:true});report.cleanup={owned_app_exited:!app||app.exitCode!==null||app.signalCode!==null,owned_peer_exited:peer.exitCode!==null||peer.signalCode!==null,isolated_removed:true,download_fixture_removed:true};
 report.finished_at=new Date().toISOString();await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));await appLog.close();await peerLog.close();
}
