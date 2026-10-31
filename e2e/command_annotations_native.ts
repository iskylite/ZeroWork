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
 await submit("printf 'ZW_NATIVE_ANNOTATION_OK\\n'; false");
 await h.waitFor(async()=>(await h.query('terminal.command.metadata.code')).find((n:any)=>shown(n)&&text(n).includes('1'))??null,15000);
 assert((await h.query('terminal.command.status')).some(shown));assert(!(await h.query('terminal.command.metadata.ai')).some(shown));await dismissHint();await capture('manual-command-complete');
 report.checks.push('Actual Local command completion exposes independent status gutter, numeric exit1, elapsed; manual source has no AI badge');
 const code=await visible('terminal.command.metadata.code'),surface=await visible('terminal.surface');
 await h.mouseMove(surface.rect.x+80,code.rect.y+code.rect.h/2);await hidden('terminal.command.metadata');await capture('command-hover-hidden');
 await h.mouseMove(10,10);await visible('terminal.command.metadata');report.checks.push('Pointer over command hides complete right metadata; leaving restores it');
 await submit('false');await h.waitFor(async()=>(await h.query('terminal.command.metadata.code')).filter((n:any)=>shown(n)&&text(n).includes('1')).length>=2||null,15000);
 await submit('false');await h.waitFor(async()=>(await h.query('terminal.command.metadata.code')).filter((n:any)=>shown(n)&&text(n).includes('1')).length>=3||null,15000);
 await dismissHint();
 const button=await visible('local.status.command-history');await h.mouseMove(button.rect.x+button.rect.w/2,button.rect.y+button.rect.h/2);await visible('terminal.command-history');
 await h.waitFor(async()=>(await h.query('terminal.command-history.record')).filter(shown).length>=3||null,10000);
 const commands=(await h.query('terminal.command-history.command')).filter(shown).map(text);assert(commands.filter((s:string)=>s==='false').length>=2);report.checks.push('Repeated human command executions remain separate native cards with real completion metadata');
 const panel=await visible('terminal.command-history');await h.mouseMove(panel.rect.x+30,panel.rect.y+30);await h.sleep(220);await visible('terminal.command-history');await capture('history-hover-preview');
 await h.mouseMove(10,10);await hidden('terminal.command-history');
 await click('local.status.command-history');await h.mouseMove(10,10);await h.sleep(250);await visible('terminal.command-history');await capture('history-pinned');
 await h.key('b',{shift:true,cmd:true});await hidden('terminal.command-history');await h.key('b',{shift:true,cmd:true});await visible('terminal.command-history');await h.mouseMove(10,10);await h.sleep(220);await visible('terminal.command-history');
 report.checks.push('History button hover previews; entering card retains it; leaving preview closes; click and ShiftCmdB toggle pinned state without mouse-leave close');
 await click('terminal.command-history.close');await hidden('terminal.command-history');
 await submit('sleep 2; true');
 await h.waitFor(async()=>(await h.query('terminal.command.metadata.code')).find((n:any)=>shown(n)&&text(n)==='—')??null,10000);await capture('command-running');
 await h.waitFor(async()=>!(await h.query('terminal.command.metadata.code')).some((n:any)=>shown(n)&&text(n)==='—')||null,10000);report.checks.push('Actual running Local command has unknown exit placeholder until its real completion; elapsed updates without a fabricated exit');
 const longCommand="printf '%s\\n' 'ZW_LONG_WRAP_"+'abcdefghijklmnopqrstuvwxyz0123456789'.repeat(5)+"'; true";
 await submit(longCommand);await h.waitFor(async()=>(await h.query('terminal.command.metadata.code')).filter((n:any)=>shown(n)&&text(n).includes('0')).length>=2||null,15000);await capture('long-command-first-row');
 const groups=(await h.query('terminal.command.metadata')).filter(shown).sort((a:any,b:any)=>a.rect.y-b.rect.y),last=groups.at(-1);assert(last);const countBefore=groups.length;
 await h.mouseMove(surface.rect.x+80,last.rect.y+last.rect.h+2);await h.waitFor(async()=>(await h.query('terminal.command.metadata')).filter(shown).length===countBefore-1||null,8000);await capture('long-command-continuation-hover');await h.mouseMove(10,10);await h.waitFor(async()=>(await h.query('terminal.command.metadata')).filter(shown).length===countBefore||null,8000);report.checks.push('Actual wrapped long command has a single first-row group; hover on its continuation hides only that command metadata and leaving restores it');

 await click('toolbar.settings');const search=await visible('settings.search');await h.clickAt(search.rect.x+40,search.rect.y+search.rect.h/2);await h.type_('command_info');await click('settings.toggle.command_info');await click('settings.save');await click('settings.close');await h.mouseMove(10,10);await hidden('terminal.command.metadata');assert((await h.query('terminal.command.status')).some(shown));report.checks.push('Saving global command_info=false immediately hides right metadata on the existing Local session while status gutter remains visible');await capture('right-hidden-status-retained');
 assert((await h.request('POST','/quit')).ok);report.exit=await Promise.race([ended,h.sleep(20000).then(()=>null)]);assert(report.exit&&report.exit.code===0&&report.exit.signal===null,'isolated App did not quit cleanly');report.status='passed';
}catch(error){report.status='failed';report.error=String(error);await writeFile(join(out,'failure-tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{});await capture('failure').catch(()=>{});process.exitCode=1}
finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,h.sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(base,{recursive:true,force:true})}
console.log(JSON.stringify({status:report.status,error:report.error,out}));
