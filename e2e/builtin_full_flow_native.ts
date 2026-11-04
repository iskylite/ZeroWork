/** Actual application + SSH PTY/SFTP. CUA operates only the real AppKit chooser.
 * Raise the native chooser before Open/Escape; stage.txt identifies each step.
 * The app and SSH peer always use disposable data, ports, and directories.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,realpath,copyFile,readFile,writeFile,open,readdir,rm} from 'node:fs/promises';
import {join,resolve,dirname} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);await mkdir(out,{recursive:false});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-builtin-full-'))),rpc=join(iso,'rpc'),data=join(iso,'data'),download=join(out,'downloads'),remote=join(out,'remote');
await Promise.all([mkdir(rpc),mkdir(data),mkdir(download)]);
const peerLog=await open(join(out,'peer.log'),'w');
const peer=spawn(process.env.ZW_TEST_PYTHON||'python3',['e2e/builtin_records_ssh_peer.py','--out',join(out,'peer'),'--sftp-root',remote,'--allow-path-completion',...(process.env.ZW_TEST_BASH==='1'?['--plain-bash']:[])],{stdio:['ignore',peerLog.fd,peerLog.fd]});
const peerEnd=new Promise(r=>peer.once('close',r));
const ready=await h.waitFor(async()=>{try{return JSON.parse(await readFile(join(out,'peer','ready.json'),'utf8'))}catch{return null}},15000);
await mkdir(join(remote,'sub'));const payload=Buffer.alloc(6*1024*1024);for(let i=0;i<payload.length;i++)payload[i]=(i*29+17)%251;
await writeFile(join(remote,'sub','payload 中文.bin'),payload);await writeFile(join(remote,'sub','path-one.txt'),'one');await writeFile(join(remote,'sub','path-two.txt'),'two');
await writeFile(join(out,'local-file.txt'),'local-completion');await mkdir(join(remote,'sub','only-dir'));await writeFile(join(remote,'sub','only-dir','nested.bin'),'nested');
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[transfer]\ndedicated_connection=false\nshared_pacing_kbps=512\ndownload_dir="${download}"\n`);
await writeFile(join(data,'known_hosts'),ready.known_host);
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Owned full flow"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
const bundle=join(out,'Builtin-Full-Flow.app'),mac=join(bundle,'Contents','MacOS');await mkdir(mac,{recursive:true});
await writeFile(join(bundle,'Contents','Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>local.zerowork.fullflow.${process.pid}</string><key>CFBundleName</key><string>Builtin Full Flow</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string></dict></plist>`);
await copyFile(binary,join(mac,'zerowork'));for(const name of ['zw_ipc.so','zw_execution.so','zw_execution_guard','zw_secret_consume.so'])await copyFile(join(dirname(binary),name),join(mac,name));
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');
const app=spawn(join(mac,'zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'0',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const appEnd=new Promise(r=>app.once('close',r));
const report:any={passed:false,pid:app.pid,bundle,rpc,out,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],captures:[],shell:process.env.ZW_TEST_BASH==='1'?'bash without OSC 133':'zsh with OSC 133',transfer:{dedicated_connection:false,pacing_kbps:512,payload_bytes:payload.length,source:join(remote,'sub','payload 中文.bin'),destination:join(download,'payload 中文.bin'),source_sha256:createHash('sha256').update(payload).digest('hex')}};
await writeFile(join(out,'session.json'),JSON.stringify(report,null,2));
const shown=(n:any)=>n&&n.rect?.w>0&&n.rect.h>0&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');
const visible=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)||null,12000);
async function click(id:string){
 let n:any;
 if(id==='transfer.window.close'){
  const panels=[...(await h.query('transfer.manager')),...(await h.query('transfer.session'))].filter(shown);
  function find(node:any):any{return node.test_id===id?node:(node.children??[]).map(find).find(Boolean)}
  n=panels.map(find).find(shown);
 }
 n??=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)
}
async function type(s:string){assert((await h.type_(s)).ok)}
async function key(s:string,mods?:any){assert((await h.key(s,mods)).ok)}
async function draft(){return (await h.query('terminal.command.input')).filter(shown).map(text).join('')}
async function expectDraft(s:string){await h.waitFor(async()=>(await draft())===s||null,10000)}
async function outputs(){return (await h.query('terminal.command.output')).filter(shown).map(text).join('\n').replaceAll('✓','')}
async function capture(name:string){assert((await h.screenshot(join(out,name+'.png'))).ok);const tree:any={};for(const id of ['terminal.command.input','terminal.command.record','terminal.command.output','terminal.surface','transfer.manager','transfer.task.status','transfer.task.rate','transfer.window.close','transfer.task.hover_detail','status.transfer.percent','status.transfer.speed'])tree[id]=await h.query(id);await writeFile(join(out,name+'.json'),JSON.stringify(tree,null,2));report.captures.push(name)}
function check(name:string){report.checks.push(name);console.log(name)}
async function begin(name:string){await type('@');await visible('terminal.commands');await type(name);await key('tab');await h.waitFor(async()=>(await draft()).startsWith('@'+name)||null);}
async function cancel(){await key('escape');await h.waitFor(async()=>(await draft())===''||null)}
async function shell(s:string,marker:string){await type(s);await key('return');await h.waitFor(async()=>{const bytes=Buffer.concat(await Promise.all((await readdir(join(out,'peer'))).filter(n=>n.startsWith('received-')).map(n=>readFile(join(out,'peer',n)))));return bytes.includes(Buffer.from(marker))||null},30000);await h.sleep(250)}
try{
 await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1280,820);
 const host=await visible('sidebar.host');await h.mouseMove(host.rect.x+host.rect.w-22,host.rect.y+host.rect.h/2);await click('sidebar.host.connect');
 await h.waitFor(async()=>(await h.query('workspace.pane')).some(n=>text(n).includes('sshrecords'))||null,30000);await h.sleep(600);await click('terminal.surface');
 await shell(`cd '${remote}/sub'`,remote+'/sub');
 for(const name of ['up','dl','ai','new','dup','grp','pin','sync','ts','history','log','socks','theme','shell','help','dots']){
  await begin(name);await type(' alpha 中文 tail');const value=await draft();assert(value.endsWith(' alpha 中文 tail'));
  await key('w',{ctrl:true});await expectDraft(value.slice(0,-4));
  await key('a',{ctrl:true});await type('X');await expectDraft('X'+value.slice(0,-4));
  await key('e',{ctrl:true});await type('Y');await key('b',{ctrl:true});await key('d',{ctrl:true});await expectDraft('X'+value.slice(0,-4));
  await key('a',{ctrl:true});await key('f',{ctrl:true});await key('k',{ctrl:true});await expectDraft('X');
  await key('u',{ctrl:true});await expectDraft('');await cancel();
  // Type directly into the initial command palette, without adopting first.
  await type('@'+name+' alpha 中文 tail');await key('w',{ctrl:true});await expectDraft('@'+name+' alpha 中文 ');
  await key('delete',{alt:true});await expectDraft('@'+name+' alpha ');
  await key('h',{ctrl:true});await expectDraft('@'+name+' alpha');
  await key('left',{alt:true});await type('X');await expectDraft('@'+name+' Xalpha');
  await key('right',{alt:true});await type('Y');await expectDraft('@'+name+' XalphaY');
  await key('home');await key('forward_delete');await expectDraft(name+' XalphaY');
  await key('end');await key('delete');await expectDraft(name+' Xalpha');
  await key('c',{ctrl:true});await h.sleep(100);await expectDraft('');check('keyboard:'+name);
 }
 for(const [name,prefix,expected] of [['ts','of','off'],['history','of','off'],['sync','o','on'],['socks','of','off'],['shell','a','attach'],['theme','dar','dark'],['new','Owned','"Owned full flow"'],['grp','lea','leave']]){
  await begin(name);if(!(await draft()).endsWith(' '))await type(' ');await type(prefix);await key('tab');await expectDraft('@'+name+' '+expected);await cancel();check('parameter-tab:'+name);
 }
 await begin('up');await type(' '+out+'/local-fi');await key('tab');await expectDraft('@up "'+out+'/local-file.txt"');await cancel();check('parameter-tab:up-local');
 await type('@dl path-');await key('tab',{shift:true});await expectDraft('@dl "path-two.txt"');await key('tab');await expectDraft('@dl "path-one.txt"');await cancel();check('remote-tab-and-shift-tab-cycle');
 await type('@dl only');await key('tab');await expectDraft('@dl "only-dir/"');await type('nest');await key('tab');await expectDraft('@dl "only-dir/nested.bin"');await cancel();check('remote-tab-descends-directory');
 await type('@dl pay');await key('tab');await expectDraft('@dl "payload 中文.bin"');check('parameter-tab:dl-remote');
 await capture('01-completed-remote-path');
 await writeFile(join(out,'stage.txt'),'choose-download-folder');
 await key('return');
 await h.waitFor(async()=>(outputs()).then(s=>s.includes('已加入下载队列')||null),120000);
 await capture('02-download-started');check('inline-download-queue-result');
 for(let i=0;i<4;i++){
  const marker='DURING_'+i;const receipt=join(remote,'during-'+i);await type(`printf ${marker} > '${receipt}'`);await key('return');await h.waitFor(async()=>{try{return (await readFile(receipt,'utf8'))===marker||null}catch{return null}},5000);
 }
 check('four-shell-commands-during-download');
 await click('toolbar.transfers');await h.waitFor(async()=>(await h.query('transfer.task.rate')).some(n=>shown(n)&&/[1-9]/.test(text(n)))||null,15000);await capture('03-download-live-progress');
 const beforeProgress=JSON.stringify(await h.query('transfer.task.progress'));await h.sleep(600);
 assert.notEqual(JSON.stringify(await h.query('transfer.task.progress')),beforeProgress,'Visible transfer progress changes during download');check('changing-visible-progress-and-nonzero-rate');
 await click('transfer.window.close');await h.waitFor(async()=>!(await h.query('transfer.manager')).some(shown)||null,5000);
 const result=join(download,'payload 中文.bin');await h.waitFor(async()=>{try{return createHash('sha256').update(await readFile(result)).digest('hex')===createHash('sha256').update(payload).digest('hex')||null}catch{return null}},60000);
 report.transfer.destination_sha256=createHash('sha256').update(await readFile(result)).digest('hex');
 for(let i=0;i<3;i++){const file=join(remote,'after-'+i);await type(`printf AFTER_${i} > '${file}'`);await key('return');await h.waitFor(async()=>{try{return (await readFile(file,'utf8'))==='AFTER_'+i||null}catch{return null}},5000)}
 await begin('ts');await type(' on');await key('return');await h.waitFor(async()=>(outputs()).then(s=>s.includes('已开启时间戳')||null));
 await capture('04-download-finished-terminal-responsive');for(const name of ['three-shell-commands-after-download','builtin-after-download','download-sha256-matches'])check(name);
 await click('toolbar.transfers');await visible('transfer.manager');const card=await visible('transfer.task');await h.mouseMove(card.rect.x+100,card.rect.y+12);await h.sleep(650);const detail=await visible('transfer.task.hover_detail');
 await h.mouseMove(detail.rect.x+20,detail.rect.y+20);await h.sleep(300);await visible('transfer.task.hover_detail');await capture('03a-real-task-hover');await h.mouseMove(5,5);await h.waitFor(async()=>!(await h.query('transfer.task.hover_detail')).some(shown)||null,3000);check('real-download-detail-hover-auto-dismisses');
 await click('transfer.window.close');await h.waitFor(async()=>!(await h.query('transfer.manager')).some(shown)||null,5000);
 await click('status.transfer');await visible('transfer.session');await click('transfer.window.close');await h.waitFor(async()=>!(await h.query('transfer.session')).some(shown)||null,5000);
 const trayReceipt=join(remote,'after-tray-close');await type(`printf TRAY_OK > '${trayReceipt}'`);await key('return');await h.waitFor(async()=>{try{return (await readFile(trayReceipt,'utf8'))==='TRAY_OK'||null}catch{return null}},5000);check('session-transfer-close-restores-terminal');
 await click('toolbar.transfers');await visible('transfer.manager');await click('toolbar.transfers');await h.waitFor(async()=>!(await h.query('transfer.manager')).some(shown)||null,5000);
 const toggleReceipt=join(remote,'after-toggle-close');await type(`printf TOGGLE_OK > '${toggleReceipt}'`);await key('return');await h.waitFor(async()=>{try{return (await readFile(toggleReceipt,'utf8'))==='TOGGLE_OK'||null}catch{return null}},5000);check('toolbar-transfer-toggle-close-restores-terminal');
 const audit=Buffer.concat(await Promise.all((await readdir(join(out,'peer'))).filter(n=>n.startsWith('received-')).map(n=>readFile(join(out,'peer',n))))).toString();
 assert(!/@(?:up|dl|ai|new|dup|grp|pin|sync|ts|history|log|socks|theme|shell|help|dots)\b/.test(audit),'Builtin drafts never reach interactive SSH');check('all-builtin-input-stays-local');
 report.passed=true;
}catch(error){report.error=String(error);await capture('failure').catch(()=>{});process.exitCode=1}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));if(app.exitCode===null)app.kill('SIGTERM');await Promise.race([appEnd,h.sleep(2500)]);if(app.exitCode===null)app.kill('SIGKILL');if(peer.exitCode===null)peer.kill('SIGTERM');await Promise.race([peerEnd,h.sleep(2500)]);await log.close();await peerLog.close();console.log(JSON.stringify(report))}
