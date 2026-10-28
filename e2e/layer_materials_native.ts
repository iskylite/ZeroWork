/** Actual model-menu hover at three material levels; isolated data and synthetic wallpaper. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,writeFile,open,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
const prefix=process.env.ZW_LAYER_TEST_PREFIX??'/tmp/zw-layer-materials-build',out=process.argv[2]??'/tmp/zw-layer-materials-evidence';
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
await mkdir(out,{recursive:true});
const shown=(n:any)=>n?.rect?.w>0&&n?.rect?.h>0&&n.visible!==false&&(n.opacity??1)>.99;
const visible=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const report:any={cases:[],limits:['Isolated native windows; synthetic input; no external requests or user configuration.']};
for(const [theme,t] of [['midnight',0],['light',75],['sauber',100]]){
 const dir=await mkdtemp('/private/tmp/zw-layer-check-'),data=join(dir,'data'),rpc=join(dir,'rpc');await mkdir(data);await mkdir(rpc);
 await writeFile(join(data,'config.toml'),`[ui]\ntheme="${theme}"\n[ui.materials]\nblur_px=0\n[ui.materials.background]\ntransparency=${t}\n[ai]\ndefault_provider="fixture"\n[[ai.providers]]\nid="fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:9/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="layer-model"\ncontext_window=128000\ndefault=true\nefforts=["low","high"]\nvision=true\n`);
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const wallpaper=join(data,'background.png');await writeFile(wallpaper,Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAJ0lEQVR4nGPQcksBoiq3aUCEzGbAKVFVkQJEWhXTgAiZjVuCDnYAAMasS4GfPJd/AAAAAElFTkSuQmCC','base64'));
 let config=await readFile(join(data,'config.toml'),'utf8');config=config.replace('[ui.materials.background]\n','[ui.materials.background]\nenabled=true\npath="'+wallpaper+'"\n');await writeFile(join(data,'config.toml'),config);
 const environment={...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''};
 for(const name of ['ZEROWORK_AI_MOCK','ZEROWORK_AI_ENDPOINT','ZEROWORK_AI_MODEL','ZEROWORK_AI_PROVIDER'])delete environment[name];
 const log=await open(join(out,`${theme}.log`),'w'),app=spawn(join(prefix,'bin/zerowork'),[],{env:environment,stdio:['ignore',log.fd,log.fd]});
 const ended=new Promise<void>(r=>app.once('close',()=>r()));
 const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
 try{
  await h.waitForServerReady(60000);await h.resizeWindow(1440,900);await click('workspace.empty.local');await click('ai.strip');await visible('ai.panel');await click('ai.composer.model');
  await visible('ai.model.menu');const row=await visible('ai.model.option');await h.mouseMove(row.rect.x+70,row.rect.y+row.rect.h/2);await visible('ai.model.details');await h.sleep(400);
  const nodes={panel:await visible('ai.panel'),menu:await visible('ai.model.menu'),hint:await visible('ai.model.details')};
  assert.equal(nodes.hint.rect.w,284);assert(nodes.hint.rect.x+nodes.hint.rect.w<=1440);assert(nodes.hint.rect.y+nodes.hint.rect.h<=900);
  assert((await h.screenshot(join(out,`${theme}-model-layers.png`))).ok);
  await writeFile(join(out,`${theme}-nodes.json`),JSON.stringify(nodes,null,2));
  await h.mouseMove(10,10);await h.key('escape');await click('ai.composer.model');const next=await visible('ai.model.option');await h.mouseMove(next.rect.x+70,next.rect.y+15);await visible('ai.model.details');
  await h.mouseMove(10,10);await h.key('escape');await h.resizeWindow(860,480);await click('ai.composer.model');const small=await visible('ai.model.option');await h.mouseMove(small.rect.x+70,small.rect.y+15);const compactHint=await visible('ai.model.details');assert(compactHint.rect.x>=0&&compactHint.rect.y>=0&&compactHint.rect.x+compactHint.rect.w<=860&&compactHint.rect.y+compactHint.rect.h<=480);await h.sleep(400);await h.screenshot(join(out,`${theme}-compact.png`));
  report.cases.push({theme,t,status:'passed',nodes});
 }catch(e){report.cases.push({theme,t,status:'failed',error:String(e)});await h.screenshot(join(out,`${theme}-failure.png`)).catch(()=>{});process.exitCode=1;break;}
 finally{app.kill('SIGTERM');await ended;await log.close();await rm(dir,{recursive:true,force:true});}
}
await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report.cases.map(({theme,t,status,error}:any)=>({theme,t,status,error}))));
