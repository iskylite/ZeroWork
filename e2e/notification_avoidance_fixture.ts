/** Real host feedback from a connection to a closed owned loopback port.
 * Private app/data/RPC, synthetic Harness input only. Session transfer coverage
 * belongs to the real SFTP upload acceptance, which reuses the same assertion.
 * node e2e/notification_avoidance_fixture.ts --binary PATH --out EMPTY_DIR
 */
import assert from 'node:assert/strict';
import {mkdir,mkdtemp,writeFile,open,readFile,copyFile,realpath} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {createHash} from 'node:crypto';
import {dirname,join,resolve} from 'node:path';
import {waitForServerReady,query,clickTestId,sleep,resizeWindow,key,mouseMove} from '../zig-out/share/zenit/harness/client.ts';
import {verifyNotificationAvoidance} from './notification_avoidance_native.ts';
const options:Record<string,string>={};
for(let i=2;i<process.argv.length;i+=2){assert(['--binary','--out'].includes(process.argv[i])&&process.argv[i+1]);options[process.argv[i]]=process.argv[i+1];}
assert(options['--binary']&&options['--out']);
const out=resolve(options['--out']);await mkdir(out,{recursive:false});
const base=await realpath(await mkdtemp('/private/tmp/zw-notification-avoidance-')),rpc=join(base,'rpc'),data=join(base,'data');await mkdir(rpc);await mkdir(data);
const server=createServer();await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));const port=(server.address() as any).port;await new Promise<void>((r,j)=>server.close(e=>e?j(e):r()));
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n');
await writeFile(join(data,'hosts.toml'),`[[hosts]]\nname="Owned closed loopback"\nhost="127.0.0.1"\nport=${port}\nuser="fixture"\n`);
const source=resolve(options['--binary']),binary=join(out,'zerowork-frozen');await copyFile(source,binary);await copyFile(join(dirname(source),'zw_ipc.so'),join(out,'zw_ipc.so'));
const sha=createHash('sha256').update(await readFile(binary)).digest('hex');
const log=await open(join(out,'app.log'),'w');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_DEVTOOLS_HIT_DEBUG:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(r=>app.once('close',()=>r()));
const report:any={status:'running',base,rpc,data,binary,binary_sha256:sha,pid:app.pid,synthetic_harness_input:true,real_transfer:false,checks:[],limits:['Session/global upload evidence must also run through the real SFTP fixture.','Synthetic Harness input does not prove physical mouse input.']};
const shown=(n:any)=>n&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
async function click(id:string){assert((await clickTestId(id)).ok,id);}
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await resizeWindow(1440,900);await click('workspace.empty.local');await sleep(700);
 await click('sidebar.host');await click('sidebar.host.connect');await sleep(1000);
 const toast=(await query('notifications.toast.0')).find(shown);assert(toast,'actual connection status published by host');await mouseMove(toast.rect.x+20,toast.rect.y+20);
 await key('escape');await sleep(200);await click('connection.progress.close');await sleep(200);
 await click('toolbar.transfers');await sleep(200);
 report.checks.push(await verifyNotificationAvoidance(out,'global-standard',{width:1440,height:900}));
 const card=(await query('notifications.toast.0')).find(shown)!;
 const body=card.children.find((n:any)=>shown(n)&&n.tag==='box'&&n.test_id!=='notifications.dismiss.0');
 const icon=card.children.find((n:any)=>shown(n)&&n.tag==='image');
 const dismiss=card.children.find((n:any)=>n.test_id==='notifications.dismiss.0');
 assert.equal(card.rect.w,340);assert.equal(card.rect.h,60,'measured V3 two-line feedback height');
 assert.equal(body.rect.w,261);assert.equal(body.rect.h,36);
 assert.equal(body.rect.y-card.rect.y,11);assert.equal(icon.rect.x-card.rect.x,13);assert.equal(icon.rect.y-card.rect.y,12);
 assert.equal(dismiss.rect.y-card.rect.y,11);assert.equal(dismiss.rect.w,19);assert.equal(dismiss.rect.h,19);
 report.toast_contract={card:card.rect,body:body.rect,icon:icon.rect,close:dismiss.rect};
 await writeFile(join(out,'two-line-toast.json'),JSON.stringify(card,null,2));
 const before=(await query('workspace.sidebar')).find(shown)!.rect.w;
 await key('b',{cmd:true});await sleep(200);
 const after=(await query('workspace.sidebar')).find(shown)?.rect.w??0;assert.notEqual(before,after,'sidebar actually changes width');report.sidebar={before,after};
 report.checks.push(await verifyNotificationAvoidance(out,'global-standard-sidebar',{width:1440,height:900}));
 await resizeWindow(860,480);await sleep(250);
 report.checks.push(await verifyNotificationAvoidance(out,'global-minimum',{width:860,height:480,close:true}));
 const logs=await readFile(join(out,'app.log'),'utf8');assert(/pointer_hit=.*test_id=transfer\.window\.close/.test(logs),'actual close hit target in native log');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);throw e;}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));app.kill('SIGTERM');await ended;await log.close();}
console.log(JSON.stringify({status:report.status,out,binary_sha256:sha}));
