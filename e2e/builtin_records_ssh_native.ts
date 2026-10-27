/** V3 builtin composite document acceptance through the real Local PTY and native Surface. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdir,mkdtemp,realpath,copyFile,readFile,writeFile,open,readdir,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep,scrollAt,mouseDown,mouseMove,mouseUp} from '../zig-out/share/zenit/harness/client.ts';
const savedClipboard=execFileSync('/usr/bin/pbpaste');
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
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Owned records SSH"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');const app=spawn(join(iso,'zerowork'),[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const report:any={status:'running',pid:app.pid,isolated:iso,sha256:createHash('sha256').update(await readFile(source)).digest('hex'),checks:[],captures:[],limits:['Public synthetic Harness on actual Metal window; no physical CUA/IME/VoiceOver acceptance.','The owned loopback SSH peer runs an actual ZSH PTY; no external host is accessed. Physical CUA/IME/VoiceOver remain separate.']};
const flat=(n:any):any[]=>[n,...(n.children??[]).flatMap(flat)];
const content=(n:any):string=>!shown(n)?'':(n.text??'')+(n.children??[]).map(content).join('');
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const vis=(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,12000),hidden=(id:string)=>waitFor(async()=>!(await query(id)).some(shown)||null,12000);
async function click(id:string){const n=await vis(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)}
async function press(name:string,mods?:any){assert((await key(name,mods)).ok)}
async function type(text:string){assert((await type_(text)).ok)}
async function capture(name:string){await sleep(180);assert((await screenshot(join(out,name+'.png'))).ok);const nodes:any={};for(const id of ['terminal.surface','terminal.commands','terminal.command.input','workspace.pane','terminal.command.record','terminal.command.output','terminal.search.count','terminal.search.query','tabs.strip'])nodes[id]=await query(id);await writeFile(join(out,name+'.json'),JSON.stringify(nodes,null,2));report.captures.push(name)}
async function palette(){await type('@');await vis('terminal.commands')}
async function command(value:string){await palette();await type(value);await press('right');await hidden('terminal.commands');await press('return');await sleep(350)}
async function outputs(){return (await query('terminal.command.output')).filter(shown).map(content).join('\n')}
async function records(){return (await query('terminal.command.record')).filter(shown).map(content)}
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1200,800);const host=await vis('sidebar.host');assert((await clickAt(host.rect.x+host.rect.w/2,host.rect.y+host.rect.h/2,2)).ok);
 await waitFor(async()=>content(await vis('workspace.pane')).includes('sshrecords')||null,30000);await sleep(450);await capture('01-actual-ssh-pty');
 await command('help');await waitFor(async()=>{const text=await outputs();return text.includes('@grp')&&text.includes('@up')||null});await capture('02-ssh-inline-help');report.checks.push('SSH source renders full help in the same retained composite document');
 await command('ts');await waitFor(async()=>(await outputs()).includes('已开启时间戳')||null);await capture('03-ssh-timestamp-record');
 const after=join(peerOut,'shell-after.txt');await type(`printf shell-after > ${JSON.stringify(after)}`);await press('return');await waitFor(async()=>{try{return await readFile(after,'utf8')==='shell-after'||null}catch{return null}},15000);await sleep(250);await capture('04-ssh-following-real-shell');report.checks.push('Following SSH bytes execute an actual local ZSH process and appear after app records without overlap');
 const commandRow=(await query('terminal.command.record')).filter(shown).flatMap(flat).find(n=>n.tag==='text'&&n.text==='@ts');assert(commandRow);const cell=commandRow.rect.w/3;const x=commandRow.rect.x,y=commandRow.rect.y+commandRow.rect.h/2;await mouseDown(x+1,y);await mouseMove(x+2.9*cell,y);await mouseUp(x+2.9*cell,y);await sleep(180);assert.equal(execFileSync('/usr/bin/pbpaste',[],{encoding:'utf8'}),'@ts');report.checks.push('Native SSH composite drag copy returns pure command bytes and excludes marker/timestamp');
 await press('f',{cmd:true});await vis('terminal.search.query');await type('@ts');await waitFor(async()=>content(await vis('terminal.search.count')).includes('1')||null);await capture('05-ssh-search');await click('terminal.search.close');report.checks.push('SSH search uses the retained composite document');
 const received=await readFile(join(peerOut,'received-1.bin'));assert(!received.includes(Buffer.from('@help')));assert(!received.includes(Buffer.from('@ts')));assert(received.includes(Buffer.from('printf shell-after')));report.checks.push('Actual SSH peer input contains real shell command and contains no app @help/@ts input or fake output');
 await type('exit');await press('return');await waitFor(async()=>{try{const state=JSON.parse(await readFile(join(peerOut,'closed-1.json'),'utf8'));return state.exit_code===0&&!state.transport_active||null}catch{return null}},15000);const tab=flat(await vis('tabs.strip')).find(n=>/^tabs\.tab\.\d+$/.test(n.test_id??''));assert(tab);await mouseMove(tab.rect.x+tab.rect.w-15,tab.rect.y+tab.rect.h/2);await sleep(180);await click(tab.test_id.replace('tabs.tab.','tabs.close.'));await vis('workspace.empty.local');await capture('06-ssh-normal-exit-close');report.checks.push('Actual SSH ZSH exit 0 and normal tab close release document anchors before native owner teardown; app remains alive with empty workspace');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});process.exitCode=1}
finally{execFileSync('/usr/bin/pbcopy',{input:savedClipboard});if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}peer.kill('SIGTERM');await Promise.race([peerEnded,sleep(3500)]);await peerLog.close();await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}))}
} finally {
 await rm(iso,{recursive:true,force:true});
}
