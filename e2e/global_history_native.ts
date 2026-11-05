/** Global catalogue / original native archive renderer, with no live sessions. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile,readFile,rm,realpath,readdir,rename} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {createHash} from 'node:crypto';
import {waitForServerReady,query,tree,clickTestId,clickAt,key,type_,waitFor,screenshot,resizeWindow,mouseMove,scrollAt,focused,request} from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]||'zig-out/bin/zerowork');
const out=resolve(process.argv[3]||'/tmp/zerowork-global-history/native');
await mkdir(out,{recursive:true});
const report:any={binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],captures:[],exits:[],limits:['Archive fixtures exercise real persisted cast decoding and normal App Quit with only readonly archive tabs. Real Local/SSH close and restart lifecycle are outside this fixture.']};
const shown=(n:any)=>n.visible!==false&&n.hidden!==true&&n.rect.w>0&&n.rect.h>0&&(n.effective_opacity??1)>0;
const visible=async(id:string)=>await waitFor(async()=>(await query(id)).find(shown)||null,10000);
const text=(n:any):string=>(n.text||'')+(n.children||[]).map(text).join('');
for(const theme of ['dark','light','sauber']){
 const isolated=await realpath(await mkdtemp(join(tmpdir(),'zw-global-history-'))),data=join(isolated,'data'),rpc=join(isolated,'rpc');
 for(const path of [rpc,join(data,'logs/history')])await mkdir(path,{recursive:true});
 const materialT=theme==='dark'?0:theme==='light'?75:100;
 const timestamps=theme==='dark';
 await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\ntimestamp_gutter=${timestamps}\n[ui.materials]\nblur_px=0\n[ui.materials.background]\ntransparency=${materialT}\n`);
 await writeFile(join(data,'hosts.toml'),'[registry]\nschema_version=2\nrevision=1\nnext_connection_id=1\nnext_group_id=1\n');
 const started=Date.now()-60000;
 const extraCount=12,recordCount=5+extraCount;
 const extraIndex=Array.from({length:extraCount},(_,i)=>`${i+4}\t${started-180000-i*60000}\t${started-150000-i*60000}\t30000\t0\tEarlier archive ${String(i+1).padStart(2,'0')}\tfixture\tlogs/history/earlier-${i}.cast\tssh\t${1000+i}\n`).join('');
 await writeFile(join(data,'logs/history/index.tsv'),`1\t${started}\t${started+30000}\t30000\t0\tDeleted host 中文 · retained production deployment output with a deliberately long original title\tfixture\tlogs/history/review.cast\tssh\t919\n2\t${started-60000}\t${started-30000}\t30000\t0\tLocal Terminal\tfixture\tlogs/history/local.cast\tlocal\t0\n3\t${started-120000}\t${started-90000}\t30000\t1\tBroken recording\tfixture\tlogs/history/broken.cast\tssh\t920\n`+extraIndex);
 const content=Array.from({length:90},(_,i)=>`line-${String(i+1).padStart(3,'0')} 中文 ANSI ${i===89?'END_WITNESS':'real retained output'}`).join('\r\n');
 const cast=JSON.stringify({version:2,width:100,height:24})+'\n'+JSON.stringify([0,'o','BEGIN_WITNESS\r\n\u001b[32m'+content+'\u001b[0m\r\n'])+'\n';
 await writeFile(join(data,'logs/history/review.cast'),cast);
 for(let i=0;i<extraCount;i++)await writeFile(join(data,`logs/history/earlier-${i}.cast`),cast);
 await writeFile(join(data,'logs/history/broken.cast'),'not a cast');
 const localCast=JSON.stringify({version:2,width:80,height:24})+'\n'+JSON.stringify([0,'o','LOCAL_ARCHIVE_DEFAULT\r\n\u001b[31mANSI_RED \u001b[38;5;1mINDEX_RED \u001b[38;2;232;121;249mTRUECOLOR_MARK\u001b[0m\r\nprompt% '])+'\n'+JSON.stringify([1,'a',JSON.stringify({id:1,owner:{session_id:2,generation:1},timestamp_ms:started,anchor_row:1,command:'@ts',output:'RECORDED_COMMAND 中文',state:'success'})])+'\n';
 await writeFile(join(data,'logs/history/local.cast'),localCast);
 const palette=Array.from({length:16},(_,i)=>i===2?0x22aa66ff:0x888888ff);
 const localManifest={schema_version:1,archive_key:'1234567890abcdef1234567890abcdef',recording_id:'abcdef1234567890abcdef1234567890',manifest_revision:1,source_kind:'local',started_ms:started-60000,ended_ms:started-30000,exit_code:0,state:'closed',display:{title:'Original local title',host:'Local Terminal',user:'fixture',endpoint:'local zsh',cwd:'/archive/original',final_cols:80,final_rows:24,timestamps:!timestamps,layout_version:1,font_family:'Menlo',font_size_px:16,line_height:1.5,theme_reference:'dark',colors:{foreground:0xe0e0e0ff,background:0x101018ff,cursor:0xe0e0e0ff,selection:0x6366f14d,ansi:palette}},recording:{generations:[{recording_generation:1,session_id:2,session_generation:1,initial_cols:80,initial_rows:24,receive_time_origin:started-60000,baselines:[{event_sequence:0,raw_offset:0,kind:'initial_empty'}]}]},files:[{path:'logs/history/local.cast',kind:'cast',committed_length:Buffer.byteLength(localCast),checksum:createHash('sha256').update(localCast).digest('hex')}],coverage:'complete',replayability:'verified',commit:{state:'indexed',committed_length:Buffer.byteLength(localCast)}};
 await writeFile(join(data,'logs/history/local.session.json'),JSON.stringify(localManifest));
 const fragment={...structuredClone(localManifest),archive_key:'33333333333333333333333333333333',recording_id:'44444444444444444444444444444444',source_kind:'ssh',started_ms:started-130000,ended_ms:started-100000,display:{...localManifest.display,title:'Retained fragment',host:'retained',endpoint:'10.0.1.24:22'},coverage:'retained',replayability:'baseline_unavailable',files:[{path:'logs/history/fragment.cast',kind:'cast',committed_length:Buffer.byteLength(cast),checksum:createHash('sha256').update(cast).digest('hex')}]};
 await writeFile(join(data,'logs/history/fragment.cast'),cast);
 await writeFile(join(data,'logs/history/fragment.session.json'),JSON.stringify(fragment));
 const notRecorded={...structuredClone(localManifest),archive_key:'55555555555555555555555555555555',recording_id:'66666666666666666666666666666666',source_kind:'ssh',started_ms:started-140000,ended_ms:started-110000,display:{...localManifest.display,title:'Not recorded',host:'unrecorded'},coverage:'unavailable',replayability:'unsupported',failure:'RecordingDisabled',files:[]};
 await writeFile(join(data,'logs/history/unrecorded.session.json'),JSON.stringify(notRecorded));
 const staging=join(isolated,'staged-history');await mkdir(staging);
 for(const name of await readdir(join(data,'logs/history')))await rename(join(data,'logs/history',name),join(staging,name));
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,`${theme}.log`),'w');
 const child=spawn(binary,[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
 const exited=new Promise(r=>child.once('close',r));
 const cap=async(name:string)=>{await mouseMove(20,20);const captured:any={};for(const id of ['history.panel','history.search','history.footer','history.confirmation','history.empty','history.empty.detail','history.message','history.viewport','history.record','terminal.history.card','terminal.history.title','terminal.history.position','terminal.history.notice','terminal.timestamp','terminal.row','terminal.command.record','terminal.command.output','terminal.command.article','tabs.strip'])captured[id]=await query(id);await writeFile(join(out,`${theme}-${name}.tree.json`),JSON.stringify(captured,null,2));assert((await screenshot(join(out,`${theme}-${name}.png`))).ok);report.captures.push(`${theme}-${name}`);};
 try{
  await waitForServerReady();await resizeWindow(1440,900);
  await visible('workspace.empty');assert((await clickTestId('toolbar.history')).ok);
  await waitFor(async()=>(await query('history.empty')).some(n=>shown(n)&&text(n).includes('还没有会话历史'))||null);const empty=await visible('history.empty'),emptyView=await visible('history.viewport'),detail=await visible('history.empty.detail');assert.equal(empty.rect.w,emptyView.rect.w);assert(Math.abs((detail.rect.x+detail.rect.w/2)-(emptyView.rect.x+emptyView.rect.w/2))<2,'empty copy is horizontally centered');assert(!(await query('history.message')).some(shown));await cap('empty');await key('escape');
  for(const name of await readdir(staging))await rename(join(staging,name),join(data,'logs/history',name));
  assert((await clickTestId('toolbar.history')).ok);
  const panel=await visible('history.panel');assert.equal(panel.rect.w,480);
  await waitFor(async()=>(await query('history.record')).filter(shown).length===recordCount||null);
  const field=await visible('history.search');assert.equal(field.rect.h,36,'full-height native Input hit target');
  const firstRow=await visible('history.record'),firstTitle=await visible('history.record.title'),glyph=firstRow.children[0];
  assert(firstTitle.rect.x>glyph.rect.x+glyph.rect.w&&firstTitle.rect.y<glyph.rect.y+glyph.rect.h&&glyph.rect.y<firstTitle.rect.y+firstTitle.rect.h,'record icon and title share the first line');
  assert(firstTitle.rect.x+firstTitle.rect.w<=firstRow.rect.x+firstRow.rect.w,'long title remains within its row');
  assert.equal(firstRow.rect.h,66,'history records use the compact two-line layout');
  const details=firstRow.children[1].children[1];
  for(const id of ['history.record.view','history.record.export','history.record.delete']){
   const action=await visible(id);assert.equal(action.rect.w,28);assert.equal(action.rect.h,28);
   assert(action.rect.y>=details.rect.y&&action.rect.y+action.rect.h<=details.rect.y+details.rect.h,'all icon actions remain on the second line');
  }
  assert((await query('history.record.export')).filter(shown).length===recordCount,'all rows expose a consistent export control');
  await clickTestId('history.record.title');
  assert((await query('history.panel')).some(shown),'clicking record content must keep the list open');
  assert(!(await query('terminal.history.card')).some(shown),'record content must not open history');
  for(const [id,tip] of [['history.record.title','history.record.title.tooltip'],['history.record.detail','history.record.detail.tooltip']]){
   const value=await visible(id);await mouseMove(value.rect.x+value.rect.w/2,value.rect.y+value.rect.h/2);
   assert.equal(text(await visible(tip)),text(value));await new Promise(r=>setTimeout(r,220));assert((await screenshot(join(out,theme+'-'+tip+'.png'))).ok);await mouseMove(20,20);
  }
  await cap('list');
  await key('up');assert.equal((await focused()).test_id,'history.record.view');
  const viewport=await visible('history.viewport'),lastRow=(await query('history.record')).filter(shown).at(-1)!;
  assert(lastRow.rect.y>=viewport.rect.y-1&&lastRow.rect.y+lastRow.rect.h<=viewport.rect.y+viewport.rect.h+1,'keyboard reaches the final complete list row');
  assert(!(await query('history.footer')).some(shown),'redundant footer is removed');
  await cap('list-bottom');
  const descendants=(n:any):number[]=>[n.id,...(n.children||[]).flatMap(descendants)];
  const focusIds=new Set(descendants(await visible('history.panel')));
  for(let i=0;i<10;i++){await key('tab');assert(focusIds.has((await focused()).id),'Tab must remain within real history controls');}
  await clickTestId('history.search');await type_('Retained fragment');
  await waitFor(async()=>(await query('history.record')).filter(shown).length===1||null);
  assert(!(await visible('history.record.view')).focusable,'fragment cannot replay without its baseline');
  assert((await visible('history.record.export')).focusable,'retained content can export independently of replay');
  await cap('retained-fragment');
  await clickTestId('history.search');await key('a',{cmd:true});await type_('Not recorded');
  await waitFor(async()=>(await query('history.record')).filter(shown).length===1||null);
  assert(!(await visible('history.record.view')).focusable&&!(await visible('history.record.export')).focusable,'unrecorded sessions expose disabled view and export');
  await cap('not-recorded');
  await clickTestId('history.search');await key('a',{cmd:true});await key('backspace');
  assert((await clickTestId('history.filter.local')).ok);
  await waitFor(async()=>(await query('history.record')).filter(shown).length===1||null);
  assert((await query('history.record.title')).filter(shown).some(n=>text(n).includes('Original local title')));
  await clickTestId('history.filter.all');await clickTestId('history.search');await type_('no-match');
  await waitFor(async()=>(await query('history.empty')).some(n=>shown(n)&&text(n).includes('没有匹配'))||null);
  await key('a',{cmd:true});await type_('Deleted');
  await waitFor(async()=>(await query('history.record')).filter(shown).length===1||null);
  await key('down');assert.equal((await focused()).test_id,'history.record.view');await key('enter');
  await visible('terminal.history.card');
  const readingTitle=await visible('terminal.history.title'),[readingIcon,readingText]=readingTitle.children;
  assert.equal(readingIcon.rect.w,16);assert(readingText.rect.x>=readingIcon.rect.x+16&&readingText.rect.y<readingIcon.rect.y+readingIcon.rect.h&&readingIcon.rect.y<readingText.rect.y+readingText.rect.h,'history bar icon and caption share one line');
  await waitFor(async()=>!(await query('history.panel')).some(shown)||null);
  await waitFor(async()=>(await query('terminal.row')).filter(shown).some(n=>text(n).includes('END_WITNESS'))||null);
  assert((await query('terminal.history.notice')).some(n=>shown(n)&&text(n).includes('旧版记录')));
  await type_('FORBIDDEN_INPUT');await key('enter');assert(!(await query('terminal.row')).some(n=>text(n).includes('FORBIDDEN_INPUT')));
  const track=await visible('terminal.history.track');assert((await clickAt(track.rect.x+2,track.rect.y+track.rect.h/2)).ok);
  await waitFor(async()=>(await query('terminal.row')).filter(shown).some(n=>text(n).includes('BEGIN_WITNESS'))||null);
  const firstPosition=text(await visible('terminal.history.position'));
  const row=await visible('terminal.row');await scrollAt(row.rect.x+150,row.rect.y+40,0,-80);
  await waitFor(async()=>text(await visible('terminal.history.position'))!==firstPosition||null);
  await key('f',{cmd:true});await visible('terminal.search');await type_('line-080');
  await waitFor(async()=>(await query('terminal.row')).filter(shown).some(n=>text(n).includes('line-080'))||null);
  await key('escape');await key('escape');await visible('terminal.history.card');
  await cap('archive');
  await clickTestId('toolbar.history');await waitFor(async()=>(await query('history.record')).filter(shown).length===recordCount||null);
  await clickTestId('history.record.view');await waitFor(async()=>!(await query('history.panel')).some(shown)||null);
  assert.equal((await query('tabs.tab.1')).filter(shown).length,1);assert.equal((await query('tabs.tab.2')).filter(shown).length,0);
  await resizeWindow(860,480);const compact=await visible('terminal.history.card');assert.equal(compact.rect.h,44);assert(compact.rect.x>=0&&compact.rect.x+compact.rect.w<=860);
  await cap('archive-compact');
  await clickTestId('toolbar.history');const compactPanel=await visible('history.panel');assert(compactPanel.rect.y>=0&&compactPanel.rect.y+compactPanel.rect.h<=480);
  await cap('list-compact');await key('escape');
  await clickTestId('toolbar.history');await waitFor(async()=>(await query('history.record')).filter(shown).length===recordCount||null);
  await clickTestId('history.filter.local');await waitFor(async()=>(await query('history.record')).filter(shown).length===1||null);await clickTestId('history.record.view');
  await waitFor(async()=>(await query('terminal.command.output')).filter(shown).some(n=>text(n).includes('RECORDED_COMMAND 中文'))||null);
  assert((await query('tabs.strip')).some(n=>text(n).includes('Original local title')));
  await waitFor(async()=>(await query('terminal.row')).filter(shown).some(n=>text(n).includes('TRUECOLOR_MARK'))||null);
  const manifestRow=(await query('terminal.row')).filter(shown).find(n=>text(n).includes('LOCAL_ARCHIVE_DEFAULT'))!;
  assert.equal(manifestRow.rect.h,24,'recorded 16px font and 1.5 line height remain intact');
  await waitFor(async()=>((await query('terminal.timestamp')).filter(shown).length>0)===timestamps||null);
  const recordedTimes=(await query('terminal.timestamp')).filter(shown).map(text);
  const manifestBefore=await readFile(join(data,'logs/history/local.session.json'),'utf8');
  await cap('manifest-command');
  report.checks.push(`${theme}: archive timestamp visibility follows global ${timestamps} over recorded ${!timestamps}`);
  if(theme==='dark'){
   const position=text(await visible('terminal.history.position'));
   for(const enabled of [false,true]){
    await clickTestId('toolbar.settings');await clickTestId('settings.nav.appearance');
    if(!(await query('settings.toggle.timestamp_gutter')).some(shown))await clickTestId('settings.appearance.aids.header');
    await visible('settings.toggle.timestamp_gutter');assert((await clickTestId('settings.toggle.timestamp_gutter')).ok);
    assert((await clickTestId('settings.save')).ok);
    await waitFor(async()=>new RegExp(`timestamp_gutter\\s*=\\s*${enabled}`).test(await readFile(join(data,'config.toml'),'utf8'))||null,10000);
    await clickTestId('settings.close');
    await waitFor(async()=>((await query('terminal.timestamp')).filter(shown).length>0)===enabled||null);
    assert.equal(text(await visible('terminal.history.position')),position,'timestamp toggle retains reading position');
    const row=(await query('terminal.row')).filter(shown).find(n=>text(n).includes('LOCAL_ARCHIVE_DEFAULT'))!;
    assert.equal(row.rect.h,24,'timestamp toggle preserves recorded font and line height');
    if(enabled){assert.equal(row.rect.x,manifestRow.rect.x);assert.deepEqual((await query('terminal.timestamp')).filter(shown).map(text),recordedTimes,'timestamps keep their recorded values');}
    else assert(row.rect.x<manifestRow.rect.x,'hiding timestamps reclaims the gutter');
    await cap('archive-timestamps-'+enabled);
   }
   assert.equal(await readFile(join(data,'logs/history/local.session.json'),'utf8'),manifestBefore,'display changes do not rewrite the recording');
   report.checks.push('Global timestamp Save updates an open archive immediately in both directions without moving the reading position or changing recorded times/typography');
   const recordedPosition=text(await visible('terminal.history.position'));
   for(const nextTheme of ['light','sauber','dark']){
    const tab=await visible('tabs.tab.2'),x=tab.rect.x+tab.rect.w/2,y=tab.rect.y+tab.rect.h/2;
    assert((await request('POST','/mouse_down',{x,y,button:'right'})).ok);assert((await request('POST','/mouse_up',{x,y,button:'right'})).ok);
    await visible('context.menu.open_theme');assert((await clickTestId('context.menu.open_theme')).ok);
    await visible('status.theme');assert((await clickTestId('status.theme.item.'+nextTheme)).ok);
    await waitFor(async()=>new RegExp(`theme\\s*=\\s*"${nextTheme}"`).test(await readFile(join(data,'config.toml'),'utf8'))||null,10000);
    await key('escape');await visible('terminal.command.output');
    assert.equal(text(await visible('terminal.history.position')),recordedPosition,'theme switch retains the original reading position');
    const retained=(await query('terminal.row')).filter(shown).find(n=>text(n).includes('LOCAL_ARCHIVE_DEFAULT'))!;
    assert.equal(retained.rect.h,24,'theme switch does not change recorded typography');
    assert.equal(retained.rect.x,manifestRow.rect.x,'theme switch preserves the current timestamp gutter and recorded layout');
    await cap('manifest-theme-'+nextTheme);
   }
  }
  await clickTestId('toolbar.history');await clickTestId('history.search');await type_('Broken');await waitFor(async()=>(await query('history.record')).filter(shown).length===1||null);await clickTestId('history.record.view');
  await waitFor(async()=>(await query('history.message')).filter(shown).some(n=>text(n).includes('损坏'))||null);
  const failedPanel=await visible('history.panel');assert(failedPanel.rect.y+failedPanel.rect.h<=480);assert.equal((await query('tabs.tab.3')).filter(shown).length,0);await cap('corrupt-keeps-list');await key('escape');
  await clickTestId('toolbar.history');
  await clickTestId('history.search');await type_('Broken');
  await waitFor(async()=>(await query('history.record')).filter(shown).length===1||null);
  await clickTestId('history.record.delete');await visible('history.confirmation');assert(!(await visible('history.record.view')).focusable,'row actions pause while deletion is awaiting confirmation');await cap('delete-confirm');
  await key('escape');await waitFor(async()=>!(await query('history.confirmation')).some(shown)||null);assert((await query('history.panel')).some(shown),'Esc only cancels confirmation');
  assert((await readFile(join(data,'logs/history/broken.cast'),'utf8'))==='not a cast');
  await clickTestId('history.record.delete');await clickTestId('history.delete.confirm');
  await waitFor(async()=>(await query('history.empty')).some(shown)||null);
  assert(!(await readFile(join(data,'logs/history/index.tsv'),'utf8')).includes('broken.cast'),'single deletion commits index');assert(!(await query('history.message')).some(shown),'successful deletion leaves no persistent message');
  await clickTestId('history.search');await key('a',{cmd:true});await key('backspace');
  await clickTestId('history.filter.ssh');
  await waitFor(async()=>(await query('history.record')).filter(shown).length===recordCount-2||null);
  const beforeConfirm=await visible('history.panel'),clear=await visible('history.clear');await clickTestId('history.clear');const bubble=await visible('history.confirmation');assert.equal(bubble.rect.w,288);assert(bubble.rect.h<150,'confirmation stays compact');assert(Math.abs(bubble.rect.x+bubble.rect.w-clear.rect.x-clear.rect.w)<2,'bubble aligns with its action');assert.equal((await visible('history.panel')).rect.h,beforeConfirm.rect.h,'confirmation does not shift list layout');await cap('clear-confirm');
  // A session arriving after confirmation must survive the frozen clear set.
  await writeFile(join(data,'logs/history/late.cast'),cast);
  const indexBefore=await readFile(join(data,'logs/history/index.tsv'),'utf8');
  await writeFile(join(data,'logs/history/index.tsv'),indexBefore+`999\t${started+1}\t${started+2}\t1\t0\tLate archive\tfixture\tlogs/history/late.cast\tssh\t909\n`);
  await clickTestId('history.delete.confirm');
  await waitFor(async()=>(await query('history.record.title')).filter(shown).some(n=>text(n).includes('Late archive'))||null);
  const indexAfter=await readFile(join(data,'logs/history/index.tsv'),'utf8');
  assert(indexAfter.includes('late.cast')&&indexAfter.includes('local.cast'),'filtered clear preserves later records and other types');
  assert(!indexAfter.includes('earlier-'),'filtered clear removes all confirmed matching records');
  assert(indexAfter.includes('review.cast'),'an open history tab protects its recording from deletion');
  await cap('cleared-filter');await key('escape');
  assert((await request('POST','/zerowork/windows',{action:'quit'})).ok);
  await Promise.race([exited,new Promise((_,reject)=>setTimeout(()=>reject(new Error('normal App Quit timed out')),15000))]);
  assert.equal(child.exitCode,0,'readonly history App Quit must exit normally');assert.equal(child.signalCode,null);
  report.exits.push({theme,code:child.exitCode,signal:child.signalCode,normal:true});
  report.checks.push(`${theme} (material T=${materialT}): empty history and global entry work with zero sessions/deleted host; explicit View (row click never opens), content-based export availability (normal/fragment/unrecorded), delete confirmation/cancel, filtered frozen clear preserving later sessions; metadata filters/search/keyboard focus, long original titles, full-height search focus and final list row; recorded typography unchanged (terminal color pixels are checked separately); original readonly renderer; real wheel/track/search synchronisation; dedup; 860×480 controls remain reachable.`);
 }catch(error){report.ok=false;report.error=String(error);try{await cap('failure');}catch{}throw error;}
 finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');await exited;await log.close();await rm(isolated,{recursive:true,force:true});}
}
report.listControlsOk=true;
if(process.argv.includes('--list-controls')){report.ok=true;report.pixelCheckSkipped='Terminal ANSI pixel comparison is outside the history list controls check';}
else try{report.pixels=JSON.parse(execFileSync('python3',[resolve('e2e/global_history_theme_pixels.py'),out],{encoding:'utf8'}));report.ok=true;}
catch(error){report.ok=false;report.error=String(error);await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));throw error;}
await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
