/** Production route approval + real Broker, isolated from model/network/PTY. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,open} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]??'/tmp/zw-routing-native-build/bin/host-approval-preview');
const out=resolve(process.argv[3]??'/tmp/zw-routing-native');await mkdir(out,{recursive:true});
const report:any={status:'running',binary,checks:[],measurements:[],shutdown:[],limitations:['Isolated production component, no model/network/PTY dispatch. Full app provider-round routing is verified separately.','CUA browser file URL rejected by URL policy; no bypass attempted. Prior headless HTML computed measurements are separate evidence.']};
const shown=(n:any)=>n&&n.visible!==false&&n.hidden!==true&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>n.text??(n.children??[]).map(text).join('');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const save=()=>writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
try{
for(const width of [600,360]){
 const iso=await mkdtemp('/tmp/zw-routing-fixture-'),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(data);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,`${width}.log`),'w');
 const child=spawn(binary,['--kind=terminal_command','--route=ask'],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
 const ended=new Promise<any>(done=>child.once('exit',(code,signal)=>done({code,signal})));
 try{
  await h.waitForServerReady(10000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),child.pid);
  await h.resizeWindow(width,400);
  const card=await visible('ai.host_approval'),title=await visible('ai.host_approval.title'),icon=await visible('ai.host_approval.icon.terminal'),row=await visible('ai.host_approval.routes'),footer=await visible('ai.host_approval.footer');
  assert(Math.abs(icon.rect.y+icon.rect.h/2-title.rect.y-title.rect.h/2)<.5);
  assert.equal(row.rect.h,32);assert.equal(card.children[0].rect.h,289.625);
  const choices=[];
  for(const suffix of ['batch','current','new']){
   const id=`ai.host_approval.route.${suffix}`,button=await visible(id);assert.equal(button.rect.h,26.5);assert(button.rect.x>=row.rect.x&&button.rect.x+button.rect.w<=row.rect.x+row.rect.w+.5);assert((await h.clickTestId(id)).ok);await visible(id);choices.push({suffix,rect:button.rect});
   assert.deepEqual((await visible('ai.host_approval.footer')).rect,footer.rect);
   assert((await h.screenshot(join(out,`${width}-${suffix}.png`))).ok);
  }
  const reason=await visible('ai.host_approval.route.reason');assert(text(reason).includes('此命令'));
  for(const node of [title,icon,row,reason])assert.equal(node.effective_opacity??1,1);
  report.measurements.push({width,card:card.children[0].rect,row:row.rect,title:title.rect,icon:icon.rect,footer:footer.rect,choices});
  await writeFile(join(out,`${width}.json`),JSON.stringify(await h.query('host_approval.preview'),null,2));
  assert((await h.clickTestId(width===600?'ai.host_approval.accept':'ai.host_approval.reject')).ok);
  await h.waitFor(async()=>!(await h.query('ai.host_approval')).some(shown)||null,10000);
  assert(text(await visible('host_approval.preview.result')).includes(width===600?'已批准':'已拒绝'));
  report.checks.push(`${width}: three route choices, fixed permission actions, opaque foreground, real Broker approve/reject, next-frame release`);
 }finally{
  let method='POST /quit';try{await h.request('POST','/quit');await h.waitFor(async()=>child.exitCode!==null||child.signalCode!==null||null,10000)}catch(e){method='SIGTERM fallback';child.kill('SIGTERM')}
  const status=await ended;report.shutdown.push({width,method,...status});await log.close();await save();assert.equal(method,'POST /quit');assert.equal(status.code,0);assert.equal(status.signal,null);
 }
}
report.status='passed';await save();console.log(`PASS ${report.checks.length} routing fixtures: ${out}`);
}catch(e){report.status='failed';report.error=String(e);await save();throw e}
