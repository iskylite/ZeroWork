/** KVM assistant geometry after a hidden Local assistant, using isolated data.
 * node e2e/kvm_ai_layout_native.ts BINARY OUTPUT_DIR
 * The KVM endpoint is an intentionally closed loopback port; no device is used.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile,rm} from 'node:fs/promises';
import {dirname,join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);
await mkdir(out,{recursive:true});
const isolated=await mkdtemp('/private/tmp/zw-kvm-ai-');
const data=join(isolated,'data'),rpc=join(isolated,'rpc'),shell=join(isolated,'shell');
await Promise.all([mkdir(data),mkdir(rpc),mkdir(shell)]);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(pathToFileURL(join(dirname(dirname(binary)),'share/zenit/harness/client.ts')).href);
await writeFile(join(shell,'.zshrc'),"PS1='layout%# '\n");
const payload={endpoint:{host:'127.0.0.1',https_port:1},username:'fixture',display:{scale:'fit',read_only_requested:true}};
await writeFile(join(data,'hosts.toml'),'[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="bmc_ikvm"\nname="KVM Layout Fixture"\npayload='+JSON.stringify(JSON.stringify(payload))+'\n');
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="sauber"\n[updates]\nauto_check=false\n');
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZDOTDIR:shell,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_E2E_ISOLATE_KEYBOARD:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n.visible!==false&&!n.hidden&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const report:any={status:'running',checks:[],limits:['Offline KVM renderer; live device connectivity and physical input are outside this layout check.']};
async function click(id:string){await visible(id);assert((await h.clickTestId(id)).ok,`click ${id}`);await h.sleep(200)}
function inside(inner:any,outer:any,label:string){assert(inner.x>=outer.x-.5&&inner.y>=outer.y-.5&&inner.x+inner.w<=outer.x+outer.w+.5&&inner.y+inner.h<=outer.y+outer.h+.5,label)}
async function capture(name:string,maximized=false,centered=true){
 await h.sleep(250);
 const content=(await visible('bmc.content')).rect,panel=(await visible('ai.panel')).rect;
 inside(panel,content,`${name}: assistant stays in KVM content`);
 if(maximized){assert(Math.abs(panel.w-(content.w-16))<1);assert(Math.abs(panel.h-(content.h-16))<1)}
 else {assert.equal(panel.w,600);assert.equal(panel.h,480);if(centered){assert(Math.abs(panel.x-(content.x+(content.w-600)/2))<1);assert(Math.abs(panel.y-(content.y+14))<1)}}
 for(const id of ['ai.close','ai.prompt','ai.composer.controls'])inside((await visible(id)).rect,panel,`${name}: ${id} stays in assistant`);
 assert((await h.query('ai.float.resize.se')).some(shown),`${name}: resize remains available`);
 await h.screenshot(join(out,name+'.png'));
 report.checks.push({name,content,panel});
}
try{
 await h.waitForServerReady();await h.resizeWindow(1440,900);await h.sleep(350);
 // The hidden Local assistant is laid out at 100×14 before KVM becomes active.
 await click('workspace.empty.local');await visible('terminal.surface');await h.sleep(350);
 const row=await visible('sidebar.host');await h.clickAt(row.rect.x+65,row.rect.y+row.rect.h/2);await h.key('return');await visible('bmc.content');await h.sleep(600);
 await click('toolbar.ai');await capture('opened');
 await click('ai.maximize');await capture('maximized',true);
 await click('ai.maximize');await capture('restored');
 await click('ai.collapse');await click('toolbar.ai');await h.resizeWindow(1000,700);await capture('reopened-compact',false,false);
 const prompt=await visible('ai.prompt');await h.clickAt(prompt.rect.x+30,prompt.rect.y+20);await h.type_('KVM layout draft');assert.equal((await h.inputState('ai.prompt')).buffer,'KVM layout draft');
 assert((await h.request('POST','/zerowork/windows',{action:'quit'})).ok);
 const quitStarted=performance.now();while(app.exitCode===null&&app.signalCode===null&&performance.now()-quitStarted<15000){
  for(const id of ['groups.close.accept','local.close.accept','session.close.accept'])try{if((await h.query(id)).some(shown))await h.clickTestId(id)}catch{}
  await Promise.race([ended,h.sleep(80)]);
 }
 assert.equal(app.exitCode,0);
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;if(app.exitCode===null)await h.screenshot(join(out,'failure.png')).catch(()=>{});console.error(error)}
finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(isolated,{recursive:true,force:true})}
console.log(`${report.status}: ${out}`);
