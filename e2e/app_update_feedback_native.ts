/** Isolated native update feedback: progress/help, force confirmation, and deleted AI drafts.
 * Injects presentation only; never invokes an installer or replaces the user's app. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,copyFile,writeFile,readFile,open,rm,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
const build=resolve(process.argv[2]??'zig-out');
const out=resolve(process.argv[3]??'/tmp/zw-update-feedback');await mkdir(out,{recursive:true});
const h=await import(pathToFileURL(join(build,'share/zenit/harness/client.ts')).href);
const base=await realpath(await mkdtemp('/tmp/zw-update-feedback-')),rpc=join(base,'rpc'),data=join(base,'data'),bundle=join(base,'ZeroWork.app'),mac=join(bundle,'Contents/MacOS');
await Promise.all([rpc,data,mac].map(p=>mkdir(p,{recursive:true})));
for(const name of ['zerowork','zw_ipc.so','zw_execution.so','zw_secret_consume.so','zw_execution_guard'])await copyFile(join(build,'bin',name),join(mac,name==='zerowork'?'ZeroWork':name));
await writeFile(join(data,'config.toml'),'[updates]\nauto_check = false\n');
await writeFile(join(bundle,'Contents/Info.plist'),'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.zerowork.app</string><key>CFBundleExecutable</key><string>ZeroWork</string><key>CFBundlePackageType</key><string>APPL</string><key>ZeroWorkReleaseVersion</key><string>0.3.0-rc1</string></dict></plist>');
const identity=execFileSync('python3',['scripts/macos_signing.py','identity'],{encoding:'utf8'}).trim();execFileSync('codesign',['--force','--deep','--sign',identity,'--identifier','com.zerowork.app',bundle]);
const root=join(process.env.HOME!,'Library/Application Support/com.zerowork.updater',createHash('sha256').update(bundle+'\n'+data).digest('hex').slice(0,32));
const log=await open(join(out,'app.log'),'w');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const app=spawn(join(mac,'ZeroWork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',(code,signal)=>r({code,signal})));
const checks:string[]=[];
const route=(action='snapshot',extra={})=>h.request('POST','/zerowork/update',{action,...extra});
const shown=(n:any)=>n&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const visible=(id:string)=>h.waitFor(async()=> (await h.query(id)).find(shown)||null,12000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id);};
const flat=(nodes:any[]):any[]=>nodes.flatMap(n=>[n,...flat(n.children??[])]);
const text=async(id:string)=>flat(await h.query(id)).map(n=>n.text??'').join('');
const cap=(name:string)=>h.screenshot(join(out,name+'.png'));
try{
 await h.waitForServerReady();await h.resizeWindow(1000,700);
 await route('theme',{theme_name:'dark'});await route('downloading');await visible('update.download.progress');
 assert((await text('update.download.progress')).includes('37%'));
 assert(!(await h.query('update.summary')).some(shown));assert(!(await h.query('update.message')).some(shown));
 const help=await visible('update.help');await h.mouseMove(help.rect.x+help.rect.w/2,help.rect.y+help.rect.h/2);
 await visible('update.help.tooltip');assert((await text('update.help.tooltip')).includes('取消下载'));await cap('download-help');
 await h.mouseMove(1,1);await h.waitFor(async()=>!(await h.query('update.help.tooltip')).some(shown)||null);await cap('download');
 await route('downloading',{received:20200000,expected:20200000});await h.waitFor(async()=> (await text('update.download.progress')).includes('100%')||null);
 await route('downloading',{received:1,expected:0});await h.waitFor(async()=>!(await h.query('update.download.progress')).some(shown)||null);
 checks.push('Live native download shows 37% then 100%; unknown totals do not fabricate a percentage; routine text is hidden behind hover help');
 await route('ready');await h.waitFor(async()=> (await text('update.title')).includes('更新已准备好安装')||null);await cap('ready');await click('update.cancel');
 await click('workspace.empty.local');await visible('terminal.surface');await click('ai.strip');await visible('ai.prompt');await click('ai.prompt');await h.type_('UNSENT_DRAFT_FOR_UPDATE');
 await h.waitFor(async()=> (await route()).draft_reason!==null||null);
 await route('open');await click('update.primary');await h.waitFor(async()=> (await route()).can_force||null);
 assert((await text('update.title')).includes('暂时无法安装'));assert((await text('update.detail')).includes('AI 会话'));assert((await text('update.primary')).includes('仍然安装'));await cap('draft-blocked');
 await click('update.primary');const forced=await h.waitFor(async()=>{const s=await route();return s.phase==='confirm'&&s.allow_unsaved?s:null;});
 assert(!forced.gate);assert((await text('update.detail')).includes('可能丢失'));assert((await text('update.primary')).includes('仍然安装并重启'));await cap('force-confirm');
 await click('update.cancel');assert.equal((await route()).allow_unsaved,false);checks.push('Real unsent AI input offers force install; final confirmation names content loss; cancel leaves all work running and resets force permission');
 // End the real composer with its draft, then delete it through the actual list.
 await click('ai.session.new');await click('ai.session.close.accept');await h.mouseMove(1,1);
 await h.waitFor(async()=> (await route()).draft_reason===null||null);
 await click('ai.sessions');const menu=await visible('ai.sessions.menu');
 const ids=[...new Set(flat([menu]).filter(shown).map(n=>n.test_id??'').filter(id=>/^ai.session.delete.\d+$/.test(id)))];assert(ids.length>0);
 for(const id of ids){await click(id);if((await h.query('ai.session.close.accept')).some(shown))await click('ai.session.close.accept');await h.sleep(120);if(id!==ids.at(-1))await click('ai.sessions');}
 await h.waitFor(async()=> (await route()).draft_reason===null||null);
 await route('open');await click('update.primary');await h.waitFor(async()=> (await route()).phase==='confirm'||null);
 assert.equal((await route()).allow_unsaved,false);assert(!(await text('update.message')).includes('未发送'));await cap('deleted-draft-install');await click('update.cancel');
 checks.push('Ended history draft does not block; deleting every listed AI conversation with a draft through native UI then installing reaches normal confirmation without force');
 // Confirm force really enters the normal snapshot/close coordinator, then cancel
 // while an isolated PTY is still releasing. No installer can be reached here.
 if((await h.query('ai.collapse')).some(shown))await click('ai.collapse');
 await click('terminal.surface');await h.type_("trap '' HUP TERM; while :; do sleep 1; done");await h.key('return');await h.sleep(200);
 await click('ai.strip');await click('ai.prompt');await h.type_('FORCE_INSTALL_DRAFT');
 await route('open');await click('update.primary');await h.waitFor(async()=> (await route()).can_force||null);
 await click('update.primary');await h.waitFor(async()=> (await route()).phase==='confirm'||null);await click('update.primary');
 const closing=await h.waitFor(async()=>{const s=await route();return s.phase==='closing'&&s.gate&&s.intent&&s.draining>0?s:null;});
 assert(closing.allow_unsaved);const snapshot=JSON.parse(await readFile(join(root,'pre-close-workspace.json'),'utf8'));assert.equal(snapshot.windows[0].tabs.length,1);await cap('force-closing');
 await click('update.cancel');await h.waitFor(async()=> !(await route()).gate||null);
 checks.push('Final force confirmation bypasses only the unsaved-content guard, saves the real workspace snapshot and starts real PTY cleanup; cancellation releases the install gate');
 await writeFile(join(out,'report.json'),JSON.stringify({status:'passed',checks},null,2));console.log(JSON.stringify({status:'passed',checks}));
}catch(error){await cap('failure').catch(()=>{});await writeFile(join(out,'failure.json'),JSON.stringify({error:String(error),state:await route().catch(()=>null)},null,2));throw error;}
finally{
 try{await h.request('POST','/zerowork/windows',{action:'quit'});await h.waitFor(async()=>app.exitCode!==null||null,12000);}catch{if(app.exitCode===null)app.kill('SIGTERM');}
 await ended;await log.close();await rm(base,{recursive:true,force:true});await rm(root,{recursive:true,force:true});
}
