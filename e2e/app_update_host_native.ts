/** Real app host integration; package injection only supplies presentation state.
 * Exercises two real PTYs, cancellation/adoption, config Save and live themes. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,copyFile,writeFile,readFile,open,rm,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[3]??'dist/update-validation/host');await mkdir(out,{recursive:true});
const build=process.argv[2]??'/tmp/zw-update-debug';
const base=await realpath(await mkdtemp('/tmp/zw-update-host-')),rpc=join(base,'rpc'),data=join(base,'data'),bundle=join(base,'ZeroWork.app'),mac=join(bundle,'Contents/MacOS');
await Promise.all([rpc,data,mac].map(p=>mkdir(p,{recursive:true})));
await copyFile(join(build,'bin/zerowork'),join(mac,'ZeroWork'));
for(const name of ['zw_ipc.so','zw_execution.so','zw_secret_consume.so','zw_execution_guard'])await copyFile(join(build,'bin',name),join(mac,name));
await writeFile(join(data,'config.toml'),'[updates]\nauto_check = true\n');
await writeFile(join(bundle,'Contents/Info.plist'),`<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.zerowork.app</string><key>CFBundleName</key><string>ZeroWork Update Check</string><key>CFBundleExecutable</key><string>ZeroWork</string><key>CFBundlePackageType</key><string>APPL</string><key>ZeroWorkReleaseVersion</key><string>0.3.0-rc1</string></dict></plist>`);
const identity=execFileSync('python3',['scripts/macos_signing.py','identity'],{encoding:'utf8'}).trim();execFileSync('/usr/bin/codesign',['--force','--deep','--sign',identity,'--identifier','com.zerowork.app',bundle]);
const root=join(process.env.HOME!,'Library/Application Support/com.zerowork.updater',createHash('sha256').update(bundle+'\n'+data).digest('hex').slice(0,32));
await mkdir(root,{recursive:true,mode:0o700});await writeFile(join(root,'check.json'),JSON.stringify({time:Date.now()/1000}));
const log=await open(join(out,'app.log'),'w');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const app=spawn(join(mac,'ZeroWork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<any>(r=>app.once('close',(code,signal)=>r({code,signal})));
const checks:string[]=[];
const route=async(action='snapshot',extra={})=>h.request('POST','/zerowork/update',{action,...extra}) as Promise<any>;
const flat=(ns:any[]):any[]=>ns.flatMap(n=>[n,...flat(n.children??[])]);
const visible=async(id:string)=>h.waitFor(async()=> (await h.query(id)).find(n=>n.visible!==false&&n.rect.w>0&&n.rect.h>0)||null);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id);};
const allTabs=async()=>flat(await h.query('tabs.strip')).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??'')&&n.rect.w>0);
try{
 await h.waitForServerReady();await h.resizeWindow(1000,700);
 await click('toolbar.settings');await click('settings.nav.updates');
 for(const theme of ['dark','light','sauber']){await route('theme',{theme_name:theme});await h.sleep(120);await h.screenshot(join(out,theme+'-settings.png'));await writeFile(join(out,theme+'-settings-geometry.json'),JSON.stringify({version:(await visible('settings.updates.version')).rect,preferences:(await visible('settings.updates.preferences')).rect,open:(await visible('settings.updates.open')).rect},null,2));}
 const initialConfig=await readFile(join(data,'config.toml'),'utf8');await click('settings.field.auto_check');
 assert.equal(await readFile(join(data,'config.toml'),'utf8'),initialConfig);
 await click('settings.revert');assert.equal(await readFile(join(data,'config.toml'),'utf8'),initialConfig);
 await click('settings.field.auto_check');await click('settings.save');await h.waitFor(async()=> (await readFile(join(data,'config.toml'),'utf8')).includes('auto_check = false')||null,10000);
 await click('settings.close');await click('toolbar.settings');await click('settings.nav.updates');
 await click('settings.field.auto_check');await click('settings.save');await h.waitFor(async()=> (await readFile(join(data,'config.toml'),'utf8')).includes('auto_check = true')||null,10000);
 await click('settings.close');checks.push('About/update page opens without index overflow; theme snapshots; automatic preference saves only on Save, can revert, and reads back on reopen');

 await click('workspace.empty.local');await h.waitFor(async()=> (await allTabs()).length===1||null);
 // Both processes ignore graceful signals; the existing PTY close policy owns escalation.
 await h.type_("trap '' HUP TERM; while :; do sleep 1; done");await h.key('return');await h.sleep(200);
 await h.key('t',{cmd:true});await click('session.menu.local');await h.waitFor(async()=> (await allTabs()).length===2||null);
 await h.type_("trap '' HUP TERM; while :; do sleep 1; done");await h.key('return');await h.sleep(200);
 await route('ready');await visible('update.modal');
 await click('update.primary');await h.waitFor(async()=> (await route()).phase==='confirm'||null);
 const measures:any[]=[];
 for(const theme of ['dark','light','sauber']){
  await route('theme',{theme_name:theme});await h.sleep(150);
  const panel=await visible('update.modal'),primary=await visible('update.primary'),cancel=await visible('update.cancel');
  assert(Math.abs(panel.rect.w-520)<1);assert(primary.rect.h>=31);assert(primary.rect.w>=100);const primaryText=flat([primary]).filter(n=>n.text).map(n=>n.text).join('');assert(primaryText.includes('结束任务并安装'));assert(cancel.rect.y+cancel.rect.h<=panel.rect.y+panel.rect.h);
  await h.mouseMove(1,1);await h.screenshot(join(out,theme+'-confirm.png'));measures.push({theme,panel:panel.rect,primary:primary.rect,cancel:cancel.rect,detail:(await visible('update.detail')).rect,summary:(await visible('update.summary')).rect,message:(await visible('update.message')).rect,state:await route()});
 }
 checks.push('same native modal follows dark/light/Sauber while preserving confirmation state');
 await h.resizeWindow(860,480);await h.sleep(100);await h.screenshot(join(out,'compact-confirm.png'));
 const panel=await visible('update.modal'),cancel=await visible('update.cancel');assert(cancel.rect.y+cancel.rect.h<=panel.rect.y+panel.rect.h);checks.push('compact viewport keeps footer reachable');
 await click('update.primary');
 let state=await h.waitFor(async()=>{const s=await route();return s.phase==='closing'&&s.draining>0&&s.work.filter((w:any)=>w.operation!==null).length>=1?s:null;});
 const batch=state.batch;const issued=state.work.filter((w:any)=>w.operation!==null);assert(state.gate);assert(state.intent);
 const snapshot=JSON.parse(await readFile(join(root,'pre-close-workspace.json'),'utf8'));assert.equal(snapshot.phase,'before-close');assert.equal(snapshot.windows[0].tabs.length,2);
 checks.push('pre-close snapshot contains both real local sessions before removal');
 await click('update.cancel');state=await h.waitFor(async()=>{const s=await route();return !s.gate&&!s.intent?s:null;});
 assert.equal(state.work.filter((w:any)=>w.operation!==null).length,issued.length);assert(state.draining>0);
 checks.push('cancel releases global gate, keeps outstanding original close and does not dispatch remaining owner');
 await route('open');await visible('update.modal');await h.screenshot(join(out,'cancel-draining.png'));
 await click('update.primary');await h.waitFor(async()=> (await route()).phase==='confirm'||null);await click('update.primary');
 state=await route();assert.equal(state.batch,batch);for(const old of issued){const adopted=state.work.find((w:any)=>w.owner===old.owner);assert.equal(adopted.operation,old.operation);}
 checks.push('restart install adopts exact issued close operation and batch');
 await click('update.cancel');await h.waitFor(async()=> (await route()).draining===0||null,12000);
 state=await route();assert.equal(state.work.filter((w:any)=>w.operation!==null).length,issued.length);assert((await allTabs()).length>=1);
 const preserved=JSON.parse(await readFile(join(root,'pre-close-workspace.json'),'utf8'));assert.equal(preserved.windows[0].tabs.length,2);
 checks.push('real PTY close receipt drains after cancel, remaining local session survives, snapshot stays pre-close');
 await h.key('t',{cmd:true});await click('session.menu.local');await h.waitFor(async()=> (await allTabs()).length>=2||null);checks.push('new real local session can be created after cancellation');
 await writeFile(join(out,'report.json'),JSON.stringify({status:'passed',checks,measures,state},null,2));console.log(JSON.stringify({status:'passed',checks}));
}catch(error){await writeFile(join(out,'failure.json'),JSON.stringify({error:String(error),fields:await h.query('settings.field.auto_check'),footer:await h.query('settings.footer.state'),config:await readFile(join(data,'config.toml'),'utf8')},null,2));await h.screenshot(join(out,'failure.png'));throw error;}finally{
 try{await h.request('POST','/zerowork/windows',{action:'quit'});await h.waitFor(async()=>app.exitCode!==null||null,15000);}catch{if(app.exitCode===null)app.kill('SIGTERM');}
 await ended;await log.close();await rm(base,{recursive:true,force:true});await rm(root,{recursive:true,force:true});
}
