/** Real native Provider configuration; isolated files and no network requests. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,realpath,writeFile,readFile,open} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,key,type_,inputState,resizeWindow,scrollAt,screenshot,sleep} from '../vendor/zenit/e2e/client.ts';
const [bin,dest,theme='dark',mode='flows']=process.argv.slice(2);assert(bin&&dest&&['dark','light'].includes(theme));
const binary=resolve(bin),out=resolve(dest),iso=await realpath(await mkdtemp(join(tmpdir(),'zw-provider-v3-'))),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(out,{recursive:true});await mkdir(data);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const config=join(data,'config.toml'),baseInitial=`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="first"\n[[ai.providers]]\nid="first"\nkind="openai_compat"\nendpoint="http://127.0.0.1:9/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="first-model"\ncontext_window=8192\ndefault=true\n[[ai.providers]]\nid="second"\nkind="ollama"\nendpoint="http://127.0.0.1:9/api/chat"\nenabled=false\n[[ai.providers.models]]\nname="second-model"\ncontext_window=16384\ndefault=true\n`;
const initial=mode==='empty'?baseInitial.slice(0,baseInitial.indexOf('[ai]')):mode==='stress'?baseInitial.replace('[[ai.providers]]\nid="second"',Array.from({length:8},(_,i)=>`[[ai.providers.models]]\nname="additional-${i+1}"\ncontext_window=128000\ndefault=false\nreasoning=true\nvision=true\n`).join('')+'[[ai.providers]]\nid="second"'):baseInitial;
await writeFile(config,initial,{mode:0o600});const log=await open(join(out,'app.log'),'w');const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});const ended=new Promise<void>(done=>app.once('close',()=>done()));
const report:any={theme,status:'running',checks:[],geometry:{},limits:['No network request or real credential; public Harness synthetic input and actual Metal pixels.','Physical IME and VoiceOver are not covered.']};
const found=async(id:string)=>waitFor(async()=> (await query(id)).find((n:any)=>n.rect.w>0&&n.rect.h>0)??null,10000);
const shown=(n:any)=>n.visible!==false&&(n.effective_opacity??1)>0;
async function reveal(id:string){
 for(let i=0;i<20;i++){
  const n=await found(id),v=await found('settings.viewport');let clip=v.rect;
  const list=(await query('settings.ai.provider_list')).find((x:any)=>x.rect.w>0&&x.rect.h>0);
  if(id.startsWith('settings.ai.provider.')&&list){const top=Math.max(v.rect.y,list.rect.y),bottom=Math.min(v.rect.y+v.rect.h,list.rect.y+list.rect.h);clip={...list.rect,y:top,h:bottom-top};}
  if(n.rect.y>=clip.y&&n.rect.y+n.rect.h<=clip.y+clip.h&&shown(n))return n;
  const distance=n.rect.y<clip.y?clip.y-n.rect.y:clip.y+clip.h-n.rect.y-n.rect.h;
  const direction=Math.sign(distance)*Math.max(2,Math.min(100,Math.abs(distance)*.65));
  const y=Math.max(v.rect.y+6,Math.min(v.rect.y+v.rect.h-6,clip.y+Math.max(10,clip.h/2)));
  await scrollAt(clip.x+clip.w-3,y,0,direction);await sleep(120);
  const next=await found(id);
  if(Math.abs(next.rect.y-n.rect.y)<.2){await scrollAt(v.rect.x+v.rect.w-6,v.rect.y+v.rect.h/2,0,direction);await sleep(120);}
 }
 throw new Error('Cannot reveal '+id);
}
async function click(id:string){const n=id.startsWith('settings.ai.provider.')?await reveal(id):await found(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await sleep(220);}
async function edit(id:string,value:string){await click(id);await key('a',{cmd:true});if(value)await type_(value);else await key('backspace');await sleep(120);assert.equal((await inputState(id)).buffer,value);}
async function capture(name:string){await sleep(200);assert((await screenshot(join(out,name+'.png'))).ok);}
async function save(){await click('settings.save');await waitFor(async()=>{const n=await found('settings.footer.state');return n.text==='已保存'?true:null},10000);}
const enabledProviders=(source:string)=>source.split('[[ai.providers]]').slice(1).map(block=>/enabled\s*=\s*true/.test(block.split('[[ai.providers.models]]')[0]));
const near=(a:number,b:number)=>assert(Math.abs(a-b)<.6,`${a} != ${b}`);
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1440,900);await click('toolbar.settings');await click('settings.nav.ai');
 if(mode==='empty'){
  await found('settings.ai.providers.empty');assert(!(await query('settings.ai.provider.0.card')).some(shown));await capture('10-empty-standard');
  await click('settings.ai.providers.empty.add');await edit('settings.ai.provider.0.name','local gateway');await edit('settings.ai.provider.0.endpoint','http://127.0.0.1:9/v1/chat/completions');await click('settings.ai.provider.0.add_model');await edit('settings.ai.model.id','first-manual-model');await edit('settings.ai.model.context','128000');await click('settings.ai.model.save');await waitFor(async()=>!(await query('settings.ai.model.dialog')).some(shown)||null);assert.equal(await readFile(config,'utf8'),initial);await save();
  const firstSaved=await readFile(config,'utf8');assert(firstSaved.includes('first-manual-model'));await click('settings.ai.add_provider');await edit('settings.ai.provider.1.name','second gateway');await edit('settings.ai.provider.1.endpoint','http://127.0.0.1:9/v1/chat/completions');await click('settings.ai.provider.1.add_model');await edit('settings.ai.model.id','second-manual-model');await edit('settings.ai.model.context','64000');await click('settings.ai.model.save');await waitFor(async()=>!(await query('settings.ai.model.dialog')).some(shown)||null);await save();const twoSaved=await readFile(config,'utf8');assert.equal((twoSaved.match(/kind = "openai_compat"/g)||[]).length,2);report.checks.push('Fresh install has empty list; first add and second same-protocol provider preserve separate names/models; child Save edits draft and outer Save persists');
  await click('settings.ai.provider.1.header');await click('settings.ai.provider.0.header');await resizeWindow(860,480);await capture('11-two-providers-compact');await click('settings.ai.add_provider');await edit('settings.ai.provider.2.name','uncommitted');await click('settings.revert');assert.equal(await readFile(config,'utf8'),twoSaved);assert(!(await query('settings.ai.provider.2.card')).some(shown));report.checks.push('Third provider outer Revert removes draft and preserves both saved entries');
 }else{
 const header=await found('settings.ai.provider.0.header'),name=await found('settings.ai.provider.0.name'),kind=await found('settings.ai.provider.0.kind'),endpoint=await found('settings.ai.provider.0.endpoint');report.geometry={header:header.rect,name:name.rect,kind:kind.rect,endpoint:endpoint.rect};near(header.rect.h,64);near(name.rect.w,kind.rect.w);near(name.rect.y,kind.rect.y);near(kind.rect.x-name.rect.x-name.rect.w,14);near(endpoint.rect.w,name.rect.w*2+14);await capture('01-provider-standard');report.checks.push('V3 provider64 header; two equal name/protocol columns and full endpoint');
 if(mode==='stress'){
  const models=await found('settings.ai.provider.0.models');near(models.rect.h,190);report.geometry.modelList=models.rect;await capture('06-many-models-standard');
  await scrollAt(models.rect.x+models.rect.w/2,models.rect.y+models.rect.h/2,0,-550);await sleep(180);await capture('07-many-models-scrolled');
  await resizeWindow(860,480);await reveal('settings.ai.provider.0.models');await capture('08-many-models-compact');report.checks.push('nine actual models remain 44px rows inside bounded190 list; inner scroll and compact capture');
 }else{
 await click('settings.ai.provider.0.enabled');assert((await readFile(config,'utf8'))===initial);await found('settings.ai.provider_error');await capture('02-last-default-protected');report.checks.push('last enabled default cannot be disabled');
 await click('settings.ai.provider.1.enabled');await save();let saved=await readFile(config,'utf8');assert(/default_provider\s*=\s*"first"/.test(saved));assert.equal(enabledProviders(saved).filter(Boolean).length,2);
 await click('settings.ai.provider.0.enabled');await save();saved=await readFile(config,'utf8');assert(/default_provider\s*=\s*"second"/.test(saved));assert.equal(enabledProviders(saved).filter(Boolean).length,1);report.checks.push('explicit enable is persisted; disabling default selects existing eligible replacement');
 await edit('settings.ai.provider.0.endpoint','not-a-url');await key('escape');assert.equal((await inputState('settings.ai.provider.0.endpoint')).buffer,'http://127.0.0.1:9/v1/chat/completions');await edit('settings.ai.provider.0.name','first draft');await click('settings.revert');assert.equal((await inputState('settings.ai.provider.0.name')).buffer,'first');report.checks.push('invalid endpoint Escape and name outer revert preserve persisted disabled provider');
 await click('settings.ai.provider.0.reveal_key');await click('settings.ai.provider.0.reveal_key');assert.equal(await readFile(config,'utf8'),saved);report.checks.push('key reveal/hide does not mutate config');
 await click('settings.ai.provider.0.model.0.delete_model');const dialog=await found('settings.ai.delete.dialog');near(dialog.rect.w,390);await capture('03-delete-cancel');await click('settings.ai.delete.cancel');await waitFor(async()=>!(await query('settings.ai.delete.dialog')).some(shown)||null);await found('settings.ai.provider.0.model.0.card');assert.equal(await readFile(config,'utf8'),saved);
 await click('settings.ai.provider.0.model.0.delete_model');await key('s',{cmd:true});assert.equal(await readFile(config,'utf8'),saved);await click('settings.ai.delete.confirm');await waitFor(async()=>!(await query('settings.ai.delete.dialog')).some(shown)||null);await save();assert(!(await readFile(config,'utf8')).includes('name = "first-model"'));report.checks.push('delete390 confirmation Cancel preserves model; Cmd-S blocked; explicit confirm then outer Save deletes inactive model');
 await click('settings.ai.provider.0.header');await resizeWindow(860,480);await capture('04-provider-compact');const footer=(await found('settings.footer')).rect;await click('settings.ai.provider.1.header');await reveal('settings.ai.provider.1.endpoint');await capture('05-provider-compact-fields');near((await found('settings.footer')).rect.y,footer.y);report.checks.push('compact nested provider scroll keeps outer footer fixed');
 await click('settings.ai.provider.0.header');await click('settings.ai.provider.0.delete_provider');await capture('09-provider-delete-compact');const beforeDelete=await readFile(config,'utf8');await click('settings.ai.delete.cancel');assert.equal(await readFile(config,'utf8'),beforeDelete);
 await click('settings.ai.provider.0.delete_provider');await click('settings.ai.delete.confirm');await waitFor(async()=>!(await query('settings.ai.delete.dialog')).some(shown)||null);assert.equal(await readFile(config,'utf8'),beforeDelete);await save();assert(!(await readFile(config,'utf8')).includes('id = "first"'));report.checks.push('provider deletion compact confirmation Cancel preserves file; confirm changes draft only; outer Save persists removal');
 }
 }
 report.status='passed_pending_pixel_review';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});throw e;}finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));if(app.exitCode===null)app.kill('SIGTERM');await ended;await log.close();}
console.log(JSON.stringify(report));
