/** Native large-history rebuild lifecycle. Profilers run outside frame samples. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,realpath,mkdir,open,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {createHash} from 'node:crypto';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
const {waitForServerReady,query,clickTestId,type_,key,waitFor,screenshot,resizeWindow,stats,resetTiming,request}=await import(process.env.ZEROWORK_HARNESS_CLIENT??new URL('../zig-out/share/zenit/harness/client.ts',import.meta.url).href);
const [binaryArg,outArg]=process.argv.slice(2);assert(binaryArg&&outArg);
const captureVisuals=process.env.ZEROWORK_REBUILD_SCREENSHOTS!=='0';
const binary=resolve(binaryArg),out=resolve(outArg),temp=await realpath(await mkdtemp(join(tmpdir(),'zw-rebuild-')));
await mkdir(out,{recursive:true});await mkdir(join(temp,'rpc'));await mkdir(join(temp,'data'));
process.env.ZENIT_E2E_FILE_RPC_DIR=join(temp,'rpc');
await writeFile(join(temp,'data/config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
const log=await open(join(out,'app.log'),'w');
const diagnosticEnv=process.env.ZEROWORK_MALLOC_DIAG==='1'?{MallocStackLogging:'1',MallocStackLoggingNoCompact:'1'}:{};
const child=spawn(binary,[],{env:{...process.env,...diagnosticEnv,ZEROWORK_DATA_DIR:join(temp,'data'),ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>child.once('close',r)),sleep=(ms:number)=>new Promise(r=>setTimeout(r,ms));
const report:any={binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),screenshots:captureVisuals,malloc_diagnostics:process.env.ZEROWORK_MALLOC_DIAG==='1',phases:{},limits:['ReleaseFast native Metal window, synthetic key events, 1200x800 logical viewport.','Action visibility includes RPC overhead; frame timing is reported separately.','RSS includes reusable allocator pages; vmmap physical footprint and heap live bytes are separate measurements.','Screenshots allocate PNG readback buffers inside the target. Use a separate no-screenshot run for memory attribution.']};
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>n.hidden||n.visible===false?'':(n.text??'')+(n.children??[]).map(text).join('');
async function tail(){return (await query('terminal.surface')).filter(shown).map(text).join('');}
async function metrics(){return request('POST','/zerowork/terminal',{action:'metrics'});}
async function command(value:string,token:string){await type_(value);await key('enter');await waitFor(async()=>(await tail()).includes(token)||null,45000,10);}
let iteration=0;
const label=(name:string)=>iteration===0?name:`reopen${iteration}_${name}`;
function rss(){return Number(execFileSync('/bin/ps',['-p',String(child.pid),'-o','rss='],{encoding:'utf8'}).trim());}
async function phase(name:string,action?:()=>Promise<void>,heap=false){
 name=label(name);
 await log.write(`PHASE_START ${name}\n`);
 await resetTiming();const start=performance.now();if(action)await action();const visible=performance.now()-start;
 await sleep(350);const frame=await stats();
 const memory=await request('POST','/zerowork/terminal',{action:'memory'});
 const m=await metrics();const v=execFileSync('/usr/bin/vmmap',['-summary',String(child.pid)],{encoding:'utf8',timeout:30000,maxBuffer:4*1024*1024});await writeFile(join(out,name+'-vmmap.txt'),v);
 const physical=v.match(/Physical footprint:\s+(\S+)/)?.[1],peak=v.match(/Physical footprint \(peak\):\s+(\S+)/)?.[1];
 report.phases[name]={visible_ms:visible,frame,terminal:m,memory,rss_kib:rss(),physical_footprint:physical,physical_footprint_peak:peak};
 if(heap){const h=execFileSync('/usr/bin/heap',['-s',String(child.pid)],{encoding:'utf8',timeout:30000,maxBuffer:4*1024*1024});await writeFile(join(out,name+'-heap.txt'),h);report.phases[name].live_malloc_bytes=Number(h.match(/All zones: \d+ nodes \((\d+) bytes\)/)?.[1]);}
 await log.write(`PHASE_END ${name}\n`);
}
try{
 await waitForServerReady(30000);await resizeWindow(1200,800);await phase('empty',undefined,true);
 for(iteration=0;iteration<Number(process.env.ZEROWORK_REBUILD_CYCLES??1);iteration++){
 const reclaimBaseline=(await request('POST','/zerowork/terminal',{action:'memory'})).idle_reclaim_runs??0;
 const openProfile:any[]=[];
 await phase('terminal_open',async()=>{
  await clickTestId('workspace.empty.local');
  await waitFor(async()=>{
   const ready=/[%#$] /.test(await tail());
   if(process.env.ZEROWORK_REBUILD_PROFILE==='1')openProfile.push(await request('POST','/zerowork/terminal',{action:'profile'}));
   return ready||null;
  },15000);
 });await sleep(250);
 if(openProfile.length)await writeFile(join(out,label('shell-profile.json')),JSON.stringify(openProfile,null,2)+'\n');
 if(process.env.ZEROWORK_REBUILD_SHELL_ONLY==='1')break;
 await command("/usr/bin/perl -e 'for(1..10000){printf \"REBUILD_%05d abcdefghijklmnopqrstuvwxyz0123456789\\n\",$_}print \"REBUILD_LINES_\".\"DONE\\n\"'",'REBUILD_LINES_DONE');
 await phase('large_history');
 if(process.env.ZEROWORK_REBUILD_CONTROL!=='1'){
 let palette=false;
 for(let attempt=1;attempt<=3;attempt++){
  await type_('@');try{await waitFor(async()=>(await query('terminal.commands')).some(shown)||null,5000);palette=true;report.palette_attempts=attempt;break;}
  catch{await key('c',{ctrl:true});await sleep(300);}
 }
 assert(palette,'Trusted shell command palette must be ready before measuring document rebuild');
 await type_('help');await key('right');await waitFor(async()=>!(await query('terminal.commands')).some(shown)||null,5000);
 const firstProfile:any[]=[],firstTrace:any[]=[];
 await phase('first_open',async()=>{const submitted=performance.now();await key('enter');
 if(process.env.ZEROWORK_REBUILD_TRACE==='1')firstTrace.push({event:'key_return',elapsed_ms:performance.now()-submitted});
 if(process.env.ZEROWORK_REBUILD_ECHO_DURING_OPEN==='1'){
  const hydrating=await waitFor(async()=>{const m=await metrics();return m.glyphs_pending?m:null;},5000,2);
  await command("printf 'REBUILD_%s\\n' LIVE_DURING_OPEN",'REBUILD_LIVE_DURING_OPEN');
  const echoed=await metrics();
  report.input_submitted_during_hydration=true;
  // A shorter hydration may finish between observing it and AppKit delivering
  // the synthetic text event. Report that race; the command/echo assertion
  // above still uses the real native input path.
  report.live_input_during_hydration=echoed.input_during_hydration===undefined?null:echoed.input_during_hydration>hydrating.input_during_hydration;
 }
 await waitFor(async()=>{
  if(process.env.ZEROWORK_REBUILD_PROFILE==='1')firstProfile.push(await request('POST','/zerowork/terminal',{action:'profile'}));
  const m=await metrics();if(process.env.ZEROWORK_REBUILD_TRACE==='1')firstTrace.push({elapsed_ms:performance.now()-submitted,...m});return m?.composite_bytes>0&&!m.glyphs_pending&&(m.composite_source_complete===undefined||m.composite_source_complete&&!m.composite_search_pending)?m:null;
 },45000,2);
 if(process.env.ZEROWORK_REBUILD_PROFILE==='1')for(let i=0;i<4;i++){firstProfile.push(await request('POST','/zerowork/terminal',{action:'profile'}));await sleep(5);}
 });
 if(firstProfile.length)await writeFile(join(out,label('first-profile.json')),JSON.stringify(firstProfile,null,2)+'\n');
 if(firstTrace.length)await writeFile(join(out,label('first-trace.json')),JSON.stringify(firstTrace,null,2)+'\n');
 if(captureVisuals)await screenshot(join(out,label('first-open')+'.png'));
 }
 await phase('newlines',async()=>{for(let i=1;i<=8;i++)await command(`printf 'REBUILD_%s\\n' NEWLINE_${i}`,`REBUILD_NEWLINE_${i}`);});
 await phase('clear_screen',async()=>command("printf '\\033[2J\\033[HREBUILD_%s\\n' CLEARED",'REBUILD_CLEARED'),true);
 const m=await metrics();
 if(process.env.ZEROWORK_REBUILD_CONTROL!=='1'&&m?.composite_synchronous_scans!==undefined){
  assert.equal(m.composite_synchronous_scans,0);assert(m.composite_incremental_rebuilds>=8);
  assert(m.composite_background_scans<=2);assert(m.composite_last_composed_rows<150);
 }
 if(captureVisuals)await screenshot(join(out,label('cleared')+'.png'));
 await phase('ended',async()=>{await type_('exit');await key('enter');await waitFor(async()=>(await query('local.ended.close')).some(shown)||null,45000);});
 await phase('tab_closed',async()=>{await clickTestId(`tabs.close.${iteration+1}`);await waitFor(async()=>(await query('workspace.empty.local')).some(shown)||null,15000);},true);
 if(captureVisuals)await screenshot(join(out,label('closed')+'.png'));assert.equal(report.phases[label('tab_closed')].terminal.error,'TabMissing');
 if(report.phases[label('tab_closed')].memory?.background_search_tasks!==undefined)assert.equal(report.phases[label('tab_closed')].memory.background_search_tasks,0);
 if(process.env.ZEROWORK_REBUILD_IDLE&&!(process.env.ZEROWORK_REBUILD_IDLE==='mixed'&&iteration===0)){
  await phase('idle_reclaimed',async()=>{await waitFor(async()=>{const m=await request('POST','/zerowork/terminal',{action:'memory'});return m.idle_reclaim_runs>reclaimBaseline&&!m.idle_reclaim_running?m:null;},10000,25);},true);
  if(captureVisuals)await screenshot(join(out,label('idle-reclaimed')+'.png'));
 }
 }
 if(process.env.ZEROWORK_MALLOC_DIAG==='1'){
  const full=execFileSync('/usr/bin/vmmap',['-w',String(child.pid)],{encoding:'utf8',timeout:30000,maxBuffer:16*1024*1024});await writeFile(join(out,'closed-full-vmmap.txt'),full);
  for(const match of full.matchAll(/^Malloc Large \(empty\)\s+([0-9a-f]+)-/gmi)){
   const address='0x'+match[1];
   try{const history=execFileSync('/usr/bin/malloc_history',[String(child.pid),address],{encoding:'utf8',timeout:30000,maxBuffer:8*1024*1024});await writeFile(join(out,'freed-'+address+'.txt'),history);}catch(e){await writeFile(join(out,'freed-'+address+'.txt'),String(e));}
  }
 }
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await screenshot(join(out,'failure.png')).catch(()=>{});throw e;}
finally{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');await Promise.race([ended,sleep(2000)]);if(child.exitCode===null&&child.signalCode===null){child.kill('SIGKILL');await ended;}if(child.pid)await cleanupOwnedBridgeDirectories(child.pid);await log.close();await rm(temp,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2)+'\n');}
