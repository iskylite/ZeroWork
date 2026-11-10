/** Own memory-only peer, real SSH/SFTP reader and native multi-file attachment UI. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-ai-v3-prefix', h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-ai-picker');await mkdir(out,{recursive:true});
const sourceName=process.env.ZW_AI_PICKER_SOURCE_NAME??'AI memory peer';
const iso=await realpath(await mkdtemp('/tmp/zw-ai-picker-')),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
const plog=await open(join(out,'peer.log'),'w'),log=await open(join(out,'app.log'),'w');
const peer=spawn(process.env.ZW_TEST_PYTHON??'python3',['e2e/ai_remote_picker_peer.py','--out',join(iso,'peer')],{stdio:['ignore',plog.fd,plog.fd]});
let app:any;const report:any={status:'running',checks:[],scope:'owned loopback SSH/SFTP and synthetic native Harness; no external server, physical file chooser not covered'};
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const actual=async(id:string)=>(await h.query(id)).filter(shown);
const visible=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,20000);
const click=async(id:string)=>{report.lastAction=id;await visible(id);assert((await h.clickTestId(id)).ok)};
const cap=async(name:string)=>{await h.sleep(200);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2));await writeFile(join(out,name+'-picker.json'),JSON.stringify(await h.query('ai.remote.picker'),null,2))};
const flat=(n:any):any[]=>[n,...(n.children??[]).flatMap(flat)];
const tabs=async()=>(await actual('tabs.strip')).flatMap(flat).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??''));
const remoteChoice=async()=>h.waitFor(async()=>{
 const menu=(await actual('ai.attachment.menu'))[0];
 return menu?flat(menu).find(n=>n.test_id==='ai.attachment.remote_file'&&shown(n))??null:null;
},10000);
const openRemotePicker=async()=>{
 await click('ai.composer.attachment');const choice=await remoteChoice();
 report.lastAction='ai.attachment.menu/ai.attachment.remote_file';
 assert((await h.clickAt(choice.rect.x+choice.rect.w/2,choice.rect.y+choice.rect.h/2)).ok);
 await visible('ai.remote.picker');
};
const remoteMenu=async(enabled:boolean,name:string)=>{
 await click('ai.composer.attachment');const choice=await remoteChoice();
 assert.equal(choice.focusable===true,enabled,'remote-file menu must follow the current owner capability');
 if(!enabled){await h.clickAt(choice.rect.x+choice.rect.w/2,choice.rect.y+choice.rect.h/2);await h.sleep(200);assert.equal((await actual('ai.remote.picker')).length,0,'disabled remote-file menu must not open a picker')}
 await cap(name);await h.key('escape');
};
const dragTab=async(source:string,target:string)=>{
 const a=await visible(source),b=await visible(target),x=a.rect.x+a.rect.w/2,y=a.rect.y+a.rect.h/2,tx=b.rect.x+b.rect.w/2,ty=b.rect.y+b.rect.h/2;
 assert((await h.mouseDown(x,y)).ok);for(let i=1;i<=8;i++){assert((await h.mouseMove(x+(tx-x)*i/8,y+(ty-y)*i/8)).ok);await h.sleep(35)}assert((await h.mouseUp(tx,ty)).ok);
};
try{
 const ready=await h.waitFor(async()=>{try{return JSON.parse(await readFile(join(iso,'peer','ready.json'),'utf8'))}catch{return null}},10000);
 await writeFile(join(data,'known_hosts'),ready.known_host);
 await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ssh]\nauto_shell_integration=false\nauto_reconnect=false\n');
 await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname=${JSON.stringify(sourceName)}\nhost="127.0.0.1"\nport=${ready.port}\nuser="fixture"\nauth={password="ai-readonly"}\noptions={strict_host_key=true}\n`);
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 app=spawn(process.env.ZW_AI_BINARY??join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 app.on('exit',(code,signal)=>{report.appExit={code,signal}});await h.waitForServerReady(60000);await h.resizeWindow(1440,900);
 await click('workspace.empty.local');await visible('terminal.surface');const localTab=(await tabs())[0].test_id;
 await click('toolbar.ai');await visible('ai.prompt');await remoteMenu(false,'00-local-disabled');await click('ai.close');await h.waitFor(async()=>(await actual('ai.panel')).length===0||null,5000);
 report.checks.push('Local standalone session disables remote-file attachment; clicking the disabled entry opens no picker');
 await click('sidebar.host');await h.key('return');await writeFile(join(out,'live.json'),JSON.stringify({pid:app.pid,iso,rpc,port:ready.port}));
 await h.waitFor(async()=>{const inputs=await actual('plugin.challenge.secret');if(inputs[0]){const n=inputs[0];await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);await h.type_('ai-readonly');const submit=(await actual('plugin.challenge.submit'))[0];if(submit)await h.clickAt(submit.rect.x+submit.rect.w/2,submit.rect.y+submit.rect.h/2);}return (await tabs()).length===2&&(await h.query('terminal.input')).some(shown)?true:null},process.env.ZW_AI_PICKER_CUA==='1'?180000:20000);await h.sleep(1000);
 await click('toolbar.ai');await visible('ai.prompt');
 await remoteMenu(true,'00-ssh-enabled');
 const filename=async(name:string)=>{const n=await h.waitFor(async()=>(await actual('ai.remote.filename')).find(n=>n.text===name)??null,10000);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)};
 const waitEntries=async(count:number)=>h.waitFor(async()=>{
  const secret=(await actual('plugin.challenge.secret'))[0];if(secret){await h.clickAt(secret.rect.x+secret.rect.w/2,secret.rect.y+secret.rect.h/2);await h.type_('ai-readonly');const submit=(await actual('plugin.challenge.submit'))[0];if(submit)await h.clickAt(submit.rect.x+submit.rect.w/2,submit.rect.y+submit.rect.h/2);}
  return (await actual('ai.remote.entry')).length===count||null;
 },20000);
 const statusIncludes=async(needle:string)=>{
  const info=await visible('ai.remote.info');await h.mouseMove(info.rect.x+info.rect.w/2,info.rect.y+info.rect.h/2);
  await h.waitFor(async()=>(await visible('ai.remote.status')).text.includes(needle)||null,5000);
  assert((await visible('ai.remote.status')).text.includes('附加仅引用来源和路径'));
  await h.mouseMove(20,20);
 };
 const hoverText=async(id:string,tipId:string,expected:string)=>{
  const n=await visible(id);await h.mouseMove(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);
  assert.equal(flat(await visible(tipId)).map(n=>n.text??'').join(''),expected);await h.sleep(220);assert((await h.screenshot(join(out,tipId+'.png'))).ok);await h.mouseMove(20,20);
 };
 await hoverText('ai.composer.model','ai.composer.model.tooltip','未配置模型');
 const setPath=async(path:string)=>{await click('ai.remote.path');await h.key('a',{cmd:true});await h.type_(path);await h.key('return')};
 await click('ai.prompt');await h.type_('检查 ');await h.type_('/');await h.sleep(200);
 assert.equal((await h.inputState('ai.prompt')).buffer,'检查 /');
 assert.equal((await actual('ai.remote.picker')).length,0,'slash must remain ordinary prompt text');
 await openRemotePicker();await waitEntries(3);
 const sourceTrigger=await visible('ai.remote.source');await h.mouseMove(sourceTrigger.rect.x+sourceTrigger.rect.w/2,sourceTrigger.rect.y+sourceTrigger.rect.h/2);
 const sourceTip=await visible('ai.remote.source.tooltip');assert.equal(flat(sourceTip).map(n=>n.text??'').join(''),sourceName);
 assert(sourceTip.rect.x>=0&&sourceTip.rect.x+sourceTip.rect.w<=1440);await cap('01-source-name-tooltip');await h.mouseMove(20,20);
 report.checks.push('Source tooltip shows the complete selected name without changing the bounded trigger');
 assert.equal((await h.inputState('ai.prompt')).buffer,'检查 /');
 assert.equal((await h.inputState('ai.remote.path')).buffer,'/fixture');await hoverText('ai.remote.filename','ai.remote.filename.tooltip','a.txt');
 assert.equal((await actual('ai.remote.status')).length,0,'status help stays hidden until hover');await statusIncludes('未选择文件');await cap('01-directory');report.checks.push('Slash stays ordinary text; the plus-menu opens the native picker, preserves the prompt, and automatically resolves /fixture without shell OSC 7');
 await click('ai.remote.filter');await h.type_('no-match');await h.waitFor(async()=>(await visible('ai.remote.empty')).text.includes('没有匹配')||null,5000);
 await h.key('a',{cmd:true});await h.key('backspace');await waitEntries(3);
 await filename('logs');await waitEntries(3);assert.equal((await h.inputState('ai.remote.path')).buffer,'/fixture/logs');await click('ai.remote.parent');await waitEntries(3);
 await setPath('/missing');await h.waitFor(async()=>(await visible('ai.remote.empty')).text.includes('不存在')||null,10000);await cap('02-missing-directory');await click('ai.remote.home');await waitEntries(3);
 await setPath('/');await waitEntries(1);await filename('fixture');await waitEntries(3);
 report.checks.push('Enter opens a path; directory entry, parent, root, home, empty filter and missing-path recovery work through real SFTP');
 await filename('a.txt');await visible('ai.remote.picker');await statusIncludes('1 个文件');
 const second=(await actual('ai.remote.filename')).find(n=>n.text==='b.log');assert(second);const box=(await actual('ai.remote.entry')).find(n=>Math.abs(n.rect.y+n.rect.h/2-(second.rect.y+second.rect.h/2))<4);assert(box);await h.clickAt(box.rect.x+box.rect.w/2,box.rect.y+box.rect.h/2);
 await statusIncludes('2 个文件');await cap('03-two-selected');await click('ai.remote.attach');
 await h.waitFor(async()=>(await actual('ai.attachment.remote_file')).length===2||null,20000);await h.waitFor(async()=>(await actual('ai.remote.picker')).length===0||null,5000);await cap('04-two-attached');
 report.checks.push('Filename and checkbox selection produce two independent native draft attachments; successful attachment closes the picker');
 const fileIO=async()=>{
  const lines=async(name:string)=>{try{return (await readFile(join(iso,'peer',name),'utf8')).trim().split('\n').filter(Boolean).map(line=>JSON.parse(line))}catch(error:any){if(error.code==='ENOENT')return [];throw error}};
  return {opens:await lines('opens.jsonl'),reads:await lines('reads.jsonl')};
 };
 assert.deepEqual(await fileIO(),{opens:[],reads:[]},'attaching two remote paths must not open or read either file');
 const metadata=(await actual('ai.attachment.metadata')).map(n=>n.text);assert(metadata.every(text=>text.includes('远程引用')&&!text.includes('0 B')));
 await h.resizeWindow(860,480);await click('ai.attachment.open');await visible('ai.attachment.preview');
 assert.equal((await visible('ai.attachment.preview.text')).text,'仅引用远程来源和路径');
 await hoverText('ai.attachment.preview.path','ai.attachment.preview.path.tooltip',(await visible('ai.attachment.preview.path')).text);await cap('05-compact-reference');await click('ai.attachment.preview.close');
 assert.deepEqual(await fileIO(),{opens:[],reads:[]},'viewing a reference displays its locator without file IO');
 await openRemotePicker();await waitEntries(3);await cap('06-compact-picker');
 const sourceControl=await visible('ai.remote.source'),pathControl=await visible('ai.remote.path');
 assert.equal(sourceControl.rect.w,180);assert.equal(sourceControl.rect.y,pathControl.rect.y);assert(pathControl.rect.w>=400);assert(sourceControl.rect.x+sourceControl.rect.w<pathControl.rect.x);
 const picker=await visible('ai.remote.picker');assert(picker.rect.y>=0&&picker.rect.y+picker.rect.h<=480);report.pickerRect=picker.rect;
 const feedbackIncludes=async(needle:string)=>h.waitFor(async()=>{const n=(await actual('ai.remote.feedback'))[0];return n?.text?.includes(needle)?n:null},10000);
 await setPath('/fixture/logs');await waitEntries(3);await filename('Rocky-8.10-x86_64-dvd1.iso');await click('ai.remote.read');
 await feedbackIncludes('正在读取预览');assert(!(await visible('ai.remote.read')).focusable,'preview is disabled during the read');
 const binaryFeedback=await feedbackIncludes('二进制文件');await visible('ai.remote.picker');
 assert.equal((await actual('ai.attachment.remote_file')).length,2);
 assert((await visible('ai.remote.attach')).focusable,'attach remains usable after a failed preview');
 const previewButton=await visible('ai.remote.read');assert(binaryFeedback.rect.x+binaryFeedback.rect.w<=previewButton.rect.x,'error fits before the actions');
 await cap('06-binary-preview-error');
 const binaryIO=await fileIO();assert.equal(binaryIO.opens.length,1);assert.equal(binaryIO.reads.length,1);report.binaryReads=binaryIO.reads;
 await click('ai.remote.attach');await h.waitFor(async()=>(await actual('ai.attachment.remote_file')).length===3||null,10000);await h.waitFor(async()=>(await actual('ai.remote.picker')).length===0||null,5000);
 assert.deepEqual(await fileIO(),binaryIO,'attaching the ISO must not trigger another file open or read');await cap('06-binary-reference-attached');
 await openRemotePicker();await waitEntries(3);await setPath('/fixture/logs');await waitEntries(3);await filename('invalid-utf8.txt');await click('ai.remote.read');await feedbackIncludes('UTF-8');await cap('06-encoding-preview-error');
 const encodingIO=await fileIO();await click('ai.remote.attach');await h.waitFor(async()=>(await actual('ai.attachment.remote_file')).length===4||null,10000);await h.waitFor(async()=>(await actual('ai.remote.picker')).length===0||null,5000);
 assert.deepEqual(await fileIO(),encodingIO,'invalid encoding does not prevent path attachment or cause another read');
 report.checks.push('Text, 16.5 GB ISO and invalid-UTF8 paths attach without opening or reading files; explicit ISO/encoding previews show specific inline errors, and attach remains usable');
 await openRemotePicker();await waitEntries(3);await filename('b.log');await click('ai.remote.read');await visible('ai.attachment.preview');
 await h.waitFor(async()=>(await visible('ai.attachment.preview.text')).text.includes('second captured source')||null,10000);assert.equal((await actual('ai.attachment.remote_file')).length,4);
 await hoverText('ai.attachment.preview.path','ai.attachment.preview.path.tooltip',(await visible('ai.attachment.preview.path')).text);await cap('07-explicit-text-preview');
 const previewIO=await fileIO();assert(previewIO.reads.some(read=>read.path==='/fixture/b.log'));
 assert(flat(await visible('ai.attachment.preview.keep')).some(n=>n.text==='附加引用'));await click('ai.attachment.preview.keep');
 await h.waitFor(async()=>(await actual('ai.attachment.remote_file')).length===5||null,10000);await h.waitFor(async()=>(await actual('ai.attachment.preview')).length===0||null,5000);
 assert.deepEqual(await fileIO(),previewIO,'confirming a preview adds only the reference and performs no additional read');
 assert((await actual('ai.attachment.metadata')).every(n=>n.text.includes('远程引用')));report.fileIO=await fileIO();await cap('07-all-references');
 report.checks.push('Explicit text preview still reads file content; confirming it adds a remote reference, and all five draft entries are labeled as references at 860×480');
 if(!process.argv.includes('--attachments-only')){
 if((await actual('ai.remote.picker')).length)await click('ai.remote.close');await h.resizeWindow(1440,900);await click('ai.close');await click(localTab);
 await click('toolbar.ai');await visible('ai.prompt');await remoteMenu(false,'08-local-after-ssh');await click('ai.close');
 const existingTabs=await tabs();await click('toolbar.new_session');await click('session.menu.local');await visible('terminal.surface');
 const secondLocal=(await tabs()).find(n=>!existingTabs.some(old=>old.test_id===n.test_id));assert(secondLocal);
 await dragTab(secondLocal.test_id,localTab);await visible('groups.workspace');await click('toolbar.ai');await visible('ai.prompt');await remoteMenu(false,'09-local-group-disabled');await click('ai.close');
 const groupTab=(await tabs()).find(n=>flat(n).some(c=>c.test_id==='tabs.group_marker'));assert(groupTab);
 const sshTab=(await tabs()).find(n=>n.test_id!==groupTab.test_id);assert(sshTab);await dragTab(sshTab.test_id,groupTab.test_id);
 await h.waitFor(async()=>(await tabs()).length===1||null,10000);await click('toolbar.ai');await visible('ai.prompt');await remoteMenu(true,'10-mixed-group-enabled');
 await openRemotePicker();await waitEntries(3);await cap('11-mixed-group-picker');
 const reopenedSource=await visible('ai.remote.source');await h.mouseMove(reopenedSource.rect.x+reopenedSource.rect.w/2,reopenedSource.rect.y+reopenedSource.rect.h/2);assert.equal(flat(await visible('ai.remote.source.tooltip')).map(n=>n.text??'').join(''),sourceName);
 await click('ai.remote.close');await h.waitFor(async()=>(await actual('ai.remote.source.tooltip')).length===0||null,5000);await h.waitFor(async()=>(await actual('ai.remote.info.tooltip')).length===0||null,5000);
 report.checks.push('Switching SSH to Local refreshes the menu; Local-only group disables remote attachment; adding a readable SSH member enables it and lists real remote files');
 }
 const exited=new Promise(resolve=>app.once('exit',resolve));assert((await h.request('POST','/zerowork/windows',{action:'quit'})).ok);
 await Promise.race([exited,h.sleep(10000)]);assert.equal(app.exitCode,0,'Normal Quit exits cleanly');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);report.authNodes=Object.fromEntries(await Promise.all(['plugin.challenge.secret','plugin.challenge.answer.0','auth.challenge.answer.0','plugin.challenge.modal','auth.challenge.modal'].map(async id=>[id,(await h.query(id)).map(n=>({id:n.id,rect:n.rect,opacity:n.effective_opacity}))])));process.exitCode=1;await cap('failure').catch(()=>{})}
finally{for(const child of [app,peer]){if(child&&child.exitCode===null&&child.signalCode===null){const closed=new Promise(r=>child.once('close',r));child.kill('SIGTERM');await closed;}}await log.close();await plog.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report))}
