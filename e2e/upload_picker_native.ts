/** Real @up chooser regression: disposable loopback SSH, actual NSOpenPanel,
 * native window captures while modal, cancel only; never selects/uploads files. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdir,mkdtemp,realpath,copyFile,readFile,writeFile,open,readdir,rm} from 'node:fs/promises';
import {join,resolve,dirname} from 'node:path';
import {createHash} from 'node:crypto';
import * as h from '../vendor/zenit/e2e/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);await mkdir(out,{recursive:false});
const iso=await realpath(await mkdtemp('/private/tmp/zw-up-picker-')),rpc=join(iso,'rpc'),data=join(iso,'data'),remote=join(iso,'remote');await mkdir(rpc);await mkdir(data);
const peerLog=await open(join(out,'peer.log'),'w');
const peer=spawn(process.env.ZW_TEST_PYTHON??'uv',process.env.ZW_TEST_PYTHON?['e2e/builtin_records_ssh_peer.py','--out',join(out,'peer'),'--sftp-root',remote]:['run','--with','paramiko','python','e2e/builtin_records_ssh_peer.py','--out',join(out,'peer'),'--sftp-root',remote],{stdio:['ignore',peerLog.fd,peerLog.fd]});
const peerEnd=new Promise(r=>peer.once('close',r));let app:any,appEnd:Promise<unknown>|undefined,appLog:any;
const report:any={status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),out,checks:[],modal_captures:[],uploads:false,limits:['Modal screenshot pixels require visual review; post-cancel palette state is asserted.']};
const shown=(n:any)=>n?.rect?.w>0&&n.rect.h>0&&n.hidden!==true&&n.visible!==false;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{const n=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)};
const os=(code:string)=>execFileSync('osascript',['-e',code],{encoding:'utf8',timeout:8000}).trim();
const windowTool=join(iso,'native-window-list');
const windows=()=>JSON.parse(execFileSync(windowTool,[String(app.pid)],{encoding:'utf8'}));
try{
 execFileSync('swiftc',['e2e/native_window_list.swift','-o',windowTool]);
 const ready=await h.waitFor(async()=>{try{return JSON.parse(await readFile(join(out,'peer/ready.json'),'utf8'))}catch{return null}},30000);
 await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[transfer]\ndedicated_connection=false\n');
 await writeFile(join(data,'known_hosts'),ready.known_host);
 await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Upload picker verification"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
 const mac=join(out,'Upload-Picker-Verification.app/Contents/MacOS');await mkdir(mac,{recursive:true});
 await writeFile(join(mac,'../Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>local.zerowork.uploadpicker.${process.pid}</string><key>CFBundleName</key><string>Upload Picker Verification</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
 await copyFile(binary,join(mac,'zerowork'));for(const name of ['zw_ipc.so','zw_execution.so','zw_execution_guard','zw_secret_consume.so'])await copyFile(join(dirname(binary),name),join(mac,name));
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;appLog=await open(join(out,'app.log'),'w');
 app=spawn(join(mac,'zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'0',ZENIT_E2E_REAL_ACTIVATION:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',appLog.fd,appLog.fd]});appEnd=new Promise(r=>app.once('close',r));
 report.pid=app.pid;report.rpc=rpc;await writeFile(join(out,'session.json'),JSON.stringify(report,null,2));
 await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1280,820);
 const host=await visible('sidebar.host');await h.mouseMove(host.rect.x+host.rect.w-22,host.rect.y+host.rect.h/2);await click('sidebar.host.connect');
 await h.waitFor(async()=>(await h.query('workspace.pane')).some(n=>text(n).includes('sshrecords'))||null,30000);await click('terminal.surface');await h.sleep(400);
 await h.type_(`cd '${remote}'`);await h.key('return');await h.sleep(500);
 const initial=windows(),main=initial.find((w:any)=>w.kCGWindowName==='ZeroWork'&&w.kCGWindowIsOnscreen&&w.kCGWindowBounds.Height>300);assert(main,'Real app window exists');
 report.main_window_id=main.kCGWindowNumber;
 for(const attempt of [1,2]){
  await h.type_('@up');await visible('terminal.commands');assert((await h.screenshot(join(out,`palette-before-${attempt}.png`))).ok);
  await h.key('return');
  const modal=await h.waitFor(async()=>{const list=windows();return list.find((w:any)=>w.kCGWindowName==='选择要上传的文件'&&w.kCGWindowIsOnscreen)||null},10000);
  const ax=os(`tell application "System Events" to tell (first process whose unix id is ${app.pid}) to get name of every window`);assert(ax.includes('选择要上传的文件'),'Actual upload chooser is open');
  await h.sleep(300);
  const during=windows();await writeFile(join(out,`windows-during-${attempt}.json`),JSON.stringify({ax,windows:during},null,2));
  execFileSync('/usr/sbin/screencapture',['-x','-l',String(main.kCGWindowNumber),join(out,`terminal-during-picker-${attempt}.png`)]);
  execFileSync('/usr/sbin/screencapture',['-x','-l',String(modal.kCGWindowNumber),join(out,`native-picker-${attempt}.png`)]);
  report.modal_captures.push(`terminal-during-picker-${attempt}.png`,`native-picker-${attempt}.png`);await writeFile(join(out,'stage.txt'),`captured-modal-${attempt}`);
  os(`tell application "System Events"
 tell (first process whose unix id is ${app.pid})
  set frontmost to true
  key code 53
 end tell
end tell`);
  await h.waitFor(async()=>!(await h.query('terminal.commands')).some(shown)||null,15000);
  await h.waitFor(async()=>(await h.query('terminal.command.output')).filter(n=>text(n).includes('已取消选择')).length>=attempt||null,15000);
  assert(!(await h.query('transfer.task')).some(shown));assert((await h.screenshot(join(out,`after-cancel-${attempt}.png`))).ok);
  report.checks.push(`Real upload chooser open/cancel ${attempt}; palette hidden afterwards; no transfer added`);
 }
 const audit=Buffer.concat(await Promise.all((await readdir(join(out,'peer'))).filter(n=>n.startsWith('received-')).map(n=>readFile(join(out,'peer',n))))).toString();assert(!audit.includes('@up'));report.checks.push('Builtin @up never sent to interactive SSH');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));if(app?.exitCode===null)app.kill('SIGTERM');if(appEnd)await Promise.race([appEnd,h.sleep(2500)]);if(app?.exitCode===null)app.kill('SIGKILL');if(peer.exitCode===null)peer.kill('SIGTERM');await Promise.race([peerEnd,h.sleep(2500)]);await appLog?.close();await peerLog.close();await rm(iso,{recursive:true,force:true});console.log(report);}
