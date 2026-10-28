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
const cap=async(name:string)=>{await h.sleep(200);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2));await writeFile(join(out,name+'-picker.json'),JSON.stringify(await h.query('ai.remote.picker'),null,2))};
try{
 const ready=await h.waitFor(async()=>{try{return JSON.parse(await readFile(join(iso,'peer','ready.json'),'utf8'))}catch{return null}},10000);
 await writeFile(join(data,'known_hosts'),ready.known_host);
 await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
 await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="AI memory peer"\nhost="127.0.0.1"\nport=${ready.port}\nuser="fixture"\nauth={password="ai-readonly"}\noptions={strict_host_key=true}\n`);
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 app=spawn(process.env.ZW_AI_BINARY??join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 app.on('exit',(code,signal)=>{report.appExit={code,signal}});await h.waitForServerReady(60000);await h.resizeWindow(1440,900);const host=await visible('sidebar.host');assert((await h.clickAt(host.rect.x+60,host.rect.y+host.rect.h/2,2)).ok);await writeFile(join(out,'live.json'),JSON.stringify({pid:app.pid,iso,rpc,port:ready.port}));
 await h.waitFor(async()=>{const inputs=await actual('plugin.challenge.secret');if(inputs[0]){const n=inputs[0];await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);await h.type_('ai-readonly');const submit=(await actual('plugin.challenge.submit'))[0];if(submit)await h.clickAt(submit.rect.x+submit.rect.w/2,submit.rect.y+submit.rect.h/2);}return (await h.query('terminal.input')).some(shown)?true:null},process.env.ZW_AI_PICKER_CUA==='1'?180000:20000);await h.sleep(1000);
 await click('toolbar.ai');await visible('ai.prompt');
 const filename=async(name:string)=>{const n=await h.waitFor(async()=>(await actual('ai.remote.filename')).find(n=>n.text===name)??null,10000);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)};
 const waitEntries=async(count:number)=>h.waitFor(async()=>{
  const secret=(await actual('plugin.challenge.secret'))[0];if(secret){await h.clickAt(secret.rect.x+secret.rect.w/2,secret.rect.y+secret.rect.h/2);await h.type_('ai-readonly');const submit=(await actual('plugin.challenge.submit'))[0];if(submit)await h.clickAt(submit.rect.x+submit.rect.w/2,submit.rect.y+submit.rect.h/2);}
  return (await actual('ai.remote.entry')).length===count||null;
 },20000);
 const setPath=async(path:string)=>{await click('ai.remote.path');await h.key('a',{cmd:true});await h.type_(path);await h.key('return')};
 await click('ai.prompt');await h.type_('检查 ');await h.type_('/');await visible('ai.remote.picker');await waitEntries(3);
 assert.equal((await h.inputState('ai.prompt')).buffer,'检查 ');
 assert.equal((await h.inputState('ai.remote.path')).buffer,'/fixture');
 await cap('01-directory');report.checks.push('Standalone slash opens the native picker, preserves the prompt, and automatically resolves /fixture without shell OSC 7');
 await click('ai.remote.filter');await h.type_('no-match');await h.waitFor(async()=>(await visible('ai.remote.empty')).text.includes('没有匹配')||null,5000);
 await h.key('a',{cmd:true});await h.key('backspace');await waitEntries(3);
 await filename('logs');await waitEntries(1);assert.equal((await h.inputState('ai.remote.path')).buffer,'/fixture/logs');await click('ai.remote.parent');await waitEntries(3);
 await setPath('/missing');await h.waitFor(async()=>(await visible('ai.remote.empty')).text.includes('不存在')||null,10000);await cap('02-missing-directory');await click('ai.remote.home');await waitEntries(3);
 await setPath('/');await waitEntries(1);await filename('fixture');await waitEntries(3);
 report.checks.push('Enter opens a path; directory entry, parent, root, home, empty filter and missing-path recovery work through real SFTP');
 await filename('a.txt');await visible('ai.remote.picker');await h.waitFor(async()=>(await visible('ai.remote.status')).text.includes('1 个文件')||null,5000);
 const second=(await actual('ai.remote.filename')).find(n=>n.text==='b.log');assert(second);const box=(await actual('ai.remote.entry')).find(n=>Math.abs(n.rect.y+n.rect.h/2-(second.rect.y+second.rect.h/2))<4);assert(box);await h.clickAt(box.rect.x+box.rect.w/2,box.rect.y+box.rect.h/2);
 await h.waitFor(async()=>(await visible('ai.remote.status')).text.includes('2 个文件')||null,5000);await cap('03-two-selected');await click('ai.remote.attach');
 await h.waitFor(async()=>(await actual('ai.attachment.remote_file')).length===2||null,20000);await h.waitFor(async()=>(await actual('ai.remote.picker')).length===0||null,5000);await cap('04-two-attached');
 report.checks.push('Filename and checkbox selection produce two independent native draft attachments; successful attachment closes the picker');
 await h.resizeWindow(860,480);await click('ai.attachment.open');await visible('ai.attachment.preview');await cap('05-compact-preview');await click('ai.attachment.preview.close');
 await click('ai.composer.attachment');const menuChoice=(await actual('ai.attachment.remote_file')).find(n=>n.rect.w>200);assert(menuChoice);await h.clickAt(menuChoice.rect.x+menuChoice.rect.w/2,menuChoice.rect.y+menuChoice.rect.h/2);await waitEntries(3);await cap('06-compact-picker');
 const picker=await visible('ai.remote.picker');assert(picker.rect.y>=0&&picker.rect.y+picker.rect.h<=480);report.pickerRect=picker.rect;await filename('b.log');await click('ai.remote.read');await visible('ai.attachment.preview');await h.waitFor(async()=>(await visible('ai.attachment.preview.text')).text.includes('second captured source')||null,10000);assert.equal((await actual('ai.attachment.remote_file')).length,2);await cap('07-read-before-attach');await click('ai.attachment.preview.close');
 report.checks.push('Plus-menu entry opens the same picker; it fits 860×480, and explicit single-file preview reads the chosen content without attaching it');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);report.authNodes=Object.fromEntries(await Promise.all(['plugin.challenge.secret','plugin.challenge.answer.0','auth.challenge.answer.0','plugin.challenge.modal','auth.challenge.modal'].map(async id=>[id,(await h.query(id)).map(n=>({id:n.id,rect:n.rect,opacity:n.effective_opacity}))])));process.exitCode=1;await cap('failure').catch(()=>{})}
finally{if(app){app.kill('SIGTERM');await new Promise(r=>app.once('close',r))}peer.kill('SIGTERM');await new Promise(r=>peer.once('close',r));await log.close();await plog.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report))}
