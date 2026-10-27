/** Own Metal windows + loopback model; no user storage, hosts or external AI. */
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile,readFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=process.env.ZW_THEME_MATERIAL_PREFIX??'/tmp/zw-theme-material-build';
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-theme-material-evidence');await mkdir(out,{recursive:true});
const model=createServer(async(req,res)=>{
 if(req.method==='GET'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({data:[{id:'material-fixture',context_window:32768}]}));return;}
 for await(const _ of req){};
 res.writeHead(200,{'Content-Type':'text/event-stream'});
 res.end('data: '+JSON.stringify({choices:[{delta:{content:'材质验证答复：这是一条本地测试消息。'}}]})+'\n\ndata: [DONE]\n\n');
});
await new Promise<void>(done=>model.listen(0,'127.0.0.1',done));
const port=(model.address() as any).port;
const report:any={status:'running',cases:[],limits:['Synthetic Harness input in isolated native windows; no physical keyboard or IME claim.','Loopback responses only; validates native transcript rendering, not remote models.']};
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id);};
try{
 for(const [theme,t,b] of [['dark',0,0],['light',75,24],['sauber',100,0]] as const){
  const name=`${theme}-t${t}`,iso=await mkdtemp('/private/tmp/zw-theme-material-'),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
  await writeFile(join(data,'config.toml'),`[ui]\ntheme = "${theme}"\n[ui.materials]\nblur_px = ${b}\n[ui.materials.background]\ntransparency = ${t}\n[ai]\ndefault_provider = "fixture"\n[[ai.providers]]\nid = "fixture"\nkind = "openai_compat"\nendpoint = "http://127.0.0.1:${port}/v1/chat/completions"\nenabled = true\n[[ai.providers.models]]\nname = "material-fixture"\ncontext_window = 32768\ndefault = true\nefforts = []\n`);
  process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
  const log=await open(join(out,name+'.log'),'w');
  const env={...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'};
  for(const key of ['ZEROWORK_AI_MOCK','ZEROWORK_AI_ENDPOINT','ZEROWORK_AI_MODEL','ZEROWORK_AI_PROVIDER'])delete env[key];
  const app=spawn(join(prefix,'bin/zerowork'),[],{cwd:process.cwd(),env,stdio:['ignore',log.fd,log.fd]});
  const ended=new Promise<void>(done=>app.once('close',()=>done()));
  const item:any={name,theme,transparency:t,blur:b,captures:[],status:'running'};report.cases.push(item);
  async function capture(stage:string,ids:string[]){await h.sleep(250);const path=join(out,name+'-'+stage+'.png');assert((await h.screenshot(path)).ok);await writeFile(path.replace('.png','.json'),JSON.stringify(Object.fromEntries(await Promise.all(ids.map(async id=>[id,await h.query(id)]))),null,2));item.captures.push(path);}
  try{
   await h.waitForServerReady();await h.resizeWindow(1440,900);
   await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await visible('ai.prompt');
   await capture('recent',['ai.panel','ai.empty.recent','ai.strip.lip']);
   await click('ai.prompt');await h.type_('请检查主题和全局透明度。');await click('ai.send');
   await visible('ai.message.user.bubble');await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,15000);
   await capture('bubble',['ai.panel','ai.message.user.bubble','ai.response','ai.strip.lip']);
   const bubble=await visible('ai.message.user.bubble');assert(bubble.rect.w>0&&bubble.rect.w<=429.5,'bubble preserves 75% width limit');
   await click('ai.composer.permission');await visible('ai.permission.menu');await capture('popover',['ai.permission.menu']);await h.key('Escape');
   await click('ai.collapse');await click('toolbar.settings');await click('settings.nav.ai');
   await visible('settings.ai.provider.0.header');
   if(!(await h.query('settings.ai.provider.0.endpoint')).some(shown))await click('settings.ai.provider.0.header');
   await visible('settings.ai.provider.0.endpoint');
   await capture('provider',['settings.panel','settings.ai.provider.0.header','settings.ai.provider.0.endpoint','settings.save']);
   await click('settings.nav.appearance');await click('settings.appearance.font.header');await click('settings.field.font_size');await capture('picker',['settings.panel','settings.field.font_size','settings.save']);await h.key('Escape');await click('settings.close');
   await click('terminal.surface');await h.type_('/bin/sleep 30');await h.key('return');await h.sleep(350);
   await click('tabs.close.1');await visible('local.close.confirmation');await capture('danger',['local.close.confirmation','local.close.accept']);await click('local.close.cancel');await visible('terminal.surface');
   item.status='passed';console.log(name+' passed');
  }catch(e){item.status='failed';item.error=String(e);await capture('failure',['settings.panel','ai.panel','tabs.strip']).catch(()=>{});throw e;}
  finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;await log.close();}
 }
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);console.error(e);process.exitCode=1;}
finally{model.close();await writeFile(join(out,'native-report.json'),JSON.stringify(report,null,2));}
