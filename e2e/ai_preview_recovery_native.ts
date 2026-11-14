/** Owned native regression: portal previews, sustained reasoning, failure recovery and notifications. */
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,writeFile,open,realpath,copyFile} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const verifyFilePicker=process.env.ZW_AI_SKIP_FILE_PICKER!=='1';
const out=resolve(process.argv[2]??'dist/ui-acceptance/ai-preview-recovery-20261029');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-preview-recovery-')),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
const testTheme=process.env.ZW_AI_TEST_THEME??'dark';assert(['dark','light','sauber'].includes(testTheme));
const textFile=join(iso,'report.html'),archiveFile=join(iso,'archive-fixture'),imageFile=resolve('assets/macos/AppIcon.png');await writeFile(textFile,Array.from({length:150},(_,i)=>`<tr><td>Row ${i+1}</td><td>Captured UTF-8 report</td></tr>`).join('\n'));
await writeFile(archiveFile,Buffer.from([0x1f,0x8b,0x08,0,0,0,0,0,0,3]));
const frame=(delta:any)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
let mode='long',held:any=null,requestCount=0,longStart=0;const timers=new Set<any>();
const server=createServer(async(req,res)=>{if(req.method!=='POST'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'preview-fixture',context_window:200000}]}));return;}
let bytes='';for await(const chunk of req)bytes+=chunk;requestCount++;const body=JSON.parse(bytes);assert(body.messages.length);
if(mode==='failure'){res.writeHead(400,{'content-type':'application/json'});res.end(JSON.stringify({error:{message:'Owned fixture rejects this request'}}));return;}
res.writeHead(200,{'content-type':'text/event-stream'});res.flushHeaders();
if(mode==='long'){longStart=Date.now();held=res;res.write(frame({reasoning_content:'正在核对报告中的具体数值。'}));const timer=setInterval(()=>{if(!res.destroyed)res.write(frame({reasoning_content:'继续核对吞吐量与延迟。'}))},2000);timers.add(timer);res.on('close',()=>{clearInterval(timer);timers.delete(timer)});return;}
if(mode==='stop'){held=res;res.write(frame({reasoning_content:'暂停测试'}));return;}
if(mode==='retry'){assert(!body.tools?.length,'answer-only retry sends no tools');held=res;res.write(frame({reasoning_content:'正在重试并保留已有内容。'}));return;}
res.end(frame({content:'附件检查完成。'})+'data: [DONE]\n\n');});await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${testTheme}"\n[ai]\ndefault_provider="preview-fixture"\npermission_mode="confirm"\nfollow_up_mode="queue"\n[[ai.providers]]\nid="preview-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="preview-fixture"\ncontext_window=200000\ndefault=true\nvision=true\nimage_token_reservation=8192\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');const bundle=join(out,'ZeroWork-Preview-Check.app');await mkdir(join(bundle,'Contents/MacOS'),{recursive:true});
await writeFile(join(bundle,'Contents/Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>PreviewCheck</string><key>CFBundleIdentifier</key><string>local.zerowork.previewcheck</string><key>CFBundleName</key><string>ZeroWork-Preview-Check</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
const binary=join(bundle,'Contents/MacOS/PreviewCheck');await copyFile(resolve('zig-out/bin/zerowork'),binary);await copyFile(resolve('zig-out/bin/zw_ipc.so'),join(bundle,'Contents/MacOS/zw_ipc.so'));
const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZDOTDIR:iso,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:verifyFilePicker?'0':'1',ZENIT_E2E_ISOLATE_POINTER:'1',...(verifyFilePicker?{ZENIT_E2E_REAL_ACTIVATION:'1'}:{})},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const report:any={status:'running',binary,pid:app.pid,checks:[],isolated:iso};
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=async(id:string)=>{report.last=id;return h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000)};
const within=(inner:h.ScreenPos,outer:h.ScreenPos)=>inner.x>=outer.x-.5&&inner.y>=outer.y-.5&&
    inner.x+inner.w<=outer.x+outer.w+.5&&inner.y+inner.h<=outer.y+outer.h+.5;
const assertPreviewBounds=(preview:h.QueryNode,panel:h.QueryNode)=>{
    assert(within(preview.rect,panel.rect),'preview stays inside the assistant');
    for(const axis of ['w','h'] as const){
        const size=panel.rect[axis];
        assert(Math.abs(preview.rect[axis]-Math.min(size-24,size*.78))<=1.5,
            `preview ${axis} follows the assistant bounds`);
    }
};
const nodeText=(node:h.QueryNode):string=>(node.text??'')+(node.children??[]).map(nodeText).join('');
const absent=async(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const cap=async(name:string)=>{assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify({panel:await h.query('ai.panel'),previews:[...await h.query('ai.attachment.preview'),...await h.query('ai.image.preview.panel')],notifications:await h.query('notifications.presenter')},null,2))};
const drop=async(path:string)=>{const p=await visible('ai.prompt');await h.dragAt(p.rect.x+30,p.rect.y+20,0,path);await h.dragAt(p.rect.x+30,p.rect.y+20,3,path)};
const send=async(text:string)=>{await click('ai.prompt');await h.type_(text);await click('ai.send')};
const panelStable=async(before:any)=>{const after=await visible('ai.panel');assert.deepEqual(after.rect,before.rect);const input=await visible('ai.prompt');assert(input.rect.y>=after.rect.y&&input.rect.y+input.rect.h<=after.rect.y+after.rect.h+.5);};
// AppKit owns the chooser, so send its keyboard events through the foreground test app.
const pickerScript=(body:string)=>execFileSync('/usr/bin/osascript',['-e',
    `tell application "System Events"
        tell (first process whose unix id is ${app.pid})
            ${body}
        end tell
    end tell`],{encoding:'utf8',timeout:15000}).trim();
async function selectFile(name:string){
    const sheet='sheet 1 of window "ZeroWork"';
    const goTo=`sheet 1 of ${sheet}`;
    const select=`button "选择" of splitter group 1 of ${sheet}`;
    await click('ai.composer.attachment');
    const entry=await h.waitFor(async()=>{
        const menu=(await h.query('ai.attachment.menu')).find(shown);
        return menu?.children?.flatMap(function descendants(node):h.QueryNode[]{
            return [node,...(node.children??[]).flatMap(descendants)];
        }).find(node=>node.test_id==='ai.attachment.local_text'&&shown(node))??null;
    });
    assert((await h.clickAt(entry.rect.x+entry.rect.w/2,entry.rect.y+entry.rect.h/2)).ok,'open local file chooser');
    report.last='AppKit file chooser';
    await h.waitFor(async()=>pickerScript(`if exists ${sheet} then return (description of ${sheet} is "选择本地文件")
return false`)==='true'||null,10000);
    report.last='AppKit Go to Folder';
    pickerScript(`
        repeat 8 times
            if exists text field 1 of ${goTo} then exit repeat
            set frontmost to true
            delay 0.2
            key code 5 using {command down, shift down}
            delay 0.3
        end repeat
        set value of text field 1 of ${goTo} to ${JSON.stringify(join(iso,name))}
        delay 0.3
        repeat 8 times
            if not (exists ${goTo}) then return
            set frontmost to true
            delay 0.2
            key code 36
            delay 0.3
        end repeat
        error "Go to Folder did not close"`);
    report.last=`AppKit file selection: ${name}`;
    await h.waitFor(async()=>pickerScript(`
        if not (exists ${sheet}) then return true
        if enabled of ${select} then
            click ${select}
            return true
        end if
        set treeItems to entire contents of ${sheet}
        repeat with itemRef in treeItems
            if role of itemRef is "AXImage" and (name of itemRef is ${JSON.stringify(name)} or name of itemRef starts with ${JSON.stringify(name+'.')}) then
                perform action "AXOpen" of contents of itemRef
                return true
            end if
        end repeat
        return false`)==='true'||null);
}

try{
await h.waitForServerReady(60000);
assert((await h.resizeWindow(1440,1000)).ok);
await click('workspace.empty.local');
await visible('terminal.surface');
await click('toolbar.ai');
await visible('ai.prompt');
let panel=await visible('ai.panel');
if(verifyFilePicker){
    await selectFile('report.html');
    await visible('ai.attachment.open');
    await absent('ai.attachment.preview');
    report.checks.push('Selecting a local HTML file attaches it without automatically opening a preview');
    panel=await visible('ai.panel');
    await click('ai.attachment.open');
    const text=await visible('ai.attachment.preview');
    assertPreviewBounds(text,panel);
    assert(nodeText(await visible('ai.attachment.preview.text')).includes('Row 1'));
    await cap('native-text-preview');
    await click('ai.attachment.preview.close');
    await absent('ai.attachment.preview');
    await panelStable(panel);
    report.checks.push('Scoped text preview retains captured source and closes without changing assistant bounds');
}
if(process.env.ZW_AI_SKIP_PREVIEW!=='1'){
    await drop(imageFile);
    await visible('ai.image.filename');
    panel=await visible('ai.panel');
    await absent('ai.image.preview.panel');
    await click('ai.image.filename');
    const image=await visible('ai.image.preview.panel');
    assertPreviewBounds(image,panel);
    const viewport=await visible('ai.image.preview.raster');
    assert(within(viewport.rect,image.rect),'image viewport stays inside the preview');
    const [raster]=viewport.children??[];
    assert(shown(raster),'preview contains a visible image');
    assert(within(raster.rect,viewport.rect),'preview image fits without cropping');
    assert(Math.abs(raster.rect.w-raster.rect.h)<=1,'square image retains its aspect ratio');
    assert(Math.min(viewport.rect.w,viewport.rect.h)-raster.rect.w<=5,'image fills the available space on its limiting axis');
    await cap('native-image-preview');
    await click('ai.image.preview.close');
    await absent('ai.image.preview.panel');
    await panelStable(panel);
    await click('ai.image.preview');
    assert((await h.key('escape')).ok);
    await absent('ai.image.preview.panel');
    await visible('ai.image.filename');
    await panelStable(panel);
    await cap('native-closed-preview');
    report.checks.push('Filename and thumbnail open an aspect-correct image preview; close and Escape preserve the attachment and composer');
}

await send('分析附加报告和图片。');
const running=await visible('ai.turn.running');
const label=await visible('ai.turn.label');
assert(within(label.rect,running.rect),'running label is inside the turn status');
assert.equal(nodeText(label),'～大浪淘金中～');
await h.waitFor(async()=>(await visible('ai.step_group.projection')).text?.includes('正在核对报告中的具体数值。')||null,5000);
const glyphOffset=async()=>{
    const glyph=await visible('ai.turn.wave.glyph');
    return glyph.rect.y-(await visible('ai.turn.running')).rect.y;
};
const initialOffset=await glyphOffset();
await cap('native-thinking-a');
await h.waitFor(async()=>Math.abs(await glyphOffset()-initialOffset)>.5||null,3000);
await h.waitFor(async()=>(await visible('ai.step_group.projection')).text?.includes('继续核对吞吐量与延迟。')||null,6000);
await cap('native-thinking-b');
report.checks.push('The running label animates while the visible reasoning summary receives new SSE text');
await h.waitFor(async()=>Date.now()-longStart>Number(process.env.ZW_AI_STREAM_DURATION_MS??62000)?true:null,70000);
assert(!held.destroyed,'active stream must survive the old 60-second deadline');
await visible('ai.turn.running');
held.end(frame({content:'持续思考已完成。'})+'data: [DONE]\n\n');
await absent('ai.turn.running');
await visible('ai.turn.complete');
assert(nodeText(await visible('ai.conversation')).includes('持续思考已完成。'));
report.checks.push(`Actual SSE reasoning stays connected for ${process.env.ZW_AI_STREAM_DURATION_MS??62000} ms and finishes normally`);
await cap('native-long-complete');
mode='failure';await send('触发请求失败。');await visible('ai.recovery');const failure=await visible('ai.recovery'),status=(await h.query('ai.turn.complete')).filter(shown).at(-1);assert(status&&status.rect.y+status.rect.h<=failure.rect.y+.5,'recovery follows the completed turn status');assert((await visible('ai.recovery.http')).text.includes('HTTP 400'));assert(within((await visible('ai.recovery.reason')).rect,failure.rect),'recovery reason stays inside the card');for(const id of ['ai.recovery.answer','ai.recovery.edit']){const n=await visible(id);assert(n.rect.x>=failure.rect.x&&n.rect.x+n.rect.w<=failure.rect.x+failure.rect.w+.5&&n.rect.y+n.rect.h<=failure.rect.y+failure.rect.h+.5,'recovery actions stay inside the card')}await absent('ai.recovery.details');await cap('native-failure');await click('ai.recovery.details.toggle');await h.waitFor(async()=>{const card=await visible('ai.recovery'),detail=await visible('ai.recovery.details'),toggle=await visible('ai.recovery.details.toggle');return card.rect.h>failure.rect.h+10&&detail.rect.h>0&&Math.abs((toggle.rotate??0)-Math.PI)<.01?true:null},5000);await cap('native-failure-expanded');let stableY:number|undefined,stableCount=0;await h.waitFor(async()=>{const n=await visible('ai.recovery.details.toggle');if(stableY===n.rect.y)stableCount++;else{stableY=n.rect.y;stableCount=0}return stableCount>=3?true:null},3000);const detailToggle=await visible('ai.recovery.details.toggle');assert((await h.clickAt(detailToggle.rect.x+detailToggle.rect.w/2,detailToggle.rect.y+detailToggle.rect.h/2)).ok);await absent('ai.recovery.details');report.checks.push('The failed turn offers a recovery explanation, actions and expandable details');
mode='retry';await click('ai.recovery.answer');await visible('ai.turn.running');await absent('ai.recovery');await absent('ai.feedback');const tree=JSON.stringify(await h.query('ai.conversation'));assert(!tree.includes('重新尝试答复'));await cap('native-retry');held.end(frame({content:'重试成功。'})+'data: [DONE]\n\n');await absent('ai.turn.running');assert(nodeText(await visible('ai.conversation')).includes('重试成功。'));report.checks.push('Answer-only retry sends no tools and shows its final reply without a synthetic retry message or feedback banner');
mode='failure';
if(verifyFilePicker){
    pickerScript('set frontmost to true');
    await h.waitFor(async()=>pickerScript('get frontmost')==='true'||null);
}
await send('再次失败，用于通知检查。');
await visible('ai.recovery');
const notice=await visible('notifications.toast.0');
assert(nodeText(notice).includes('AI 请求失败'));
const detail=await visible('notifications.detail');
assert(within(detail.rect,notice.rect));
assert.match(nodeText(detail),/HTTP 400[\s\S]*Owned fixture rejects this request/);
await cap('native-notification');
await click('notifications.dismiss.0');
await absent('notifications.toast.0');
await absent('notifications.toast.0');
mode='stop';
await send('验证正常停止');
await visible('ai.turn.running');
if(verifyFilePicker){
    await selectFile('archive-fixture');
    await visible('ai.attachment.local_reference');
    await click('ai.prompt');
    await h.type_('检查压缩包');
    assert((await h.key('return',{cmd:true,shift:true})).ok);
    const followup=await visible('ai.followup.pending');
    assert.match(nodeText(followup),/检查压缩包[\s\S]*已附加本机文件引用/);
    assert(!nodeText(followup).includes('<local_file_reference>'));
    report.checks.push('A binary attachment stays a local file reference without exposing provider metadata in the follow-up bubble');
}
await click('ai.stop');
await absent('ai.turn.running');
await absent('ai.recovery');
await absent('notifications.toast.0');
report.checks.push('Stopping a live turn does not produce a recovery card or an error notification');

await click('toolbar.notifications');
const notices=nodeText(await visible('notifications.history'));
assert(!/正在停止 AI|已停止生成|AI (?:停止中|已停止)|AI 操作未完成/.test(notices),'manual stop does not publish an error notification');
await h.waitFor(async()=>(await h.query('notifications.history.details')).some(
    row=>shown(row)&&nodeText(row).includes('Owned fixture rejects this request'))||null);
await cap('native-notification-history');
report.checks.push('AI failure toast shows its diagnostic and notification history retains the full diagnostic');
report.status='passed';report.requests=requestCount;
}catch(error){report.status='failed';report.error=String(error);await cap('failure').catch(()=>{});process.exitCode=1;}finally{for(const timer of timers)clearInterval(timer);held?.destroy();server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));app.kill('SIGTERM');await Promise.race([ended,new Promise(r=>setTimeout(r,2000))]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));}
