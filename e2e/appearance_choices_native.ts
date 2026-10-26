/** Isolated appearance radio choices: geometry, saved values and restart. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,readFile,writeFile,realpath,open} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const output=resolve(process.argv[2]??'/tmp/zerowork-logo-verification/choices');await mkdir(output,{recursive:true});
const base=await realpath(await mkdtemp(join(tmpdir(),'zerowork-app-icon-'))), data=join(base,'data');await mkdir(data);
const binary=resolve(process.argv[3]??'zig-out/bin/zerowork');
const checks:string[]=[];
async function launch(round:number,run:()=>Promise<void>){
 const rpc=join(base,'rpc-'+round);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(output,'app-'+round+'.log'),'w');
 const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_E2E_BACKGROUND:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
 const ended=new Promise(r=>app.once('close',r));
 try {await h.waitForServerReady();await h.resizeWindow(1000,700);await click('toolbar.settings');await click('settings.nav.appearance');await run();}
 finally{if(app.exitCode===null)app.kill('SIGTERM');await ended;await log.close();}
}
async function node(id:string){return h.waitFor(async()=> (await h.query(id)).find(n=>n.visible!==false&&n.hidden!==true&&n.rect.w>0&&n.rect.h>0&&(n.effective_opacity??1)>0)??null)}
async function click(id:string){await node(id);assert((await h.clickTestId(id)).ok,id);}
async function save(value:string){await click('settings.option.icon_background.'+value);await click('settings.save');await h.waitFor(async()=> /icon_background = "([^"]+)"/.exec(await readFile(join(data,'config.toml'),'utf8'))?.[1]===value?true:null,10000);checks.push('save '+value);}
async function capture(name:string){await h.sleep(300);await h.screenshot(join(output,name+'.png'));}
try{
 await launch(1,async()=>{
  await click('settings.appearance.font.header');
  for(const cursor of ['bar','underline','block']){
   await click('settings.option.cursor_style.'+cursor);
   await click('settings.save');
   await h.waitFor(async()=> (await readFile(join(data,'config.toml'),'utf8')).includes('cursor_style = "'+cursor+'"')?true:null,10000);
   checks.push('cursor save '+cursor);
  }
  await click('settings.option.cursor_style.block');await click('settings.help');await capture('cursor-standard');
  for(const [w,height] of [[1000,700],[860,480]]){
   await h.resizeWindow(w,height);await click('settings.option.cursor_style.block');
   const group=await node('settings.field.cursor_style'),viewport=await node('settings.viewport');
   assert(group.rect.y>=viewport.rect.y-1&&group.rect.y+group.rect.h<=viewport.rect.y+viewport.rect.h+1,'cursor visible in viewport');
   for(const v of ['block','bar','underline']){
    const n=await node('settings.option.cursor_style.'+v);
    assert(n.rect.x>=group.rect.x&&n.rect.x+n.rect.w<=group.rect.x+group.rect.w+1);
   }
   await click('settings.help');await capture('cursor-'+w);checks.push('cursor geometry '+w);
  }
  await save('dark');
 });
 await launch(2,async()=>{
  await click('settings.appearance.font.header');
  const config=await readFile(join(data,'config.toml'),'utf8');
  assert(config.includes('cursor_style = "block"'));assert(config.includes('icon_background = "dark"'));
  await capture('choices-restored');checks.push('cursor and icon restored');
 });
 for(const round of [1,2])assert(!(await readFile(join(output,'app-'+round+'.log'),'utf8')).includes('Dock icon could not be applied'));
 await writeFile(join(output,'report.json'),JSON.stringify({status:'passed',checks,binary,data},null,2));
 console.log(JSON.stringify({status:'passed',checks,output}));
}catch(e){await writeFile(join(output,'report.json'),JSON.stringify({status:'failed',checks,error:String(e)},null,2));throw e;}
