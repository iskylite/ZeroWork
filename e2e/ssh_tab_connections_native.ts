/** Reported connection regressions against an owned loopback SSH + real ZSH PTY. */
import assert from 'node:assert/strict';
import net from 'node:net';
import {spawn,execFileSync} from 'node:child_process';
import {mkdir,mkdtemp,realpath,copyFile,readFile,writeFile,open,readdir,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep,scrollAt,mouseDown,mouseMove,mouseUp,request} from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]),source=resolve(process.argv[3]);await mkdir(out,{recursive:false});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-builtin-records-'))),rpc=join(iso,'rpc'),data=join(iso,'data'),shell=join(iso,'shell');
// Always remove this run's sandbox, including setup and reporting failures.
try {
await Promise.all([mkdir(rpc),mkdir(data),mkdir(shell)]);
await writeFile(join(shell,'.zshrc'),"bindkey -e\nPS1='records%# '\n");
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
const bundle=join(iso,'SSHMenu.app');const bin=join(bundle,'Contents','MacOS');await mkdir(bin,{recursive:true});await writeFile(join(bundle,'Contents','Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>local.zerowork.menu.${process.pid}</string><key>CFBundleName</key><string>SSHMenu</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);await copyFile(source,join(bin,'zerowork'));await copyFile(join(source,'..','zw_ipc.so'),join(bin,'zw_ipc.so'));
const peerLog=await open(join(out,'peer.log'),'w');const peerOut=join(out,'peer');const peer=spawn('python3',['e2e/ssh_tab_connections_peer.py','--out',peerOut],{stdio:['ignore',peerLog.fd,peerLog.fd]});const peerEnded=new Promise(r=>peer.once('close',r));
const ready=await waitFor(async()=>{try{return JSON.parse(await readFile(join(peerOut,'ready.json'),'utf8'))}catch{return null}},15000);
await writeFile(join(data,'known_hosts'),ready.known_host);
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Owned records SSH"\ngroup="QA hosts"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');const app=spawn(join(bin,'zerowork'),[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'0'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const report:any={status:'running',pid:app.pid,isolated:iso,sha256:createHash('sha256').update(await readFile(source)).digest('hex'),checks:[],captures:[],limits:['Public synthetic Harness on actual Metal window; no physical CUA/IME/VoiceOver acceptance.','The owned loopback SSH peer runs an actual ZSH PTY; no external host is accessed. Physical CUA/IME/VoiceOver remain separate.']};
const flat=(n:any):any[]=>[n,...(n.children??[]).flatMap(flat)];
const content=(n:any):string=>!shown(n)?'':(n.text??'')+(n.children??[]).map(content).join('');
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const vis=(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,12000),hidden=(id:string)=>waitFor(async()=>!(await query(id)).some(shown)||null,12000);
async function click(id:string){const n=await vis(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await sleep(160)}
async function press(name:string,mods?:any){assert((await key(name,mods)).ok)}
async function type(text:string){assert((await type_(text)).ok)}
async function capture(name:string){await sleep(180);assert((await screenshot(join(out,name+'.png'))).ok);report.captures.push(name)}
async function palette(){await type('@');await vis('terminal.commands')}
async function command(value:string){await palette();await type(value);await press('right');await hidden('terminal.commands');await press('return');await sleep(350)}
async function outputs(){return (await query('terminal.command.output')).filter(shown).map(content).join('\n')}
async function records(){return (await query('terminal.command.record')).filter(shown).map(content)}
try{
 await waitForServerReady(60000);await resizeWindow(1440,900);const host=await vis('sidebar.host');assert((await clickAt(host.rect.x+host.rect.w/2,host.rect.y+host.rect.h/2,2)).ok);await waitFor(async()=>content(await vis('workspace.pane')).includes('sshrecords')||null,30000);await sleep(450);
 await capture('connected');
 await click('status.connection.chain');await vis('connection.details');await click('connection.details.logs');
 const logs=await vis('connection.logs');assert.equal(logs.rect.w,760);assert(logs.rect.h<=282);
 await capture('independent-connection-logs');await click('connection.logs.close');await press('escape');
 report.checks.push('Independent connection log reader retains its 760-point viewport and working close action');
 const tab=flat(await vis('tabs.strip')).find(n=>shown(n)&&n.test_id?.startsWith('tabs.tab.'));assert(tab);
 async function button(n:any,button:string){const p={x:n.rect.x+n.rect.w/2,y:n.rect.y+n.rect.h/2,button};assert((await request('POST','/mouse_down',p)).ok);assert((await request('POST','/mouse_up',p)).ok)}
 await button(tab,'right');
 for(const [action,label] of [['new_tab','新标签连接'],['reuse_connection','复用连接'],['new_window','新窗口连接']]){assert(content(await vis('context.menu.'+action)).includes(label));}
 assert(!(await query('context.menu.clone_session')).some(shown));
 await capture('tab-menu');report.checks.push('Real tab right click opens all three distinct connection actions');
 await click('context.menu.view_jump_chain');await vis('connection.details');
 await capture('tab-menu-connection-chain');await click('connection.details.close');
 report.checks.push('Tab communication chain action opens the native connection details panel');
 const terminal=await vis('terminal.input');await button(terminal,'middle');await vis('context.menu');
 for(const action of ['new_tab','reuse_connection','new_window'])assert(!(await query('context.menu.'+action)).some(shown));
 await capture('terminal-menu');report.checks.push('Real terminal middle click contains no connection creation actions');await press('escape');
 await button(tab,'right');await click('context.menu.reuse_connection');
 await waitFor(async()=>flat(await vis('tabs.strip')).filter(n=>shown(n)&&n.test_id?.startsWith('tabs.tab.')).length===2||null,15000);
 await waitFor(async()=>{const state:any=await request('POST','/zerowork/windows',{action:'snapshot'});return state.sessions.filter((s:any)=>s.plugin==='ssh'&&s.lifecycle==='attached').length===2||null},20000);
 assert.equal((await readdir(peerOut)).filter(n=>n.startsWith('connection-')).length,1);
 assert.equal((await readdir(peerOut)).filter(n=>n.startsWith('shell-')).length,2);
 report.checks.push('Reuse menu creates two attached tabs and two shell channels on one authenticated transport');
 await capture('reused-connection');
 await button(tab,'right');await click('context.menu.new_tab');
 await waitFor(async()=>flat(await vis('tabs.strip')).filter(n=>shown(n)&&n.test_id?.startsWith('tabs.tab.')).length===3||null,15000);
 await waitFor(async()=>(await readdir(peerOut)).filter(n=>n.startsWith('connection-')).length===2||null,15000);
 report.checks.push('New connection action creates a third tab and a second authenticated transport');
 await click(tab.test_id);
 await click(tab.test_id.replace('tabs.tab.','tabs.close.'));
 await waitFor(async()=>{for(const id of ['session.close.accept','local.close.accept']){if((await query(id)).some(shown))await click(id);}return !(await query(tab.test_id)).some(shown)||null},20000);
 assert(!(await readdir(peerOut)).includes('closed-1.json'));
 report.checks.push('Closing the source tab preserves the shared authenticated transport');
 const remaining=flat(await vis('tabs.strip')).filter(n=>shown(n)&&n.test_id?.startsWith('tabs.tab.'));const next=remaining[0];assert(next);
 await click(next.test_id);await click('terminal.input');
 await type("printf '%s%s\\n' ZW_SHARED_ AFTER_CLOSE");await press('return');
 await waitFor(async()=>content(await vis('workspace.pane')).includes('ZW_SHARED_AFTER_CLOSE')||null,15000);
 report.checks.push('The surviving shared shell receives input and produces command output after source tab closes');
 await button(next,'right');await click('context.menu.reuse_connection');
 await waitFor(async()=>{const state:any=await request('POST','/zerowork/windows',{action:'snapshot'});return state.sessions.filter((s:any)=>s.plugin==='ssh'&&s.lifecycle==='attached').length===3||null},20000);
 assert.equal((await readdir(peerOut)).filter(n=>n.startsWith('connection-')).length,2);
 assert.equal((await readdir(peerOut)).filter(n=>n.startsWith('shell-1-')).length,3);
 report.checks.push('A surviving shared tab can open another shell on the original transport after source tab closes');
 const last=flat(await vis('tabs.strip')).find(n=>shown(n)&&n.test_id?.startsWith('tabs.tab.')&&!remaining.some(r=>r.test_id===n.test_id));assert(last);
 for(const shared of [next,last]){await click(shared.test_id);await click(shared.test_id.replace('tabs.tab.','tabs.close.'));await waitFor(async()=>{for(const id of ['session.close.accept','local.close.accept'])if((await query(id)).some(shown))await click(id);return !(await query(shared.test_id)).some(shown)||null},20000);}
 await waitFor(async()=>(await readdir(peerOut)).includes('closed-1.json')||null,15000);
 report.checks.push('Closing the last shared tab closes the original authenticated transport');
 const independent=flat(await vis('tabs.strip')).find(n=>shown(n)&&n.test_id?.startsWith('tabs.tab.'));assert(independent);
 await button(independent,'right');await click('context.menu.new_window');
 const windows:any=await waitFor(async()=>{const state:any=await request('POST','/zerowork/windows',{action:'snapshot'});return state.windows?.length===2?state:null},20000);
 assert.equal(windows.native_count,2);
 await waitFor(async()=>{const state:any=await request('POST','/zerowork/windows',{action:'snapshot'});return state.sessions.filter((s:any)=>s.plugin==='ssh'&&s.lifecycle==='attached').length===2||null},20000);
 assert.equal((await readdir(peerOut)).filter(n=>n.startsWith('connection-')).length,3);
 await capture('new-window');report.checks.push('Tab new window action creates a second native window');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});process.exitCode=1}
finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}peer.kill('SIGTERM');await Promise.race([peerEnded,sleep(3500)]);await peerLog.close();await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
console.log(JSON.stringify({status:report.status,checks:report.checks,error:report.error,out}));
} finally {
 await rm(iso,{recursive:true,force:true});
}
