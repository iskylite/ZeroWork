/** Floating surface pointer/wheel regression in an isolated native window.
 * node e2e/floating_input_native.ts BINARY OUTPUT_DIR
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,writeFile,rm,realpath} from 'node:fs/promises';
import {join} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';
const out=process.argv[3]??'/tmp/zerowork-floating-input-evidence';await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/private/tmp/zw-overlay-audit-')),data=join(iso,'data'),rpc=join(iso,'rpc'),shell=join(iso,'shell');
await Promise.all([mkdir(data),mkdir(rpc),mkdir(shell)]);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
await writeFile(join(shell,'.zshrc'),"PS1='audit%# '\nbindkey -e\n");
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\n');
const logPath=join(out,'app.log'),log=await open(logPath,'w');
const app=spawn(process.argv[2],[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZDOTDIR:shell,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_DEVTOOLS_HIT_DEBUG:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));const report={status:'running',cases:[]};
const shown=n=>n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const vis=id=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const hidden=id=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
async function click(id){const n=await vis(id);await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);await h.sleep(130);}
async function trace(name,id,dx=5,dy=8){
 const n=await vis(id),point={x:n.rect.x+dx,y:n.rect.y+dy};
 const offset=(await readFile(logPath,'utf8')).length;
 await h.scrollAt(point.x,point.y,0,-18);await h.sleep(100);
 await h.clickAt(point.x,point.y);await h.sleep(130);
 const lines=(await readFile(logPath,'utf8')).slice(offset).split('\n').filter(l=>l.includes('[devtools-hit]'));
 const hits=lines.filter(l=>/pointer_hit=|dispatch_scroll_target=/.test(l));
 assert(hits.some(l=>l.includes('dispatch_scroll_target=')),name+': wheel dispatch captured');
 assert(hits.some(l=>l.includes('pointer_hit=')),name+': pointer hit captured');
 assert(hits.every(l=>!l.includes('test_id=terminal.surface')&&!l.includes('test_id=ai.conversation.viewport')),name+': input must remain in floating surface');
 const wheel=hits.find(l=>l.includes('dispatch_scroll_target='));
 assert(wheel.includes('test_id='+id+' ')||(name==='local-close-scrim'&&wheel.includes('component=Modal ')),name+': wheel must stop on the expected surface');
 const item={name,id,rect:n.rect,point,focus:await h.focused(),lines};report.cases.push(item);
 await h.screenshot(join(out,name+'.png'));await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
 console.log(name,lines.filter(l=>/pointer_hit=|dispatch_scroll_target=/.test(l)).join('\n'));
}
try{
 await h.waitForServerReady();await h.resizeWindow(1440,900);await click('workspace.empty.local');await click('terminal.surface');await h.sleep(250);
 await h.type_("printf 'overlay audit\\n'");await h.key('return');await h.sleep(300);
 await click('toolbar.transfers');await trace('transfer-header','transfer.manager',240,8);await trace('transfer-footer','transfer.manager',240,(await vis('transfer.manager')).rect.h-8);await click('transfer.window.close');
 await h.key('p',{cmd:true});await trace('quick-connect-padding','quick.connect',4,80);await h.key('escape');await h.sleep(200);
 await click('toolbar.ai');await trace('ai-side-padding','ai.panel',4,150);
 await click('ai.composer.permission');await trace('ai-permission-header','ai.permission.menu',8,6);await vis('ai.panel');
 await click('ai.permission.close');await hidden('ai.permission.menu');await click('ai.prompt');await h.type_('outside press draft');
 assert.equal((await h.inputState('ai.prompt')).buffer,'outside press draft');
 await click('ai.composer.permission');await vis('ai.permission.menu');
 await h.clickAt(3,450);await hidden('ai.permission.menu');await hidden('ai.panel');
 await click('toolbar.ai');await vis('ai.panel');assert.equal((await h.inputState('ai.prompt')).buffer,'outside press draft');
 await click('toolbar.ai');await hidden('ai.panel');
 await click('toolbar.history');await trace('global-history-header','history.panel',130,8);await h.clickAt(3,450);await hidden('history.panel');
 await click('toolbar.ai');await vis('ai.panel');await click('toolbar.settings');await hidden('ai.panel');
 await trace('settings-card-padding','settings.panel',150,8);await h.clickAt(3,450);await vis('settings.panel');await h.key('escape');await hidden('settings.panel');
 await click('toolbar.notifications');await trace('notifications-header','notifications.history',120,8);await click('notifications.history.close');
 await click('terminal.surface');await h.type_('@');await h.sleep(250);await trace('command-catalogue-header','terminal.commands',100,10);await h.key('escape');await h.key('backspace');
 await h.request('POST','/quit',{});await trace('local-close-header','local.close.confirmation',180,8);
 // This point is in the modal scrim above the isolated terminal.
 await trace('local-close-scrim','local.close.confirmation',-210,70);
 // Outside click dismisses this dialog. A repeated window-close request may
 // complete the retained close transaction without showing another dialog.
 await h.request('POST','/quit',{});await h.sleep(700);
 if(app.exitCode===null&&app.signalCode===null)await click('local.close.accept');
 await h.waitFor(()=>app.exitCode!==null||app.signalCode!==null||null,10000);report.exitCode=await ended;assert.equal(report.exitCode,0);
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;console.error(e);await h.screenshot(join(out,'failure.png')).catch(()=>{});}
finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(iso,{recursive:true,force:true});}
