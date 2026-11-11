/** Real loopback SFTP: global progress ring and the top-right transfer list.
 * Always uploads real files; --live-transfers remains accepted for existing commands.
 * --foreground verifies the same controls in an activated disposable window.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,realpath} from 'node:fs/promises';
import {dirname,resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
const live=true,foreground=process.argv.includes('--foreground');
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);await mkdir(out,{recursive:true});
const {waitForServerReady,waitFor,query,clickAt,focused,mouseMove,dragAt,key,type_,resizeWindow,screenshot,sleep,request}=await import(pathToFileURL(resolve(dirname(binary),'../share/zenit/harness/client.ts')).href);
const iso=await realpath(await mkdtemp('/tmp/zw-transfer-entrypoints-')),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(data);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w'),peerLog=await open(join(out,'peer.log'),'w'),peerOut=join(out,'peer');
const peer=spawn(process.env.ZW_TEST_PYTHON??'python3',[live?'e2e/sftp_v3_peer.py':'e2e/builtin_records_ssh_peer.py','--out',peerOut],{stdio:['ignore',peerLog.fd,peerLog.fd]});const peerEnd=new Promise(r=>peer.once('close',r));
let app:any,appEnd:Promise<any>;const report:any={checks:[],isolated:iso,live_transfers:live,foreground,binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),samples:[]};
const shown=(n:any)=>n?.rect?.w>0&&n.rect.h>0&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0;
const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join(' ').trim();
const visible=(id:string)=>waitFor(async()=>{assert(!app||app.exitCode===null&&app.signalCode===null,'Owned application remains alive');return(await query(id)).find(shown)??null},15000);
const hidden=(id:string)=>waitFor(async()=>!(await query(id)).some(shown)||null,5000);
const tabs=async()=>flat(await visible('tabs.strip')).filter(n=>shown(n)&&/^tabs\.tab\.\d+$/.test(n.test_id??''));
const progressText=async()=>text((await query('toolbar.transfers.percent')).find(shown));
async function progressGeometry(){
 const button=await visible('toolbar.transfers');
 for(const id of ['toolbar.transfers.progress','toolbar.transfers.percent']){const n=await visible(id);assert(n.rect.x>=button.rect.x&&n.rect.y>=button.rect.y&&n.rect.x+n.rect.w<=button.rect.x+button.rect.w+.5&&n.rect.y+n.rect.h<=button.rect.y+button.rect.h+.5,id+' stays inside its trigger')}
}
async function click(id:string){const n=await visible(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)}
async function capture(name:string){assert((await screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(Object.fromEntries(await Promise.all(['toolbar.transfers','toolbar.transfers.progress','toolbar.transfers.percent','toolbar.transfers.badge','transfer.manager','connection.progress','files.copy.overlay','transfer.conflict.overlay'].map(async id=>[id,await query(id)]))),null,2))}
const payloads=new Map<string,Buffer>();
async function enqueue(name:string,size=1024*1024){
 const path=join(iso,name),payload=Buffer.alloc(size,37+payloads.size);payloads.set(name,payload);await writeFile(path,payload);
 const remote=await visible('files.remote'),x=remote.rect.x+remote.rect.w/2,y=remote.rect.y+remote.rect.h-65;
 await dragAt(x,y,0);await dragAt(x,y,3,'file://'+encodeURI(path));await visible('files.copy.confirmation');
 if(payloads.size===1){
  const overlay=await visible('files.copy.overlay');
  for(const edge of ['x','y','w','h'])assert(Math.abs(overlay.rect[edge]-remote.rect[edge])<=1,`File copy backdrop follows destination pane ${edge}`);
  await click('toolbar.transfers');await visible('transfer.manager');await visible('files.copy.confirmation');
  await click('toolbar.transfers');await hidden('transfer.manager');
  await capture('file-confirmation-scope');
  report.checks.push('File copy backdrop matches the remote pane, and the toolbar transfer list remains interactive');
 }
 await click('files.copy.submit');await hidden('files.copy.confirmation');
}
try{
 const ready=await waitFor(async()=>{assert(peer.exitCode===null&&peer.signalCode===null,'Owned peer remains alive');try{return JSON.parse(await readFile(join(peerOut,'ready.json'),'utf8'))}catch{return null}},15000);
 await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="${live?'sftp':'ssh'}"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Owned transfer fixture"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
 if(ready.known_host)await writeFile(join(data,'known_hosts'),ready.known_host);
 await writeFile(join(data,'config.toml'),'[ui]\ntheme="dark"\n[transfer]\ndedicated_connection=true\nwindow_chunks=1\nchunk_kb=32\nmax_tasks=1\nresume=true\nverify_md5=false\n');
 app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:foreground?'0':'1',ZENIT_E2E_REAL_ACTIVATION:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});appEnd=new Promise(r=>app.once('close',r));report.pid=app.pid;
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 if(foreground){const windows=await request('GET','/zerowork/windows');assert.equal(windows.windows.length,1);assert((await request('POST','/zerowork/windows',{action:'select',window:windows.windows[0].window})).ok);await waitFor(async()=>(await request('GET','/zerowork/menu-bar')).foreground||null,10000)}
 await resizeWindow(1440,900);
 await click('workspace.empty.local');await visible('terminal.surface');
 const localTab=(await tabs())[0].test_id;
 const host=await visible('sidebar.host');await clickAt(host.rect.x+host.rect.w/2,host.rect.y+host.rect.h/2);await click('sidebar.host.connect');
 await waitFor(async()=>{
  assert(app.exitCode===null&&app.signalCode===null,'SFTP connection progress must not crash');
  if((await query(live?'files.workspace':'terminal.surface')).some(shown))return true;
  const title=(await query('plugin.challenge.title')).find(shown);if(title){
   if(text(title).includes('核对主机密钥')){assert(text(await visible('plugin.challenge.material')).includes(ready.fingerprint));await click('plugin.challenge.choice.0')}
   else if(text(title).includes('SSH 密码认证')){const input=(await query('plugin.challenge.answer.0')).find(shown)??await visible('plugin.challenge.secret');await clickAt(input.rect.x+10,input.rect.y+10);await type_(ready.password);await click('plugin.challenge.submit')}
   else throw Error('Unexpected authentication challenge: '+text(title));
  }return null;
 },30000);
 await hidden('connection.progress');report.checks.push('Real SFTP connects through production progress/authentication UI without crashing');
 if(live){
  const edit=flat(await visible('files.local')).find(n=>n.test_id==='files.path.edit'&&shown(n));assert(edit);await clickAt(edit.rect.x+edit.rect.w/2,edit.rect.y+edit.rect.h/2);
  const field=flat(await visible('files.local')).find(n=>n.test_id==='files.path'&&shown(n));assert(field);await clickAt(field.rect.x+10,field.rect.y+field.rect.h/2);await key('a',{cmd:true});await type_(iso);await key('return');
 }


 await hidden('toolbar.transfers.badge');await hidden('toolbar.transfers.progress');
 await enqueue('first.bin');
 const firstPercent=await waitFor(async()=>{const value=await progressText();return /^\d+%$/.test(value)&&Number(value.slice(0,-1))>0?value:null},15000);
 await progressGeometry();await capture('known-progress');
 await enqueue('second.bin');
 await waitFor(async()=>await progressText()==='·'||null,15000);
 await progressGeometry();await hidden('toolbar.transfers.badge');
 const trigger=await visible('toolbar.transfers');await mouseMove(trigger.rect.x+trigger.rect.w/2,trigger.rect.y+trigger.rect.h/2);await sleep(650);
 await hidden('transfer.manager');assert.equal((await query('transfer.session')).length,0);
 for(let i=0;i<8;i++){
  const value=await progressText();assert(value==='·'||/^\d+%$/.test(value));
  report.samples.push({at:Date.now(),progress:value});await hidden('toolbar.transfers.badge');await sleep(250);
 }
 report.first_percent=firstPercent;
 report.checks.push('A single known-size upload shows percent; a queued unknown-size task uses an indeterminate ring; both fit the trigger without a numeric badge');
 report.checks.push('Hover keeps the global transfer list closed');
 if(foreground){report.native_activation=await request('GET','/zerowork/menu-bar');assert.equal(report.native_activation.foreground,true,'Native app actually gained foreground')}
 await capture('queued-progress');
 await click('toolbar.transfers');const fromTop=await visible('transfer.manager');await capture('toolbar-open');
 assert.equal((await query('transfer.manager')).filter(shown).length,1);
 assert(fromTop.rect.y>=trigger.rect.y+trigger.rect.h-1&&fromTop.rect.x>=0&&fromTop.rect.x+fromTop.rect.w<=1440.5,'List anchors below the toolbar and remains in the window');
 await key('escape');await hidden('transfer.manager');
 await click('toolbar.transfers');await visible('transfer.manager');await click('toolbar.transfers');await hidden('transfer.manager');
 await enqueue('third.bin',65536);await hidden('toolbar.transfers.badge');
 await click('toolbar.transfers');await visible('transfer.manager');
 await resizeWindow(860,480);const compact=await visible('transfer.manager');
 assert(compact.rect.x>=0&&compact.rect.y>=0&&compact.rect.x+compact.rect.w<=860.5&&compact.rect.y+compact.rect.h<=480.5,'Compact transfer list remains within the content area');
 await capture('compact');await click('transfer.window.close');await hidden('transfer.manager');
 report.checks.push('Toolbar toggle, Escape and close button work; the populated list remains bounded at 860x480');
 await resizeWindow(1440,900);
 const state=await waitFor(async()=>{try{const state=JSON.parse(await readFile(join(peerOut,'state.json'),'utf8'));return [...payloads].every(([name,payload])=>state.files['/fixture/'+name]?.bytes===payload.length&&state.files['/fixture/'+name]?.sha256===createHash('sha256').update(payload).digest('hex'))?state:null}catch{return null}},90000);
 report.files=[...payloads].map(([name,payload])=>({name,bytes:payload.length,sha256:state.files['/fixture/'+name].sha256}));
 await click('toolbar.transfers');await waitFor(async()=>{const states=flat(await visible('transfer.manager')).filter(n=>n.test_id==='transfer.task.status'&&shown(n));return states.filter(s=>text(s).includes('已完成')).length===payloads.size||null},10000);
 await capture('completed');await click('transfer.window.close');await hidden('transfer.manager');await hidden('toolbar.transfers.progress');await hidden('toolbar.transfers.percent');await hidden('toolbar.transfers.badge');
 report.checks.push('Every upload completed with matching peer SHA-256; viewed completion returns the toolbar to its idle icon');
 const fileTab=(await tabs()).find(n=>n.test_id!==localTab)?.test_id;assert(fileTab);
 await enqueue('README.md',512);await visible('transfer.conflict');
 const conflictOverlay=await visible('transfer.conflict.overlay'),remoteColumn=await visible('files.column.remote');
 for(const edge of ['x','y','w','h'])assert(Math.abs(conflictOverlay.rect[edge]-remoteColumn.rect[edge])<=1,`Upload conflict backdrop follows the target column ${edge}`);
 const localFilter=flat(await visible('files.local')).find(n=>shown(n)&&n.test_id==='files.filter');assert(localFilter);
 await clickAt(localFilter.rect.x+20,localFilter.rect.y+localFilter.rect.h/2);
 await waitFor(async()=>(await focused()).id===localFilter.id||null,5000);await visible('transfer.conflict');
 await click(localTab);await visible('terminal.surface');await hidden('transfer.conflict.overlay');
 await click(fileTab);await visible('transfer.conflict');
 await capture('original-conflict-scope');
 await click('transfer.conflict.skip');await click('transfer.conflict.apply');await hidden('transfer.conflict');
 report.checks.push('A real SFTP conflict leaves the sibling file column interactive, suspends on the local terminal tab, and resumes for the original task');
 assert((await request('POST','/zerowork/windows',{action:'quit'})).ok);
 const quit=await Promise.race([appEnd.then(()=>false),waitFor(async()=>(await query('local.close.accept')).some(shown)||null,10000)]);
 if(quit)await click('local.close.accept');
 await Promise.race([appEnd,sleep(10000)]);assert.equal(app.exitCode,0,'Normal Quit exits cleanly');report.checks.push('Normal application Quit returned exit code 0');report.status='passed';
}catch(e){report.status='failed';report.error=e instanceof Error?e.stack:String(e);process.exitCode=1;if(app&&app.exitCode===null&&app.signalCode===null)await capture('failure').catch(()=>{})}
finally{if(app&&app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await appEnd!}if(peer.exitCode===null&&peer.signalCode===null){peer.kill('SIGTERM');await peerEnd}await log.close();await peerLog.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,foreground,checks:report.checks,error:report.error,out}))}
