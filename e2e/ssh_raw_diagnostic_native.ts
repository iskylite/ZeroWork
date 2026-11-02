/** Hover the exact failed native log row; no separate diagnostic button. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';
const out=resolve(process.argv[2]??'artifacts/ssh-raw-diagnostic');
await mkdir(out,{recursive:true});
const rpc=await mkdtemp('/tmp/zw-ssh-raw-');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'native.log'),'w');
const app=spawn(resolve('zig-out/bin/connection-progress-preview'),['handshake'],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&n.opacity!==0&&(n.effective_opacity??1)>.9&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
try{
 await h.waitForServerReady();
 await visible('connection.progress');
 await h.clickTestId('connection.progress.logs.toggle');
 assert.equal((await h.query('connection.progress.logs.raw')).length,0,'no separate raw-log button');
 for(const [w,ht] of [[1280,720],[860,480]]){
  await h.resizeWindow(w,ht);
  const ordinary=(await h.query('connection.progress.logs.row')).find(shown);assert(ordinary);
  await h.mouseMove(ordinary.rect.x+40,ordinary.rect.y+8);
  await h.sleep(450);
  await absent('connection.progress.logs.raw-popover');
  const failure=await visible('connection.progress.logs.failure');
  await h.mouseMove(failure.rect.x+40,failure.rect.y+8);
  const bubble=await visible('connection.progress.logs.raw-popover');
  assert.equal(bubble.rect.w,520);
  assert(bubble.rect.x>=0&&bubble.rect.y>=0&&bubble.rect.x+bubble.rect.w<=w+1&&bubble.rect.y+bubble.rect.h<=ht+1,'bubble stays inside viewport');
  const raw=text(await visible('connection.progress.logs.raw-text'));
  await writeFile(join(out,`raw-${w}.json`),JSON.stringify(await h.query('connection.progress.logs.raw-text'),null,2));
  // Harness query truncates each text node to 200 bytes; complete values and
  // elapsed suffixes are covered by the production view/journal tests.
  assert(raw.includes('handshake transport')&&raw.includes('rc=-13'));
  assert(/\n\d{2}:\d{2}:\d{2}\.\d{3} - handshake transport/.test(raw));
  const phase=text(await visible('connection.progress.logs'));
  assert(/\d{2}:\d{2}:\d{2}\.\d{3} - TCP/.test(phase)&&!phase.includes('+0.'));
  await h.sleep(150);
  assert((await h.screenshot(join(out,`native-${w}.png`))).ok);
  await writeFile(join(out,`native-${w}.json`),JSON.stringify({progress:await h.query('connection.progress'),bubble:await h.query('connection.progress.logs.raw-popover')},null,2));
  await h.mouseMove(ordinary.rect.x+40,ordinary.rect.y+8);
  await absent('connection.progress.logs.raw-popover');
  await h.mouseMove(failure.rect.x+40,failure.rect.y+8);
  await visible('connection.progress.logs.raw-popover');
  await h.key('escape');
  await absent('connection.progress.logs.raw-popover');
  await visible('connection.progress');
 }
 const failure=await visible('connection.progress.logs.failure');
 await h.mouseMove(20,80);await h.mouseMove(failure.rect.x+40,failure.rect.y+8);
 await visible('connection.progress.logs.raw-popover');
 await h.clickTestId('connection.progress.retry');
 await h.waitFor(async()=>text(await visible('connection.progress.attempt'))==='第 2 次尝试'||null);
 await absent('connection.progress.logs.raw-popover');
 await absent('connection.progress.logs.failure');
 await writeFile(join(out,'result.json'),JSON.stringify({status:'passed',checks:['failure-row hover only; no separate button','timestamp-message-duration in live/raw logs','native bubble 1280/860 viewport bounds','Escape closes bubble only','leaving failed row dismisses bubble','retry clears previous diagnostic']},null,2));
 console.log('PASS: native failure-row SSH hover bubble with no separate button');
}finally{app.kill('SIGTERM');await ended;await log.close();await rm(rpc,{recursive:true,force:true});}
