/** Same xterm-256color contract over actual Local PTY and loopback SSH PTY.
 * node e2e/xterm_capabilities_native.ts OUT BINARY [local|ssh] [xterm-256color|xterm|vt100]
 * An explicit type selects the independent installed-terminfo matrix fixture.
 * Public Harness input and real Metal screenshots; no direct VT feed/state routes.
 */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdir,mkdtemp,realpath,readFile,writeFile,open} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]),binary=resolve(process.argv[3]),only=process.argv[4],profile=process.argv[5],term=profile??'xterm-256color';
assert(['xterm-256color','xterm','vt100'].includes(term));
await mkdir(out,{recursive:true});
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>shown(n)?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any):string=>flat(n).map(v=>v.text??'').join('');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,20000);
const click=async(id:string)=>{const r=(await visible(id)).rect;assert((await h.clickAt(r.x+r.w/2,r.y+r.h/2)).ok)};
async function rows(){const result=[];for(let i=0;i<65;i++){const ns=await h.query('terminal.surface.row.'+i);const row=ns.find(shown);if(row){const glyphs=flat(row).filter(v=>v.tag==='text'&&v.text).sort((a,b)=>a.rect.x-b.rect.x);const sample=glyphs.find(v=>/^[\x20-\x7e]+$/.test(v.text));const cw=sample?sample.rect.w/sample.text.length:8.43;let value='',col=0;for(const glyph of glyphs){const next=Math.max(col,Math.round((glyph.rect.x-row.rect.x)/cw));value+=' '.repeat(next-col)+glyph.text;col=next+Math.round(glyph.rect.w/cw)}result.push({index:i,rect:row.rect,text:value,glyphs})}else if(result.length)break}return result;}
async function contains(value:string){return h.waitFor(async()=>{const r=await rows();return r.some(v=>v.text.includes(value))?r:null},20000);}
const readJSON=async(p:string)=>{try{return JSON.parse(await readFile(p,'utf8'))}catch{return null}};
const report:any={binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),runs:[],limits:['Harness events use the production dispatcher and actual PTYs/SSH, not physical keyboard/IME input.','PNG captures need visual review; functional assertions alone do not certify pixels.','The contract is the endpoint installed xterm-256color terminfo, plus listed modern extensions.']};
let clipboard:Buffer|undefined;
try{clipboard=execFileSync('/usr/bin/pbpaste')}catch{}
try{
for(const transport of only?[only]:['local','ssh']){
 assert(!profile||transport==='ssh'||term==='xterm-256color','Local app default stays xterm-256color; other local types use real-PTY service tests');
 const runOut=join(out,transport);await mkdir(runOut,{recursive:true});
 const iso=await realpath(await mkdtemp('/private/tmp/zw-xterm-')),data=join(iso,'data'),rpc=join(iso,'rpc'),shell=join(iso,'shell'),fixture=join(iso,'fixture');await Promise.all([mkdir(data),mkdir(rpc),mkdir(shell),mkdir(fixture)]);
 const log=await open(join(runOut,'app.log'),'w');let peer:any,peerLog:any;let app:any;
 const run:any={transport,term,iso,status:'running',checks:[],captures:[]};report.runs.push(run);
 const release=(stage:string)=>writeFile(join(fixture,stage+'.release'),'continue');
 const capture=async(name:string)=>{await h.sleep(150);assert((await h.screenshot(join(runOut,name+'.png'))).ok);await writeFile(join(runOut,name+'.rows.json'),JSON.stringify(await rows(),null,2));run.captures.push(name)};
 try{
  await writeFile(join(shell,'.zshrc'),"bindkey -e\nPS1='contract%# '\n");
  await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\nline_height=1.5\ncursor_style="bar"\ninput_line_highlight=false\ntimestamp_gutter=false\n[completion]\nenabled=false\n[ssh]\nterm="'+term+'"\n');
  if(transport==='ssh'){
   peerLog=await open(join(runOut,'peer.log'),'w');peer=spawn('python3',['e2e/builtin_records_ssh_peer.py','--out',join(iso,'peer')],{stdio:['ignore',peerLog.fd,peerLog.fd]});
   const ready=await h.waitFor(async()=>readJSON(join(iso,'peer/ready.json')),15000);await writeFile(join(data,'known_hosts'),ready.known_host);
   await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Xterm contract SSH"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
  }
  process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
  app=spawn(binary,[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
  await h.waitForServerReady(60000);assert.equal(Number((await readJSON(join(rpc,'owner.json'))).pid),app.pid);await h.resizeWindow(1440,900);
  if(transport==='local')await click('workspace.empty.local');else{const r=(await visible('sidebar.host')).rect;await h.clickAt(r.x+r.w/2,r.y+r.h/2,2)}
  await visible('terminal.surface');await h.sleep(600);
  const cmd=async(value:string)=>{await click('terminal.surface');assert((await h.type_(value)).ok);assert((await h.key('return')).ok)};
  const python=execFileSync('which',['python3'],{encoding:'utf8'}).trim();
  let readyIndex=0;const shellReady=async()=>{await h.sleep(350);const target=join(iso,'ready-'+(++readyIndex));await cmd('printf ready > '+JSON.stringify(target));await h.waitFor(async()=>{try{return await readFile(target,'utf8')==='ready'||null}catch{return null}},15000)};
  await cmd(`${JSON.stringify(python)} ${JSON.stringify(resolve(profile?'e2e/terminal_types.py':'e2e/xterm_capabilities.py'))} --out ${JSON.stringify(fixture)}${profile?' --term '+JSON.stringify(term):''}`);
  const keyMap:any={'key-up-normal':['up'],'key-up-application':['up'], 'key-down-normal':['down'],'key-right-normal':['right'],'key-left-normal':['left'],'key-down-application':['down'],'key-right-application':['right'],'key-left-application':['left'], 'key-backspace-bs':['backspace'],'key-backspace-del':['backspace'],'key-up-after-is2':['up'],'key-up-after-rs1':['up'],'key-up-after-rs2':['up'],'key-home':['home'],'key-end':['end'],'key-delete':['forward_delete'],'key-insert':['insert'],'key-pageup':['page_up'],'key-pagedown':['page_down'],'key-backtab':['tab',{shift:true}],'key-ctrl-up':['up',{ctrl:true}],'key-alt-a':['a',{alt:true}]};
  for(let i=1;i<=63;i++){const group=Math.floor((i-1)/12),number=(i-1)%12+1;keyMap['key-f'+i]=['f'+number,group===0?{}:group===1?{shift:true}:group===2?{ctrl:true}:group===3?{shift:true,ctrl:true}:group===4?{alt:true}:{alt:true,shift:true}]}
  Object.assign(keyMap,{'key-backspace':['backspace']});for(const [label,name] of Object.entries({delete:'forward_delete',end:'end',home:'home',insert:'insert',left:'left',pagedown:'page_down',pageup:'page_up',right:'right',down:'down',up:'up'}))keyMap['key-shift-'+label]=[name,{shift:true}];
  let previous='';
  for(;;){
   const state=await h.waitFor(async()=>{const s=await readJSON(join(fixture,'stage.json'));const r=await readJSON(join(fixture,'result.json'));if(r?.status==='failed')throw Error(r.error);return s&&s.name!==previous?s:null},30000);previous=state.name;
   if(state.name==='done')break;
   if(state.name==='visual'){await contains('VISUAL_DONE');await capture('01-visual');if(!profile)run.color_pixels=JSON.parse(execFileSync('python3',['e2e/xterm_pixels.py',join(runOut,'01-visual.png'),join(runOut,'01-visual.rows.json')],{encoding:'utf8'}));if(profile){const r=await rows();assert(r.some(v=>v.text.includes('┌───┐ │ └───┘ ASCII_OK')),'selected terminfo ACS must render line drawing and restore ASCII');assert(r.some(v=>v.text.includes('BOLD / UNDERLINE / REVERSE / STANDOUT /')),'declared SGR baseline')}await release('visual')}
   else if(profile&&state.name.startsWith('cursor-')){await h.sleep(200);const caret=(await h.query('terminal.surface.caret')).filter(shown);assert.equal(caret.length>0,state.name!=='cursor-civis');await release(state.name)}
   else if(state.name.startsWith('cursor-')){await contains('CURSOR_SHAPE');await h.sleep(200);const r=(await visible('terminal.surface.caret')).rect;if(state.name==='cursor-bar'||state.name==='cursor-default'){assert.equal(r.w,2);assert(r.h>10)}else if(state.name==='cursor-underline'){assert.equal(r.h,2);assert(r.w>2)}else{assert(r.w>2&&r.h>10)}await release(state.name)}
   else if(state.name==='editing'||state.name.startsWith('editing-')){await contains('EDIT_DONE');const r=await rows();for(const [row,want] of Object.entries(state.expected)){assert.equal(r.find(v=>v.index===Number(row))?.text.trimEnd(),String(want),'editing row '+row)}await capture(profile?state.name:'02-editing');await release(state.name)}
   else if(state.name==='alternate'){const r=await contains('ALTERNATE_ACTIVE');assert(!r.some(v=>v.text.includes('PRIMARY_RESTORED')));await capture('03-alternate');await release('alternate')}
   else if(state.name==='primary'){const r=await contains('PRIMARY_RESTORED');assert(!r.some(v=>v.text.includes('ALTERNATE_ACTIVE')));await capture('04-primary');await release('primary')}
   else if(keyMap[state.name]){await h.sleep(120);const [name,mods]=keyMap[state.name];assert((await h.key(name,mods)).ok)}
   else if(state.name==='paste'){await h.sleep(150);execFileSync('/usr/bin/pbcopy',{input:'paste-界🧪'});assert((await h.key('v',{cmd:true})).ok)}
   else if(state.name.startsWith('mouse-')){await h.sleep(200);const r=await h.screenPos('terminal.surface');const point={x:r.x+120,y:r.y+70,button:state.name.slice(6)};assert((await h.request('POST','/mouse_down',point)).ok);assert((await h.request('POST','/mouse_up',point)).ok)}
   else if(state.name==='wheel'){await h.sleep(200);const r=await h.screenPos('terminal.surface');assert((await h.scrollAt(r.x+120,r.y+70,0,21)).ok)}
   else if(state.name==='focus'){await h.sleep(250);await click('toolbar.settings');await h.sleep(400);await click('settings.close');await click('terminal.surface');await h.sleep(350)}
   else if(state.name==='resize'){await h.resizeWindow(1050,680);await h.sleep(650);await release('resize')}
   else if(state.name==='scroll'){await contains('SCROLL_179');const r=await h.screenPos('terminal.surface');await h.scrollAt(r.x+120,r.y+90,0,500);await h.sleep(650);const old=(await rows()).map(v=>v.text).join('\n');assert(!old.includes('SCROLL_179'));run.pinned=old;await capture('05-pinned');await release('scroll')}
   else if(state.name==='scroll-new'){await h.sleep(500);assert.equal((await rows()).map(v=>v.text).join('\n'),run.pinned,'incoming output must retain viewport');await capture('06-pinned-after');const r=await h.screenPos('terminal.surface');await h.scrollAt(r.x+120,r.y+90,0,-100000);await contains('NEW_019');await release('scroll-new')}
   else throw Error('Unknown stage '+state.name);
   run.checks.push(state.name);
  }
  run.fixture=await readJSON(join(fixture,'result.json'));if(transport==='ssh'){run.pty_request=await readJSON(join(iso,'peer/pty-request.json'));assert.equal(run.pty_request.term,term)}assert.equal(run.fixture.status,'passed');await writeFile(join(runOut,'fixture-result.json'),JSON.stringify(run.fixture,null,2));await contains('COMPATIBILITY_DONE');
  await cmd('vim -Nu NONE -n -i NONE '+JSON.stringify(join(iso,'vim.txt')));await h.sleep(600);await h.type_('i');await h.type_('VIM_界_é_🧪');await h.key('escape');await h.type_(':wq');await h.key('return');await h.waitFor(async()=>{try{return (await readFile(join(iso,'vim.txt'),'utf8')).trim()==='VIM_界_é_🧪'||null}catch{return null}});run.checks.push('real-vim-unicode-save-exit');await shellReady();
  await writeFile(join(iso,'less.txt'),Array.from({length:200},(_,i)=>'LESS_'+i.toString().padStart(3,'0')).join('\n')+'\n');await cmd('less -R '+JSON.stringify(join(iso,'less.txt')));await contains('LESS_000');await h.type_('G');await contains('LESS_199');await capture('07-less');await h.type_('q');run.checks.push('real-less-fullscreen-page-exit');await shellReady();
  await cmd('top -s 1');await contains('Processes:');await capture('08-top');await h.type_('q');run.checks.push('real-top-fullscreen-refresh-exit');await shellReady();
  if(process.env.ZW_XTERM_TMUX){const tmux=process.env.ZW_XTERM_TMUX;const socket=join(iso,'tmux.sock');await cmd(`${JSON.stringify(tmux)} -S ${JSON.stringify(socket)} -f /dev/null new-session -s contract /bin/zsh -f`);await h.sleep(700);await h.type_('printf TMUX_NATIVE_OK');await h.key('return');await contains('TMUX_NATIVE_OK');await h.key('b',{ctrl:true});await h.type_('%');await h.sleep(500);assert.equal(execFileSync(tmux,['-S',socket,'list-panes','-F','#{pane_id}'],{encoding:'utf8'}).trim().split('\n').length,2);await capture('10-tmux-split');await h.type_('exit');await h.key('return');await h.sleep(200);await h.type_('exit');await h.key('return');run.checks.push('real-tmux-split-input-exit');await shellReady()}
  if(process.env.ZW_XTERM_VTTEST){await cmd(JSON.stringify(process.env.ZW_XTERM_VTTEST)+' -l '+JSON.stringify(join(runOut,'vttest.log')));await contains('Enter choice number (0 - 12):');await h.type_('1');await h.key('return');await contains("The screen should be cleared");await capture('11-vttest-cursor');for(let n=0;n<16;n++){await h.key('return');await h.sleep(180);if((await rows()).some(v=>v.text.includes('Choose test type:')))break}await contains('Choose test type:');await h.type_('0');await h.key('return');run.checks.push('vttest-cursor-control-screens');await shellReady()}
  await cmd('printf CONTRACT_SHELL_RESTORED');await contains('CONTRACT_SHELL_RESTORED');await capture('09-restored');run.status='passed';delete run.pinned;
 }catch(e){run.status='failed';run.error=String(e);await capture('failure').catch(()=>{});throw e}
 finally{
  if(app&&app.exitCode===null){app.kill('SIGTERM');await Promise.race([new Promise(r=>app.once('close',r)),h.sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await new Promise(r=>app.once('close',r))}}
  if(peer){peer.kill('SIGTERM');await new Promise(r=>peer.once('close',r));await peerLog.close()}
  await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
 }
}
report.status='passed';
}finally{if(clipboard)execFileSync('/usr/bin/pbcopy',{input:clipboard});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2))}
console.log(JSON.stringify(report.runs.map((r:any)=>({transport:r.transport,status:r.status,checks:r.checks.length}))));
