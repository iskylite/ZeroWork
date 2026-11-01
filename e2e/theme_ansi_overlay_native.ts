/** Native overlays over real local PTY truecolor output, without a wallpaper.
 * node e2e/theme_ansi_overlay_native.ts BINARY EVIDENCE_DIR [theme,theme]
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,open,realpath,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import * as h from '../vendor/zenit/e2e/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);await mkdir(out,{recursive:true});
const palettes=JSON.parse(await readFile(new URL('../docs/UI_V3/theme-presets.json',import.meta.url),'utf8')).themes;
const themes=process.argv[4]?.split(',')??Object.keys(palettes);
const report:any={status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),cases:[],limits:['Actual local zsh PTY output; no external host or model request.','1440×900 pt, no background image, transparency 100, blur 0.','Black and white use explicit 24-bit SGR backgrounds, independent of each theme ANSI slots.']};
const shown=(n:any)=>n?.rect&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const vis=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{const n=await vis(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok,id)};
try{for(const theme of themes){
 assert(palettes[theme],theme);
 const iso=await realpath(await mkdtemp('/private/tmp/zw-ansi-overlay-')),data=join(iso,'data'),rpc=join(iso,'rpc'),shell=join(iso,'shell');
 for(const p of [data,rpc,shell])await mkdir(p);
 await writeFile(join(shell,'.zshrc'),"PS1='overlay%# '\nbindkey -e\n");
 await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\n[ui.materials]\nblur_px=0\n[ui.materials.background]\nenabled=false\ntransparency=100\n`);
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,theme+'.log'),'w'),app=spawn(binary,[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]}),ended=new Promise(r=>app.once('close',r));
 try{await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1440,900);await click('workspace.empty.local');await vis('terminal.surface');await h.sleep(700);
  for(const [name,value]of [['black',0],['white',255]]as const){
   const item:any={theme,background:name,transparency:100,captures:[]};report.cases.push(item);
   const capture=async(state:string,ids:string[])=>{if(ids.includes('ai.permission.menu')){const n=await vis('ai.permission.menu');await h.mouseMove(n.rect.x+n.rect.w-4,n.rect.y+4);}else await h.mouseMove(3,3);await h.sleep(300);for(const id of ids)await vis(id);const stem=(state==='terminal'?'proof-':'')+theme+'-'+name+'-'+state;assert((await h.screenshot(join(out,stem+'.png'))).ok);await writeFile(join(out,stem+'.json'),JSON.stringify(Object.fromEntries(await Promise.all(ids.map(async id=>[id,await h.query(id)]))),null,2));item.captures.push(stem)};
   await click('terminal.surface');await h.type_(`printf '\\033[38;2;${255-value};${255-value};${255-value};48;2;${value};${value};${value}m'; repeat 28 { printf '%136s\\n' 'ANSI background'; }; printf '\\033[0m'; printf ready > '${join(iso,name)}'`);await h.key('return');await h.waitFor(async()=>{try{return(await readFile(join(iso,name),'utf8'))==='ready'||null}catch{return null}},15000);await capture('terminal',['terminal.surface']);
   await h.key('k',{cmd:true});await vis('quick.connect');await capture('quick',['quick.connect']);await h.key('escape');await h.sleep(150);
   await click('toolbar.ai');await vis('ai.panel');await capture('ai',['ai.panel']);
   await click('ai.composer.permission');await vis('ai.permission.menu');await capture('permission',['ai.permission.menu']);await h.key('escape');await click('ai.collapse');await h.sleep(180);
   item.status='captured';console.log(theme,name,'captured');await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
  }
 }finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;await log.close();await rm(iso,{recursive:true,force:true})}
}report.status='passed'}catch(e){report.status='failed';report.error=String(e);console.error(e);process.exitCode=1}finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2))}
