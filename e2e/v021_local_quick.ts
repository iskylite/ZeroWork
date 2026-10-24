/** Targeted final-candidate Local registered-create and normal-exit regression. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep} from '../vendor/zenit/e2e/client.ts';
const opts:Record<string,string>={};for(let i=2;i<process.argv.length;i+=2){assert(['--binary','--out'].includes(process.argv[i])&&process.argv[i+1]);opts[process.argv[i]]=process.argv[i+1];}
assert(opts['--binary']&&opts['--out']);const binary=resolve(opts['--binary']),out=resolve(opts['--out']);await mkdir(out,{recursive:true});
const iso=await mkdtemp(join(tmpdir(),'zw-v021-local-quick-')),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(data);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const report:any={status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),pid:app.pid,checks:[],limits:['Public synthetic Harness input; physical keyboard/IME not claimed.','Final own-process SIGTERM is cleanup, not normal window-close evidence.']};
function shown(n:any){return n?.rect&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;}
function text(n:any):string{return !shown(n)?'':(n.text??'')+(n.children??[]).map(text).join('');}
async function visible(id:string){return waitFor(async()=>(await query(id)).find(shown)??null,15000);}
async function absent(id:string){return waitFor(async()=>!(await query(id)).some(shown)||null,15000);}
async function click(id:string){const n=await visible(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await sleep(100);}
function ptys(){return execFileSync('/usr/sbin/lsof',['-nP','-a','-p',String(app.pid),'-Ffn'],{encoding:'utf8'}).split('\n').filter(s=>/^n\/dev\/(ptmx|pty|ttys)/.test(s));}
function shellPid(){return execFileSync('/bin/ps',['-axo','pid=,ppid=,comm='],{encoding:'utf8'}).split('\n').map(s=>s.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/)).find(m=>m&&Number(m[2])===app.pid&&m[3].endsWith('/zsh'))?.[1];}
async function capture(name:string){await sleep(250);const ids=['tabs.strip','local.ended.close','local.statusbar','local.status.identity','workspace.empty.local'];await writeFile(join(out,name+'.json'),JSON.stringify(Object.fromEntries(await Promise.all(ids.map(async id=>[id,await query(id)]))),null,2));assert((await screenshot(join(out,name+'.png'))).ok);}
let failure:any;
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1440,900);const before=ptys();
 await click('workspace.empty.local');await visible('terminal.surface');await visible('tabs.tab.1');report.shell_pid=Number(await waitFor(async()=>shellPid()??null,15000));const active=ptys();assert(active.length>before.length);
 assert((await type_("printf 'V021_LOCAL_QUICK_%s\\n' READY")).ok);await key('return');await waitFor(async()=>text(await visible('terminal.surface')).includes('V021_LOCAL_QUICK_READY')||null,15000);await capture('00-local-real-pty');
 await type_('exit 0');await key('return');await visible('local.ended.close');await waitFor(async()=>{try{process.kill(report.shell_pid,0);return null;}catch(e:any){if(e.code==='ESRCH')return true;throw e;}},15000);
 await waitFor(async()=>text(await visible('local.status.identity')).includes('已退出')||null,15000);assert.deepEqual(ptys(),before);await capture('01-local-exited-readonly');
 await click('local.ended.close');await absent('tabs.tab.1');await visible('workspace.empty.local');assert(app.exitCode===null&&app.signalCode===null);await capture('02-ended-tab-closed');
 report.pty_descriptors={before,active,after:ptys()};report.checks.push('Registered Local quick action creates a real app-owned zsh PTY','Real command output reaches the terminal projection','Shell exit 0 removes the actual process and returns PTY descriptors to baseline while retaining the readonly tombstone','Closing the ended tab returns the same live App to its empty workspace');report.status='passed';
}catch(e){failure=e;report.status='failed';report.error=String(e);try{await capture('failure-live');}catch{}}
finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await Promise.race([ended,sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}report.cleanup={exit_code:app.exitCode,signal:app.signalCode};await log.close();await rm(iso,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
console.log(report.status);if(failure)throw failure;
