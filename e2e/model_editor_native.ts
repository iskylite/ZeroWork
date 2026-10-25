/** Real V3 model dialog: independent draft, validation, persistence and compact layout. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,realpath,open,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep,scrollAt,mouseMove} from '../vendor/zenit/e2e/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]),theme=process.argv[4]??'dark';
assert(['dark','light'].includes(theme));await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp(join(tmpdir(),'zw-model-editor-'))),data=join(base,'data'),rpc=join(base,'rpc');await mkdir(data);await mkdir(rpc);
const config=join(data,'config.toml');
await writeFile(join(data,'hosts.toml'),'');
const initial=`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="local-fixture"\n[[ai.providers]]\nid="local-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:9/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="fixture-model"\ncontext_window=1000000\ndefault=true\nreasoning=true\nvision=true\nefforts=["low","high","max"]\n`;
await writeFile(config,initial);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w'),app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_E2E_BACKGROUND:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise<void>(r=>app.once('close',()=>r()));
const shown=(n:any)=>n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const flat=(n:any):any[]=>[n,...(n.children??[]).flatMap(flat)],text=(n:any)=>flat(n).map(x=>x.text??'').join(' ');
const current=async(id:string)=>(await query(id)).find(shown)??null;
const visible=async(id:string)=>waitFor(()=>current(id));
async function click(id:string){
 const viewport=id.startsWith('settings.ai.provider.')?'settings.viewport':(['settings.ai.model.id','settings.ai.model.context','settings.ai.model.reasoning','settings.ai.model.vision','settings.ai.model.default'].includes(id)||id.startsWith('settings.ai.model.effort.'))?'settings.ai.model.viewport':null;
 if(viewport)for(let i=0;i<15;i++){
  const n=await visible(id),v=await visible(viewport);
  if(n.rect.y>=v.rect.y&&n.rect.y+n.rect.h<=v.rect.y+v.rect.h)break;
  await scrollAt(v.rect.x+v.rect.w/2,v.rect.y+v.rect.h/2,0,n.rect.y<v.rect.y?180:-180);await sleep(120);
 }
 let last='';await waitFor(async()=>{const n=await current(id);if(!n)return null;const at=JSON.stringify(n.rect),stable=last===at;last=at;await sleep(60);return stable?n:null;});const n=await visible(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);}
async function fill(id:string,value:string){await click(id);await key('a',{cmd:true});await type_(value);await waitFor(async()=>text(await visible(id)).includes(value)||null);}
async function hidden(id:string){await waitFor(async()=>!(await query(id)).some(shown)||null);}
const report:any={theme,status:'running',checks:[],limits:['Harness input and live Metal pixels; no physical IME or VoiceOver claim.','Synthetic provider configuration; no network request or real credentials.']};
async function capture(name:string){await sleep(250);assert((await screenshot(join(out,name+'.png'))).ok);}
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await resizeWindow(1440,900);await click('toolbar.settings');await click('settings.nav.ai');
 const row=await visible('settings.ai.provider.0.model.0.card');assert.equal(row.rect.h,44);await capture('01-single-row');
 await fill('settings.ai.provider.0.name','Outer draft');await click('settings.ai.provider.0.model.0.edit_model');
 await fill('settings.ai.model.id','cancelled-model');await key('s',{cmd:true});await sleep(200);assert.equal(await readFile(config,'utf8'),initial);
 await click('settings.ai.model.cancel');await hidden('settings.ai.model.dialog');assert(text(await visible('settings.ai.provider.0.name')).includes('Outer draft'));assert(text(await visible('settings.ai.provider.0.model.0.header')).includes('fixture-model'));
 await click('settings.revert');await click('settings.ai.provider.0.model.0.edit_model');await clickAt(100,450);await hidden('settings.ai.model.dialog');await visible('settings.panel');await click('settings.ai.provider.0.model.0.edit_model');await key('comma',{cmd:true});await visible('settings.ai.model.dialog');await visible('settings.panel');await click('settings.ai.model.cancel');await click('settings.ai.provider.0.model.0.edit_model');await fill('settings.ai.model.context','0');await click('settings.ai.model.save');assert(text(await visible('settings.ai.model.error')).includes('1–4294967295'));assert.equal(await readFile(config,'utf8'),initial);await capture('02-validation');
 await fill('settings.ai.model.context','1048576');await click('settings.ai.model.vision');await click('settings.ai.model.vision.no');await click('settings.ai.model.effort.low');await click('settings.ai.model.save');await hidden('settings.ai.model.dialog');assert.equal(await readFile(config,'utf8'),initial);
 await click('settings.save');await waitFor(async()=>/context_window\s*=\s*1048576/.test(await readFile(config,'utf8'))||null,15000);const saved=await readFile(config,'utf8');assert(/vision\s*=\s*false/.test(saved));const efforts=/efforts\s*=\s*\[([^\]]*)\]/.exec(saved);assert(efforts&&!efforts[1].includes('low')&&efforts[1].includes('high')&&efforts[1].includes('max'));await capture('03-parent-saved');
 await click('settings.ai.provider.0.model.0.edit_model');assert(text(await visible('settings.ai.model.context')).includes('1048576'));assert(text(await visible('settings.ai.model.vision')).includes('不支持'));
 await resizeWindow(860,480);const dialog=await visible('settings.ai.model.dialog'),footer=await visible('settings.ai.model.footer');assert.equal(dialog.rect.w,480);assert.equal(dialog.rect.h,416);assert(Math.abs(dialog.rect.x+240-430)<1);assert(Math.abs(dialog.rect.y+208-240)<1);const panel=await visible('settings.panel');assert(dialog.rect.y>=panel.rect.y+8);assert(dialog.rect.y+dialog.rect.h<=panel.rect.y+panel.rect.h-8+.5);assert(footer.rect.y+footer.rect.h<=dialog.rect.y+dialog.rect.h+0.5);await capture('04-minimum-editor');
 await click('settings.ai.model.reasoning');await capture('05-capability-menu');await key('escape');await visible('settings.ai.model.dialog');await key('escape');await hidden('settings.ai.model.dialog');
 await click('settings.ai.provider.0.model.0.edit_model');const long='organization/very-long-custom-model-name-for-truncation-2026-10-25';await fill('settings.ai.model.id',long);await click('settings.ai.model.save');await hidden('settings.ai.model.dialog');const compact=await visible('settings.ai.provider.0.model.0.card');for(const suffix of ['default_model','edit_model','delete_model']){const n=await visible('settings.ai.provider.0.model.0.'+suffix);assert(n.rect.x>=compact.rect.x&&n.rect.x+n.rect.w<=compact.rect.x+compact.rect.w+0.5)}await capture('06-long-name-row');const name=await visible('settings.ai.provider.0.model.0.header');await mouseMove(name.rect.x+name.rect.w/2,name.rect.y+name.rect.h/2);await sleep(650);const tip=await visible('settings.ai.provider.0.model.0.name.tooltip');assert(text(tip).includes(long));assert(tip.rect.x>=0&&tip.rect.y>=0&&tip.rect.x+tip.rect.w<=860&&tip.rect.y+tip.rect.h<=480);await capture('06b-full-name-hover');await mouseMove(20,20);await click('settings.revert');
 await click('settings.ai.provider.0.model.0.edit_model');const v=await visible('settings.ai.model.viewport');await scrollAt(v.rect.x+v.rect.w/2,v.rect.y+v.rect.h/2,0,-500);await capture('07-minimum-scrolled');await click('settings.ai.model.cancel');await hidden('settings.ai.model.dialog');
 report.status='passed';report.checks=['44px single model row','Local edit and Cancel preserve both model and unrelated outer draft','Parent Cmd-S cannot persist while model dialog is open; Cmd-comma does not close or hide the parent while the child is active','Invalid capacity stays in dialog without changing config','Model Save only changes outer draft; outer Save writes actual file','Reopen reads committed capacity and vision selection; reasoning effort checkbox is saved','480x416 dialog stays within compact settings panel with 8px clearance; fixed footer','Outside click cancels only the model dialog; Escape closes capability menu before model dialog','Long model ID does not displace action buttons and has a full-name hover tooltip','Body scroll exposes lower capabilities in minimum window'];
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});throw e;}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));app.kill('SIGTERM');await ended;await log.close();}
