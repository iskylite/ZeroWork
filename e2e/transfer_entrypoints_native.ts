/** Real loopback SFTP: ticker rotation, read badges and shared top-right list.
 * --live-transfers enqueues actual uploads; --foreground also checks passive
 * ticker acknowledgement in an activated, disposable application window.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,realpath} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,mouseMove,dragAt,key,type_,resizeWindow,screenshot,sleep,request} from '../zig-out/share/zenit/harness/client.ts';
const live=process.argv.includes('--live-transfers'),foreground=process.argv.includes('--foreground');assert(!foreground||live);
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-transfer-entrypoints-')),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(data);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w'),peerLog=await open(join(out,'peer.log'),'w'),peerOut=join(out,'peer');
const peer=spawn(process.env.ZW_TEST_PYTHON??'python3',[live?'e2e/sftp_v3_peer.py':'e2e/builtin_records_ssh_peer.py','--out',peerOut],{stdio:['ignore',peerLog.fd,peerLog.fd]});const peerEnd=new Promise(r=>peer.once('close',r));
let app:any,appEnd:Promise<any>;const report:any={checks:[],isolated:iso,live_transfers:live,foreground,binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),samples:[]};
const shown=(n:any)=>n?.rect?.w>0&&n.rect.h>0&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0;
const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join(' ').trim();
const visible=(id:string)=>waitFor(async()=>{assert(!app||app.exitCode===null&&app.signalCode===null,'Owned application remains alive');return(await query(id)).find(shown)??null},15000);
const hidden=(id:string)=>waitFor(async()=>!(await query(id)).some(shown)||null,5000);
const badgeCount=async()=>{const badge=(await query('toolbar.transfers.badge')).find(shown);return badge?Number(text(badge)):0};
async function expectBadge(count:number){await waitFor(async()=>await badgeCount()===count||null,6000)}
async function click(id:string){const n=await visible(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)}
async function capture(name:string){assert((await screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(Object.fromEntries(await Promise.all(['toolbar.transfers','toolbar.transfers.badge','status.transfer','transfer.manager','transfer.session','connection.progress'].map(async id=>[id,await query(id)]))),null,2))}
const payloads=new Map<string,Buffer>();
async function enqueue(name:string,size=1024*1024){
 const path=join(iso,name),payload=Buffer.alloc(size,37+payloads.size);payloads.set(name,payload);await writeFile(path,payload);
 const remote=await visible('files.remote'),x=remote.rect.x+remote.rect.w/2,y=remote.rect.y+remote.rect.h-65;
 await dragAt(x,y,0);await dragAt(x,y,3,'file://'+encodeURI(path));await visible('files.copy.confirmation');await click('files.copy.submit');await hidden('files.copy.confirmation');
}
try{
 const ready=await waitFor(async()=>{assert(peer.exitCode===null&&peer.signalCode===null,'Owned peer remains alive');try{return JSON.parse(await readFile(join(peerOut,'ready.json'),'utf8'))}catch{return null}},15000);
 await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="${live?'sftp':'ssh'}"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Owned transfer fixture"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
 if(ready.known_host)await writeFile(join(data,'known_hosts'),ready.known_host);
 await writeFile(join(data,'config.toml'),'[ui]\ntheme="dark"\n[transfer]\ndedicated_connection=true\nwindow_chunks=1\nchunk_kb=32\nmax_tasks=1\nresume=true\nverify_md5=false\n');
 app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:foreground?'0':'1',ZENIT_E2E_REAL_ACTIVATION:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});appEnd=new Promise(r=>app.once('close',r));report.pid=app.pid;
 await waitForServerReady();await resizeWindow(1440,900);const host=await visible('sidebar.host');await clickAt(host.rect.x+host.rect.w/2,host.rect.y+host.rect.h/2);await click('sidebar.host.connect');
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

 await hidden('toolbar.transfers.badge');
 if(live){await enqueue('first.bin');await enqueue('second.bin');if(!foreground)await expectBadge(2)}
 const ticker=await visible('status.transfer');await mouseMove(ticker.rect.x+ticker.rect.w/2,ticker.rect.y+ticker.rect.h/2);await sleep(650);
 await hidden('transfer.manager');assert.equal((await query('transfer.session')).length,0);report.checks.push('Hover keeps lists closed; old bottom popover is absent');
 if(live){
  const changes:any[]=[];for(let i=0;i<24;i++){
   const ids=['status.transfer.name','status.transfer.percent','status.transfer.speed','status.transfer.counts'];const values=Object.fromEntries(await Promise.all(ids.map(async id=>[id,text((await query(id)).find(shown))])));
   const sample={at:Date.now(),name:values[ids[0]],percent:values[ids[1]],speed:values[ids[2]],count:values[ids[3]],badge:await badgeCount()};report.samples.push(sample);
   assert.equal(sample.count,'2');assert(['first.bin','second.bin'].includes(sample.name));
   if(sample.name!==changes.at(-1)?.name)changes.push(sample);
   await sleep(300);
  }
  assert(new Set(changes.map(s=>s.name)).size===2,'Both actual tasks rotate');
  const intervals=changes.slice(2).map((s,i)=>s.at-changes[i+1].at);assert(intervals.length>0);for(const interval of intervals)assert(interval>=2300&&interval<=3800,'Three-second rotation cadence: '+interval);report.rotation_intervals_ms=intervals;
  assert(report.samples.some(s=>/[1-9]/.test(s.percent)),'Real upload progress is visible');
  assert(report.samples.some(s=>/[1-9].*[KM]?i?B\/s/.test(s.speed)),'Real upload speed is visible');
  if(foreground){await expectBadge(0);report.native_activation=await request('GET','/zerowork/menu-bar');assert.equal(report.native_activation.foreground,true,'Native app actually gained foreground');report.checks.push('Foreground ticker shows both actual tasks and clears their badges without opening any list')}
  else {await expectBadge(2);report.checks.push('Background rotation leaves both unseen tasks badged until the list is viewed')}
  report.checks.push('Two real transfers rotate at three-second intervals with current progress, speed and task count');
 }
 await capture('ticker');
 const bottom=await visible('status.transfer');await clickAt(bottom.rect.x+2,bottom.rect.y+bottom.rect.h/2);const fromBottom=await visible('transfer.manager');await expectBadge(0);await capture('bottom-open');
 assert.equal((await query('transfer.manager')).filter(shown).length,1);const toolbar=await visible('toolbar.transfers');assert(fromBottom.rect.y>toolbar.rect.y&&fromBottom.rect.y<toolbar.rect.y+toolbar.rect.h+40,'List anchors below the top-right toolbar');
 await key('escape');await hidden('transfer.manager');await sleep(1000);await expectBadge(0);
 await click('toolbar.transfers');const fromTop=await visible('transfer.manager');assert.deepEqual(fromTop.rect,fromBottom.rect);await click('toolbar.transfers');await hidden('transfer.manager');
 report.checks.push('Whole bottom control and toolbar open the same top-right global list; Escape and either trigger close it');
 if(live&&!foreground){
  await enqueue('third.bin',65536);await expectBadge(1);await capture('new-task-badge');await click('toolbar.transfers');await expectBadge(0);await click('transfer.window.close');await hidden('transfer.manager');await sleep(1000);await expectBadge(0);
  report.checks.push('Viewing via bottom clears badge 2; a subsequent new task restores badge 1; viewing via toolbar clears it again and closing never restores it');
 }
 await resizeWindow(860,480);await click('status.transfer');await visible('transfer.manager');await capture('compact');await click('transfer.window.close');await hidden('transfer.manager');report.checks.push('Compact window opens and closes the same populated list');
 if(live){
  const state=await waitFor(async()=>{try{const state=JSON.parse(await readFile(join(peerOut,'state.json'),'utf8'));return [...payloads].every(([name,payload])=>state.files['/fixture/'+name]?.bytes===payload.length&&state.files['/fixture/'+name]?.sha256===createHash('sha256').update(payload).digest('hex'))?state:null}catch{return null}},90000);
  report.files=[...payloads].map(([name,payload])=>({name,bytes:payload.length,sha256:state.files['/fixture/'+name].sha256}));
  await click('toolbar.transfers');await waitFor(async()=>{const states=flat(await visible('transfer.manager')).filter(n=>n.test_id==='transfer.task.status'&&shown(n));return states.filter(s=>text(s).includes('已完成')).length===payloads.size||null},10000);await capture('completed');await click('transfer.window.close');await hidden('transfer.manager');await sleep(1000);await expectBadge(0);
  report.checks.push('Every real upload completed with matching peer SHA-256; completed tasks do not restore cleared badges');
 }
 assert((await request('POST','/zerowork/windows',{action:'quit'})).ok);await Promise.race([appEnd,sleep(10000)]);assert.equal(app.exitCode,0,'Normal Quit exits cleanly');report.checks.push('Normal application Quit returned exit code 0');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;if(app&&app.exitCode===null&&app.signalCode===null)await capture('failure').catch(()=>{})}
finally{if(app&&app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await appEnd!}if(peer.exitCode===null&&peer.signalCode===null){peer.kill('SIGTERM');await peerEnd}await log.close();await peerLog.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,foreground,checks:report.checks,error:report.error,out}))}
