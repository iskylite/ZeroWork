/** V0.1.8.1 comparable native-window workload. RPC observation includes automation
 * overhead and is NOT key-to-photon latency. Idle sampling makes no RPC calls. */
import assert from 'node:assert/strict';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
import {spawn, execFileSync} from 'node:child_process';
import {mkdir, mkdtemp, open, writeFile, readFile, rm, realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve, join} from 'node:path';
import {createHash} from 'node:crypto';
import {waitForServerReady, query, clickTestId, type_, key, waitFor, screenshot, resizeWindow, screenPos, stats, resetTiming, startWindowRecording, stopWindowRecording} from '../zig-out/share/zenit/harness/client.ts';
const [binaryArg, outputArg] = process.argv.slice(2);
assert(binaryArg && outputArg, 'usage: node e2e/terminal_perf_patch.ts binary output');
const binary=resolve(binaryArg), out=resolve(outputArg), isolated=await realpath(await mkdtemp(join(tmpdir(),'zw-perf-')));
const rpc=join(isolated,'rpc'), data=join(isolated,'data');
for (const path of [out,rpc,data]) await mkdir(path,{recursive:true});
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Menlo"\nfont_size = 14\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const child=spawn(binary,[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const closed=new Promise(r=>child.once('close',r));
const report:any={binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),pid:child.pid,checks:[],query_strategy:'Bounded parallel per-row queries after initial row discovery',limits:['RPC input-to-visible observation includes Harness IPC and per-row query overhead; not key-to-photon.','Idle CPU is process CPU-time delta / wall time, one core = 100%; Harness server remains enabled.','Termination of this isolated test process does not prove normal quit cleanup.']};
const sleep=(ms:number)=>new Promise(r=>setTimeout(r,ms));
function shown(n:any){return n.hidden!==true && n.visible!==false && n.rect?.w>0 && n.rect?.h>0 && (n.effective_opacity??1)>0;}
function text(n:any):string {return n.hidden===true?'':(n.text??'')+(n.children??[]).map(text).join('');}
async function surface(){const result=await query('terminal.surface');if(!Array.isArray(result)) throw new Error(JSON.stringify(result));return result.find(shown);}
let rowIds:string[]=[];
async function rows(ids=rowIds){return (await Promise.all(ids.map(id=>query(id)))).flat().filter(shown);}
async function outputText(ids=rowIds){return (await rows(ids)).map(text).join('');}
function sample(){
 const fields=execFileSync('/bin/ps',['-p',String(child.pid),'-o','time=,rss='],{encoding:'utf8'}).trim().split(/\s+/);
 const parts=fields[0].split(':').map(Number);let seconds=0;for(const part of parts) seconds=seconds*60+part;
 return {cpu_seconds:seconds,rss_kib:Number(fields[1]),at:performance.now()};
}
async function idle(label:string){
 await sleep(1000);const framesBefore=(await stats()).frame_count;await sleep(100);
 const a=sample();await sleep(8000);const b=sample();
 const framesAfter=(await stats()).frame_count;
 report[label]={cpu_percent:(b.cpu_seconds-a.cpu_seconds)*100000/(b.at-a.at),rss_kib:b.rss_kib,wall_ms:b.at-a.at,frame_delta:framesAfter-framesBefore};
 if(process.env.ZEROWORK_PERF_EXPECT_IDLE==='1') assert(framesAfter-framesBefore<=50,`${label}: static terminal kept rendering ${framesAfter-framesBefore} frames`);
}
try {
 await waitForServerReady();await resizeWindow(1200,800);
 assert((await clickTestId('workspace.empty.local')).ok);
 // Let the native pane apply its first PTY resize before discovering the row pool.
 await sleep(500);
 const initial=await waitFor(async()=>{const n=await surface();return n?.children?.some((r:any)=>r.test_id?.startsWith('terminal.surface.row.'))?n:null;},15000);
 rowIds=initial.children.filter((n:any)=>n.test_id?.startsWith('terminal.surface.row.')).map((n:any)=>n.test_id);
 assert(rowIds.length>0,'Discover actual terminal rows before output grows');
 await sleep(1500);
 await idle('single_idle');
 const observations:number[]=[];
 for(let i=0;i<12;i++){
  const token=`ZW_PATCH_ECHO_${i}_OK`;const start=performance.now();
  await type_(`printf 'ZW_PATCH_ECHO_%s_OK\\n' ${i}`);await key('enter');
  await waitFor(async()=>(await outputText()).includes(token)||null,5000);
  observations.push(performance.now()-start);
 }
 report.rpc_command_visible_ms=observations;report.checks.push('12 real PTY commands produce ordered output');
 await type_("printf '\\033[31mPATCH_中文_ANSI_OK\\033[0m\\n'");await key('enter');
 await waitFor(async()=>(await outputText()).includes('PATCH_中文_ANSI_OK')||null);
 await resizeWindow(1000,720);await sleep(500);
 assert((await screenshot(join(out,'local-terminal.png'))).ok);report.checks.push('ANSI/Unicode output and resize captured');
 const tailIds=(await rows()).map((n:any)=>n.test_id).slice(-6);
 async function tailText(){return outputText(tailIds);}
 const before=sample();
 await type_("i=0; while [ $i -lt 1000 ]; do printf 'PATCH_LINE_%s abcdefghijklmnopqrstuvwxyz\\n' $i; i=$((i+1)); done; printf 'PATCH_%s\\n' FLOOD_DONE");await key('enter');
 await waitFor(async()=>(await tailText()).includes('PATCH_FLOOD_DONE')||null,30000);
 const after=sample();report.flood={cpu_seconds:after.cpu_seconds-before.cpu_seconds,wall_ms:after.at-before.at,rss_kib:after.rss_kib};
 await idle('post_flood_idle');report.frame_stats=await stats();
 const measuredRows=await rows();
 function nodeCount(n:any):number{return 1+(n.children??[]).reduce((sum:number,c:any)=>sum+nodeCount(c),0);}
 report.terminal_row_nodes=measuredRows.reduce((sum:number,row:any)=>sum+nodeCount(row),0);
 await resetTiming();
 const echoObservations:number[]=[];
 let typed='';
 for(const char of 'printf ZW_NATIVE_TYPING_0123456789'){
  typed+=char;const began=performance.now();await type_(char);
  await waitFor(async()=>(await tailText()).includes(typed)||null,5000,5);
  echoObservations.push(performance.now()-began);
 }
 report.rpc_character_visible_ms=echoObservations;
 report.typing_frame_stats=await stats();
 await key('enter');await sleep(300);
 await resetTiming();
 await type_("/usr/bin/perl -e '$|=1; for(1..180){printf \"NATIVE_STREAM_%03d abcdefghijklmnopqrstuvwxyz\\n\", $_; select undef,undef,undef,0.01} print \"NATIVE_STREAM_DONE\\n\"'");await key('enter');
 await sleep(2600);
 await waitFor(async()=>(await tailText()).includes('NATIVE_STREAM_DONE')||null,10000);
 report.continuous_frame_stats=await stats();
 assert((await screenshot(join(out,'continuous-output.png'))).ok);
 if(process.env.ZEROWORK_PERF_RECORD==='1'){
  await startWindowRecording(join(out,'continuous-output.mp4'),{fps:60});
  await type_("/usr/bin/perl -e '$|=1;for(1..120){printf \"RECORDING_%03d abcdefghijklmnopqrstuvwxyz\\n\",$_;select undef,undef,undef,0.01}'");await key('enter');
  await sleep(2200);report.recording=await stopWindowRecording();
 }
 report.checks.push('Per-character PTY echo and 180 paced output updates remain responsive');
 assert((await screenshot(join(out,'post-flood.png'))).ok);
 await writeFile(join(out,'post-flood-rows.json'),JSON.stringify(Object.fromEntries(await Promise.all(tailIds.map(async(id:string)=>[id,await query(id)]))),null,2));
 if(process.env.ZEROWORK_PERF_SAMPLE==='1') execFileSync('/usr/bin/sample',[String(child.pid),'3','-file',join(out,'sample.txt')],{stdio:'ignore'});
 await type_("printf 'PATCH_%s\\n' AFTER_FLOOD");await key('enter');await waitFor(async()=>(await tailText()).includes('PATCH_AFTER_FLOOD')||null);
 report.checks.push('1000-line flood completes and input remains usable');
 await resizeWindow(1440,900);await sleep(300);
 assert((await screenshot(join(out,'local-reference-size.png'))).ok);
 report.reference_size=await screenPos('workspace.shell');
 assert.equal(report.reference_size.w,1440);assert.equal(report.reference_size.h,900);
 await type_('exit');await key('enter');
 await waitFor(async()=> (await query('local.ended.close')).find(shown)||null,10000);
 report.checks.push('shell exit reaches retained terminal state');report.status='passed';
} catch(e){report.status='failed';report.error=String(e);report.child_exit_code=child.exitCode;await screenshot(join(out,'failure.png')).catch(()=>{});throw e;}
finally {
 if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');
 await Promise.race([closed,sleep(2000)]);
 if(child.exitCode===null&&child.signalCode===null){child.kill('SIGKILL');await closed;}
 const bridges=child.pid?await cleanupOwnedBridgeDirectories(child.pid):[];
 report.process_cleanup={exit_code:child.exitCode,signal:child.signalCode,private_bridge_directories_removed:bridges};
 await log.close();await rm(isolated,{recursive:true,force:true});
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2)+'\n');
}
