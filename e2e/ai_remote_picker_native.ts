/** Own memory-only peer, real SSH/SFTP reader and native multi-file attachment UI. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-ai-v3-prefix', h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-ai-picker');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-ai-picker-')),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
const plog=await open(join(out,'peer.log'),'w'),log=await open(join(out,'app.log'),'w');
const peer=spawn('python3',['e2e/ai_remote_picker_peer.py','--out',join(iso,'peer')],{stdio:['ignore',plog.fd,plog.fd]});
let app:any;const report:any={status:'running',checks:[],scope:'owned loopback SSH/SFTP and synthetic native Harness; no external server, physical file chooser not covered'};
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const actual=async(id:string)=>(await h.query(id)).filter(shown);
const visible=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,20000);
const click=async(id:string)=>{report.lastAction=id;await visible(id);assert((await h.clickTestId(id)).ok)};
const cap=async(name:string)=>{await h.sleep(200);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2))};
try{
 const ready=await h.waitFor(async()=>{try{return JSON.parse(await readFile(join(iso,'peer','ready.json'),'utf8'))}catch{return null}},10000);
 await writeFile(join(data,'known_hosts'),ready.known_host);
 await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
 await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="AI memory peer"\nhost="127.0.0.1"\nport=${ready.port}\nuser="fixture"\nauth={password="ai-readonly"}\noptions={strict_host_key=true}\n`);
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 app=spawn(process.env.ZW_AI_BINARY??join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 app.on('exit',(code,signal)=>{report.appExit={code,signal}});await h.waitForServerReady(60000);await h.resizeWindow(1440,900);await click('sidebar.host');await writeFile(join(out,'live.json'),JSON.stringify({pid:app.pid,iso,rpc,port:ready.port}));
 await h.waitFor(async()=>{const inputs=await actual('plugin.challenge.secret');if(inputs[0]){const n=inputs[0];await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);await h.type_('ai-readonly');const submit=(await actual('plugin.challenge.submit'))[0];if(submit)await h.clickAt(submit.rect.x+submit.rect.w/2,submit.rect.y+submit.rect.h/2);}return (await h.query('terminal.input')).some(shown)?true:null},process.env.ZW_AI_PICKER_CUA==='1'?180000:20000);await h.sleep(1000);
 await click('toolbar.ai');await visible('ai.prompt');await click('ai.composer.attachment');await click('ai.attachment.remote_file');await visible('ai.remote.picker');await click('ai.remote.source');await h.key('escape');
 await click('ai.remote.path');await h.key('a',{cmd:true});await h.type_('/fixture');await click('ai.remote.go');await h.waitFor(async()=>{const secret=(await actual('plugin.challenge.secret'))[0];if(secret){await h.clickAt(secret.rect.x+secret.rect.w/2,secret.rect.y+secret.rect.h/2);await h.type_('ai-readonly');const submit=(await actual('plugin.challenge.submit'))[0];if(submit)await h.clickAt(submit.rect.x+submit.rect.w/2,submit.rect.y+submit.rect.h/2);}return (await h.query('ai.remote.entry')).filter(shown).length===2||null},20000);
 await cap('01-directory');let entries=(await h.query('ai.remote.entry')).filter(shown);for(const row of entries)assert((await h.clickAt(row.rect.x+row.rect.w/2,row.rect.y+row.rect.h/2)).ok);
 await h.waitFor(async()=>(await visible('ai.remote.status')).text.includes('2')||null,5000);await cap('02-two-selected');await click('ai.remote.attach');await h.waitFor(async()=>(await h.query('ai.attachment.remote_file')).filter(shown).length===2||null,20000);await cap('03-two-attached');report.checks.push('Two remote files selected once and captured as independent native draft attachments through real SFTP');
 await click('ai.remote.close');await h.resizeWindow(860,480);await click('ai.attachment.open');await visible('ai.attachment.preview');await cap('04-compact-preview');await click('ai.attachment.preview.close');report.checks.push('Attached remote snapshot opens native preview in compact window');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);report.authNodes=Object.fromEntries(await Promise.all(['plugin.challenge.secret','plugin.challenge.answer.0','auth.challenge.answer.0','plugin.challenge.modal','auth.challenge.modal'].map(async id=>[id,(await h.query(id)).map(n=>({id:n.id,rect:n.rect,opacity:n.effective_opacity}))])));process.exitCode=1;await cap('failure').catch(()=>{})}
finally{if(app){app.kill('SIGTERM');await new Promise(r=>app.once('close',r))}peer.kill('SIGTERM');await new Promise(r=>peer.once('close',r));await log.close();await plog.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report))}
