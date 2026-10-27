/** Isolated settings -> assistant refresh, local brand marks, and model row layout. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'/tmp/zw-ai-settings-refresh');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-ai-refresh-')),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ai]\ndefault_provider="Magpie"\n[[ai.providers]]\nid="Magpie"\nkind="openai_compat"\nendpoint="http://127.0.0.1:1/v1"\nenabled=false\n[[ai.providers.models]]\nname="grok/grok-4.7"\ncontext_window=256000\nreasoning=true\nvision=true\nefforts=["low","high"]\ndefault=true\n[[ai.providers.models]]\nname="team/claude-sonnet-4-5"\ncontext_window=200000\nreasoning=true\nvision=true\nefforts=["high"]\n[[ai.providers.models]]\nname="团队自建模型"\ncontext_window=32000\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');const app=spawn(resolve('zig-out/bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const shown=n=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=id=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,12000);
const click=async id=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const flat=n=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=n=>flat(n).map(n=>n.text??'').join(' ');
const capture=async name=>{await h.mouseMove(20,300);await h.sleep(120);await h.screenshot(join(out,name+'.png'))};
const report={status:'running',checks:[],data};
try{
 await h.waitForServerReady();await h.resizeWindow(1440,1000);await click('workspace.empty.local');await click('ai.strip');await visible('ai.empty.unconfigured');
 await click('ai.empty.settings');await visible('settings.ai.provider.0.card');
 const logo=await visible('settings.ai.provider.0.logo');assert.equal(text(logo).trim(),'M');
 const row=await visible('settings.ai.provider.0.model.0.card');assert.equal(row.rect.h,60);
 const name=await visible('settings.ai.provider.0.model.0.name.text'),meta=await visible('settings.ai.provider.0.model.0.metadata');assert(meta.rect.y>=name.rect.y+name.rect.h);assert(text(meta).includes('256K 上下文'));assert(text(meta).includes('推理'));assert(text(meta).includes('识图'));
 const brand=await visible('settings.ai.provider.0.model.0.logo');assert(flat(brand).some(n=>n.tag==='image'),JSON.stringify(brand));
 await capture('01-settings');report.checks.push('Custom provider M; bundled Grok logo; model name above readable context/reasoning/vision');
 await click('settings.ai.provider.0.enabled');await click('settings.save');await h.waitFor(async()=>(await readFile(join(data,'config.toml'),'utf8')).includes('enabled = true')||null,20000);await click('settings.close');await visible('ai.empty.configured');assert(!(await h.query('ai.empty.unconfigured')).some(shown));await capture('02-refreshed');report.checks.push('Saving enabled provider refreshes the already-open assistant welcome');
 await click('ai.composer.model');await visible('ai.model.logo');await capture('03-model-menu');report.checks.push('Assistant model chooser displays bundled brand marks');await h.key('Escape');
 await click('toolbar.settings');await click('settings.nav.ai');await h.resizeWindow(860,600);const vp=(await visible('settings.viewport')).rect;await h.scrollAt(vp.x+vp.w-4,vp.y+vp.h/2,0,-290);await h.sleep(200);await capture('04-compact');
 const compactName=await visible('settings.ai.provider.0.model.0.name.text'),compactMeta=await visible('settings.ai.provider.0.model.0.metadata');assert(compactMeta.rect.y>=compactName.rect.y+compactName.rect.h);await click('settings.close');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});process.exitCode=1}finally{app.kill('SIGTERM');await new Promise(r=>app.exitCode!==null||app.signalCode!==null?r():app.once('close',r));await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report))}
