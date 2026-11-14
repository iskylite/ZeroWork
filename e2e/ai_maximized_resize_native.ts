/** Maximized assistant resize with an isolated Local terminal and no model requests.
 * ZW_AI_TEST_PREFIX=<test build> node e2e/ai_maximized_resize_native.ts <out>
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,realpath,rm,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-ai-max-resize-build');
const out=resolve(process.argv[2]??'/tmp/zw-ai-max-resize-evidence');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/private/tmp/zw-ai-max-resize-'));
const data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[updates]\nauto_check=false\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const alive=()=>app.exitCode===null&&app.signalCode===null;
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const report:any={status:'running',checks:[],geometry:{}};
const click=async(id:string)=>{report.lastAction=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
const rectIs=(a:any,b:any)=>['x','y','w','h'].every(k=>Math.abs(a[k]-b[k])<1);
const waitRect=(expected:any)=>h.waitFor(async()=>rectIs((await visible('ai.panel')).rect,expected)||null,5000);
const capture=async(name:string)=>{await h.mouseMove(1,1);assert((await h.screenshot(join(out,name+'.png'))).ok);report.geometry[name]=(await visible('ai.panel')).rect};
async function dragStart(id:string,dx:number,dy:number){
 const r=(await visible(id)).rect,x=r.x+r.w/2,y=r.y+r.h/2;
 await h.mouseMove(x,y);await h.mouseDown(x,y);await h.mouseMove(x+dx,y+dy);
 return {x:x+dx,y:y+dy};
}
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1440,900);
 await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');
 const normal=(await visible('ai.panel')).rect;await click('ai.maximize');
 const full=await h.waitFor(async()=>{const r=(await visible('ai.panel')).rect;return r.w>normal.w+100?r:null},5000);
 for(const edge of ['n','s','w','e','nw','ne','sw','se'])await visible('ai.float.resize.'+edge);
 await capture('maximized');
 const cancelAt=await dragStart('ai.float.resize.w',80,0);
 await h.waitFor(async()=>Math.abs((await visible('ai.panel')).rect.w-(full.w-80))<1||null,5000);
 await h.key('escape');await h.mouseUp(cancelAt.x,cancelAt.y);await waitRect(full);
 const end=await dragStart('ai.float.resize.se',-120,-80);await h.mouseUp(end.x,end.y);
 const resized=await h.waitFor(async()=>{const r=(await visible('ai.panel')).rect;return Math.abs(r.w-(full.w-120))<1&&Math.abs(r.h-(full.h-80))<1?r:null},5000);
 await capture('resized');await click('ai.maximize');await waitRect(full);await click('ai.maximize');await waitRect(resized);
 report.checks.push('All handles are available while maximized; Escape cancels, and maximize/restore retains the new rectangle');
 await h.resizeWindow(860,480);await click('ai.maximize');
 const compact=(await visible('ai.panel')).rect;
 const compactEnd=await dragStart('ai.float.resize.w',30,0);await h.mouseUp(compactEnd.x,compactEnd.y);
 await h.waitFor(async()=>Math.abs((await visible('ai.panel')).rect.w-(compact.w-30))<1||null,5000);
 await capture('compact-resized');report.checks.push('The maximized assistant can also be resized in the compact window');
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;if(alive())await h.screenshot(join(out,'failure.png')).catch(()=>{});}
finally{
 try{if(alive()){
  await h.request('POST','/zerowork/windows',{action:'quit'});
  await Promise.race([ended,h.sleep(500)]);
  const start=performance.now();while(alive()&&performance.now()-start<15000){
   for(const id of ['groups.close.accept','local.close.accept','session.close.accept'])try{if(alive()&&(await h.query(id)).some(shown))await h.clickTestId(id)}catch{}
   await Promise.race([ended,h.sleep(80)]);
  }
 }}catch(error){report.quitError=String(error)}
 if(alive()){report.forced=true;app.kill('SIGTERM');await ended;}
 report.exitCode=app.exitCode;if(report.forced||app.exitCode!==0){report.status='failed';process.exitCode=1;}
 await log.close();await rm(iso,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}
