/** Isolated native regression for initial effort and cross-provider inheritance. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,open,realpath,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';

const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);
await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp('/tmp/zw-effort-')),data=join(base,'data'),rpc=join(base,'rpc');
await mkdir(data);await mkdir(rpc);await writeFile(join(data,'hosts.toml'),'');
const models=[
 {id:'model-a',context_window:64000,reasoning:true,thinking:{values:['medium','high']}},
 {id:'quiet',context_window:64000,reasoning:false},
 {id:'model-b',context_window:64000,reasoning:true,thinking:{values:['low','high','xhigh']}},
];
const requests:any[]=[];
const server=createServer(async(req,res)=>{
 if(req.method==='GET'){
  res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:models}));return;
 }
 let body='';for await(const chunk of req)body+=chunk;
 requests.push(JSON.parse(body));
 res.writeHead(200,{'content-type':'text/event-stream'});
 res.end('data: '+JSON.stringify({choices:[{index:0,delta:{content:'已收到。'},finish_reason:null}]})+'\n\ndata: '+JSON.stringify({choices:[{index:0,delta:{},finish_reason:'stop'}]})+'\n\ndata: [DONE]\n\n');
});
await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ai]\ndefault_provider="one"\n`+
 [['one',models.slice(0,2)],['two',models.slice(2)]].map(([id,list]:any)=>
 `[[ai.providers]]\nid="${id}"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n`+
 list.map((m:any,i:number)=>`[[ai.providers.models]]\nname="${m.id}"\ncontext_window=64000\ndefault=${i===0}\nreasoning=${m.reasoning}\nefforts=${JSON.stringify(m.thinking?.values??[])}\n`).join('')).join(''));
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n&&n.visible!==false&&!n.hidden&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id);};
const menu=async()=>{if(!(await h.query('ai.model.menu')).some(shown))await click('ai.composer.model');await visible('ai.model.menu');};
const value=(expected:string)=>h.waitFor(async()=>(await visible('ai.effort.value')).text===expected||null,10000);
async function select(model:string){
 await menu();
 const row=await h.waitFor(async()=>(await h.query('ai.model.option')).find(n=>shown(n)&&flat(n).some(c=>c.text===model))??null,15000);
 assert((await h.clickAt(row.rect.x+row.rect.w/2,row.rect.y+row.rect.h/2)).ok);
 await h.waitFor(async()=>flat(await visible('ai.composer.model')).some(n=>shown(n)&&n.text===model)||null);
 await menu();
}
async function send(model:string,effort:string){
 if((await h.query('ai.model.menu')).some(shown))await h.key('escape');
 const count=requests.length;
 await click('ai.prompt');await h.type_('验证推理强度 '+count);await click('ai.send');
 await h.waitFor(()=>requests.length>count||null,15000);
 assert.equal(requests[count].model,model);assert.equal(requests[count].reasoning_effort,effort);
 await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,15000);
}
const report:any={status:'running',checks:[]};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1440,900);
 await click('workspace.empty.local');await visible('terminal.surface');await click('ai.strip');await menu();
 await value('中');assert((await h.screenshot(join(out,'01-lowest-medium.png'))).ok);
 await send('model-a','medium');report.checks.push('Unselected model starts at its lowest declared level (medium), and sends medium');
 await select('model-b');await value('档位不支持');
 report.checks.push('Switching provider preserves medium even when the target only supports low/high/xhigh');
 const popupBefore=(await visible('ai.model.menu')).rect;
 report.effortPopupGeometry=[];
 for(const [ratio,expected] of [[0.5,'高'],[0,'低'],[0.5,'高'],[1,'较高'],[0.5,'高']] as const){
  const track=await visible('ai.effort.slider.track');
  await h.trackStart('ai.model.menu');
  assert((await h.clickAt(track.rect.x+1+(track.rect.w-2)*ratio,track.rect.y+track.rect.h/2)).ok);
  await value(expected);
  const samples=await h.trackStop();
  assert(samples.length>1,'Effort switch must capture intermediate frames');
  for(const sample of samples){
   assert(sample.found,'Popup disappeared during effort switch');
   for(const axis of ['x','y','w','h'] as const)assert(Math.abs(sample[axis]-samples[0][axis])<=0.5,`Effort ${expected} shifted popup ${axis} in an intermediate frame`);
  }
  const rect=(await visible('ai.model.menu')).rect;
  for(const axis of ['x','y','w','h'] as const)assert(Math.abs(rect[axis]-popupBefore[axis])<=0.5,`Effort ${expected} moved popup ${axis}: ${popupBefore[axis]} -> ${rect[axis]}`);
  report.effortPopupGeometry.push({effort:expected,rect,samples});
  if(expected==='低'||expected==='高')assert((await h.screenshot(join(out,`stable-${expected}.png`))).ok);
 }
 report.checks.push('Repeated low/high/xhigh changes preserve popup position and dimensions');
 await send('model-b','high');
 await select('quiet');await select('model-a');await value('高');
 assert((await h.screenshot(join(out,'02-inherited-high.png'))).ok);
 await send('model-a','high');report.checks.push('Manual high is sent, survives a non-reasoning model, and is sent after switching back');
 await select('model-b');await value('高');
 const end=await visible('ai.effort.slider.track');
 assert((await h.clickAt(end.rect.x+end.rect.w-1,end.rect.y+end.rect.h/2)).ok);
 await value('较高');await select('model-a');await value('档位不支持');
 assert((await h.screenshot(join(out,'03-unsupported-inherited-xhigh.png'))).ok);
 report.checks.push('Manual xhigh is retained on an incompatible model, with the existing unsupported-level message');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await h.screenshot(join(out,'failure.png')).catch(()=>{});throw e;}
finally{
 await writeFile(join(out,'report.json'),JSON.stringify({...report,requests:requests.map(r=>({model:r.model,effort:r.reasoning_effort}))},null,2));
 if(app.exitCode===null)app.kill('SIGTERM');await ended;
 server.closeAllConnections();server.close();await log.close();
}
