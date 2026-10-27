/** Reported connection regressions against an owned loopback SSH + real ZSH PTY. */
import assert from 'node:assert/strict';
import net from 'node:net';
import {spawn,execFileSync} from 'node:child_process';
import {mkdir,mkdtemp,realpath,copyFile,readFile,writeFile,open,readdir,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep,scrollAt,mouseDown,mouseMove,mouseUp} from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]),source=resolve(process.argv[3]);await mkdir(out,{recursive:false});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-builtin-records-'))),rpc=join(iso,'rpc'),data=join(iso,'data'),shell=join(iso,'shell');
// Always remove this run's sandbox, including setup and reporting failures.
try {
await Promise.all([mkdir(rpc),mkdir(data),mkdir(shell)]);
await writeFile(join(shell,'.zshrc'),"bindkey -e\nPS1='records%# '\n");
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
await copyFile(source,join(iso,'zerowork'));await copyFile(join(source,'..','zw_ipc.so'),join(iso,'zw_ipc.so'));
const peerLog=await open(join(out,'peer.log'),'w');const peerOut=join(out,'peer');const peer=spawn('python3',['e2e/builtin_records_ssh_peer.py','--out',peerOut],{stdio:['ignore',peerLog.fd,peerLog.fd]});const peerEnded=new Promise(r=>peer.once('close',r));
const ready=await waitFor(async()=>{try{return JSON.parse(await readFile(join(peerOut,'ready.json'),'utf8'))}catch{return null}},15000);
await writeFile(join(data,'known_hosts'),ready.known_host);
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Owned records SSH"\ngroup="QA hosts"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');const app=spawn(join(iso,'zerowork'),[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
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
 await click('status.connection.forward');await click('socks.info.config');await vis('socks.config');const probe=net.createServer();await new Promise<void>(r=>probe.listen(0,'127.0.0.1',r));const socksPort=(probe.address()as net.AddressInfo).port;await new Promise<void>(r=>probe.close(()=>r()));await click('socks.config.port');await key('a',{cmd:true});await type(String(socksPort));await click('socks.config.save');await hidden('socks.config');const saved=await readFile(join(data,'hosts.toml'),'utf8');assert(saved.includes('[[groups]]'));assert(saved.includes('QA hosts'));assert(saved.includes('socks_enabled = true'));report.checks.push('Saving forwarding for a grouped host preserves durable asset groups and succeeds');await capture('01-forwarding-saved');await click('status.connection.forward');await click('socks.info.control');await waitFor(async()=>content(await vis('socks.info.status')).includes('正在监听')||null,12000);const socket=net.createConnection({host:'127.0.0.1',port:socksPort});await new Promise<void>((r,j)=>{socket.once('connect',r);socket.once('error',j)});const greeting=new Promise<Buffer>((r,j)=>{socket.once('data',r);socket.once('error',j);socket.setTimeout(5000,()=>j(new Error('SOCKS greeting timeout')))});socket.write(Buffer.from([5,1,0]));assert.deepEqual(await greeting,Buffer.from([5,0]));socket.destroy();await click('socks.info.control');await waitFor(async()=>content(await vis('socks.info.status')).includes('未开启')||null,12000);await press('escape');report.checks.push('Saved SOCKS rule starts a real listener, completes SOCKS5 negotiation, and stops');
 for(let i=0;i<3;i++){await click('status.connection.chain');await vis('connection.details');await click('connection.details.sample');await sleep(250);await press('escape');await hidden('connection.details');}report.checks.push('Chain details reopen three times after RTT testing without stale view failure');await capture('02-chain-reopen');
 const terminal=await vis('terminal.input');await clickAt(terminal.rect.x+80,terminal.rect.y+80);await command('grp SSH-QA');await vis('groups.pane.header');await command('new');await waitFor(async()=>{const modal=(await query('plugin.challenge.modal')).find(shown);const answer=modal&&flat(modal).find(n=>(n.test_id==='plugin.challenge.secret'||n.test_id==='plugin.challenge.answer.0')&&n.focusable);if(!answer)return null;await clickAt(answer.rect.x+answer.rect.w/2,answer.rect.y+answer.rect.h/2);await type(ready.password);await click('plugin.challenge.submit');return true},20000);await waitFor(async()=>(await query('groups.pane.header')).filter(shown).length===2||null,20000);await waitFor(async()=>{const statuses=(await query('groups.pane.status')).filter(shown);return statuses.length===2&&statuses.every(n=>content(n)==='在线')||null},20000);report.checks.push('A new SSH session created inside a group refreshes both member states to online');await capture('03-ssh-group-online');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});process.exitCode=1}
finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}peer.kill('SIGTERM');await Promise.race([peerEnded,sleep(3500)]);await peerLog.close();await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
console.log(JSON.stringify({status:report.status,checks:report.checks,error:report.error,out}));
} finally {
 await rm(iso,{recursive:true,force:true});
}
