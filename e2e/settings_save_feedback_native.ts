/** Save feedback regression with isolated data, no credentials or HTTP requests. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]),theme=process.argv[4]??'light';
await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp(join(tmpdir(),'zw-save-feedback-'))),data=join(base,'data'),rpc=join(base,'rpc');
await mkdir(data);await mkdir(rpc);await writeFile(join(data,'hosts.toml'),'');
const config=join(data,'config.toml');
const initial=`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\n[ai]\ndefault_provider="Magpie"\n[[ai.providers]]\nid="Magpie"\nkind="openai_compat"\nendpoint="http://127.0.0.1:3425/v1"\nenabled=true\n[[ai.providers.models]]\nname="existing-model"\ncontext_window=128000\ndefault=true\n[[ai.providers]]\nid="SCNetX"\nkind="openai_compat"\nendpoint="https://example.test/v1"\nenabled=true\n[[ai.providers.models]]\nname="other-model"\ncontext_window=128000\ndefault=true\n`;
await writeFile(config,initial);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>[n,...(n.children??[]).flatMap(flat)],text=(n:any)=>flat(n).map(n=>n.text??'').join(' ');
const node=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null);
async function reveal(id:string){const viewport=id.startsWith('settings.ai.model.')?'settings.ai.model.viewport':'settings.viewport';for(let i=0;i<30;i++){const n=await node(id),v=await node(viewport);if(n.rect.y>=v.rect.y&&n.rect.y+n.rect.h<=v.rect.y+v.rect.h)return n;await h.scrollAt(v.rect.x+v.rect.w-4,v.rect.y+v.rect.h/2,0,n.rect.y<v.rect.y?100:-100);await h.sleep(60);}throw Error('Cannot reveal '+id);}
async function click(id:string){if(id.startsWith('settings.ai.provider.')||['settings.ai.model.context','settings.ai.model.reasoning','settings.ai.model.vision'].includes(id))await reveal(id);await node(id);assert((await h.clickTestId(id)).ok,id);await h.sleep(100);}
async function fill(id:string,value:string){await click(id);await h.key('a',{cmd:true});await h.type_(value);}
async function capture(name:string){await h.mouseMove(20,20);await h.screenshot(join(out,name+'.png'));}
async function feedback(){const n=await node('notifications.toast.0');assert(text(n).includes('SCNetX · API Key'));assert(text(n).includes('请填写 API Key，或停用此服务提供方'));assert(!text(n).includes('InvalidDraft'));assert(!text(n).includes('偏好设置'));assert(!flat(n).filter(n=>n.test_id==='notifications.metadata').some(shown));assert(!(await h.query('settings.save_feedback')).some(shown));return n;}
const report:any={theme,checks:[],status:'running'};
try{
 await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1440,900);await click('toolbar.settings');await click('settings.nav.ai');await click('settings.ai.provider.0.header');await click('settings.ai.provider.0.add_model');
 await click('settings.ai.model.catalog');await fill('settings.ai.model.id','new-model');await click('settings.ai.model.catalog.manual');await fill('settings.ai.model.context','1000000');await click('settings.ai.model.reasoning');await click('settings.ai.model.reasoning.no');await click('settings.ai.model.vision');await click('settings.ai.model.vision.no');await click('settings.ai.model.save');
 await click('settings.save');await feedback();await capture('01-added-model-error');assert.equal(await readFile(config,'utf8'),initial);
 await click('settings.save');await h.waitFor(async()=>{const f=await h.focused();return f.test_id==='settings.ai.provider.1.api_key'?f:null;});
 await feedback();const inline=await node('settings.ai.provider.1.api_key.error');assert(text(inline).includes('请填写 API Key'));const list=await node('settings.ai.provider_list'),viewport=await node('settings.viewport');assert(inline.rect.y+inline.rect.h<=Math.min(list.rect.y+list.rect.h,viewport.rect.y+viewport.rect.h)+.5);await writeFile(join(out,'located-geometry.json'),JSON.stringify({inline,list:list.rect,viewport:viewport.rect},null,2));await capture('02-located-field');
 report.checks.push('Adding a valid model shows the other provider and exact missing field; Save stays clickable and reveals/focuses the collapsed provider without writing invalid data');
 await click('settings.nav.ssh');await feedback();await click('notifications.action');await h.waitFor(async()=>{const f=await h.focused();return f.test_id==='settings.ai.provider.1.api_key'?f:null;});
 report.checks.push('The existing global notification stays visible across categories and locates the field');
 await click('settings.close');const confirmation=await node('settings.confirmation');assert(text(confirmation).includes('SCNetX · API Key'));assert(text(confirmation).includes('返回修正'));await capture('03-close-confirmation');await click('settings.confirmation.save');
 await h.waitFor(async()=>!(await h.query('settings.confirmation')).some(shown)||null);await feedback();assert.equal(await readFile(config,'utf8'),initial);
 report.checks.push('Close confirmation names the issue and returns to correction; no InvalidDraft and no draft loss');
 await h.resizeWindow(860,480);await feedback();const footer=await node('settings.footer'),panel=await node('settings.panel');assert(footer.rect.y+footer.rect.h<=panel.rect.y+panel.rect.h+.5);await capture('04-compact-error');
 await click('notifications.dismiss.0');await click('settings.ai.provider.1.enabled');await h.waitFor(async()=>!(await h.query('notifications.toast.0')).some(shown)||null);await click('settings.save');await h.waitFor(async()=>(await readFile(config,'utf8')).includes('new-model')||null);
 const saved=await readFile(config,'utf8');assert(saved.includes('1000000'));assert(/id\s*=\s*"SCNetX"[\s\S]*?enabled\s*=\s*false/.test(saved));await capture('05-saved');
 report.checks.push('The existing global toast remains visible above the compact settings modal; disabling incomplete non-default provider clears feedback and persists the newly added model');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});throw e;}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));if(app.exitCode===null)app.kill('SIGTERM');await ended;await log.close();}
