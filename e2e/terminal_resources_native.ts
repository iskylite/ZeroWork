/** Repeatable native PTY memory/throughput workload, with optional heap evidence.
 * RPC latencies include automation; diagnostic tools run outside frame samples. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,realpath,mkdir,open,writeFile,readFile,rm,stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {createHash} from 'node:crypto';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
const {waitForServerReady,query,clickTestId,type_,key,waitFor,screenshot,resizeWindow,stats,resetTiming,request}=await import(process.env.ZEROWORK_HARNESS_CLIENT??new URL('../zig-out/share/zenit/harness/client.ts',import.meta.url).href);
const [binaryArg,outArg]=process.argv.slice(2);assert(binaryArg&&outArg);
const binary=resolve(binaryArg),out=resolve(outArg),temp=await realpath(await mkdtemp(join(tmpdir(),'zw-resources-')));
await mkdir(out,{recursive:true});await mkdir(join(temp,'rpc'));await mkdir(join(temp,'data'));
process.env.ZENIT_E2E_FILE_RPC_DIR=join(temp,'rpc');
await writeFile(join(temp,'data/config.toml'),'[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Menlo"\nfont_size = 14\n');
const log=await open(join(out,'app.log'),'w');
const child=spawn(binary,[],{env:{...process.env,...(process.env.ZEROWORK_RESOURCE_STACKS==='1'?{MallocStackLogging:'1'}:{}),ZEROWORK_DATA_DIR:join(temp,'data'),ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>child.once('close',r));
const sleep=(ms:number)=>new Promise(r=>setTimeout(r,ms));
const report:any={binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),phases:{},limits:['RSS is a whole-process observation; renderer/font/allocator caches are included.','RPC observation includes automation overhead.','Memory diagnostics are outside frame timing samples.']};
let tailIds:string[]=[];
const shown=(n:any)=>!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>n.hidden||n.visible===false?'':(n.text??'')+(n.children??[]).map(text).join('');
async function tail(){const rows=await query('terminal.surface');return Array.isArray(rows)?rows.filter(shown).map(text).join(''):'';}
async function command(value:string,token:string){await type_(value);await key('enter');await waitFor(async()=>(await tail()).includes(token)||null,45000,20);}
function resource(){const raw=execFileSync('/bin/ps',['-p',String(child.pid),'-o','rss=,time='],{encoding:'utf8'}).trim().split(/\s+/);return {rss_kib:Number(raw[0]),cpu_seconds:raw[1].split(':').map(Number).reduce((a,b)=>a*60+b,0)};}
async function metrics(){return await request('POST','/zerowork/terminal',{action:'metrics'}).catch(()=>null);}
async function phase(name:string){await sleep(500);const start=resource();await sleep(2500);const end=resource();report.phases[name]={...end,idle_cpu_percent:(end.cpu_seconds-start.cpu_seconds)*40,terminal:await metrics(),frame:await stats()};}
async function diagnostic(name:string){for(const [tool,args] of [['vmmap',['-summary',String(child.pid)]],['heap',['-s',String(child.pid)]],...(process.env.ZEROWORK_RESOURCE_STACKS==='1'?[['malloc_history',[String(child.pid),'-callTree','malloc[48k-]']]]:[])]){try{await writeFile(join(out,`${name}-${tool}.txt`),execFileSync('/usr/bin/'+tool,args,{encoding:'utf8',timeout:30000,maxBuffer:8*1024*1024}));}catch(e){report[`${name}_${tool}_error`]=String(e);}}}
try{
 await waitForServerReady(30000);await resizeWindow(1200,800);await phase('empty');if(process.env.ZEROWORK_RESOURCE_DIAGNOSTIC==='1')await diagnostic('empty');
 await clickTestId('workspace.empty.local');await sleep(1000);
 const surface=(await query('terminal.surface')).find(shown);assert(surface);
 const ids=surface.children.filter((n:any)=>n.test_id?.startsWith('terminal.surface.row.')).map((n:any)=>n.test_id);
 tailIds=ids.slice(-6);await phase('prompt');
 await command("/usr/bin/perl -e 'for(1..10000){printf \"RESOURCE_%05d abcdefghijklmnopqrstuvwxyz0123456789\\n\",$_}print \"RESOURCE_LINES_\".\"DONE\\n\"'",'RESOURCE_LINES_DONE');
 await phase('ten_thousand_lines');
 await resetTiming();
 await command("/usr/bin/perl -e '$|=1;for(1..2500){printf \"\\rRESOURCE_TICK_%05d abcdefghijklmnopqrstuvwxyz\",$_;select undef,undef,undef,0.002}print \"\\nRESOURCE_TICKS_\".\"DONE\\n\"'",'RESOURCE_TICKS_DONE');
 report.continuous=await stats();await phase('repeated_updates');
 if(process.env.ZEROWORK_RESOURCE_DIAGNOSTIC==='1')await diagnostic('after-updates');
 const feature=await metrics();
 if(feature?.ok&&process.env.ZEROWORK_RESOURCE_EXPORT!=='0'){
  await command("/usr/bin/perl -e 'for(1..2048){print \"\\033]2;\",(\"x\"x4096),\"\\a\"}print \"RESOURCE_EXPORT_\".\"READY\\n\"'",'RESOURCE_EXPORT_READY');
  await resetTiming();
  const path=join(out,'large-export');const before=performance.now();
  const start=await request('POST','/zerowork/terminal',{action:'export',path,format:'txt_cast'});assert(start.ok);report.export_dispatch_ms=performance.now()-before;
  await command("printf 'RESOURCE_%s\\n' DURING_EXPORT",'RESOURCE_DURING_EXPORT');
  const result=await waitFor(async()=>{const m=await metrics();return m?.exports_completed>feature.exports_completed?m:null;},45000,20);
  assert.equal(result.export_error,null);assert((await stat(path+'.cast')).size>100000);assert((await stat(path+'.txt')).size>100000);
  report.export_result=result;report.export_bytes=(await stat(path+'.cast')).size;assert(report.export_bytes>8*1024*1024);report.export_frame_stats=await stats();
  report.export_checks=['paired large export completes','terminal command remains responsive while export is queued'];
 }
 if(process.env.ZEROWORK_RESOURCE_COMPOSITE==='1'){
  await type_('@');await waitFor(async()=>(await query('terminal.commands')).some(shown)||null,5000);
  await type_('help');await key('right');await waitFor(async()=>!(await query('terminal.commands')).some(shown)||null,5000);await key('enter');
  await waitFor(async()=>{const m=await metrics();return m?.composite_bytes>0?m:null;},15000);await sleep(500);
  report.composite_before_typing=await metrics();
 }
 await resetTiming();const observations:number[]=[];
 let typed='';for(const ch of 'printf RESOURCE_TYPING_OK'){typed+=ch;const t=performance.now();await type_(ch);await waitFor(async()=>(await tail()).includes(typed)||null,5000,5);observations.push(performance.now()-t);}
 report.rpc_character_visible_ms=observations;report.typing=await stats();
 if(report.composite_before_typing){report.composite_after_typing=await metrics();assert.equal(report.composite_after_typing.composite_full_rebuilds,report.composite_before_typing.composite_full_rebuilds);assert(report.composite_after_typing.composite_tail_updates>report.composite_before_typing.composite_tail_updates);await phase('composite_typing');if(process.env.ZEROWORK_RESOURCE_DIAGNOSTIC==='1')await diagnostic('after-composite');}
 await key('enter');
 await screenshot(join(out,'terminal.png'));
 await command("printf '\\033[2J\\033[HRESOURCE_CLEARED\\n'",'RESOURCE_CLEARED');await phase('cleared');
 await type_('exit');await key('enter');await waitFor(async()=>(await query('local.ended.close')).find(shown)||null,10000);
 await phase('ended');await clickTestId('tabs.close.1');await sleep(500);await phase('tab_closed');if(process.env.ZEROWORK_RESOURCE_DIAGNOSTIC==='1')await diagnostic('tab-closed');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await screenshot(join(out,'failure.png')).catch(()=>{});throw e;}
finally{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');await Promise.race([ended,sleep(2000)]);if(child.exitCode===null&&child.signalCode===null){child.kill('SIGKILL');await ended;}if(child.pid)await cleanupOwnedBridgeDirectories(child.pid);await log.close();await rm(temp,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2)+'\n');}
