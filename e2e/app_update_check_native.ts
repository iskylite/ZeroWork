/** Exercise the real stable feed through the current macOS network settings. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,copyFile,writeFile,open,rm,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const build=resolve(process.argv[2]??'/tmp/zerowork-update-fix');
const out=resolve(process.argv[3]??'/tmp/zerowork-update-fix-evidence');await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp('/tmp/zw-update-check-')),rpc=join(base,'rpc'),data=join(base,'data'),bundle=join(base,'ZeroWork.app'),mac=join(bundle,'Contents/MacOS');
await Promise.all([rpc,data,mac].map(p=>mkdir(p,{recursive:true})));
for(const name of ['zerowork','zw_ipc.so','zw_execution.so','zw_secret_consume.so','zw_execution_guard'])await copyFile(join(build,'bin',name),join(mac,name==='zerowork'?'ZeroWork':name));
await writeFile(join(data,'config.toml'),'[updates]\nauto_check = false\n');
await writeFile(join(bundle,'Contents/Info.plist'),'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.zerowork.app</string><key>CFBundleExecutable</key><string>ZeroWork</string><key>CFBundlePackageType</key><string>APPL</string><key>ZeroWorkReleaseVersion</key><string>0.3.0-rc21</string></dict></plist>');
const identity=execFileSync('python3',['scripts/macos_signing.py','identity'],{encoding:'utf8'}).trim();
execFileSync('/usr/bin/codesign',['--force','--deep','--sign',identity,'--identifier','com.zerowork.app',bundle]);
const root=join(process.env.HOME!,'Library/Application Support/com.zerowork.updater',createHash('sha256').update(bundle+'\n'+data).digest('hex').slice(0,32));
const log=await open(join(out,'app.log'),'w');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const app=spawn(join(mac,'ZeroWork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',(code,signal)=>r({code,signal})));
const route=(action:string,extra={})=>h.request('POST','/zerowork/update',{action,...extra});
const visible=async(id:string)=>h.waitFor(async()=> (await h.query(id)).find(n=>n.visible!==false&&n.rect.w>0&&n.rect.h>0)||null);
const text=async(id:string)=>JSON.stringify(await h.query(id));
try{
 await h.waitForServerReady();await h.resizeWindow(1000,700);
 await h.clickTestId('toolbar.settings');await visible('settings.nav.updates');await h.clickTestId('settings.nav.updates');
 await route('open');await h.waitFor(async()=> (await text('update.title')).includes('暂无可用的正式版更新')||null,60000);
 assert((await text('update.detail')).includes('正式版通道尚未发布可用版本'));
 const measures=[];
 for(const theme of ['dark','light','sauber']){
  await route('theme',{theme_name:theme});await h.sleep(120);
  const panel=await visible('update.modal'),primary=await visible('update.primary'),cancel=await visible('update.cancel');
  assert(primary.rect.y+primary.rect.h<=panel.rect.y+panel.rect.h);
  measures.push({theme,panel:panel.rect,primary:primary.rect,cancel:cancel.rect});
  await h.screenshot(join(out,theme+'-no-stable.png'));
 }
 await h.resizeWindow(860,480);await h.sleep(100);await h.screenshot(join(out,'compact-no-stable.png'));
 await h.clickTestId('update.primary');await h.waitFor(async()=> (await text('update.title')).includes('暂无可用的正式版更新')||null,60000);
 await h.clickTestId('update.cancel');await h.waitFor(async()=> (await text('settings.updates.version')).includes('暂无正式版')||null);
 await h.screenshot(join(out,'settings-no-stable.png'));
 const report={status:'passed',scope:'real public feed and macOS system proxy; isolated data, no download or install',checks:['confirmed empty stable channel','manual recheck','settings badge','three native themes','compact footer'],measures};
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}catch(error){await h.screenshot(join(out,'failure.png')).catch(()=>{});throw error;}
finally{
 try{await h.request('POST','/zerowork/windows',{action:'quit'});await h.waitFor(async()=>app.exitCode!==null||null,15000);}catch{if(app.exitCode===null)app.kill('SIGTERM');}
 await ended;await log.close();await rm(base,{recursive:true,force:true});await rm(root,{recursive:true,force:true});
}
