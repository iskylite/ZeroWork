/** Real loopback SSH: exit, loss, inline reconnect, failure, retry, output and close. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,realpath,writeFile,readFile,rm,open} from 'node:fs/promises';
import {resolve,join} from 'node:path';
const prefix=process.env.ZW_REMOTE_NOTICE_PREFIX??'/tmp/zw-remote-notice-build';
const automatic=process.argv.includes('--automatic'),buffered=process.argv.includes('--buffered');
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'output/remote-session-notice');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-remote-notice-'));await mkdir(iso+'/data');await mkdir(iso+'/rpc');
process.env.ZENIT_E2E_FILE_RPC_DIR=iso+'/rpc';
const peerLog=await open(out+'/peer.log','w');const peer=spawn('python3',['e2e/remote_session_notice_peer.py','--out',iso+'/peer'],{stdio:['ignore',peerLog.fd,peerLog.fd]});const peerEnd=new Promise(r=>peer.once('close',r));
let app:any,appEnd:any,appLog:any;
const report:any={status:'running',checks:[],captures:[],isolated:iso};
const flat=(n:any):any[]=>[n,...(n.children??[]).flatMap(flat)];
const text=(n:any)=>flat(n).map(v=>v.text??'').join('');
const shown=(n:any)=>n?.visible!==false&&!n.hidden&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const nodes=async(id:string)=>{const ns=await h.query(id);return Array.isArray(ns)?ns.filter(shown):[]};
const vis=(id:string)=>h.waitFor(async()=> (await nodes(id))[0]??null,15000);
const title=(value:string)=>h.waitFor(async()=> (await nodes('remote.notice.title')).find(n=>n.text===value)??null,20000);
async function dismissToasts(){for(let i=0;i<3;i++){const n=(await nodes('notifications.dismiss.'+i))[0];if(n)assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)}}
const click=async(id:string)=>{if(id.startsWith('remote.notice.'))await dismissToasts();const n=await vis(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok,id)};
const hidden=async(id:string)=>assert.equal((await nodes(id)).length,0,id+' hidden');
const capture=async(name:string)=>{await dismissToasts();const p=out+'/'+name+'.png';assert((await h.screenshot(p)).ok);report.captures.push(p)};
async function connected(marker:string){await h.waitFor(async()=>{const ns=await nodes('terminal.input');return ns.some(n=>text(n).includes(marker))&&(await nodes('status.connection.identity')).some(n=>text(n).includes('已连接'))||null},25000); /* Worker requires a 500ms shell-output quiet interval before accepting input. */ await h.sleep(650);}
async function command(value:string){await click('terminal.input');await h.type_(value);await h.key('return')}
try{
 const ready=await h.waitFor(async()=>{try{return JSON.parse(await readFile(iso+'/peer/ready.json','utf8'))}catch{return null}},15000);
 await writeFile(iso+'/data/config.toml',`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ssh]\nauto_reconnect=${automatic}\nbuffer_input=${buffered}\nreconnect_backoff=[3,3,3,3,3]\n`);
 await writeFile(iso+'/data/hosts.toml',`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Remote notice SSH"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
 appLog=await open(out+'/app.log','w');app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:iso+'/data',ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',appLog.fd,appLog.fd]});appEnd=new Promise(r=>app.once('close',r));
 await h.waitForServerReady();await h.resizeWindow(1280,760);
 const row=await vis('sidebar.host');assert((await h.clickAt(row.rect.x+70,row.rect.y+row.rect.h/2)).ok);
 await h.waitFor(async()=>{const modal=(await nodes('plugin.challenge.modal'))[0];if(modal){const choice=flat(modal).find(n=>n.test_id==='plugin.challenge.choice.1'&&shown(n));if(choice) await click('plugin.challenge.choice.1');else if(flat(modal).some(n=>n.test_id==='plugin.challenge.secret'&&shown(n))){await click('plugin.challenge.secret');await h.type_(ready.password);await click('plugin.challenge.submit')}}return (await nodes('terminal.input')).some(n=>text(n).includes('REMOTE_HISTORY_1'))||null},30000);
 await connected('REMOTE_HISTORY_1');await command('exit 7');await title('远程终端已退出');await vis('remote.notice.reconnect');assert(text(await vis('remote.notice.detail')).includes('退出码 7'));
 assert(text(await vis('terminal.input')).includes('REMOTE_HISTORY_1'));await capture('01-exited');report.checks.push('Actual SSH exit-status 7 is distinct from transport loss; transcript retained');
 await writeFile(iso+'/peer/slow','1');await click('remote.notice.reconnect');await title('正在重新连接远程主机…');await hidden('remote.notice.reconnect');await hidden('remote.notice.retry');await capture('02-reconnecting');
 await click('terminal.input');assert(text(await vis('remote.notice.detail')).includes(buffered?'缓冲':'恢复后'));await h.type_(buffered?'BUFFERED_ONCE':'DO_NOT_REPLAY');await h.key('return');await rm(iso+'/peer/slow');await connected('REMOTE_HISTORY_2');await hidden('remote.notice');report.checks.push('Exit reconnect uses same pane, hides retry during connection, restores input and hides notice on attachment');
 await command('DROP');await title('与远程主机的连接已断开');await vis('remote.notice.reconnect');if(automatic)assert(text(await vis('remote.notice.detail')).includes('自动重连'));await h.resizeWindow(860,600);await capture('03-disconnected-compact');
 const bar=await vis('remote.notice'),close=await vis('remote.notice.close'),retry=await vis('remote.notice.reconnect');assert(close.rect.x+close.rect.w<=retry.rect.x);assert(retry.rect.x+retry.rect.w<=bar.rect.x+bar.rect.w);
 await writeFile(iso+'/peer/reject','1');await click('remote.notice.reconnect');await title('重新连接失败');await vis('remote.notice.retry');assert(text(await vis('terminal.input')).includes('REMOTE_HISTORY_2'));await capture('04-retry-failed');report.checks.push('Transport loss and failed retry have separate titles/actions, preserve history, and fit 860px');
 await rm(iso+'/peer/reject');await click('remote.notice.retry');await connected('REMOTE_HISTORY_4');await hidden('remote.notice');if(automatic){await writeFile(iso+'/peer/slow','1');await command('DROP');await title('与远程主机的连接已断开');await h.waitFor(async()=>text(await vis('remote.notice.detail')).includes('自动重连')||null,5000);await capture('05-auto-countdown');await title('正在重新连接远程主机…');await capture('06-auto-reconnecting-buffered');await rm(iso+'/peer/slow');await connected('REMOTE_HISTORY_5');await hidden('remote.notice');report.checks.push('Actual automatic retry countdown advances to reconnect and successful attachment without a manual click')}await command('DROP');await title('与远程主机的连接已断开');await click('remote.notice.close');await vis('workspace.empty.local');report.checks.push('Retry after failure reconnects successfully; close removes ended pane');
 const peerReport=JSON.parse(await readFile(iso+'/peer/report.json','utf8'));const allInput=peerReport.inputs.map((n:any)=>n.text).join('');if(buffered){assert.equal(allInput.split('BUFFERED_ONCE').length-1,1);report.checks.push('Configured buffered input is explained and delivered once after reconnect')}else{assert(!allInput.includes('DO_NOT_REPLAY'));report.checks.push('Input typed during reconnect never reaches successor SSH shell when buffering is disabled')}report.peer=peerReport;report.status='passed';
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;await capture('failure').catch(()=>{});}
finally{if(app){app.kill('SIGTERM');await appEnd;await appLog.close()}peer.kill('SIGTERM');await peerEnd;await peerLog.close();await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));}
