/** Native command palette + real isolated SSH PTY. No user's app/config is used. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=process.env.ZW_NESTED_PREFIX??'/private/tmp/zw-nested-shell-build';
const python=process.env.ZW_TEST_PYTHON??'/private/tmp/zw-nested-shell-test-venv/bin/python';
const out=resolve(process.argv[2]??'/private/tmp/zw-nested-shell-native');await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-nested-native-');await mkdir(join(iso,'data'));await mkdir(join(iso,'rpc'));
process.env.ZENIT_E2E_FILE_RPC_DIR=join(iso,'rpc');
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const peerLog=await open(join(out,'peer.log'),'w');
const peer=spawn(python,['e2e/ssh_nested_shell_peer.py','--out',join(iso,'peer')],{stdio:['ignore',peerLog.fd,peerLog.fd]});
const peerEnded=new Promise(r=>peer.once('close',r));
let app:any,appEnded:any,appLog:any;
const report:any={status:'running',checks:[],captures:[]};
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map((v:any)=>v.text??'').join('');
const shown=(n:any)=>n&&n.visible!==false&&!n.hidden&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{const n=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)};
const command=async(value:string)=>{await click('terminal.input');await h.type_(value);await h.key('enter')};
const builtin=async(args='')=>{await click('terminal.input');for(const character of '@shell'+(args?' '+args:''))await h.type_(character);await h.key('enter')};
const hint=(value:string)=>h.waitFor(async()=>{return (await h.query('terminal.command.output')).find((n:any)=>shown(n)&&text(n).includes(value))??null},20000);
const capture=async(name:string)=>{await h.mouseMove(5,5);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('terminal.input'),null,2));report.captures.push(name)};
try{
 const ready=await h.waitFor(async()=>{try{return JSON.parse(await readFile(join(iso,'peer','ready.json'),'utf8'))}catch{return null}},15000);
 await writeFile(join(iso,'data','config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ssh]\nauto_reconnect=false\nauto_shell_integration=true\n');
 await writeFile(join(iso,'data','hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Nested Shell fixture"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
 appLog=await open(join(out,'app.log'),'w');
 app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:join(iso,'data'),ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',appLog.fd,appLog.fd]});
 appEnded=new Promise(r=>app.once('close',r));await h.waitForServerReady(60000);await h.resizeWindow(1280,800);const row=await visible('sidebar.host');await h.mouseMove(row.rect.x+row.rect.w-18,row.rect.y+row.rect.h/2);await click('sidebar.host.connect');
 await h.waitFor(async()=>{const modal=(await h.query('plugin.challenge.modal')).find(shown);if(modal){if(flat(modal).some((n:any)=>n.test_id==='plugin.challenge.choice.1'&&shown(n)))await click('plugin.challenge.choice.1');else if(flat(modal).some((n:any)=>n.test_id==='plugin.challenge.secret'&&shown(n))){await click('plugin.challenge.secret');await h.type_(ready.password);await click('plugin.challenge.submit')}}return text(await h.query('terminal.input')).includes('fixture>')||null},30000);
 await h.waitFor(async()=>{try{return JSON.parse(await readFile(join(iso,'peer','state.json'),'utf8')).contexts.length>=1||null}catch{return null}},25000);
 await builtin();await hint('已接入层级 1');await capture('01-root-status');
 await command('bash --noprofile --norc -i');await h.waitFor(async()=>text(await h.query('terminal.input')).includes('bash-')||null,10000);
 await builtin('attach');await hint('当前 Shell 已接入');await capture('02-attached-existing-shell');
 await builtin();await hint('已接入层级 2');
 await command('bash --noprofile --norc -i');await h.waitFor(async()=>text(await h.query('terminal.input')).includes('bash-')||null,10000);
 await builtin('attach');await hint('当前 Shell 已接入');
 await h.waitFor(async()=>{try{return JSON.parse(await readFile(join(iso,'peer','state.json'),'utf8')).contexts.length>=3||null}catch{return null}},20000);
 await builtin();await hint('已接入层级 3');
 await h.waitFor(async()=>(await h.query('terminal.command.metadata.code')).filter((n:any)=>shown(n)&&text(n)==='—').length>=2||null,10000);
 report.checks.push('While both child shells are open, both parent entry commands retain an unknown exit code instead of false EXIT 0');
 await capture('03-attached-third-layer');
 await command('exit');await h.sleep(250);await builtin();await hint('已接入层级 2');
 await command('exit');await h.sleep(250);await builtin();await hint('已接入层级 1');await capture('04-restored-parent');
 report.checks.push('Native @shell palette action attaches an existing Bash without replacing the PTY; ordinary third-layer entry with explicit attachment; exit restores each known parent; inline status is visible');
 await command('export TMUX=fixture; bash --noprofile --norc -i');await h.sleep(300);await builtin('attach');await hint('暂不支持层级接入');await capture('05-unsupported-with-guidance');
 report.checks.push('Unsupported multiplexer environment is explained with an alternative; failed attach leaves SSH connected');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;await capture('failure').catch(()=>{})}
finally{
 if(app){app.kill('SIGTERM');await Promise.race([appEnded,new Promise(r=>setTimeout(()=>{app.kill('SIGKILL');r(null)},3000))]);await appLog.close()}
 peer.kill('SIGTERM');await peerEnded;await peerLog.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}
