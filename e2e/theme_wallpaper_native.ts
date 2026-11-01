/** Actual native black/white image boundaries; only runner-owned files/configuration. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,rm,readFile,writeFile,open,realpath} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {createHash} from 'node:crypto';
import * as h from '../vendor/zenit/e2e/client.ts';
const root=resolve(import.meta.dirname,'..'),binary=resolve(process.argv[2]),out=resolve(process.argv[3]);await mkdir(out,{recursive:true});
const palettes=JSON.parse(await readFile(join(root,'docs/UI_V3/theme-presets.json'),'utf8')).themes;
const themes=process.argv[4]?.split(',')??Object.keys(palettes),levels=process.argv[5]?.split(',')??['0','50','100'],images=process.argv[6]?.split(',')??['black','white'];
const assets=join(out,'assets');await mkdir(assets,{recursive:true});
const solid={checker:'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAa0lEQVR4nO2VwQlAMQhDq5PpZDqam/lv4qFQCvUg35wiBAIPJLCSVDW8iIRn5vBmdpXHVSxsXwAV3C3l+yPC6gJw9+fcNeX7I8LqAiCi59wl5fsjwuoCyMfswU6zB3/4A589OGj24Kj+f/AB9YxesxodZDUAAAAASUVORK5CYII=',black:'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAADElEQVR4nGNgGB4AAADIAAGtQHYiAAAAAElFTkSuQmCC',white:'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFUlEQVR4nGP8//8/AzbAhFV00EoAAFbUAw037MyjAAAAAElFTkSuQmCC'};for(const [name,png]of Object.entries(solid))await writeFile(join(assets,name+'.png'),Buffer.from(png,'base64'));
const report:any={status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),cases:[],limits:['Native screenshots and actual black/white PNGs at 1440x900 pt, Retina 2x.','No model requests, external connection, real user files or physical input.']};
const shown=(n:any)=>n?.rect&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const vis=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{const n=await vis(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok,id);await h.sleep(90)};
async function reveal(id:string){for(let i=0;i<35;i++){const n=await vis(id),v=(await vis('settings.viewport')).rect;if(n.rect.y>=v.y&&n.rect.y+n.rect.h<=v.y+v.h)return;await h.scrollAt(v.x+v.w-5,v.y+v.h/2,0,n.rect.y<v.y?150:-150);await h.sleep(70)}throw Error('Cannot reveal '+id)}
try{for(const theme of themes)for(const image of images){
 const iso=await realpath(await mkdtemp('/private/tmp/zw-wallpaper-')),data=join(iso,'data'),rpc=join(iso,'rpc'),shell=join(iso,'shell');await mkdir(data);await mkdir(rpc);await mkdir(shell);await writeFile(join(shell,'.zshrc'),"PS1='wallpaper%# '\nbindkey -e\n");process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\n[ui.materials]\nblur_px=0\n[ui.materials.background]\nenabled=true\npath=${JSON.stringify(join(assets,image+'.png'))}\ntransparency=0\n`);
 await writeFile(join(data,'hosts.toml'),'[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="agent"\nname="Wallpaper boundary host"\nhost="127.0.0.1"\nport=1\nuser="review"\n');
 const log=await open(join(out,theme+'-'+image+'.log'),'w'),app=spawn(binary,[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));const item:any={theme,image,iso,captures:[]};report.cases.push(item);
 const cap=async(name:string,ids:string[],keepPointer=false,captureTheme=theme)=>{if(!keepPointer)await h.mouseMove(3,3);await h.sleep(250);const stem=captureTheme+'-'+image+'-'+name;assert((await h.screenshot(join(out,stem+'.png'))).ok);await writeFile(join(out,stem+'.json'),JSON.stringify(Object.fromEntries(await Promise.all(ids.map(async id=>[id,await h.query(id)]))),null,2));item.captures.push(stem)};
 try{await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1440,900);await click('workspace.empty.local');await vis('terminal.surface');await h.sleep(500);await click('terminal.surface');await h.type_("printf '\\033[0mDEFAULT_BOUNDARY\\n'; printf ready > '"+join(iso,'ready')+"'");await h.key('return');await h.waitFor(async()=>{try{return await readFile(join(iso,'ready'),'utf8')==='ready'||null}catch{return null}},15000);await h.sleep(200);
 let materials=false;
 for(const t of levels){
  await click('toolbar.settings');await click('settings.nav.appearance');if(!materials){await reveal('settings.materials.header');await click('settings.materials.header');materials=true;}await reveal('settings.field.transparency');await click('settings.field.transparency');await h.key('a',{cmd:true});await h.key('backspace');await h.type_(t);await h.key('return');if((await vis('settings.footer.state')).text!=='已保存'){await click('settings.save');await h.waitFor(async()=>(await vis('settings.footer.state')).text==='已保存'||null)}await reveal('settings.background.preview');await cap('t'+t+'-settings',['settings.panel']);await click('settings.close');await h.sleep(260);
  await cap('t'+t+'-chrome',['workspace.sidebar','tabs.strip','status.bar','terminal.row','terminal.surface']);const host=await vis('sidebar.host');await h.mouseMove(host.rect.x+host.rect.w-5,host.rect.y+5);await cap('t'+t+'-chrome-hover',['workspace.sidebar','tabs.strip','status.bar','terminal.row','terminal.surface'],true);await h.mouseMove(3,3);
  await h.key('k',{cmd:true});await vis('quick.connect');await cap('t'+t+'-quick',['quick.connect']);await h.key('escape');await h.sleep(150);await click('toolbar.ai');await vis('ai.panel');await cap('t'+t+'-ai',['ai.panel']);await click('ai.collapse');await h.sleep(150);
 }
 if(process.env.ZW_WALLPAPER_SWITCH==='1'){
  const scopeIds=['workspace.sidebar','tabs.strip','status.bar','terminal.row','terminal.surface'];
  const save=async()=>{await click('settings.save');await h.waitFor(async()=>(await vis('settings.footer.state')).text==='已保存'||null,15000)};
  for(const enabled of [false,true]){await click('toolbar.settings');await reveal('settings.toggle.enabled');await click('settings.toggle.enabled');await save();const config=await readFile(join(data,'config.toml'),'utf8');assert(config.includes('enabled = '+enabled));await click('settings.close');await h.sleep(350);await cap('switch-image-'+(enabled?'on':'off'),scopeIds);}
  for(const selected of ['light','solarized-dark','dark']){
   await click('toolbar.settings');await click('settings.nav.appearance');await reveal('settings.theme.strip');const strip=await vis('settings.theme.strip');let tile=await vis('settings.theme.'+selected);for(let i=0;i<30&&(tile.rect.x<strip.rect.x||tile.rect.x+tile.rect.w>strip.rect.x+strip.rect.w);i++){await h.scrollAt(strip.rect.x+strip.rect.w/2,strip.rect.y+strip.rect.h/2,tile.rect.x<strip.rect.x?strip.rect.x-tile.rect.x+5:strip.rect.x+strip.rect.w-tile.rect.x-tile.rect.w-5,0);await h.sleep(60);tile=await vis('settings.theme.'+selected)}await click('settings.theme.'+selected);await save();assert((await readFile(join(data,'config.toml'),'utf8')).includes('theme = "'+selected+'"'));await cap('switch-theme-settings',['settings.panel'],false,selected);await click('settings.close');await h.sleep(350);await cap('switch-theme-chrome',scopeIds,false,selected);
  }
 }
 item.status='captured';console.log(theme,image,'captured');await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
 }catch(e){item.status='failed';item.error=String(e);await cap('failure',['workspace.sidebar','settings.panel','quick.connect','ai.panel']).catch(()=>{});throw e}finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;await log.close();await rm(iso,{recursive:true,force:true})}
}report.status='passed'}catch(e){report.status='failed';report.error=String(e);console.error(e);process.exitCode=1}finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2))}
