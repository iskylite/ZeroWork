/** Actual Local zsh terminal: command overlays and retained history interactions.
 * Run with an already-built shared test-mode binary; no production config/SSH.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,realpath,rm,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]),binary=resolve(process.argv[3]);await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp(join(tmpdir(),'zw-command-annotations-'))),data=join(base,'data'),rpc=join(base,'rpc'),zdot=join(base,'zsh');await mkdir(data);await mkdir(rpc);await mkdir(zdot);await writeFile(join(zdot,'.zshrc'),'PS1="qa % "\n');
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\ncommand_info=true\n');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(resolve=>app.once('close',(code,signal)=>resolve({code,signal})));
const report:any={status:'running',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],captures:[],limits:['Actual production Local zsh and native App in isolated test-mode paths. Does not validate an external SSH endpoint or AI model provenance; those have separate production execution tests.']};
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>(n?.text??'')+(n?.children??[]).map(text).join('');
async function visible(id:string){return h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000)}
async function hidden(id:string){await h.waitFor(async()=>!(await h.query(id)).some(shown)||null,8000)}
async function click(id:string){const n=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await h.sleep(100)}
async function dismissHint(){if((await h.query('terminal.ai-error-hint.dismiss')).some(shown)){await click('terminal.ai-error-hint.dismiss');await h.mouseMove(10,10)}}
async function capture(name:string){await h.sleep(200);assert((await h.screenshot(join(out,name+'.png'))).ok);report.captures.push(name)}
async function submit(command:string){const n=await visible('terminal.surface');await h.clickAt(n.rect.x+60,n.rect.y+n.rect.h-45);assert((await h.type_(command)).ok);assert((await h.key('enter')).ok);await h.mouseMove(10,10)}
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1280,800);await click('workspace.empty.local');await visible('terminal.surface');await h.sleep(400);
 await click('toolbar.history');await visible('history.panel');
 const historyTrigger=await visible('status.command-history');
 await h.mouseMove(historyTrigger.rect.x+historyTrigger.rect.w/2,historyTrigger.rect.y+historyTrigger.rect.h/2);
 await h.sleep(250);
 assert(!(await h.query('terminal.command-history')).some(shown),'hover cannot cover the open log catalogue');
 await h.key('escape');await hidden('history.panel');await h.sleep(250);
 assert(!(await h.query('terminal.command-history')).some(shown),'dismissing logs does not trigger a preview under the stationary pointer');
 await click('toolbar.history');await visible('history.panel');
 await click('status.command-history');await visible('terminal.command-history');await hidden('history.panel');await capture('command-history-replaces-logs');
 await click('toolbar.history');await visible('history.panel');await hidden('terminal.command-history');await capture('logs-replace-command-history');
 await h.key('escape');await hidden('history.panel');
 assert(!(await h.query('terminal.command-history')).some(shown),'closing logs cannot restore the old pinned history');
 report.checks.push('Log catalogue and command history switch in one click in either direction, and hovering cannot reopen command history over the catalogue');
 await click('status.command-history');await visible('terminal.command-history');
 await click('toolbar.transfers');
 const transfers=await visible('transfer.manager'),commandClose=await visible('terminal.command-history.close');
 const closePoint={x:commandClose.rect.x+commandClose.rect.w/2,y:commandClose.rect.y+commandClose.rect.h/2};
 assert(closePoint.x>transfers.rect.x&&closePoint.x<transfers.rect.x+transfers.rect.w&&closePoint.y>transfers.rect.y&&closePoint.y<transfers.rect.y+transfers.rect.h,'transfer manager overlaps the command history close button');
 await h.clickAt(closePoint.x,closePoint.y);await h.sleep(100);
 assert((await h.query('terminal.command-history')).some(shown),'the later transfer panel gets the overlapping press');
 await click('status.command-history');await hidden('terminal.command-history');
 await click('status.command-history');await visible('terminal.command-history');
 await click('terminal.command-history.close');await hidden('terminal.command-history');
 await visible('transfer.manager');await click('toolbar.transfers');await hidden('transfer.manager');
 report.checks.push('Transfer manager and command history receive overlapping clicks in opening order');
 await h.resizeWindow(860,480);await click('toolbar.expand');
 await click('toolbar.history');await visible('history.panel');
 assert.equal((await h.focused()).test_id,'history.search');
 await click('status.command-history');await visible('terminal.command-history');await hidden('history.panel');
 await click('toolbar.history');await visible('history.panel');await hidden('terminal.command-history');
 await h.clickAt(3,350);await hidden('history.panel');
 await h.resizeWindow(1280,800);
 report.checks.push('At 860×480, the expanded toolbar supports both switches, the log search gets focus, and an outside press dismisses the logs');
 await click('status.command-history');await visible('terminal.command-history');
 await click('toolbar.notifications');await visible('notifications.history');await hidden('terminal.command-history');
 await click('status.connection.theme');await visible('status.theme');await hidden('notifications.history');
 await click('toolbar.new_session');await visible('session.menu');await hidden('status.theme');
 await h.key('escape');await hidden('session.menu');
 await click('toolbar.history');await visible('history.panel');
 await h.key('p',{cmd:true});await visible('quick.connect');await hidden('history.panel');
 await h.key('escape');await hidden('quick.connect');
 report.checks.push('Notifications, theme, session menu, command history, log catalogue and quick connect replace their peers across pointer and keyboard entry points');
 await click('toolbar.transfers');await visible('transfer.manager');
 await click('toolbar.notifications');
 await visible('notifications.history');await visible('transfer.manager');
 await capture('notifications-over-transfers');
 await click('notifications.history.close');await hidden('notifications.history');await visible('transfer.manager');
 await click('toolbar.transfers');await hidden('transfer.manager');
 report.checks.push('The notifications bubble opens and closes over the retained transfer panel without dismissing it');
 await click('toolbar.ai');await visible('ai.panel');
 await click('toolbar.transfers');await visible('transfer.manager');await visible('ai.panel');
 await click('ai.composer.permission');await visible('ai.permission.menu');await visible('ai.panel');await visible('transfer.manager');
 await h.key('escape');await hidden('ai.permission.menu');
 await click('toolbar.ai');await hidden('ai.panel');await visible('transfer.manager');
 await click('toolbar.transfers');await hidden('transfer.manager');
 report.checks.push('AI and transfers coexist, and opening the AI permission menu keeps both panels visible');
 await h.key('n',{cmd:true,alt:true});await visible('notes.floating');
 await click('toolbar.transfers');await visible('transfer.manager');await visible('notes.floating');
 const notesHeader=await visible('notes.floating.header');
 const transferPanel=await visible('transfer.manager');
 assert(notesHeader.rect.x+15<transferPanel.rect.x,'notes has an exposed header region');
 await h.clickAt(notesHeader.rect.x+15,notesHeader.rect.y+14);await h.sleep(100);
 await click('notes.floating.close');await hidden('notes.floating');await visible('transfer.manager');
 await click('toolbar.transfers');await hidden('transfer.manager');
 report.checks.push('Clicking the exposed notes header raises it over transfers and the notes close button dismisses only notes');
 await submit("printf 'ZW_NATIVE_ANNOTATION_OK\\n'; false");
 await h.waitFor(async()=>(await h.query('terminal.command.metadata.code')).find((n:any)=>shown(n)&&text(n).includes('1'))??null,15000);
 assert(!(await h.query('terminal.command.status')).some(shown));assert(!(await h.query('terminal.command.metadata.ai')).some(shown));await dismissHint();await capture('manual-command-complete');
 report.checks.push('Actual Local command completion exposes one metadata tag with EXIT 1 and elapsed, without a left status icon; manual source has no AI badge');
 const code=await visible('terminal.command.metadata.code'),surface=await visible('terminal.surface'),tag=await visible('terminal.command.metadata');
 assert.equal(text(code),'EXIT 1','right metadata must label the exit code with EXIT');
 assert.equal(tag.rect.h,18,'the complete metadata tag stays compact');
 assert(code.rect.x>=tag.rect.x+6&&code.rect.x+code.rect.w<=tag.rect.x+tag.rect.w-6,'EXIT is enclosed by the tag padding');
 assert(Math.abs(code.rect.y+code.rect.h/2-(tag.rect.y+tag.rect.h/2))<0.5,'metadata is centered inside the tag');
 await h.mouseMove(surface.rect.x+80,code.rect.y+code.rect.h/2);await hidden('terminal.command.metadata');await capture('command-hover-hidden');
 await h.mouseMove(10,10);await visible('terminal.command.metadata');report.checks.push('Pointer over command hides complete right metadata; leaving restores it');
 await submit('false');await h.waitFor(async()=>(await h.query('terminal.command.metadata.code')).filter((n:any)=>shown(n)&&text(n).includes('1')).length>=2||null,15000);
 await submit('false');await h.waitFor(async()=>(await h.query('terminal.command.metadata.code')).filter((n:any)=>shown(n)&&text(n).includes('1')).length>=3||null,15000);
 await dismissHint();
 const metadataBeforeClick=(await h.query('terminal.command.metadata')).filter(shown).length;
 const emptyPoint={x:surface.rect.x+80,y:surface.rect.y+surface.rect.h-30};
 await h.mouseDown(emptyPoint.x,emptyPoint.y);await h.sleep(250);
 assert.equal((await h.query('terminal.command.metadata')).filter(shown).length,metadataBeforeClick,'holding a focus click on an empty row must preserve other command tags');
 await capture('empty-row-mouse-down');
 await h.mouseUp(emptyPoint.x,emptyPoint.y);await h.sleep(150);
 assert.equal((await h.query('terminal.command.metadata')).filter(shown).length,metadataBeforeClick,'releasing an empty-row click must preserve other command tags');
 await capture('empty-row-click');await h.mouseMove(10,10);
 report.checks.push('Pressing, holding and releasing a focus click on an empty terminal row preserves all existing command metadata tags');
 const button=await visible('status.command-history');await h.mouseMove(button.rect.x+button.rect.w/2,button.rect.y+button.rect.h/2);await visible('terminal.command-history');
 await h.waitFor(async()=>(await h.query('terminal.command-history.record')).filter(shown).length>=3||null,10000);
 const commands=(await h.query('terminal.command-history.command')).filter(shown).map(text);assert(commands.filter((s:string)=>s==='false').length>=2);report.checks.push('Repeated human command executions remain separate native cards with real completion metadata');
 const panel=await visible('terminal.command-history');await h.mouseMove(panel.rect.x+30,panel.rect.y+30);await h.sleep(220);await visible('terminal.command-history');await capture('history-hover-preview');
 await h.mouseMove(10,10);await hidden('terminal.command-history');
 await click('status.command-history');await h.mouseMove(10,10);await h.sleep(250);await visible('terminal.command-history');await capture('history-pinned');
 await h.key('b',{shift:true,cmd:true});await h.sleep(150);await visible('terminal.command-history');
 report.checks.push('History button hover previews and click pins the panel; the former Shift+Cmd+B binding does not toggle it');
 await click('terminal.command-history.close');await hidden('terminal.command-history');
 await h.key('b',{shift:true,cmd:true});await h.sleep(150);await hidden('terminal.command-history');
 await click('terminal.surface');await h.type_("printf 'ZW_NATIVE_ANN");
 await h.key('i',{cmd:true});await visible('terminal.completion');
 await h.key('escape');await h.key('c',{ctrl:true});
 report.checks.push('Cmd+I opens terminal completion for a previously executed command');
 await submit('sleep 2; true');
 await h.waitFor(async()=>(await h.query('terminal.command.metadata.code')).find((n:any)=>shown(n)&&text(n)==='—')??null,10000);await capture('command-running');
 await h.waitFor(async()=>!(await h.query('terminal.command.metadata.code')).some((n:any)=>shown(n)&&text(n)==='—')||null,10000);report.checks.push('Actual running Local command has unknown exit placeholder until its real completion; elapsed updates without a fabricated exit');
 const longCommand="printf '%s\\n' 'ZW_LONG_WRAP_"+'abcdefghijklmnopqrstuvwxyz0123456789'.repeat(5)+"'; true";
 await submit(longCommand);await h.waitFor(async()=>(await h.query('terminal.command.metadata.code')).filter((n:any)=>shown(n)&&text(n).includes('0')).length>=2||null,15000);await capture('long-command-first-row');
 const groups=(await h.query('terminal.command.metadata')).filter(shown).sort((a:any,b:any)=>a.rect.y-b.rect.y),last=groups.at(-1);assert(last);const countBefore=groups.length;
 await h.mouseMove(surface.rect.x+80,last.rect.y+last.rect.h+2);await h.waitFor(async()=>(await h.query('terminal.command.metadata')).filter(shown).length===countBefore-1||null,8000);await capture('long-command-continuation-hover');await h.mouseMove(10,10);await h.waitFor(async()=>(await h.query('terminal.command.metadata')).filter(shown).length===countBefore||null,8000);report.checks.push('Actual wrapped long command has a single first-row group; hover on its continuation hides only that command metadata and leaving restores it');

 await submit('clear');await hidden('terminal.command.status');await hidden('terminal.command.metadata');await capture('clear-removes-old-markers');
 await submit("printf 'ZW_AFTER_CLEAR_A\\nZW_OUTPUT_A\\n'; true");
 await h.waitFor(async()=>(await h.query('terminal.command.metadata.code')).find((n:any)=>shown(n)&&text(n)==='EXIT 0')??null,15000);
 await submit("printf 'ZW_AFTER_CLEAR_B\\nZW_OUTPUT_B\\n'; false");
 await h.waitFor(async()=>(await h.query('terminal.command.metadata.code')).find((n:any)=>shown(n)&&text(n)==='EXIT 1')??null,15000);await dismissHint();
 async function alignedAfterClear(){
  const statuses=(await h.query('terminal.command.status')).filter(shown).sort((a:any,b:any)=>a.rect.y-b.rect.y);
  const codes=(await h.query('terminal.command.metadata.code')).filter(shown).sort((a:any,b:any)=>a.rect.y-b.rect.y);
  assert.equal(statuses.length,0,'left status icons must be removed');assert.deepEqual(codes.map(text),['EXIT 0','EXIT 1']);
  const rows=[];for(let index=0;index<8;index++)rows.push(...(await h.query(`terminal.surface.row.${index}`)).filter(shown));
  for(const [i,marker]of codes.entries()){
   const row=rows.find((r:any)=>Math.abs(r.rect.y+r.rect.h/2-(marker.rect.y+marker.rect.h/2))<0.5);assert(row,'marker must align with an actual grid row');
   const body=(row.children??[]).filter((n:any)=>shown(n)&&n.tag==='text'&&!n.test_id?.startsWith('terminal.command.')).map(text).join('');
   assert(body.includes(i===0?'ZW_AFTER_CLEAR_A':'ZW_AFTER_CLEAR_B'),'marker must be on the submitted command, not its output or an empty row');
  }
  report.clear_geometry={statuses:statuses.map((n:any)=>n.rect),codes:codes.map((n:any)=>({text:text(n),rect:n.rect}))};
 }
 await alignedAfterClear();await capture('new-commands-after-clear');await h.resizeWindow(1000,700);await h.sleep(250);await alignedAfterClear();await capture('new-commands-resized');await h.resizeWindow(1280,800);
 report.checks.push('Clear removes both old decorations while retained history remains; subsequent success/failure tags align with their actual submitted command rows before and after resize');

 await click('toolbar.settings');const search=await visible('settings.search');await h.clickAt(search.rect.x+40,search.rect.y+search.rect.h/2);await h.type_('command_info');await click('settings.toggle.command_info');await click('settings.save');await click('settings.close');await h.mouseMove(10,10);await hidden('terminal.command.metadata');assert(!(await h.query('terminal.command.status')).some(shown));report.checks.push('Saving global command_info=false immediately hides right metadata on the existing Local session with no left status icons');await capture('right-tag-hidden');
 assert((await h.request('POST','/zerowork/windows',{action:'quit'})).ok);report.exit=await Promise.race([ended,h.sleep(20000).then(()=>null)]);assert(report.exit&&report.exit.code===0&&report.exit.signal===null,'isolated App did not quit cleanly');report.status='passed';
}catch(error){report.status='failed';report.error=String(error);await writeFile(join(out,'failure-tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{});await capture('failure').catch(()=>{});process.exitCode=1}
finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,h.sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(base,{recursive:true,force:true})}
console.log(JSON.stringify({status:report.status,error:report.error,out}));
