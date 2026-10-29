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
 await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n[ui.materials]\nblur_px=0\n[ui.materials.background]\ntransparency=${materialT}\n`);
 await writeFile(join(data,'hosts.toml'),'[registry]\nschema_version=2\nrevision=1\nnext_connection_id=1\nnext_group_id=1\n');
 const started=Date.now()-60000;
 const extraCount=12,recordCount=3+extraCount;
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
 const localManifest={schema_version:1,archive_key:'1234567890abcdef1234567890abcdef',recording_id:'abcdef1234567890abcdef1234567890',manifest_revision:1,source_kind:'local',started_ms:started-60000,ended_ms:started-30000,exit_code:0,state:'closed',display:{title:'Original local title',host:'Local Terminal',user:'fixture',endpoint:'local zsh',cwd:'/archive/original',final_cols:80,final_rows:24,timestamps:true,layout_version:1,font_family:'Menlo',font_size_px:16,line_height:1.5,theme_reference:'dark',colors:{foreground:0xe0e0e0ff,background:0x101018ff,cursor:0xe0e0e0ff,selection:0x6366f14d,ansi:palette}},recording:{generations:[{recording_generation:1,session_id:2,session_generation:1,initial_cols:80,initial_rows:24,receive_time_origin:started-60000,baselines:[{event_sequence:0,raw_offset:0,kind:'initial_empty'}]}]},files:[{path:'logs/history/local.cast',kind:'cast',committed_length:Buffer.byteLength(localCast),checksum:createHash('sha256').update(localCast).digest('hex')}],coverage:'complete',replayability:'verified',commit:{state:'indexed',committed_length:Buffer.byteLength(localCast)}};
 await writeFile(join(data,'logs/history/local.session.json'),JSON.stringify(localManifest));
 const staging=join(isolated,'staged-history');await mkdir(staging);
 for(const name of await readdir(join(data,'logs/history')))await rename(join(data,'logs/history',name),join(staging,name));
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,`${theme}.log`),'w');
 const child=spawn(binary,[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
 const exited=new Promise(r=>child.once('close',r));
 const cap=async(name:string)=>{await mouseMove(20,20);const captured:any={};for(const id of ['history.panel','history.search','history.footer','history.viewport','history.record','terminal.history.card','terminal.history.title','terminal.history.position','terminal.history.notice','terminal.row','terminal.command.record','terminal.command.output','terminal.command.article','tabs.strip'])captured[id]=await query(id);await writeFile(join(out,`${theme}-${name}.tree.json`),JSON.stringify(captured,null,2));assert((await screenshot(join(out,`${theme}-${name}.png`))).ok);report.captures.push(`${theme}-${name}`);};
 try{
  await waitForServerReady();await resizeWindow(1440,900);
  await visible('workspace.empty');assert((await clickTestId('toolbar.history')).ok);
  await waitFor(async()=>(await query('history.empty')).some(n=>shown(n)&&text(n).includes('还没有会话历史'))||null);await cap('empty');await key('escape');
  for(const name of await readdir(staging))await rename(join(staging,name),join(data,'logs/history',name));
  assert((await clickTestId('toolbar.history')).ok);
  const panel=await visible('history.panel');assert.equal(panel.rect.w,440);
  await waitFor(async()=>(await query('history.record')).filter(shown).length===recordCount||null);
  const field=await visible('history.search');assert.equal(field.rect.h,36,'full-height native Input hit target');
  const firstRow=await visible('history.record'),firstTitle=await visible('history.record.title'),glyph=firstRow.children[0];
  assert(firstTitle.rect.x>glyph.rect.x+glyph.rect.w&&firstTitle.rect.y<glyph.rect.y+glyph.rect.h&&glyph.rect.y<firstTitle.rect.y+firstTitle.rect.h,'record icon and title share the first line');
  assert(firstTitle.rect.x+firstTitle.rect.w<=firstRow.rect.x+firstRow.rect.w,'long title remains within its row');
  await cap('list');
  await key('up');assert.equal((await focused()).test_id,'history.record');
  const viewport=await visible('history.viewport'),lastRow=(await query('history.record')).filter(shown).at(-1)!;
  assert(lastRow.rect.y>=viewport.rect.y-1&&lastRow.rect.y+lastRow.rect.h<=viewport.rect.y+viewport.rect.h+1,'keyboard reaches the final complete list row');
  const foot=await visible('history.footer');assert(foot.rect.y>=viewport.rect.y+viewport.rect.h,'footer stays outside list scrolling');
  await cap('list-bottom');
  const descendants=(n:any):number[]=>[n.id,...(n.children||[]).flatMap(descendants)];
  const focusIds=new Set(descendants(await visible('history.panel')));
  for(let i=0;i<10;i++){await key('tab');assert(focusIds.has((await focused()).id),'Tab must remain within real history controls');}
  await clickTestId('history.search');
  assert((await clickTestId('history.filter.local')).ok);
  await waitFor(async()=>(await query('history.record')).filter(shown).length===1||null);
  assert((await query('history.record.title')).filter(shown).some(n=>text(n).includes('Original local title')));
  await clickTestId('history.filter.all');await clickTestId('history.search');await type_('no-match');
  await waitFor(async()=>(await query('history.empty')).some(n=>shown(n)&&text(n).includes('没有匹配'))||null);
  await key('a',{cmd:true});await type_('Deleted');
  await waitFor(async()=>(await query('history.record')).filter(shown).length===1||null);
  await key('down');assert.equal((await focused()).test_id,'history.record');await key('enter');
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
  await clickTestId('history.record');await waitFor(async()=>!(await query('history.panel')).some(shown)||null);
  assert.equal((await query('tabs.tab.1')).filter(shown).length,1);assert.equal((await query('tabs.tab.2')).filter(shown).length,0);
  await resizeWindow(860,480);const compact=await visible('terminal.history.card');assert.equal(compact.rect.h,44);assert(compact.rect.x>=0&&compact.rect.x+compact.rect.w<=860);
  await cap('archive-compact');
  await clickTestId('toolbar.history');const compactPanel=await visible('history.panel');assert(compactPanel.rect.y>=0&&compactPanel.rect.y+compactPanel.rect.h<=480);
  await cap('list-compact');await key('escape');
  await clickTestId('toolbar.history');await waitFor(async()=>(await query('history.record')).filter(shown).length===recordCount||null);
  await clickTestId('history.filter.local');await waitFor(async()=>(await query('history.record')).filter(shown).length===1||null);await clickTestId('history.record');
  await waitFor(async()=>(await query('terminal.command.output')).filter(shown).some(n=>text(n).includes('RECORDED_COMMAND 中文'))||null);
  assert((await query('tabs.strip')).some(n=>text(n).includes('Original local title')));
  await waitFor(async()=>(await query('terminal.row')).filter(shown).some(n=>text(n).includes('TRUECOLOR_MARK'))||null);
  const manifestRow=(await query('terminal.row')).filter(shown).find(n=>text(n).includes('LOCAL_ARCHIVE_DEFAULT'))!;
  assert.equal(manifestRow.rect.h,24,'recorded 16px font and 1.5 line height remain intact');
  await cap('manifest-command');
  if(theme==='dark'){
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
    assert.equal(retained.rect.x,manifestRow.rect.x,'theme switch preserves the recorded timestamp gutter and layout');
    await cap('manifest-theme-'+nextTheme);
   }
  }
  await clickTestId('toolbar.history');await clickTestId('history.search');await type_('Broken');await waitFor(async()=>(await query('history.record')).filter(shown).length===1||null);await clickTestId('history.record');
  await waitFor(async()=>(await query('history.message')).filter(shown).some(n=>text(n).includes('损坏'))||null);
  const failedPanel=await visible('history.panel');assert(failedPanel.rect.y+failedPanel.rect.h<=480);assert.equal((await query('tabs.tab.3')).filter(shown).length,0);await cap('corrupt-keeps-list');await key('escape');
  assert((await request('POST','/zerowork/windows',{action:'quit'})).ok);
  await Promise.race([exited,new Promise((_,reject)=>setTimeout(()=>reject(new Error('normal App Quit timed out')),15000))]);
  assert.equal(child.exitCode,0,'readonly history App Quit must exit normally');assert.equal(child.signalCode,null);
  report.exits.push({theme,code:child.exitCode,signal:child.signalCode,normal:true});
  report.checks.push(`${theme} (material T=${materialT}): empty history and global entry work with zero sessions/deleted host; metadata filters/search/Enter, long original titles, full-height search focus and final list row; current global default/indexed palette with literal RGB retained and recorded typography unchanged; original readonly renderer; real wheel/track/search synchronisation; dedup; 860×480 controls remain reachable.`);
 }catch(error){report.ok=false;report.error=String(error);try{await cap('failure');}catch{}throw error;}
 finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');await exited;await log.close();await rm(isolated,{recursive:true,force:true});}
}
try{report.pixels=JSON.parse(execFileSync('python3',[resolve('e2e/global_history_theme_pixels.py'),out],{encoding:'utf8'}));report.ok=true;}
catch(error){report.ok=false;report.error=String(error);await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));throw error;}
await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
