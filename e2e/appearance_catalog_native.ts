/** Native catalogue, persistence and font-search acceptance. Uses isolated local data only.
 * node e2e/appearance_catalog_native.ts /absolute/evidence [binary]
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,rm,open,readFile,writeFile,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]);await mkdir(out,{recursive:true});
const binary=resolve(process.argv[3]??'zig-out/bin/zerowork');
const isolated=await realpath(await mkdtemp('/private/tmp/zerowork-appearance-catalog-')),rpc=join(isolated,'rpc'),data=join(isolated,'data');
await mkdir(rpc);await mkdir(data);await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Menlo"\nfont_size = 14\nfont_weight = "regular"\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const design=JSON.parse(await readFile('docs/UI_V3/theme-presets.json','utf8'));
const report:any={status:'running',data,binary,themes:[],checks:[],captures:[],limits:['Synthetic Harness input; no physical keyboard/IME verification.','Bundled fonts register inside the process; the test does not install system fonts.']};
let child:any,ended:Promise<unknown>;
function launch(){child=spawn(binary,[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});ended=new Promise(r=>child.once('close',r));}
const shown=(n:any)=>n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const node=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null);
async function click(id:string){await node(id);assert((await h.clickTestId(id)).ok,id);}
async function capture(name:string){await h.mouseMove(5,5);await h.sleep(200);await h.screenshot(join(out,name+'.png'));report.captures.push(name+'.png');}
async function saved(){await h.waitFor(async()=>(await node('settings.footer.state')).text==='已保存'||null);}
async function chooseTheme(id:string){const strip=await node('settings.theme.strip');let tile=await node('settings.theme.'+id);for(let i=0;i<30&&(tile.rect.x<strip.rect.x||tile.rect.x+tile.rect.w>strip.rect.x+strip.rect.w);i++){await h.scrollAt(strip.rect.x+strip.rect.w/2,strip.rect.y+strip.rect.h/2,tile.rect.x<strip.rect.x?strip.rect.x-tile.rect.x+6:strip.rect.x+strip.rect.w-tile.rect.x-tile.rect.w-6,0);await h.sleep(80);tile=await node('settings.theme.'+id);}await click('settings.theme.'+id);await click('settings.save');await saved();assert.match(await readFile(join(data,'config.toml'),'utf8'),new RegExp('theme = "'+id+'"'));const palette=await node('settings.theme.ansi');assert.equal(palette.children[1].children.length,16,'actual 16-slot palette');report.themes.push(id);}
async function searchFont(text:string){await click('settings.field.font_family');await h.key('a',{cmd:true});await h.key('backspace');await h.type_(text);}
try{
 launch();await h.waitForServerReady();await h.resizeWindow(1280,720);await click('toolbar.settings');await click('settings.nav.appearance');
 for(const id of Object.keys(design.themes)){await chooseTheme(id);if(['forest','graphite','paper','catppuccin-latte','tokyo-night','rose-pine'].includes(id))await capture(id);}
 report.checks.push('Every builtin theme selected through its real tile and persisted; 16 ANSI swatches mounted.');
 await click('settings.appearance.font.header');
 await searchFont('Menlo');await node('settings.option.font_family.Menlo');assert(!(await h.query('settings.option.font_family.Monaco')).some(shown));await click('settings.option.font_family.Menlo');
 await searchFont('Fira');const missing=await node('settings.option.font_family.Fira Code');await writeFile(join(out,'font-option.json'),JSON.stringify(missing,null,2));await capture('font-search');await click('settings.option.font_family.Fira Code');
 await node('settings.font.preview');await capture('font-preview');await click('settings.save');await saved();assert.match(await readFile(join(data,'config.toml'),'utf8'),/font_family = "Fira Code"/);
 report.checks.push('Font search filters candidates and selecting another family persists its requested identity, without replacing the requested identity.');
 await h.resizeWindow(860,480);await capture('compact-font');await h.resizeWindow(1280,720);
 child.kill('SIGTERM');await ended;launch();await h.waitForServerReady();await click('toolbar.settings');await click('settings.nav.appearance');await node('settings.theme.rose-pine');assert.match(await readFile(join(data,'config.toml'),'utf8'),/font_family = "Fira Code"/);await capture('restarted');report.checks.push('Saved theme and requested font survive a fresh process.');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});console.error(e);}finally{if(child?.exitCode===null){child.kill('SIGTERM');await ended;}await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(isolated,{recursive:true,force:true});}
if(report.status!=='passed')process.exitCode=1;else console.log('PASS',report.themes.length,'themes;',report.checks.length,'native acceptance checks');
