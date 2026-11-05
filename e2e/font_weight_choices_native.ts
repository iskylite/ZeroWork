/** Native font-weight filtering, family changes and Chinese validation messages.
 * node e2e/font_weight_choices_native.ts /absolute/evidence [binary]
 * Uses isolated data and public synthetic Harness input.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,rm,open,readFile,writeFile,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
import * as h from '../zig-out/share/zenit/harness/client.ts';

const out=resolve(process.argv[2]??'/tmp/zerowork-font-weight-choices');
await mkdir(out,{recursive:true});
const binary=resolve(process.argv[3]??'zig-out/bin/zerowork');
const base=await realpath(await mkdtemp('/private/tmp/zerowork-font-weight-'));
const data=join(base,'data');await mkdir(data);
const config=join(data,'config.toml');
// A legacy unsupported value must remain actionable, with a Chinese explanation.
await writeFile(config,'[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Monaco"\nfont_size = 14\nfont_weight = "light"\nline_height = 1.5\n');
const report:any={status:'running',binary,checks:[],captures:[]};
let child:any,ended:Promise<unknown>,log:any;
const shown=(n:any)=>n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');
const node=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null);
async function reveal(id:string){
 for(let i=0;i<8;i++){
  const n=await node(id),v=await node('settings.viewport');
  if(n.rect.y>=v.rect.y+2&&n.rect.y+n.rect.h<=v.rect.y+v.rect.h-2)return;
  const delta=n.rect.y<v.rect.y?v.rect.y-n.rect.y+6:v.rect.y+v.rect.h-n.rect.y-n.rect.h-6;
  await h.scrollAt(v.rect.x+v.rect.w/2,v.rect.y+v.rect.h/2,0,delta);await h.sleep(60);
 }
}
async function click(id:string){if(id.startsWith('settings.field.'))await reveal(id);await node(id);assert((await h.clickTestId(id)).ok,id);}
async function capture(name:string){await h.mouseMove(5,5);await h.sleep(150);await h.screenshot(join(out,name+'.png'));report.captures.push(name+'.png');}
async function settings(){await click('toolbar.settings');await click('settings.nav.appearance');if(!(await h.query('settings.field.font_family')).some(shown))await click('settings.appearance.font.header');}
async function choose(family:string){await click('settings.field.font_family');await h.key('a',{cmd:true});await h.key('backspace');await h.type_(family);await click('settings.option.font_family.'+family);await h.waitFor(async()=>(await h.inputState('settings.font.search')).buffer===family?true:null);}
async function choices(expected:string[],shot?:string){
 await click('settings.field.font_weight');
 for(const weight of ['light','regular','medium','bold'])assert.equal((await h.query('settings.option.font_weight.'+weight)).some(shown),expected.includes(weight),weight);
 if(shot)await capture(shot);
 await h.key('escape');
}
async function save(family:string,weight:string){await click('settings.save');await h.waitFor(async()=>{const s=await readFile(config,'utf8');return s.includes('font_family = "'+family+'"')&&s.includes('font_weight = "'+weight+'"')&&(await node('settings.footer.state')).text==='已保存'?true:null;});}
async function launch(round:number){
 const rpc=join(base,'rpc-'+round);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 log=await open(join(out,'app-'+round+'.log'),'w');
 child=spawn(binary,[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
 ended=new Promise(r=>child.once('close',r));await h.waitForServerReady();await h.resizeWindow(1280,900);await settings();
}
async function stop(){if(child?.exitCode===null){child.kill('SIGTERM');await ended;}if(child?.pid)await cleanupOwnedBridgeDirectories(child.pid);await log?.close();}
try{
 await launch(1);
 const status=await node('settings.font.status');assert.equal(text(status),'当前字体不支持所选字重，请选择其他字重。');
 await reveal('settings.font.status');await capture('unsupported-weight-chinese');
 await choices(['regular'],'monaco-weights');
 await click('settings.field.font_weight');await click('settings.option.font_weight.regular');await save('Monaco','regular');
 report.checks.push('Legacy Monaco Light displays a Chinese message; only Regular is offered and fixes the saved value.');
 await choose('Fira Code');await choices(['light','regular','medium','bold'],'fira-weights');
 await click('settings.field.font_weight');await click('settings.option.font_weight.light');
 await choose('Menlo');assert.match(text(await node('settings.field.font_weight')),/Regular/);await choices(['regular','bold'],'menlo-weights');await save('Menlo','regular');
 report.checks.push('Fira Code offers four weights; switching from Light to Menlo selects Regular and removes Light/Medium.');
 await click('settings.field.font_weight');await click('settings.option.font_weight.bold');
 await choose('Source Code Pro');assert.match(text(await node('settings.field.font_weight')),/Bold/);await choices(['light','regular','medium','bold']);
 await choose('Monaco');assert.match(text(await node('settings.field.font_weight')),/Regular/);await save('Monaco','regular');
 report.checks.push('A supported Bold survives family changes; switching to Monaco reconciles it to Regular.');
 await choose('Fira Code');await click('settings.field.font_weight');await click('settings.option.font_weight.light');
 await click('settings.field.font_family');await h.key('a',{cmd:true});await h.key('backspace');await h.type_('自定义');await click('settings.option.font_family.custom');
 await click('settings.field.font_family');await h.key('a',{cmd:true});await h.type_('ZeroWorkMissingFontWeightNative');await h.key('enter');
 assert.match(text(await node('settings.field.font_weight')),/Regular/);await choices(['regular','bold']);await save('ZeroWorkMissingFontWeightNative','regular');
 report.checks.push('A custom missing family uses Menlo fallback weights and reconciles its previous Light.');
 await click('settings.close');await stop();
 await launch(2);await choices(['regular','bold']);assert.match(text(await node('settings.field.font_weight')),/Regular/);await capture('fallback-restarted');
 report.checks.push('Saved family, reconciled weight and fallback choices survive restart.');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});console.error(e);}
finally{await stop();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(base,{recursive:true,force:true});}
if(report.status!=='passed')process.exitCode=1;else console.log('PASS',report.checks.length,'font weight native checks');
