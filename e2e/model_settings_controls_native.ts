/** Isolated model settings regression: default state, provenance and compact layout. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,realpath,open,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';

const binary=resolve(process.argv[2]),out=resolve(process.argv[3]),theme=process.argv[4]??'dark';
assert(['dark','light'].includes(theme));await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp(join(tmpdir(),'zw-model-controls-'))),data=join(base,'data'),rpc=join(base,'rpc');
await mkdir(data);await mkdir(rpc);await writeFile(join(data,'hosts.toml'),'');
const server=createServer((req,res)=>{assert.equal(req.url,'/v1/models');res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'api-model',context_window:128000,reasoning:true,vision:true,thinking:{values:['low','medium','high','xhigh','max','none','ultra']}}]}));});
await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
const port=(server.address() as any).port,config=join(data,'config.toml');
const initial=`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\n[ai]\ndefault_provider="Fixture"\n[[ai.providers]]\nid="Fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n`+[true,false].map((v,i)=>`[[ai.providers.models]]\nname="model-${i}"\ncontext_window=128000\ndefault=${v}\nreasoning=true\nvision=true\nefforts=["low","high","max"]\n`).join('');
await writeFile(config,initial);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_E2E_BACKGROUND:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n.visible!==false&&!n.hidden&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const flat=(n:any):any[]=>[n,...(n.children??[]).flatMap(flat)],text=(n:any)=>flat(n).map(n=>n.text??'').join(' ');
const current=async(id:string)=>(await h.query(id)).find(shown)??null;
const node=(id:string)=>h.waitFor(()=>current(id));
async function reveal(id:string){
 const viewport=id.startsWith('settings.ai.provider.')?'settings.viewport':'settings.ai.model.viewport';
 for(let i=0;i<15;i++){const n=await node(id),v=await node(viewport);if(n.rect.y>=v.rect.y&&n.rect.y+n.rect.h<=v.rect.y+v.rect.h)return n;await h.scrollAt(v.rect.x+v.rect.w/2,v.rect.y+v.rect.h/2,0,n.rect.y<v.rect.y?160:-160);await h.sleep(80);}
 throw Error('Cannot reveal '+id);
}
async function click(id:string){if(id.startsWith('settings.ai.provider.')||id==='settings.ai.model.default'||id.startsWith('settings.ai.model.effort.'))await reveal(id);await node(id);assert((await h.clickTestId(id)).ok,id);await h.sleep(80);}
async function capture(name:string){assert((await h.screenshot(join(out,name+'.png'))).ok);}
async function checked(id:string){const n=await node(id);return (n.children?.[0]?.children?.[0]?.opacity??1)>.5;}
async function source(kind:string,index:number,label:string){
 const id='settings.ai.model.'+kind+'.source',n=await reveal(id);assert.equal(n.rect.h,18);assert.equal(n.children.filter(shown).length,1);assert(shown(n.children[index]));
 await h.mouseMove(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);assert(text(await node(id+'.tooltip')).includes(label));await h.mouseMove(20,20);
}
const report:any={theme,status:'running',checks:[],limits:['Isolated temporary configuration and local HTTP fixture.','Harness keyboard input and Metal screenshots; no physical IME or VoiceOver verification.']};
try{
 await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await h.resizeWindow(1440,900);await click('toolbar.settings');await click('settings.nav.ai');await click('settings.ai.provider.0.model.1.edit_model');
 const ranks=await Promise.all(['none','low','medium','high','xhigh','max','ultra'].map(e=>node('settings.ai.model.effort.'+e)));
 for(const n of ranks){assert.equal(n.rect.h,30);assert(Math.abs(n.rect.w-ranks[0].rect.w)<1);}
 assert.equal(ranks[0].rect.y,ranks[3].rect.y);assert.equal(ranks[4].rect.y-ranks[0].rect.y,36);
 await writeFile(join(out,'geometry.json'),JSON.stringify(ranks.map(n=>({id:n.test_id,rect:n.rect})),null,2));await capture('01-capabilities');
 await source('reasoning',1,'手动设置');await source('vision',1,'手动设置');report.checks.push('Seven equal 30px effort targets in strength order, 4 + 3 grid; one-line provenance with manual tooltip');
 assert.equal(await checked('settings.ai.model.default'),false);await click('settings.ai.model.default');assert(await checked('settings.ai.model.default'));await h.key('space');assert.equal(await checked('settings.ai.model.default'),false);await h.key('space');assert(await checked('settings.ai.model.default'));
 await click('settings.ai.model.effort.low');await click('settings.ai.model.effort.none');await reveal('settings.ai.model.default');await capture('02-default-selected');
 await click('settings.ai.model.save');assert.equal(await readFile(config,'utf8'),initial);await click('settings.save');
 await h.waitFor(async()=>{const s=await readFile(config,'utf8');return /name\s*=\s*"model-1"[\s\S]*?default\s*=\s*true/.test(s)||null});
 const blocks=(await readFile(config,'utf8')).split('[[ai.providers.models]]').slice(1);assert(/default\s*=\s*false/.test(blocks[0]));assert(/default\s*=\s*true/.test(blocks[1]));assert(/"none"/.test(blocks[1]));assert(!/"low"/.test(blocks[1]));
 await click('settings.ai.provider.0.model.1.edit_model');assert(await checked('settings.ai.model.default'));assert(await checked('settings.ai.model.effort.none'));assert.equal(await checked('settings.ai.model.effort.low'),false);
 report.checks.push('Default checkbox updates on click and Space, stays local until outer Save, persists exclusively and reopens selected; reordered effort indices persist correctly');
 await h.resizeWindow(860,480);await reveal('settings.ai.model.default');const dialog=await node('settings.ai.model.dialog'),footer=await node('settings.ai.model.footer');assert.equal(dialog.rect.w,480);assert.equal(dialog.rect.h,416);assert(footer.rect.y+footer.rect.h<=dialog.rect.y+dialog.rect.h+.5);await capture('03-compact');await click('settings.ai.model.cancel');
 report.checks.push('Compact 860 × 480 window retains scrollable content and fixed dialog footer');
 await h.resizeWindow(1440,900);await click('settings.ai.provider.0.add_model');await source('reasoning',2,'接口未返回');await capture('04-missing');await click('settings.ai.model.fetch_models');
 await h.waitFor(async()=>text(await node('settings.ai.model.catalog_status')).includes('已获取')||null,15000);await click('settings.ai.model.catalog');await click('settings.ai.model.catalog.option.0');
 await source('context',0,'接口已返回');await source('reasoning',0,'接口已返回');await source('vision',0,'接口已返回');await capture('05-api-metadata');
 await click('settings.ai.model.vision');await click('settings.ai.model.vision.no');await source('vision',1,'手动设置');assert(text(await node('settings.ai.model.vision')).includes('不支持'));await capture('06-manual-override');await click('settings.ai.model.cancel');
 report.checks.push('Missing/API/manual metadata each show one distinct icon with working tooltip; manual override replaces API provenance');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});throw e;}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));if(app.exitCode===null)app.kill('SIGTERM');await ended;server.closeAllConnections();server.close();await log.close();}
