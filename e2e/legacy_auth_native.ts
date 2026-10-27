/** Actual retained View + InteractiveBridge in an explicit component window.
 * Never claims this fixture is an active production SSH route. No IO secrets.
 * zig build auth-challenge-preview -Dtest-mode=true
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,realpath,open,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]),theme=process.argv[3]??'dark';await mkdir(out,{recursive:true});
const isolated=await realpath(await mkdtemp(join(tmpdir(),'zw-legacy-auth-'))),rpc=join(isolated,'rpc');await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(resolve('zig-out/bin/auth-challenge-preview'),[theme],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const report:any={status:'running',theme,checks:[],captures:[],limits:['Actual retained component in an isolated native window; no live production legacy route exists.','Bridge decisions verified without SSH, trust-store or credential writes.','Synthetic Harness input; physical keyboard/IME not claimed.']};
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,12000);
const click=async(id:string)=>{report.lastAction=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
const text=(n:any)=>flat(n).map(x=>x.text??'').join(' ');
const cap=async(name:string)=>{await h.sleep(250);const modal=await visible('auth.challenge.modal');await writeFile(join(out,name+'.json'),JSON.stringify(modal,null,2));assert((await h.screenshot(join(out,name+'.png'))).ok);report.captures.push(name);const actions=await visible('auth.challenge.actions');assert(actions.rect.y>=modal.rect.y&&actions.rect.y+actions.rect.h<=modal.rect.y+modal.rect.h+.5);};
const outcome=async(expected:string)=>{await h.waitFor(async()=>text(await visible('legacy.auth.outcome'))===expected||null,10000);await h.waitFor(async()=>!(await h.query('auth.challenge.modal')).some(shown)||null,10000)};
const start=async(kind:string)=>{await click('legacy.auth.'+kind);await visible('auth.challenge.modal');await visible('auth.challenge.title.icon')};
const fill=async(value:string)=>{await click('auth.challenge.answer.0');await h.type_(value)};
try{
 await h.waitForServerReady(30000);
 for(const kind of ['password','private_key_passphrase','keyboard_interactive','host_key_unknown','host_key_changed']){
  await h.resizeWindow(1440,900);await start(kind);await cap(kind+'-standard');
  await h.resizeWindow(860,480);await cap(kind+'-minimum');
  if(theme!=='dark'){await click('auth.challenge.cancel');await outcome('cancelled');continue;}
  if(kind==='host_key_unknown'){
   await h.key('return');assert.equal(text(await visible('legacy.auth.outcome')),'pending');await click('auth.challenge.trust_once');await outcome('trust_once');
   await start(kind);await click('auth.challenge.submit');await outcome('trust_save');
   await start(kind);await click('auth.challenge.cancel');await outcome('cancelled');report.checks.push('Unknown host-key Enter does not trust; once/save/cancel emit distinct scoped bridge decisions');
  }else if(kind==='host_key_changed'){
   await fill('no');await click('auth.challenge.submit');assert.equal(text(await visible('legacy.auth.outcome')),'pending');await h.key('return');assert.equal(text(await visible('legacy.auth.outcome')),'pending');await click('auth.challenge.answer.0');await h.key('a',{cmd:true});await h.type_('yes');await cap('host-key-changed-yes');await click('auth.challenge.submit');await outcome('replace_host_key');report.checks.push('Changed key rejects arbitrary input and Enter; explicit yes enables replacement');
  }else{
   const value=kind==='keyboard_interactive'?'123456':'owned-fixture-secret';await fill(value);
   assert(!text(await visible('auth.challenge.modal')).includes(value),'Input should stay masked');
   if(kind!=='keyboard_interactive'){await click('auth.challenge.reveal.0');assert(text(await visible('auth.challenge.modal')).includes(value));await click('auth.challenge.reveal.0');}
   await click('auth.challenge.submit');await outcome('submitted');await start(kind);await fill(value);await h.key('escape');await outcome('cancelled');report.checks.push(kind+': masked submit, scoped bridge response, Escape cancellation');
  }
 }
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await h.screenshot(join(out,'failure.png')).catch(()=>{});}
finally{if(app.exitCode===null)app.kill('SIGTERM');await ended;await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));}
