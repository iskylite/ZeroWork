/** Shared clipboard acknowledgements outside AI, against production native views. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_COPY_TEST_PREFIX??'zig-out');
const out=resolve(process.argv[2]??'/tmp/zw-copy-all-evidence');await mkdir(out,{recursive:true});
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const shown=(n:any)=>n?.rect?.w>0&&n.rect.h>0&&!n.hidden&&n.visible!==false;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const click=async(id:string)=>{const n=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);};
const text=(n:any):string=>[n.text??'',...(n.children??[]).map(text)].join('');
const report:any={status:'running',checks:[]};
for(const scene of ['transfer','progress']){
 const iso=await mkdtemp('/private/tmp/zw-copy-feedback-');const rpc=join(iso,'rpc');await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,scene+'.log'),'w');
 const app=spawn(join(prefix,'bin',scene==='transfer'?'transfer-controls-preview':'connection-progress-preview'),scene==='progress'?['direct']:[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 const ended=new Promise<void>(done=>app.once('close',()=>done()));
 const cap=async(name:string)=>{assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.tree(),null,2));};
 try{
  await h.waitForServerReady();await h.resizeWindow(1440,900);
  if(scene==='transfer'){
   const row=await visible('transfer.task');await h.mouseMove(row.rect.x+100,row.rect.y+12);await visible('transfer.task.hover_detail');
   const local=await visible('transfer.detail.local');
   const park=async()=>h.mouseMove(local.rect.x+20,local.rect.y+local.rect.h/2);
   await park();await cap('00-transfer-idle');
   await click('transfer.detail.copy_remote');assert.equal(execFileSync('pbpaste',{encoding:'utf8'}),'/srv/releases/release.tar.gz');await park();await cap('01-transfer-copied');
   await h.sleep(1100);await click('transfer.detail.copy_remote');await park();await h.sleep(1100);await cap('02-transfer-renewed');
   await h.sleep(1200);await cap('03-transfer-reset');
   await click('transfer.detail.local');assert.equal(execFileSync('pbpaste',{encoding:'utf8'}),'/private/var/folders/hb/12753xs57vs9vv2xpy73kcn80000gn/T/zerowork-native-transfer-fixture-long-directory/local/release.tar.gz');await park();await cap('04-transfer-path-click');
   report.checks.push('Transfer copy buttons write exact remote/local paths; clicking a path acknowledges on its adjacent button; repeated clicks renew the two-second feedback');
  }else{
   await click('connection.progress.logs.toggle');
   await cap('05-logs-idle');await click('connection.progress.logs.copy');
   await h.waitFor(async()=>text(await visible('connection.progress.logs.copy')).includes('已复制')||null,3000);await cap('06-logs-copied');
   await h.sleep(1100);await click('connection.progress.logs.copy');await h.sleep(1100);
   assert(text(await visible('connection.progress.logs.copy')).includes('已复制'));await cap('07-logs-renewed');
   await h.waitFor(async()=>text(await visible('connection.progress.logs.copy')).includes('复制日志')||null,4000);await cap('08-logs-reset');
   report.checks.push('Connection log custom icon/text button acknowledges its callback, renews feedback on repeated clicks, and restores its original label after two seconds');
  }
 }catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await cap(scene+'-failure').catch(()=>{});break;}
 finally{app.kill('SIGTERM');await Promise.race([ended,h.sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}await log.close();await rm(iso,{recursive:true,force:true});}
}
if(report.status!=='failed'){
 try{
  // Harness trees omit icon assets; inspect the exact button pixels for the idle-window regression.
  execFileSync('python3',['-c',String.raw`
from PIL import Image
from pathlib import Path
import json,sys
out=Path(sys.argv[1])
def find(node,identifier):
 if isinstance(node,list):
  for child in node:
   found=find(child,identifier)
   if found:return found
 elif isinstance(node,dict):
  if node.get('test_id')==identifier:return node
  for child in node.values():
   if isinstance(child,(list,dict)):
    found=find(child,identifier)
    if found:return found
def green(shot,identifier):
 node=find(json.loads((out/(shot+'.json')).read_text()),identifier)
 image=Image.open(out/(shot+'.png')).convert('RGB');scale=image.width/1440
 x,y,w,h=(round(node['rect'][key]*scale) for key in ['x','y','w','h'])
 return sum(g-r>40 and g-b>30 for r,g,b in image.crop((x,y,x+w,y+h)).get_flattened_data())
remote='transfer.detail.copy_remote';local='transfer.detail.copy_local'
assert green('00-transfer-idle',remote)==0
assert green('01-transfer-copied',remote)>15
assert green('01-transfer-copied',local)==0
assert green('02-transfer-renewed',remote)>15
assert green('03-transfer-reset',remote)==0
assert green('04-transfer-path-click',local)>15
`,out]);
  report.checks.push('Button pixels confirm independent success marks, renewed timeout and automatic reset in a static tooltip');
  report.status='passed';
 }catch(error){report.status='failed';report.error=String(error);process.exitCode=1;}
}
await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(report.status+': '+join(out,'report.json'));
