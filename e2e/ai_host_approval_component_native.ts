/** Isolated production host approval View + Broker. Never issues HTTP/PTY. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,open} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]??'/tmp/zerowork-host-approval-build/out/bin/host-approval-preview');
const out=resolve(process.argv[3]??'/tmp/zw-host-approval-evidence');await mkdir(out,{recursive:true});
const shown=(n:any)=>n&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>n.text??(n.children??[]).map(text).join('');
const visible=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const report:any={status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],measurements:[],shutdown:[],matrix:{themes:['dark','light','sauber'],transparency:[0,75,100],width:[600,360],kinds:['network_url','lifecycle','terminal_command']},limitations:['Component acceptance uses representative trusted host subjects; production tool routing is integrated separately.','No network or PTY is attempted; integration retains its own live backend validation.','This isolated fixture mounts the inline production card directly on surface_1, without the AI L1 floating shell. L1 alpha 245/222/214 and backdrop blur are therefore not measured by this fixture. The tree RPC exposes geometry and opacity, not paint, border, outline or font styles; those require source and pixel inspection.']};
const saveReport=()=>writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
const within=(inner:any,outer:any)=>inner.x>=outer.x-.5&&inner.y>=outer.y-.5&&inner.x+inner.w<=outer.x+outer.w+.5&&inner.y+inner.h<=outer.y+outer.h+.5;
const fixtures=[];
for(const theme of report.matrix.themes)for(const transparency of report.matrix.transparency)for(const width of report.matrix.width)for(const subject of [{kind:'network_url',title:'获取网页',icon:'network'},{kind:'lifecycle',title:'管理会话',icon:'lifecycle'},{kind:'terminal_command',title:'执行命令',icon:'terminal'}]){
 const long=subject.kind==='network_url'&&width===360;
 fixtures.push({...subject,theme,transparency,name:`${subject.kind}-${theme}-t${transparency}-${width}${long?'-long':''}`,args:[`--kind=${subject.kind}`,`--theme=${theme}`,`--transparency=${transparency}`,...(long?['--long-url']:[])],width,decision:subject.kind!=='terminal_command'&&width===600});
}
await saveReport();
try{
for(const fixture of fixtures){
 const isolated=await mkdtemp('/tmp/zw-host-approval-final-'),rpc=join(isolated,'rpc'),data=join(isolated,'data');await mkdir(rpc);await mkdir(data);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,`${fixture.name}.log`),'w');
 const child=spawn(binary,fixture.args,{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
 const ended=new Promise<{code:number|null,signal:string|null}>(done=>child.once('exit',(code,signal)=>done({code,signal})));
 try{
  await h.waitForServerReady(10000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),child.pid);await h.resizeWindow(fixture.width,360);
  await h.waitFor(async()=>{const n=(await h.query('host_approval.preview')).find(shown);return n?.rect.w===fixture.width&&n?.rect.h===360||null},10000);
  const card=await visible('ai.host_approval'),preview=await visible('host_approval.preview');
  const title=await visible('ai.host_approval.title');assert.equal(text(title),fixture.title);
  const icon=await visible(`ai.host_approval.icon.${fixture.icon}`);
  assert(Math.abs(icon.rect.y+icon.rect.h/2-title.rect.y-title.rect.h/2)<.5);
  assert(icon.rect.x+icon.rect.w<=title.rect.x);
  const target=await visible('ai.host_approval.target'),impact=await visible('ai.host_approval.impact'),notice=await visible('ai.host_approval.impact_notice');
  assert(target.rect.w>0);assert(within(target.rect,card.rect));assert(text(target).length>0);assert(text(impact).length>0);
  for(const node of [card,title,icon,target,impact,notice])assert.equal(node.effective_opacity??1,1,'foreground opacity must remain 1');
  if(fixture.title==='获取网页'){
   const bar=await visible('ai.host_approval.address_bar');
   assert.equal(bar.rect.h,38);assert(!(await h.query('ai.host_approval.source')).some(shown));
  }
  const details=await visible('ai.host_approval.details'),footer=await visible('ai.host_approval.footer');assert(footer.rect.y>=details.rect.y+details.rect.h-.5);assert(within(footer.rect,preview.rect));assert(within(footer.rect,card.rect));
  const accept=await visible('ai.host_approval.accept'),reject=await visible('ai.host_approval.reject');assert.equal(accept.rect.w,reject.rect.w);assert.equal(accept.rect.h,reject.rect.h);
  assert(within(accept.rect,footer.rect));assert(within(reject.rect,footer.rect));assert(reject.rect.x+reject.rect.w<=accept.rect.x);
  await h.waitFor(async()=>(await h.stats()).frame_count>=2||null,10000);
  // Harness query text is capped at 200 bytes. The full retained address is
  // one line and scrolls horizontally inside the dedicated 38px bar.
  if(fixture.name.includes('long')){
   const url=await visible('ai.host_approval.url'),viewport=await visible('ai.host_approval.url_viewport'),copy=await visible('ai.host_approval.copy_url');assert.equal(url.text.length,200);assert.equal(url.rect.h,17);assert(url.rect.w>viewport.rect.w);assert(footer.rect.y+footer.rect.h<=360);assert(copy.rect.x>=viewport.rect.x+viewport.rect.w);
   await h.scrollAt(viewport.rect.x+viewport.rect.w/2,viewport.rect.y+viewport.rect.h/2,-800,0);
   await h.waitFor(async()=>(await visible('ai.host_approval.url')).rect.x<url.rect.x-100||null,5000);
   assert.deepEqual((await visible('ai.host_approval.copy_url')).rect,copy.rect);assert.deepEqual((await visible('ai.host_approval.footer')).rect,footer.rect);
   await h.mouseMove(1,359);
   assert((await h.screenshot(join(out,`${fixture.name}-scrolled.png`))).ok);
   await h.scrollAt(viewport.rect.x+viewport.rect.w/2,viewport.rect.y+viewport.rect.h/2,800,0);
   await h.waitFor(async()=>Math.abs((await visible('ai.host_approval.url')).rect.x-url.rect.x)<1||null,5000);
  }
  // Risk text can exceed the fixed body in a narrow card. Its final line must
  // be reachable by the body scroll while decisions remain outside it.
  await h.scrollAt(details.rect.x+details.rect.w/2,details.rect.y+details.rect.h-2,0,-800);
  const scrolledImpact=await visible('ai.host_approval.impact');assert(scrolledImpact.rect.y+scrolledImpact.rect.h<=details.rect.y+details.rect.h+.5);assert.deepEqual((await visible('ai.host_approval.footer')).rect,footer.rect);
  await h.scrollAt(details.rect.x+details.rect.w/2,details.rect.y+details.rect.h/2,0,800);
  await h.mouseMove(1,359);
  assert((await h.screenshot(join(out,`${fixture.name}.png`))).ok);
  await writeFile(join(out,`${fixture.name}.json`),JSON.stringify(await h.query('host_approval.preview'),null,2));
  report.measurements.push({name:fixture.name,theme:fixture.theme,transparency:fixture.transparency,width:fixture.width,kind:fixture.kind,preview:preview.rect,wrapper:card.rect,card:card.children[0].rect,title:title.rect,icon:icon.rect,icon_title_center_delta:Math.abs(icon.rect.y+icon.rect.h/2-title.rect.y-title.rect.h/2),target:{rect:target.rect,text:text(target)},impact:{rect:impact.rect,text:text(impact),scrolled_rect:scrolledImpact.rect},details:details.rect,footer:footer.rect,accept:accept.rect,reject:reject.rect,foreground_opacity:1,stats:await h.stats(),isolated,rpc,pid:child.pid});
  assert((await h.clickTestId(fixture.decision?'ai.host_approval.accept':'ai.host_approval.reject')).ok);
  await h.waitFor(async()=>!(await h.query('ai.host_approval')).some(shown)||null,10000);
  assert(text(await visible('host_approval.preview.result')).includes(fixture.decision?'已批准':'已拒绝'));
  report.checks.push(`${fixture.name}: full subject, fixed decisions, real Broker decision and next-frame card release passed`);
  console.log(`PASS ${report.checks.length}/54 ${fixture.name}`);
 }finally{
  const shutdown:any={name:fixture.name,method:'already_exited'};
  if(child.exitCode===null&&child.signalCode===null){
   try{shutdown.response=await h.request('POST','/quit');shutdown.method='POST /quit';await h.waitFor(async()=>child.exitCode!==null||child.signalCode!==null||null,10000)}catch(error){shutdown.error=String(error);shutdown.method='SIGTERM fallback';child.kill('SIGTERM')}
  }
  Object.assign(shutdown,await ended);report.shutdown.push(shutdown);await log.close();await saveReport();
  assert.equal(shutdown.method,'POST /quit','normal fixture shutdown required');assert.equal(shutdown.code,0);assert.equal(shutdown.signal,null);
 }
}
assert.equal(report.checks.length,54);report.status='passed';await saveReport();console.log(`Passed all 54 fixtures; evidence: ${out}`);
}catch(error){report.status='failed';report.error=String(error);await saveReport();throw error}
