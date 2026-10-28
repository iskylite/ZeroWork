/** Theme paint coverage using the production file View with bounded UI fixture data. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,writeFile,readFile,open,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);await mkdir(out,{recursive:true});
const themes=(process.argv[4]??'dark,light,sauber,midnight,forest,ocean,plum,ember,graphite,paper,sand,ice,catppuccin-mocha,dracula,dark-pro,solarized-dark,nord').split(',');
const shown=(n:any)=>n?.rect&&n.visible!==false&&n.hidden!==true&&n.rect.w>0&&n.rect.h>0;
const flat=(n:any):any[]=>[n,...(n.children??[]).flatMap(flat)];
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');
const report:any={status:'running',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),cases:[],limits:['Production View in a native component fixture; explicit local and remote UI data, no filesystem or SFTP service.','Public synthetic Harness input; physical input, IME and VoiceOver are outside this check.']};
try{for(const theme of themes){for(const state of ['normal',...(['dark','paper','solarized-dark'].includes(theme)?['empty','failed']:[])]){
 const iso=await mkdtemp('/private/tmp/zw-theme-files-'),rpc=join(iso,'rpc');await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,theme+'-'+state+'.log'),'w');const app=spawn(binary,['--theme='+theme,'--state='+state],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));const item:any={theme,state};report.cases.push(item);
 try{
  await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1194,794);
  const root=await h.waitFor(async()=>{const a=await h.query('files.workspace');return Array.isArray(a)?a.find(shown)??null:null},15000);
  if(state==='normal'){
   const local=(await h.query('files.local')).find(shown);assert(local);const row=flat(local).find(n=>n.test_id==='files.row'&&text(n).includes('native-fixture-003.txt'));assert(row);
   assert((await h.clickAt(row.rect.x+100,row.rect.y+row.rect.h/2)).ok);
   await h.waitFor(async()=>{const a=await h.query('files.local');return Array.isArray(a)&&a.some(n=>text(n).includes('已选 1'))||null},10000);
  }else{
   const remote=(await h.query('files.remote')).find(shown);assert(text(remote).includes(state==='empty'?'目录为空':'Connection lost'));
  }
  await h.sleep(300);assert((await h.screenshot(join(out,theme+'-'+state+'.png'))).ok);await writeFile(join(out,theme+'-'+state+'.json'),JSON.stringify(await h.query('files.workspace'),null,2));item.rect=root.rect;item.status='passed';console.log(theme+' '+state+' passed');
 }catch(e){item.status='failed';item.error=String(e);await h.screenshot(join(out,theme+'-'+state+'-failure.png')).catch(()=>{});throw e;}
 finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;await log.close();await rm(iso,{recursive:true,force:true});}
}}report.status='passed';}catch(e){report.status='failed';report.error=String(e);console.error(e);process.exitCode=1;}finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2))}
