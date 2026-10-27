/** Verify builtin choices, custom declaration wording and persistence in real native settings. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,realpath,open,readFile,writeFile} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);await mkdir(out,{recursive:true});
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>shown(n)?[n,...(n.children??[]).flatMap(flat)]:[];
const report:any={binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),status:'running',runs:[],limits:['Isolated native test windows; public Harness input, no physical keyboard/IME or VoiceOver verification.','HTML source wording is synchronized; browser preview was unavailable because file URLs were blocked.']};
try{for(const theme of ['dark','light']){
 const iso=await realpath(await mkdtemp('/private/tmp/zw-term-settings-'));const data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
 await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="'+theme+'"\nfont_family="Menlo"\n[ssh]\nterm="xterm-256color"\n');
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,theme+'.log'),'w');const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
 const run:any={theme,status:'running',checks:[]};report.runs.push(run);
 const node=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
 const click=async(id:string)=>{const r=(await node(id)).rect;assert((await h.clickAt(r.x+r.w/2,r.y+r.h/2)).ok)};
 const capture=async(name:string)=>{await h.sleep(300);assert((await h.screenshot(join(out,theme+'-'+name+'.png'))).ok);await writeFile(join(out,theme+'-'+name+'.json'),JSON.stringify(Object.fromEntries(await Promise.all(['settings.field.term','settings.help.term.tooltip','settings.term.option.xterm-256color','settings.term.option.xterm','settings.term.option.vt100','settings.term.option.custom','settings.term.custom.note'].map(async id=>[id,await h.query(id)]))),null,2))};
 try{
  await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1440,900);await click('toolbar.settings');await click('settings.nav.ssh');
  if(!(await h.query('settings.field.term')).some(shown))await click('settings.ssh.connection.header');
  const hint=await node('settings.help.term');await h.mouseMove(hint.rect.x+hint.rect.w/2,hint.rect.y+hint.rect.h/2);
  const help=await node('settings.help.term.tooltip');assert(flat(help).some(n=>n.text?.includes('自定义仅声明 TERM 名称')));await capture('help');await h.mouseMove(10,10);
  await click('settings.field.term');
  for(const name of ['xterm-256color','xterm','vt100','custom'])await node('settings.term.option.'+name);
  await capture('choices');await click('settings.term.option.custom');
  const note=await node('settings.term.custom.note');assert(flat(note).some(n=>n.text?.includes('不保证对应终端兼容')));await capture('custom');
  await h.key('a',{cmd:true});await h.type_('vt100-custom');await h.key('return');await h.waitFor(async()=>!(await h.query('settings.term.custom.note')).some(shown)||null);
  await click('settings.save');await h.waitFor(async()=>(await readFile(join(data,'config.toml'),'utf8')).includes('term = "vt100-custom"')||null);
  await capture('saved');run.checks.push('TERM help distinguishes verified builtins and custom declaration','Builtin choices and explicit custom option visible','Custom editor warning visible','Unknown TERM name saves unchanged');run.status='passed';
 }catch(e){run.status='failed';run.error=String(e);await capture('failure').catch(()=>{});throw e}
 finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,h.sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}await log.close()}
}report.status='passed'}catch(e){report.status='failed';report.error=String(e);process.exitCode=1}finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report))}
