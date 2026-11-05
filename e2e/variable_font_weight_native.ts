/** Variable weight UI, exact preview, validation, family changes and persistence.
 * node e2e/variable_font_weight_native.ts /absolute/evidence [binary]
 * Private data, process-local fonts and public synthetic Harness only.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,rm,open,readFile,writeFile,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'/tmp/zerowork-variable-font-native');await mkdir(out,{recursive:true});
const binary=resolve(process.argv[3]??'zig-out/bin/zerowork');
const base=await realpath(await mkdtemp('/private/tmp/zerowork-variable-font-')),data=join(base,'data');await mkdir(data);
const config=join(data,'config.toml');
await writeFile(config,'[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Inter Variable"\nfont_size = 14\nfont_weight = "420"\nline_height = 1.5\n');
const report:any={status:'running',checks:[],captures:[]};let child:any,ended:Promise<unknown>,log:any;
const shown=(n:any)=>n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');
const node=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null);
async function reveal(id:string){for(let i=0;i<8;i++){const n=await node(id),v=await node('settings.viewport');if(n.rect.y>=v.rect.y+2&&n.rect.y+n.rect.h<=v.rect.y+v.rect.h-2)return;await h.scrollAt(v.rect.x+v.rect.w/2,v.rect.y+v.rect.h/2,0,n.rect.y<v.rect.y?v.rect.y-n.rect.y+6:v.rect.y+v.rect.h-n.rect.y-n.rect.h-6);await h.sleep(60);}}
async function click(id:string){if(id.startsWith('settings.field.')||id.startsWith('settings.slider.'))await reveal(id);await node(id);assert((await h.clickTestId(id)).ok,id);}
async function capture(name:string){await h.mouseMove(5,5);await h.sleep(120);await h.screenshot(join(out,name+'.png'));report.captures.push(name+'.png');}
async function value(){return (await h.inputState('settings.field.font_weight')).buffer;}
async function preview(weight:number){assert.equal(Number(await value()),weight);const command=await node('settings.font.preview.command');report.preview_widths??={};report.preview_widths[weight]=command.rect.w;}
async function edit(id:string,value:string){await click(id);await h.key('a',{cmd:true});await h.type_(value);await h.key('enter');}
async function choose(family:string){await click('settings.field.font_family');await h.key('a',{cmd:true});await h.key('backspace');await h.type_(family);await click('settings.option.font_family.'+family);}
async function save(family:string,weight:string){await click('settings.save');await h.waitFor(async()=>{const c=await readFile(config,'utf8');return c.includes('font_family = "'+family+'"')&&c.includes('font_weight = "'+weight+'"')&&(await node('settings.footer.state')).text==='已保存'?true:null;});}
async function launch(round:number){const rpc=join(base,'rpc-'+round);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;log=await open(join(out,'app-'+round+'.log'),'w');child=spawn(binary,[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});ended=new Promise(r=>child.once('close',r));await h.waitForServerReady();await h.resizeWindow(1280,900);await click('toolbar.settings');await click('settings.nav.appearance');if(!(await h.query('settings.field.font_family')).some(shown))await click('settings.appearance.font.header');}
async function stop(){if(child?.exitCode===null){child.kill('SIGTERM');await ended;}if(child?.pid)await cleanupOwnedBridgeDirectories(child.pid);await log?.close();}
try{
 await launch(1);await node('settings.slider.font_weight');assert.equal(await value(),'420');await preview(420);
 assert(!(await h.query('settings.chooser.font_weight')).some(shown));
 const inputId=(await node('settings.field.font_weight')).id;
 await edit('settings.field.font_weight','421');await preview(421);assert.equal((await node('settings.field.font_weight')).id,inputId,'editing weight keeps the input mounted');await capture('variable-421');
 await edit('settings.field.font_weight','550');await preview(550);assert.notEqual(report.preview_widths[420],report.preview_widths[550],'weight changes actual preview glyph advances');await save('Inter Variable','550');
 report.checks.push('Inter Variable automatically uses slider + number, with exact intermediate weights and a stable input while editing.');
 await click('settings.slider.font_weight');const before=Number(await value());await h.key('right');assert.equal(Number(await value()),before+1);await preview(before+1);
 const track=await node('settings.slider.font_weight');await h.mouseDown(track.rect.x+track.rect.w*.25,track.rect.y+track.rect.h/2);await h.mouseMove(track.rect.x+track.rect.w*.7,track.rect.y+track.rect.h/2);await h.mouseUp(track.rect.x+track.rect.w*.7,track.rect.y+track.rect.h/2);const dragged=Number(await value());assert(dragged>550&&dragged<800);await preview(dragged);
 report.checks.push('Slider click, keyboard step of 1 and dragging synchronize the number and native preview without remounting.');
 await edit('settings.field.font_weight','901');assert.match(text(await node('settings.error.font_weight')),/100–900/);const saved=await readFile(config,'utf8');await h.clickTestId('settings.save');assert.equal(await readFile(config,'utf8'),saved);await click('settings.field.font_weight');await h.key('escape');assert.equal(Number(await value()),dragged);
 for(const invalid of ['99','420.5','NaN']){await edit('settings.field.font_weight',invalid);await node('settings.error.font_weight');await h.key('escape');assert.equal(Number(await value()),dragged);}
 await edit('settings.field.font_weight','100');await preview(100);await edit('settings.field.font_weight','900');await preview(900);await edit('settings.field.font_weight','420');await save('Inter Variable','420');
 await h.resizeWindow(860,480);await reveal('settings.field.font_weight');const number=await node('settings.field.font_weight'),slider=await node('settings.slider.font_weight'),viewport=await node('settings.viewport');assert(number.rect.x+number.rect.w<=viewport.rect.x+viewport.rect.w+1);assert(slider.rect.x+slider.rect.w<number.rect.x+1);await capture('compact-variable');await h.resizeWindow(1280,900);
 report.checks.push('Range endpoints work; invalid, fractional and nonnumeric input keep the last valid preview and Escape restores it. Compact controls stay inside the viewport.');
 await choose('Menlo');assert.match(text(await node('settings.field.font_weight')),/Regular/);assert(!(await h.query('settings.slider.font_weight')).some(shown));await click('settings.field.font_weight');await node('settings.option.font_weight.regular');await node('settings.option.font_weight.bold');assert(!(await h.query('settings.option.font_weight.light')).some(shown));await h.key('escape');
 await click('settings.field.font_family');await h.key('a',{cmd:true});await h.key('backspace');await h.type_('自定义');await click('settings.option.font_family.custom');await edit('settings.field.font_family','Inter Variable');await node('settings.slider.font_weight');assert.equal(await value(),'400');await edit('settings.field.font_weight','550');await save('Inter Variable','550');await reveal('settings.font.preview');await capture('variable-550');
 report.checks.push('Switching to Menlo shows only native Regular/Bold and reconciles 420; typing a variable family restores the continuous control.');
 await click('settings.close');await stop();await launch(2);assert.equal(await value(),'550');await preview(550);await node('settings.slider.font_weight');await capture('restarted-variable');report.checks.push('Exact numeric weight and variable control survive a new process.');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});console.error(e);}
finally{await stop();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(base,{recursive:true,force:true});}
if(report.status!=='passed')process.exitCode=1;else console.log('PASS',report.checks.length,'variable font native checks');
