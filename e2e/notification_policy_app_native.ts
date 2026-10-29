/** Verify local failure routing in the complete native application, with an isolated data directory. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,writeFile,rm,realpath} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'/tmp/zw-notification-policy-app');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-notify-app-')),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(data);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const binary=resolve('zig-out/bin/zerowork'),log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n?.rect&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
const click=async(id:string)=>{const n=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok,id);};
const report:any={status:'running',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],limits:['Real local shell and production app; no remote connection, remote command, or OS permission change.']};
async function capture(name:string){await h.sleep(250);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.tree(),null,2));}
try{
 await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1280,720);
 await click('workspace.empty.local');await visible('terminal.surface');await h.sleep(1000);
 const terminal=await visible('terminal.surface');await h.clickAt(terminal.rect.x+30,terminal.rect.y+30);await h.type_('zerowork_missing_notification_policy_command');await h.key('return');
 await visible('terminal.ai-error-hint');await absent('notifications.toast.0');await absent('notifications.unread');await capture('local-command-error');
 await click('terminal.ai-error-hint.dismiss');await click('toolbar.notifications');await visible('notifications.history.empty');await absent('notifications.history.record');await capture('local-error-no-global-record');
 await click('notifications.history.recent');await visible('notifications.history.empty');await absent('notifications.history.record');
 await click('notifications.history.close');await h.key('w',{cmd:true});await click('toolbar.notifications');await visible('notifications.history.empty');await absent('notifications.unread');
 report.checks=['real shell failure shows local AI analysis hint','ordinary command failure produces no global banner or unread','dismissing local hint does not add pending or recent records','closing source does not recreate global history'];report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});process.exitCode=1;}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await Promise.race([ended,h.sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}await log.close();await rm(iso,{recursive:true,force:true});}
console.log(JSON.stringify({status:report.status,out,error:report.error}));
