/** Execution/retention controls through the actual main window; isolated data only. */
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_EXECUTION_TEST_PREFIX??'/tmp/zw-execution-settings-native');
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-execution-settings-evidence');await mkdir(out,{recursive:true});
const report:any={status:'running',binary:join(prefix,'bin/zerowork'),binary_sha256:createHash('sha256').update(await readFile(join(prefix,'bin/zerowork'))).digest('hex'),cases:[],checks:[],limits:['File-RPC synthetic input with real Metal screenshots; physical IME and VoiceOver are not covered.','No command/send actions are invoked; startup model discovery may run. Runtime execution policy enforcement is tested separately.']};
const modes=[['auto','自行判断'],['ask','每次询问'],['isolated_exec','批处理'],['attached_pty','附加现有 PTY'],['new_pty','新建 PTY']];
const transparencies=(process.env.ZW_EXECUTION_TRANSPARENCIES??'0').split(',').map(Number);
assert(transparencies.length>0&&transparencies.every(value=>Number.isFinite(value)&&value>=0&&value<=100),'valid material transparency matrix');
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,12000);
const settled=(id:string)=>h.waitFor(async()=>(await h.query(id)).find((node:any)=>shown(node)&&Math.abs((node.effective_opacity??1)-1)<.001)??null,5000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id);await h.sleep(100)};
const text=async(id:string)=>flat(await visible(id)).map(n=>n.text??'').join('');
async function edit(id:string,value:string){await click(id);await h.key('a',{cmd:true});if(value)await h.type_(value);else await h.key('backspace');await h.sleep(150)}
async function capture(item:any,name:string){await h.sleep(150);const file=join(out,name+'.png');assert((await h.screenshot(file)).ok);const png=await readFile(file);item.captures.push({file,pixels:[png.readUInt32BE(16),png.readUInt32BE(20)]});await writeFile(join(out,name+'.json'),JSON.stringify({panel:await h.query('ai.panel'),controls:await h.query('ai.composer.controls'),menu:await h.query('ai.execution.menu'),retention:await h.query('ai.retention.menu'),permission:await h.query('ai.permission.menu'),attachment:await h.query('ai.attachment.menu'),model:await h.query('ai.model.menu'),usage:await h.query('ai.usage.menu'),settings:await h.query('settings.ai.execution')},null,2))}
async function chooseSetting(key:string,index:number){await click('settings.field.'+key);await h.key('home');for(let i=0;i<index;i++)await h.key('down');await h.key('return');await h.sleep(150)}
matrix:for(const theme of ['dark','light','sauber'])for(const transparency of transparencies){
 const caseName=transparencies.length===1&&transparency===0?theme:`${theme}-t${transparency}`;
 const modelName=transparency===75?'provider/longest-supported-model-identifier':'policy-fixture';
 const iso=await realpath(await mkdtemp('/tmp/zw-execution-settings-')),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const configPath=join(data,'config.toml');await writeFile(configPath,`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n[ui.materials]\nblur_px=0\n[ui.materials.background]\ntransparency=${transparency}\n[ai]\ndefault_provider="fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:9/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="${modelName}"\ncontext_window=200000\ndefault=true\n`);
 const environment={...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''};
 for(const name of ['ZEROWORK_AI_MOCK','ZEROWORK_AI_ENDPOINT','ZEROWORK_AI_MODEL','ZEROWORK_AI_PROVIDER'])delete environment[name];
 const log=await open(join(out,caseName+'.log'),'w');const app=spawn(join(prefix,'bin/zerowork'),[],{env:environment,stdio:['ignore',log.fd,log.fd]});
 const ended=new Promise<void>(r=>app.once('close',()=>r()));const item:any={theme,transparency,status:'running',isolated:iso,captures:[],geometry:[]};report.cases.push(item);
 try{
  await h.waitForServerReady(60000);await h.resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await visible('ai.composer.execution');
  for(const [mode,label]of modes){await click('ai.composer.execution');await click('ai.execution.'+mode);await h.waitFor(async()=>(await text('ai.composer.execution')).includes(label)||null,5000);}
  assert((await text('ai.composer.permission')).includes('确认后执行'));
  await click('ai.composer.execution');await click('ai.execution.retention');await click('ai.retention.keep');await click('ai.composer.execution');assert((await text('ai.execution.retention')).includes('保留任务会话'));await capture(item,caseName+'-menu-wide');await h.key('escape');
  await click('ai.composer.execution');await click('ai.execution.attached_pty');
  for(const [w,height]of [[1440,900],[860,480]]){
   await h.resizeWindow(w,height);await h.sleep(150);const ids=['ai.composer.attachment','ai.composer.permission','ai.composer.execution','ai.composer.usage','ai.composer.model','ai.composer.trailing'];const nodes=await Promise.all(ids.map(visible));
   for(let i=0;i<nodes.length;i++){const r=nodes[i].rect;assert(r.x>=0&&r.y>=0&&r.x+r.w<=w+1&&r.y+r.h<=height+1,ids[i]);if(i)assert(nodes[i-1].rect.x+nodes[i-1].rect.w<=r.x+.5,'controls overlap');}
   if(transparency===transparencies[0])for(const kind of ['attachment','permission','model','usage']){
    await click('ai.composer.'+kind);const surface=await settled('ai.'+kind+'.menu');assert(surface.rect.x>=0&&surface.rect.y>=0&&surface.rect.x+surface.rect.w<=w&&surface.rect.y+surface.rect.h<=height,kind+' menu bounds');assert.equal(surface.effective_opacity,1);
    if(kind==='permission'||kind==='usage'){const label=await visible('ai.'+kind+'.title'),icon=await visible('ai.'+kind+'.header.icon');assert(Math.abs(label.rect.y+label.rect.h/2-icon.rect.y-icon.rect.h/2)<.5,kind+' title and icon share one line');}
    await capture(item,caseName+'-'+kind+'-'+w);await h.key('escape');
   }
   item.geometry.push({size:[w,height],controls:nodes.map((n:any,i:number)=>({id:ids[i],rect:n.rect}))});await capture(item,caseName+'-composer-'+w);await click('ai.composer.execution');const menu=await settled('ai.execution.menu');assert(menu.rect.x>=0&&menu.rect.y>=0&&menu.rect.x+menu.rect.w<=w&&menu.rect.y+menu.rect.h<=height);
   const title=await visible('ai.execution.title'),icon=await visible('ai.execution.header.icon'),close=await visible('ai.execution.close');assert(Math.abs(title.rect.y+title.rect.h/2-icon.rect.y-icon.rect.h/2)<.5,'execution title and icon share one line');assert.equal(close.rect.w,24);assert.equal(close.rect.h,24);assert.equal(menu.effective_opacity,1);await capture(item,caseName+'-menu-'+w);
   const viewport=await visible('ai.execution.viewport');await h.scrollAt(viewport.rect.x+viewport.rect.w/2,viewport.rect.y+viewport.rect.h/2,0,-1000);await h.sleep(150);const effect=await visible('ai.execution.effect');assert(effect.rect.y>=viewport.rect.y-.5&&effect.rect.y+effect.rect.h<=viewport.rect.y+viewport.rect.h+.5,'effect note reachable');await visible('ai.execution.retention');await capture(item,caseName+'-menu-bottom-'+w);
   await click('ai.execution.retention');const retention=await settled('ai.retention.menu');assert.equal(retention.effective_opacity,1);assert(retention.rect.x>=0&&retention.rect.y>=0&&retention.rect.x+retention.rect.w<=w&&retention.rect.y+retention.rect.h<=height,'nested retention bounds');await capture(item,caseName+'-retention-layer-'+w);await h.key('escape');if((await h.query('ai.execution.menu')).some(shown))await h.key('escape');
  }
  await click('ai.composer.execution');await click('ai.execution.new_pty');
  // Global draft save affects inherit and preserves an explicit conversation override.
  await click('toolbar.settings');await edit('settings.search','execution_mode');await visible('settings.field.execution_mode');await chooseSetting('execution_mode',2);await click('settings.save');await h.waitFor(async()=>/execution_mode\s*=\s*"isolated_exec"/.test(await readFile(configPath,'utf8'))||null,10000);await capture(item,caseName+'-settings-mode-saved');await click('settings.close');
  assert((await text('ai.composer.execution')).includes('新建 PTY'),'explicit override preserved after global save');
  await click('ai.composer.execution');await click('ai.execution.inherit');assert((await text('ai.composer.execution')).includes('批处理'));
  await click('toolbar.settings');await edit('settings.search','session_retention');await chooseSetting('session_retention',2);await click('settings.save');await h.waitFor(async()=>/session_retention\s*=\s*"keep"/.test(await readFile(configPath,'utf8'))||null,10000);await capture(item,caseName+'-settings-retention-saved');await click('settings.close');
  await click('toolbar.settings');await edit('settings.search','execution_mode');assert((await text('settings.field.execution_mode')).includes('批处理'));await edit('settings.search','session_retention');assert((await text('settings.field.session_retention')).includes('保留任务会话'));await click('settings.close');
  const saved=await readFile(configPath,'utf8');assert(/permission_mode\s*=\s*"confirm"/.test(saved));assert.equal(/name\s*=\s*"([^"]+)"/.exec(saved)?.[1],modelName);assert.equal(/theme\s*=\s*"([^"]+)"/.exec(saved)?.[1],theme);
  assert((await h.request('POST','/zerowork/windows',{action:'quit'})).ok,'normal App Quit request');
  await Promise.race([ended,new Promise((_,reject)=>setTimeout(()=>reject(new Error('normal App Quit timed out')),15000))]);
  item.exit={code:app.exitCode,signal:app.signalCode,normal:app.exitCode===0&&app.signalCode===null};assert(item.exit.normal,'normal App Quit exits 0');item.status='passed';
 }catch(error){item.status='failed';item.error=String(error);await capture(item,caseName+'-failure').catch(()=>{});report.status='failed';process.exitCode=1;break matrix}
 finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');item.cleanup_signal='SIGTERM';}await ended;await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2))}
}
if(report.status!=='failed'){report.status='passed_pending_pixel_review';report.checks=['All five modes are acknowledged independently from permissions; retention is acknowledged and a nullable inherit override follows global defaults.','Composer ordering, menu bounds and fixed original controls remain reachable in all three themes at 1440×900 and 860×480.','Global mode and retention save/reopen through the native Settings transaction; explicit mode override survives global changes.']}
await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,report:join(out,'report.json')}));
