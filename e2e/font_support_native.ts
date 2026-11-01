/** Bundled terminal fonts: real native search, save/restart and Local PTY geometry.
 * node e2e/font_support_native.ts /absolute/evidence [binary]
 * Only runner-owned data is used. Input is the public synthetic Harness, not a physical keyboard or IME.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,rm,open,readFile,writeFile,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'/tmp/zerowork-font-support/native');await mkdir(out,{recursive:true});
const binary=resolve(process.argv[3]??'zig-out/bin/zerowork');
const base=await realpath(await mkdtemp('/private/tmp/zerowork-font-support-')),data=join(base,'data');await mkdir(data);
const config=join(data,'config.toml');await writeFile(config,'[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Menlo"\nfont_size = 14\nfont_weight = "regular"\nline_height = 1.5\ncursor_style = "block"\ncommand_info = false\ninput_line_highlight = false\n[completion]\nenabled = false\n');
const report:any={status:'running',binary,data,checks:[],captures:[],limits:['Public synthetic Harness input; physical keyboard and real IME were not tested.','No system fonts are installed or modified. Pixel review is separate from geometry assertions.']};
let child:any,ended:Promise<unknown>,log:any;
const shown=(n:any)=>n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');
const node=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null);
async function reveal(id:string){for(let i=0;i<8;i++){const n=await node(id),v=(await h.query('settings.viewport')).find(shown);if(!v||n.rect.y>=v.rect.y+2&&n.rect.y+n.rect.h<=v.rect.y+v.rect.h-2)return;const delta=n.rect.y<v.rect.y?v.rect.y-n.rect.y+6:v.rect.y+v.rect.h-n.rect.y-n.rect.h-6;await h.scrollAt(v.rect.x+v.rect.w/2,v.rect.y+v.rect.h/2,0,delta);await h.sleep(60);}}
async function click(id:string){if(id.startsWith('settings.field.')||id==='settings.font.preview')await reveal(id);await node(id);assert((await h.clickTestId(id)).ok,id);}
async function capture(name:string){await h.mouseMove(5,5);await h.sleep(150);await h.screenshot(join(out,name+'.png'));report.captures.push(name+'.png');}
async function launch(round:number){const rpc=join(base,'rpc-'+round);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;log=await open(join(out,'app-'+round+'.log'),'w');child=spawn(binary,[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});ended=new Promise(r=>child.once('close',r));await h.waitForServerReady();await h.resizeWindow(1280,900);}
async function stop(){if(child?.exitCode===null){child.kill('SIGTERM');await ended;}if(child?.pid)await cleanupOwnedBridgeDirectories(child.pid);await log?.close();}
async function settings(){await click('toolbar.settings');await click('settings.nav.appearance');if(!(await h.query('settings.field.font_family')).some(shown))await click('settings.appearance.font.header');}
async function edit(id:string,value:string){await click(id);await h.key('a',{cmd:true});await h.type_(value);await h.key('enter');await h.waitFor(async()=>{const state=await h.inputState(id);return state.buffer===value&&state.cursor_pos===Buffer.byteLength(value)?state:null});}
async function search(value:string){await click('settings.field.font_family');await h.key('a',{cmd:true});await h.key('backspace');await h.type_(value);}
async function choose(family:string){await search(family);const option=await node('settings.option.font_family.'+family);assert.match(text(option),/内置/);await click('settings.option.font_family.'+family);await h.waitFor(async()=>text(await node('settings.font.preview')).includes(family+' ·')?true:null);assert.equal(text(await h.query('settings.font.status').then(v=>v[0])),'');}
async function save(family:string,weight:string,size:number){await click('settings.save');await h.waitFor(async()=>(await node('settings.footer.state')).text==='已保存'||null);const source=await readFile(config,'utf8');for(const line of ['font_family = "'+family+'"','font_weight = "'+weight+'"','font_size = '+size])assert(source.includes(line),line);}
async function previewMetrics(size=18){const preview=await h.waitFor(async()=>{const n=await node('settings.font.preview');return text(n).includes(' · '+size+' pt')?n:null});const command=await node('settings.font.preview.command'),caret=await node('settings.font.preview.caret');assert(Math.abs(caret.rect.w-command.rect.w/[...command.text!].length)<0.4,'cursor width follows the selected monospace face');assert(Math.abs(caret.rect.h-command.rect.h)<0.4,'cursor height follows the text row pitch');assert(Math.abs(command.rect.h-size*1.5)<.4,'preview row actually applies the committed font size');assert.match((await node('settings.font.preview.multilingual')).text!,/中文终端/);}
async function rows(){const result:any[]=[];for(let i=0;i<8;i++){const r=(await h.query('terminal.surface.row.'+i)).find(shown);if(r){const glyphs=(r.children??[]).filter(n=>shown(n)&&n.tag==='text'&&n.text).sort((a,b)=>a.rect.x-b.rect.x);result.push({node:r,text:glyphs.map(n=>n.text).join(''),glyphs});}}return result;}
const near=(a:number,b:number,label:string)=>assert(Math.abs(a-b)<0.4,`${label}: ${a} vs ${b}`);
const containsId=(n:any,id:number):boolean=>n.id===id||(n.children??[]).some((child:any)=>containsId(child,id));
async function settingsSearchRetainsFocus(){
 const search=await node('settings.search');await click('settings.search');await h.key('a',{cmd:true});await h.key('backspace');
 const focused=(await h.focused()).id;assert(focused!==undefined&&containsId(search,focused),'settings search owns focus');
 let page=(await node('settings.appearance.font')).id;
 for(const [part,expected] of [['字','字'],['体','字体']]){
  await h.type_(part);await h.waitFor(async()=>{const current=await node('settings.appearance.font');return current.id!==page?current:null});page=(await node('settings.appearance.font')).id;
  const state=await h.inputState('settings.search');assert.equal(state.buffer,expected);assert.equal(state.cursor_pos,Buffer.byteLength(expected));assert.equal(state.buffer_len,Buffer.byteLength(expected));assert.equal((await h.focused()).id,focused,'content remount preserves settings search focus');
 }
 await h.key('a',{cmd:true});await h.key('backspace');await h.waitFor(async()=>(await node('settings.appearance.font')).id!==page?true:null);assert.equal((await h.inputState('settings.search')).buffer,'');assert.equal((await h.focused()).id,focused);assert.equal((await node('settings.footer.state')).text,'已保存');
 report.checks.push('Two separately delivered Chinese settings-search characters retain focus and UTF-8 cursor/buffer after each real content remount; clearing search leaves the saved draft untouched.');
}
try{
 await launch(1);await settings();
 await settingsSearchRetainsFocus();
 await search('Fira');await node('settings.option.font_family.Fira Code');assert(!(await h.query('settings.option.font_family.Monaco')).some(shown));await h.key('escape');assert.equal((await h.inputState('settings.font.search')).buffer,'Menlo');assert.equal((await node('settings.footer.state')).text,'已保存');report.checks.push('Search filters suggestions; Escape restores selected label and leaves the saved draft untouched.');
 for(const family of ['Fira Code','Source Code Pro']){
  await choose(family);await edit('settings.field.font_size','18');
  for(const weight of ['light','regular','medium','bold']){await click('settings.field.font_weight');await click('settings.option.font_weight.'+weight);await previewMetrics();await save(family,weight,18);}
  await reveal('settings.font.preview');await capture(family==='Fira Code'?'fira-native-preview':'source-native-preview');
 }
 report.checks.push('Both bundled families are available without system installation; all four weights save with exact requested family and matching preview cursor geometry.');
 await edit('settings.field.font_size','8');await previewMetrics(8);await save('Source Code Pro','bold',8);await edit('settings.field.font_size','48');await previewMetrics(48);await save('Source Code Pro','bold',48);report.checks.push('Minimum 8 and maximum 48 sizes preserve native text/cursor row geometry and persist.');
 await click('settings.field.font_size');await h.key('a',{cmd:true});await h.type_('20');await h.key('tab');await previewMetrics(20);await edit('settings.field.font_size','18');await click('settings.field.font_weight');await click('settings.option.font_weight.regular');await save('Source Code Pro','regular',18);await click('settings.field.font_size');await h.key('a',{cmd:true});const selectedSize=await h.inputState('settings.field.font_size');await h.key('enter');await h.waitFor(async()=>{const restored=await h.inputState('settings.field.font_size');return restored.buffer===selectedSize.buffer&&restored.cursor_pos===selectedSize.cursor_pos&&restored.anchor===selectedSize.anchor?restored:null});const retainedInput=(await node('settings.field.font_size')).id;await h.sleep(800);const idleInput=await h.inputState('settings.field.font_size');assert.equal((await node('settings.field.font_size')).id,retainedInput,'idle frames must not remount the input again');assert.equal(idleInput.cursor_pos,selectedSize.cursor_pos);assert.equal(idleInput.anchor,selectedSize.anchor);report.checks.push('Enter and Tab refresh actual size/cursor geometry without crashing; Enter preserves the focused input UTF-8 caret and selection across its safe remount and later idle frames.');
 await h.resizeWindow(860,480);await reveal('settings.font.preview');await capture('compact-font');await h.resizeWindow(1280,900);await click('settings.close');await stop();
 await launch(2);await settings();assert.equal((await h.inputState('settings.font.search')).buffer,'Source Code Pro · 内置');await previewMetrics();await reveal('settings.font.preview');await capture('restarted-source');await click('settings.close');report.checks.push('Selected bundled family, size and weight survive a fresh process and resolve without a fallback warning.');
 await click('workspace.empty.local');await node('terminal.surface.row.0');
 const fixture=join(base,'font-fixture.zsh');const payload='\x1b[0m\x1b[3J\x1b[2J\x1b[HFONT_METRICS Wi 00\r\n中文终端 mixed Aa\r\n\x1b[1mBOLD Aa 00\x1b[0m\r\nCARET> ';
 await writeFile(fixture,"#!/bin/zsh\nprintf '%s' '"+payload+"'\n/bin/sleep 40\n");
 await click('terminal.surface');await h.type_("/bin/zsh -f '"+fixture+"'");await h.key('enter');
 const rendered:any=await h.waitFor(async()=>{const r=await rows();return r.some(v=>v.text.startsWith('FONT_METRICS'))?r:null});await writeFile(join(out,'terminal-rows.json'),JSON.stringify(rendered,null,2));
 const latin=rendered.find((r:any)=>r.text.startsWith('FONT_METRICS')),cjk=rendered.find((r:any)=>r.text.includes('中文终端')),bold=rendered.find((r:any)=>r.text.startsWith('BOLD')),caret=await node('terminal.surface.caret');assert(latin&&cjk&&bold,'real PTY Latin, Chinese fallback and bold rows');const cell=latin.glyphs[0].rect.w/[...latin.glyphs[0].text].length;
 for(const row of [latin,cjk,bold]){near(row.node.rect.h,27,'18×1.5 row pitch');for(const glyph of row.glyphs)near(glyph.rect.h,27,'glyph shares row pitch');}
 near(cjk.glyphs.find((g:any)=>g.text==='中').rect.w,2*cell,'Chinese wide glyph occupies two terminal cells');near(caret.rect.w,cell,'terminal block cursor uses the same cell width');near(caret.rect.h,27,'terminal cursor row height');
 await capture('source-live-terminal');
 const first=latin.glyphs[0];await h.mouseDown(first.rect.x+cell*.1,first.rect.y+13);await h.mouseMove(first.rect.x+cell*5.1,first.rect.y+13);await h.mouseUp(first.rect.x+cell*5.1,first.rect.y+13);
 const selected=await node(latin.node.test_id);await writeFile(join(out,'terminal-selection.json'),JSON.stringify(selected,null,2));const rects=(selected.children??[]).filter((n:any)=>shown(n)&&n.tag!=='text'&&Math.abs(n.rect.w-5*cell)<.4&&Math.abs(n.rect.h-27)<.4);assert(rects.length,'drag selection covers exactly five measured terminal cells');await capture('source-live-selection');report.checks.push('Real Local PTY renders Latin, bold and Chinese fallback on 18×1.5 rows; CJK occupies two cells, block cursor uses the same cell and a drag selection covers exactly five cells.');
 await click('terminal.surface');await h.key('c',{ctrl:true});
 await settings();await search('自定义');await click('settings.option.font_family.custom');const missing='ZeroWorkMissingFontNative_20261101';await edit('settings.field.font_family',missing);await h.waitFor(async()=>text(await node('settings.font.preview')).includes('预览使用 Menlo')?true:null);await save(missing,'regular',18);await reveal('settings.font.preview');await capture('custom-font-fallback');await click('settings.close');await stop();
 await launch(3);await settings();assert.equal((await h.inputState('settings.font.search')).buffer,missing);assert.match(text(await node('settings.font.preview')),/预览使用 Menlo/);await reveal('settings.font.preview');await capture('custom-font-restarted');report.checks.push('Custom missing family can be typed and saved; its requested identity survives restart while preview explicitly reports the actual Menlo fallback.');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});console.error(e);}finally{await stop();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(base,{recursive:true,force:true});}
if(report.status!=='passed')process.exitCode=1;else console.log('PASS',report.checks.length,'font native acceptance checks');
