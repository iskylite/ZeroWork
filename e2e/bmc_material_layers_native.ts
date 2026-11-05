/** Production KVM + real Metal textures + the application's material policy.
 * node e2e/bmc_material_layers_native.ts /absolute/bmc-kvm-preview /tmp/evidence
 * Local typed services only; input never leaves the fixture.
 */
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir, mkdtemp, open, readFile, writeFile, rm} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';

const binary=resolve(process.argv[2]), out=resolve(process.argv[3]);
await mkdir(out,{recursive:true});
const base=await mkdtemp('/private/tmp/zw-kvm-material-'), rpc=join(base,'rpc');
await mkdir(rpc); process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,['--theme=dark','--state=controlled'],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_E2E_ISOLATE_KEYBOARD:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const report:any={status:'running',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),captures:[],violations:[],limits:['Real native renderer and Metal; synthetic local frames, input and service snapshots. No BMC transport, credentials or management writes.']};
let theme='dark', width=1440, height=900, transparency=75;
const shown=(n:any)=>n?.rect?.w>0&&n.rect.h>0&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>.98;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
async function click(id:string){await visible(id);assert((await h.clickTestId(id)).ok,id);await h.sleep(350);}
async function paint(id:string){const p=await h.request('POST','/app/bmc-fixture/material-node',{id});assert(!p.error,`${id}: ${JSON.stringify(p)}`);return p;}
async function appearance(name:string,t:number){theme=name;transparency=t;assert((await h.request('POST','/app/bmc-fixture/appearance',{theme:name,transparency:t,blur:24})).ok);await h.sleep(220);}
async function state(name:string){assert((await h.request('POST','/app/bmc-fixture/state',{state:name})).ok);await h.sleep(180);}
async function capture(label:string,ids:string[],pixels:any[]=[]){
  report.step=label;
  if(ids.includes('bmc.progress.surface')){ids=[...ids,'bmc.viewport'];pixels.push({kind:'progress',id:'bmc.progress.surface',underNode:'bmc.viewport',staleFrame:label==='disconnected'?[240,240,240]:null});}
  if(!ids.some(id=>id.endsWith('.tooltip')))await h.mouseMove(4,4);await h.sleep(150);
  const name=`${theme}-${width}x${height}-t${transparency}-${label}`;
  const nodes:any={};for(const id of ids){await visible(id);nodes[id]=await paint(id);if(id.endsWith('.tooltip')&&JSON.stringify(nodes[id].ink)!==JSON.stringify(nodes[id].foreground))report.violations.push({theme,width,height,id,reason:'stale help ink',actual:nodes[id].ink,expected:nodes[id].foreground});}
  assert((await h.screenshot(join(out,name+'.png'))).ok);
  const tree=await h.query('bmc.content');
  await writeFile(join(out,name+'.json'),JSON.stringify({nodes,tree},null,2));
  report.captures.push({name,width,height,theme,transparency,nodes,pixels});
  return nodes;
}
function alpha(id:string,node:any,level:number){const expected=node.layer_alpha[level-1];if(node.background.a!==expected&&!(node.background.a===0&&node.compensated))report.violations.push({theme,width,height,transparency,id,actual:node.background.a,expected,level});}
async function close(menu:string){await click(`bmc.${menu}.close`);await h.sleep(120);}
async function frame(rgb:number[]){assert((await h.request('POST','/app/bmc-fixture/frame',{red:rgb[0],green:rgb[1],blue:rgb[2]})).ok);await h.sleep(180);}
try{
  await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
  for(const name of (process.env.ZW_KVM_THEMES??'dark,light,sauber').split(','))for(const size of [[1440,900],[860,480]]){
    [width,height]=size;assert((await h.resizeWindow(width,height)).ok);await appearance(name,75);await state('controlled');
    await click('bmc.display');await click('bmc.display.original');await close('display');
    for(const rgb of [[240,240,240],[0,0,0]]){
      await frame(rgb);await visible('bmc.fps');
      const nodes=await capture(rgb[0]?'white-video-fps':'black-video-fps',['bmc.frame','bmc.fps','bmc.fps.display'],[{kind:'video',id:'bmc.frame',rgb},{kind:'hud',id:'bmc.fps',under:rgb}]);
      assert.deepEqual(nodes['bmc.fps'].background,{r:18,g:20,b:24,a:199});
      assert.equal(nodes['bmc.fps.display'].ink.a,255);
    }
    await frame([240,240,240]);
    const video=await visible('bmc.viewport');await h.clickAt(video.rect.x+100,video.rect.y+100);await h.sleep(100);
    assert((await h.request('GET','/app/bmc-fixture/input-stats')).captured);
    await h.key('unknown');await h.request('POST','/key_up',{key:'unknown'});
    await capture('input-notice',['bmc.input_hint','bmc.fps'],[{kind:'hint',id:'bmc.input_hint',under:[240,240,240]}]);
    await h.key('escape',{ctrl:true,alt:true});await h.request('POST','/key_up',{key:'escape',ctrl:true,alt:true});
    for(const t of [0,75,100]){
      await appearance(name,t);
      await capture('video-preserved',['bmc.frame','bmc.fps'],[{kind:'video',id:'bmc.frame',rgb:[240,240,240]}]);
    }
    await appearance(name,75);
    await click('bmc.display');await click('bmc.display.fit');await close('display');
    for(const menu of ['control','keys','display','power','boot']){
      await click(`bmc.${menu}`);
      const ids=[`bmc.${menu}.popover`];if(menu==='power'||menu==='boot')ids.push(`bmc.${menu}.summary`);
      const nodes=await capture(menu,ids);alpha(ids[0],nodes[ids[0]],1);if(ids[1])alpha(ids[1],nodes[ids[1]],2);
      if(menu==='boot'){
        await click('bmc.boot.target.trigger');let p=await capture('boot-dropdown',['bmc.boot.popover','bmc.boot.target.dropdown','bmc.boot.option.none']);alpha('bmc.boot.target.dropdown',p['bmc.boot.target.dropdown'],2);
        if(JSON.stringify(p['bmc.boot.option.none'].ink)!==JSON.stringify(p['bmc.boot.option.none'].foreground))report.violations.push({theme,width,height,id:'bmc.boot.option.none',reason:'stale option ink',actual:p['bmc.boot.option.none'].ink,expected:p['bmc.boot.option.none'].foreground});
        await click('bmc.boot.option.none');
        if(!(await h.request('GET','/app/bmc-fixture/menus')).open[4])await click('bmc.boot');
        await click('bmc.boot.order');await capture('boot-order',['bmc.boot.order_modal']);await click('bmc.boot.order_close');await click('bmc.boot');
      }
      if(menu==='display'){
        const toggle=await visible('bmc.display.fps');await h.mouseMove(toggle.rect.x+80,toggle.rect.y+10);
        await h.waitFor(async()=>(await h.query('bmc.display.fps.tooltip')).some(shown)||null,5000);
        if((await h.query('bmc.display.fps.tooltip')).some(shown))await capture('fps-tooltip',['bmc.display.popover','bmc.display.fps.tooltip']);
        else report.violations.push({theme,width,height,id:'bmc.display.fps.tooltip',reason:'unreachable by pointer and Tab'});
        await h.mouseMove(4,4);await click('bmc.display.fps');await close('display');
        assert(!(await h.query('bmc.fps')).some(shown));await click('bmc.display');await click('bmc.display.fps');
        if(!(await h.request('GET','/app/bmc-fixture/menus')).open[2])await click('bmc.display');
        await click('bmc.display.connection_log');const p=await capture('connection-log',['bmc.connection_log.modal','bmc.connection_log.route','bmc.connection_log.footer']);alpha('bmc.connection_log.route',p['bmc.connection_log.route'],2);alpha('bmc.connection_log.footer',p['bmc.connection_log.footer'],2);
        await click('bmc.connection_log.close');
        await click('bmc.display');
      }
      await close(menu);
    }
    await click('bmc.disconnect');await capture('disconnect-confirmation',['bmc.disconnect.confirmation']);await click('bmc.disconnect.return');
    for(const s of ['read_only','no_signal','disconnected']){await state(s);await capture(s,s==='read_only'?['bmc.fps']:['bmc.progress','bmc.progress.surface']);}
    for(const phase of ['public_script','waiting_certificate','waiting_credentials','redfish_discovery']){
      assert((await h.request('POST','/app/bmc-fixture/progress',{stage:phase,revision:12,elapsed_ms:9900,stage_elapsed_ms:900,log_generation:1})).ok);await h.sleep(180);
      const p=await capture(phase,['bmc.progress','bmc.progress.surface','bmc.progress.route']);alpha('bmc.progress.surface',p['bmc.progress.surface'],1);alpha('bmc.progress.route',p['bmc.progress.route'],2);
    }
    assert((await h.request('POST','/app/bmc-fixture/progress',{stage:'public_script',revision:13,elapsed_ms:9900,stage_elapsed_ms:900,failure:true,log_generation:1})).ok);await h.sleep(180);
    await capture('failed',['bmc.progress','bmc.progress.surface']);
    for(const t of [0,100]){await appearance(name,t);const p=await capture('failed-material',['bmc.progress','bmc.progress.surface']);alpha('bmc.progress.surface',p['bmc.progress.surface'],1);}
    await state('controlled');
  }
  const stats=await h.request('GET','/app/bmc-fixture/stats');assert.equal(stats.power_writes,0);assert.equal(stats.boot_writes,0);
  await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
  execFileSync('python3',[resolve('e2e/bmc_material_pixels.py'),out],{stdio:'inherit'});
  assert.equal(report.violations.length,0,JSON.stringify(report.violations));report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;report.menus=await h.request('GET','/app/bmc-fixture/menus').catch(()=>null);await h.screenshot(join(out,'failure.png')).catch(()=>{});await writeFile(join(out,'failure-tree.json'),JSON.stringify(await h.tree(),null,2)).catch(()=>{});}
finally{
  if(app.exitCode===null&&app.signalCode===null){await h.request('POST','/quit').catch(()=>{});await Promise.race([ended,h.sleep(3000)]);}
  if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await ended;}
  if(app.pid)await cleanupOwnedBridgeDirectories(app.pid);await log.close();await rm(base,{recursive:true,force:true});
  await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,captures:report.captures.length,violations:report.violations.length}));
}
