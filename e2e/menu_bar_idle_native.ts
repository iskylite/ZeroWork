/** Isolated idle-frame measurement; does not open saved hosts or use user data. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,copyFile,writeFile,readFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const source=resolve(process.argv[2]??'/tmp/zw-menu-maintenance-build/bin/zerowork');
const out=resolve(process.argv[3]??'/tmp/zw-menu-maintenance-idle');await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp('/tmp/zw-menu-idle-')),rpc=join(base,'rpc'),data=join(base,'data'),bundle=join(base,'ZeroWork Idle Check.app'),contents=join(bundle,'Contents'),mac=join(contents,'MacOS');
await Promise.all([rpc,data,mac].map(p=>mkdir(p,{recursive:true})));
await writeFile(join(data,'config.toml'),'[updates]\nauto_check = false\n');
const binary=join(mac,'zerowork');await copyFile(source,binary);
await writeFile(join(contents,'Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.zerowork.idle-check</string><key>CFBundleName</key><string>ZeroWork Idle Check</string><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
const identity=execFileSync('python3',['scripts/macos_signing.py','identity'],{encoding:'utf8'}).trim();
execFileSync('/usr/bin/codesign',['--force','--deep','--sign',identity,'--identifier','com.zerowork.idle-check',bundle],{stdio:'pipe'});
const log=await open(join(out,'app.log'),'w');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const closed=new Promise(r=>app.once('close',r));
const cpuSeconds=()=>{const text=execFileSync('/bin/ps',['-p',String(app.pid),'-o','time='],{encoding:'utf8'}).trim();return text.split(':').reduce((n,v)=>n*60+Number(v),0);};
try{
 await h.waitForServerReady();await h.resizeWindow(1280,800);await h.sleep(2500);
 const start=await h.stats(),cpu0=cpuSeconds(),time0=performance.now();
 await h.sleep(5000);
 const time1=performance.now(),cpu1=cpuSeconds(),end=await h.stats();
 const seconds=(time1-time0)/1000,frames=end.frame_count-start.frame_count;
 const report={source,sha256:createHash('sha256').update(await readFile(source)).digest('hex'),scenario:'empty isolated workspace, 1280x800, background native harness, Debug or supplied binary',seconds,frames,fps:frames/seconds,cpu_percent:(cpu1-cpu0)/seconds*100,cpu_frame_us:end.cpu_frame_us,layout_us:end.layout_us,cpu_p95_us:end.cpu_p95_us,native_click_latency:'not measured by this idle test'};
 await h.screenshot(join(out,'idle-window.png'));
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
 assert(frames/seconds<12,`idle repaint loop: ${frames} frames in ${seconds}s`);
 console.log(JSON.stringify(report));
}finally{if(app.exitCode===null)app.kill('SIGTERM');await closed;await log.close();}
