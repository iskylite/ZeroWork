/** V3 builtin composite document acceptance through the real Local PTY and native Surface. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdir,mkdtemp,realpath,copyFile,readFile,writeFile,open,readdir} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep,scrollAt,mouseDown,mouseMove,mouseUp,inputState,focused,screenPos} from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]),source=resolve(process.argv[3]);await mkdir(out,{recursive:false});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-builtin-records-'))),rpc=join(iso,'rpc'),data=join(iso,'data'),shell=join(iso,'shell');await Promise.all([mkdir(rpc),mkdir(data),mkdir(shell)]);
await writeFile(join(shell,'.zshrc'),"bindkey -e\nPS1='records%# '\n");
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
await copyFile(source,join(iso,'zerowork'));await copyFile(join(source,'..','zw_ipc.so'),join(iso,'zw_ipc.so'));
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');const app=spawn(join(iso,'zerowork'),[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const report:any={status:'running',pid:app.pid,isolated:iso,sha256:createHash('sha256').update(await readFile(source)).digest('hex'),checks:[],captures:[],limits:['Public synthetic Harness on actual Metal window; no physical CUA/IME/VoiceOver acceptance.','Physical CUA middle-click menu/IME/VoiceOver and SSH transport acceptance are separate checks.']};
const flat=(n:any):any[]=>[n,...(n.children??[]).flatMap(flat)];
const content=(n:any):string=>!shown(n)?'':(n.text??'')+(n.children??[]).map(content).join('');
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const vis=(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,12000),hidden=(id:string)=>waitFor(async()=>!(await query(id)).some(shown)||null,12000);
async function click(id:string){const n=await vis(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)}
async function press(name:string,mods?:any){assert((await key(name,mods)).ok)}
async function type(text:string){assert((await type_(text)).ok)}
async function capture(name:string){await sleep(180);assert((await screenshot(join(out,name+'.png'))).ok);const nodes:any={};for(const id of ['terminal.surface','terminal.commands','terminal.command.input','terminal.command.record','terminal.command.output','terminal.search.count','terminal.search.query','tabs.strip','groups.workspace','ai.prompt'])nodes[id]=await query(id);await writeFile(join(out,name+'.json'),JSON.stringify(nodes,null,2));report.captures.push(name)}
async function palette(){await type('@');await vis('terminal.commands')}
async function command(value:string){await palette();await type(value);await press('right');await hidden('terminal.commands');await press('return');await sleep(350)}
async function outputs(){return (await query('terminal.command.output')).filter(shown).map(content).join('\n')}
async function records(){return (await query('terminal.command.record')).filter(shown).map(content)}
async function tabs(){return flat(await vis('tabs.strip')).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??''))}
async function members(){return (await query('groups.pane.title')).filter(shown).map(n=>({id:(n.text??'').match(/#(\d+)/)?.[1],text:n.text})).filter(n=>n.id)}
async function pane(id:string){return waitFor(async()=>{const rect=await screenPos('groups.pane.'+id);return rect.w>0&&rect.h>0?{rect}:null},12000)}
async function paneText(id:string){const {rect}=await pane(id);const nodes=[...(await query('terminal.command.record')),...(await query('terminal.command.output'))].filter(n=>shown(n)&&n.rect.x>=rect.x&&n.rect.x+n.rect.w<=rect.x+rect.w+1);return nodes.map(content).join('\n')}
async function focusPane(id:string){const n=await pane(id);assert((await clickAt(n.rect.x+40,n.rect.y+n.rect.h-60)).ok)}
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1440,900);await click('workspace.empty.local');await vis('terminal.surface');await sleep(1500);
 const ready=join(iso,'ready.txt');await type(`printf ready > ${JSON.stringify(ready)}`);await press('return');await waitFor(async()=>{try{return await readFile(ready,'utf8')==='ready'||null}catch{return null}},15000);await sleep(300);
 const sourceTab=(await tabs())[0].test_id,sourceId=sourceTab.split('.').at(-1)!;
 await command('help');await waitFor(async()=>{const text=await outputs();return text.includes('@grp')&&text.includes('@up')&&text.includes('@help')||null});await capture('01-inline-help');report.checks.push('Full help is retained in the source command result');
 await command('pin');await waitFor(async()=>(await outputs()).includes('当前会话未加入终端组')||null);await capture('02-pin-error');report.checks.push('Missing-group pin error remains failure and generic success does not overwrite it');
 await command('ai 分析服务日志');await vis('ai.prompt');assert.equal((await inputState('ai.prompt')).buffer,'分析服务日志');assert(!(await query('ai.stop')).some(shown));await capture('03-ai-draft-not-sent');await click('toolbar.ai');await click('terminal.surface');report.checks.push('AI builtin preserves exact text in current-owner draft without sending');
 await command('theme light');await waitFor(async()=>(await outputs()).includes('已应用主题选择')||null);await capture('04-theme-light');await command('theme dark');report.checks.push('Theme command changes the actual global theme and retains its source result');
 await command('grp RecordsAcceptance');await vis('groups.workspace');await pane(sourceId);await capture('05-group-source');assert((await paneText(sourceId)).includes('已加入终端组'));await focusPane(sourceId);await command('pin');await waitFor(async()=>(await paneText(sourceId)).includes('已置顶当前会话')||null);await capture('06-pin-success');report.checks.push('Group creation and pin retain concrete source-owned success records');
 await focusPane(sourceId);const expectedSourceFocus=await focused();await command('new');await waitFor(async()=>(await members()).length===2||null);await waitFor(async()=>(await paneText(sourceId)).includes('新会话已连接')||null,15000);await sleep(300);const focus=await focused();assert.equal(focus.id,expectedSourceFocus.id,'@new must preserve source pane focus');await capture('07-new-original-source');report.checks.push('@new creates exactly one owned member, finalizes original record and preserves source focus');
 const second=(await members()).find(n=>n.id!==sourceId)!.id!;assert(!(await paneText(second)).includes('@new'));
 await focusPane(sourceId);await command('dup');await waitFor(async()=>(await members()).length===3||null);await waitFor(async()=>{const text=await paneText(sourceId);return text.includes('@dup')&&text.match(/新会话已连接/g)?.length===2||null},15000);await sleep(300);const afterDupFocus=await focused();assert.equal(afterDupFocus.id,expectedSourceFocus.id,'@dup must preserve source pane focus');await capture('08-dup-source-identity');report.checks.push('@dup creates one distinct member and updates the original command without switching source focus');
 await focusPane(second);await sleep(1500);const marker=join(iso,'second-shell.txt');await type(`printf second > ${JSON.stringify(marker)}`);await press('return');await waitFor(async()=>{try{return await readFile(marker,'utf8')==='second'||null}catch{return null}},15000);assert(!(await paneText(second)).includes('@new'));assert(!(await paneText(second)).includes('@dup'));await capture('09-second-shell-no-cross-write');report.checks.push('Switching to another member keeps new/dup records exclusively in the original source and real shell continues');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});process.exitCode=1}
finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}))}
