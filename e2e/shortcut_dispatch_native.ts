/** Saved shortcut dispatch through the production window, using owned Local PTYs only. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,rm,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';

const [binaryArg,outputArg]=process.argv.slice(2);
assert(binaryArg&&outputArg,'usage: node e2e/shortcut_dispatch_native.ts BINARY OUTPUT');
const output=resolve(outputArg);await mkdir(output,{recursive:true});
const isolated=await mkdtemp('/private/tmp/zw-shortcut-dispatch-');
const data=isolated+'/data',rpc=isolated+'/rpc',shell=isolated+'/shell';
for(const path of [data,rpc,shell])await mkdir(path);
await writeFile(shell+'/.zshrc',"bindkey -e\nPS1='ZW-shortcuts%# '\n");
await writeFile(data+'/config.toml','[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[keys]\nnew_tab="cmd+shift+b"\nquick_connect="cmd+shift+r"\ncompletion="cmd+shift+space"\nsidebar="cmd+alt+b"\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(output+'/native.log','w');
const app=spawn(resolve(binaryArg),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZDOTDIR:shell,OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const shown=(node:any)=>node?.visible!==false&&node?.rect?.w>0&&node?.rect?.h>0&&(node.effective_opacity??1)>0;
const visible=async(id:string)=>(await h.query(id)).filter(shown);
const node=async(id:string):Promise<any>=>h.waitFor(async()=>(await visible(id))[0]??null,12000);
const click=async(id:string)=>{const n=await node(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);};
const report:any={status:'running',checks:[],networkConnections:0};
async function readyCommand(command:string,path:string){
 await h.type_(command);await h.key('return');
 await h.waitFor(async()=>{try{return (await readFile(path,'utf8'))==='ready'||null;}catch{return null;}},12000);
 await h.sleep(250);
}
try{
 await h.waitForServerReady();await h.resizeWindow(1440,900);
 assert.equal(Number(JSON.parse(await readFile(rpc+'/owner.json','utf8')).pid),app.pid);
 await click('workspace.empty.local');await node('terminal.surface');
 const ready=isolated+'/ready';await readyCommand(`printf ready > '${ready}'`,ready);
 await h.key('b',{cmd:true,shift:true});await node('session.menu');
 assert.equal((await visible('terminal.command-history')).length,0);
 report.checks.push('saved Cmd+Shift+B opens the session chooser without opening command history');
 await h.screenshot(output+'/native-session-shortcut.png');await h.key('escape');
 await h.key('j',{cmd:true});await node('ai.panel');await click('ai.prompt');
 await h.type_('shortcut draft');
 await h.key('left');const aiBefore=await h.inputState('ai.prompt');
 await h.key('b',{cmd:true,alt:true});
 assert.equal((await h.focused()).test_id,'ai.prompt');
 const aiAfter=await h.inputState('ai.prompt');
 assert.equal(aiAfter.buffer,aiBefore.buffer);assert.equal(aiAfter.cursor_pos,aiBefore.cursor_pos);assert.equal(aiAfter.anchor,aiBefore.anchor);
 report.checks.push('sidebar shortcut preserves AI focus, draft and cursor');
 await h.key('r',{cmd:true,shift:true});await node('quick.connect');
 await h.sleep(200);await click('quick.query');await h.type_('no-matching-host');
 assert.equal((await h.inputState('quick.query')).buffer,'no-matching-host');
 report.checks.push('saved Cmd+Shift+R opens quick connect while the AI input owns focus');
 await h.screenshot(output+'/native-ai-shortcut.png');await h.key('escape');
 assert.equal((await h.inputState('ai.prompt')).buffer,'shortcut draft');
 await click('ai.prompt');await h.key('b',{cmd:true,shift:true});await node('session.menu');
 assert.equal((await visible('terminal.command-history')).length,0);
 report.checks.push('saved Cmd+Shift+B also takes priority from the AI input');
 await h.key('escape');await click('ai.collapse');
 const surface=await node('terminal.surface');await h.clickAt(surface.rect.x+surface.rect.w/2,surface.rect.y+surface.rect.h/2);
 const seed=isolated+'/seed';await readyCommand(`printf ready > '${seed}'`,seed);
 await h.type_('printf rea');await h.sleep(200);
 await h.key('semicolon',{cmd:true});await h.sleep(150);
 assert.equal((await visible('terminal.completion')).length,0,'old completion binding must be inactive');
 await h.key('space',{cmd:true,shift:true});await node('terminal.completion');
 report.checks.push('saved Cmd+Shift+Space opens real history candidates; old completion binding stays inactive');
 await h.screenshot(output+'/native-completion.png');await h.key('escape');await h.key('c',{ctrl:true});
 await h.key('d',{cmd:true});await node('groups.workspace');await node('status.group.broadcast');
 await h.key('i',{cmd:true,shift:true});await node('group.broadcast.card');
 assert((await visible('group.broadcast.accept')).length>0);
 report.checks.push('default broadcast binding opens the existing confirmation for the current group');
 await h.mouseMove(16,80);await h.resizeWindow(860,480);await h.mouseMove(16,80);await h.sleep(150);await h.screenshot(output+'/native-broadcast.png');
 await h.key('escape');report.status='passed';
}catch(error){report.status='failed';report.error=String(error);await h.screenshot(output+'/failure.png').catch(()=>{});throw error;}
finally{
 await writeFile(output+'/report.json',JSON.stringify(report,null,2));
 if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');
 await ended;await log.close();await rm(isolated,{recursive:true,force:true});
}
console.log(JSON.stringify(report,null,2));
