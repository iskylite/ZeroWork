// Editable local prototype. No terminal, SSH or clipboard source is read.
const $ = id => document.getElementById(id);
const icons = {
  terminal:'<path d="m4 5 5 7-5 7m8 0h8"/>',server:'<rect x="3" y="3" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="7" rx="2"/><path d="M7 6h.01M7 17h.01"/>',
  x:'<path d="m6 6 12 12M18 6 6 18"/>',plus:'<path d="M12 5v14M5 12h14"/>',clock:'<circle cx="12" cy="12" r="8"/><path d="M12 7v5l3 2"/>',
  'list-clock':'<path d="M4 5h15M4 10h8M4 15h5"/><circle cx="16" cy="16" r="5"/><path d="M16 13v3l2 1"/>',
  'panel-left':'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/>',
  sparkles:'<path d="m12 3 2.4 6.6L21 12l-6.6 2.4L12 21l-2.4-6.6L3 12l6.6-2.4ZM20 2v4m-2-2h4"/>',
  search:'<circle cx="10" cy="10" r="6"/><path d="m15 15 5 5"/>',transfer:'<path d="M8 3v16m-4-4 4 4 4-4M16 21V5m-4 4 4-4 4 4"/>',
  settings:'<path d="m9 3 1 3h4l1-3 3 2-1 3 2 3h3v3l-3 1-2 3 1 3-3 1-2-3h-3l-2 3-3-2 1-3-2-3-3-1v-3h3l2-3-1-3Z"/><circle cx="12" cy="12" r="3"/>',
  network:'<rect x="8" y="2" width="8" height="6" rx="1"/><rect x="2" y="16" width="7" height="6" rx="1"/><rect x="15" y="16" width="7" height="6" rx="1"/><path d="M12 8v4H5v4m7-4h7v4"/>',
  plug:'<path d="M8 3v5m8-5v5M6 8h12v4a6 6 0 0 1-12 0ZM12 18v4"/>',palette:'<path d="M20 13a8.5 8.5 0 1 0-8 8h2a2 2 0 0 0 1-4c-2-1-1-4 1-4Z"/><path d="M7 9h.01M10 6h.01M15 7h.01M6 13h.01"/>',
  check:'<path d="m5 12 4 4L19 6"/>',failed:'<path d="m7 7 10 10M17 7 7 17"/>',running:'<path d="M12 3a9 9 0 1 1-6.4 2.6"/><path d="M3 3h4v4"/>',copy:'<rect x="8" y="8" width="12" height="13" rx="2"/><path d="M16 8V3H3v13h5"/>'
};
const icon = name => `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name] || icons.terminal}</svg>`;
const escapeHtml = value => value.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
document.querySelectorAll('[data-icon]').forEach(el => el.innerHTML = icon(el.dataset.icon) + el.innerHTML);
const commands = [
 {id:1,time:'10:24:10',command:'cd /srv/zerowork',duration:'12 ms',code:0,status:'success',ai:false},
 {id:2,time:'10:24:12',command:'git status --short',duration:'38 ms',code:0,status:'success',ai:false},
 {id:3,time:'10:24:19',command:'nginx -t -c /srv/zerowork/config/nginx.conf',duration:'46 ms',code:1,status:'failed',ai:false},
 {id:4,time:'10:25:02',command:'python3 tools/check_routes.py --config /srv/zerowork/config/routes/staging-2026-10-30.yaml --endpoint https://staging.example.test/api/v1/health --timeout 8 --format json',duration:'1.2 s',code:0,status:'success',ai:true},
 {id:5,time:'10:25:18',command:'python3 tools/check_routes.py --watch',duration:'18 s',code:null,status:'running',ai:true}
];
const history = $('command-history');
let mode = new URLSearchParams(location.search).get('mode') === 'local' ? 'local' : 'ssh';
let openMode = 'closed', peekArmed = true, hideTimer, feedbackTimer;
const states = {ssh:{open:'closed',takeover:false},local:{open:'closed',takeover:false}};
const rows = [];
let preferences={global:true,host:null};
try{const stored=JSON.parse(localStorage.getItem('zw-terminal-info-preview')||'null');if(stored&&typeof stored.global==='boolean'&&(stored.host===null||typeof stored.host==='boolean'))preferences=stored;}catch{}
let dialogType='global',draftGlobal=true;
const metadataVisible=()=>mode==='local'?preferences.global:(preferences.host??preferences.global);
function renderMetadata(){
 const layer=$('command-metadata-layer');layer.hidden=!metadataVisible();
 layer.innerHTML=commands.map(c=>`<span class="command-metadata" data-meta="${c.id}">${c.ai?'<span class="meta-ai">AI</span>':''}<span class="meta-code ${c.status}">${icon(c.status==='success'?'check':c.status)}${c.code===null?'—':c.code}</span><span>${c.duration}</span></span>`).join('');
}

function row(text,time='',command=null,kind='output',html=null){rows.push({text,time,command,kind,html});}
function renderTerminal(){
 rows.length=0;
 const prompt = mode==='ssh'?'ops@staging-01':'sky@MacBook';
 const prefix = cwd => `${prompt} ${cwd} $ `;
 row('Last login: Fri Oct 30 10:24:06 2026','','','note');row('');
 row(prefix('~')+commands[0].command,commands[0].time,commands[0]);row('');
 row(prefix('zerowork')+commands[1].command,commands[1].time,commands[1]);
 row(' M config/nginx.conf','10:24:12');row(' M config/routes.json','10:24:12');row('');
 row(prefix('zerowork')+commands[2].command,commands[2].time,commands[2]);
 row('nginx: [emerg] unknown directive "proxy_timeuot"','10:24:19',null,'output','<span class="ansi-red">nginx: [emerg] unknown directive "proxy_timeuot"</span>');
 row('       in /srv/zerowork/config/nginx.conf:42','10:24:19');row('nginx: configuration file /srv/zerowork/config/nginx.conf test failed','10:24:19');row('');
 row(prefix('zerowork')+commands[3].command,commands[3].time,commands[3]);
 row('{"healthy":true,"routes":4,"latency_ms":24}','10:25:03');row('');
 row(prefix('zerowork')+commands[4].command,commands[4].time,commands[4]);
 row('Watching 4 routes · press Ctrl-C to stop','10:25:18');row('');
 row('200  GET /health          12 ms','10:25:18');row('200  GET /api/version     24 ms','10:25:18');row('200  GET /api/status      19 ms','10:25:18');row('504  GET /api/reports   5001 ms','10:25:18');row('200  GET /health          10 ms','10:25:23');row('200  GET /api/version     21 ms','10:25:23');row('');
 $('terminal-text').innerHTML=rows.map((r,i)=>`<span class="vt-line" data-row="${i}" data-kind="${r.kind}" ${r.command?`id="command-${r.command.id}" data-command="${r.command.id}"`:''}>${r.html||escapeHtml(r.text)}\n</span>`).join('')+'<span class="terminal-caret" aria-hidden="true"></span>';
 $('terminal-gutter').innerHTML=rows.map((r,i)=>!r.time?'':`<div class="gutter-row" data-for-row="${i}">${r.command?`<button class="gutter-mark ${r.command.status}" data-detail="${r.command.id}" aria-label="命令 ${r.command.id} 详情">${icon(r.command.status==='success'?'check':r.command.status)}</button>`:'<span class="gutter-mark blank"></span>'}<time>${r.time}</time></div>`).join('');
 $('terminal-pane').setAttribute('aria-label',mode==='ssh'?'SSH 终端':'本地 zsh 终端');
 $('connection-label').textContent=mode==='ssh'?'SSH 已连接':'本地 zsh';$('latency').textContent=mode==='ssh'?'18 ms':'';$('history-session').textContent=mode==='ssh'?'staging-01':'本地终端';
 $('ai-control').hidden=states[mode].takeover;
 document.querySelectorAll('[data-mode]').forEach(el=>{el.classList.toggle('active',el.dataset.mode===mode);el.classList.toggle('selected',el.dataset.mode===mode);if(el.role==='tab')el.setAttribute('aria-selected',String(el.dataset.mode===mode));});
 renderHistory();renderMetadata(); requestAnimationFrame(layoutGutter);
}
function layoutGutter(){
 const docRect=$('terminal-document').getBoundingClientRect(),text=$('terminal-text'),first=text.firstElementChild;
 const fontInset=first?first.getBoundingClientRect().top-text.getBoundingClientRect().top:0;
 document.querySelectorAll('.gutter-row').forEach(el=>{const line=document.querySelector(`[data-row="${el.dataset.forRow}"]`);el.style.top=`${line.getBoundingClientRect().top-docRect.top-fontInset}px`;});
 document.querySelectorAll('[data-meta]').forEach(el=>{const line=$(`command-${el.dataset.meta}`);el.style.top=`${line.getBoundingClientRect().top-docRect.top-fontInset}px`;});
}
function renderHistory(){
 $('history-list').innerHTML=commands.map(c=>`<button class="history-row ${c.status}" data-jump="${c.id}" aria-label="定位命令 ${c.id}">${icon(c.status==='success'?'check':c.status)}<span class="history-row-body"><span class="history-command">${escapeHtml(c.command)}</span><span class="history-meta"><time>${c.time}</time><span>${c.duration}</span><span class="spacer"></span>${c.ai?'<span class="history-ai">AI</span>':''}${c.code===null?'<span class="history-running">运行中</span>':`<span class="history-code ${c.status}" title="退出码 ${c.code}" aria-label="退出码 ${c.code}">${icon(c.code===0?'check':'failed')}${c.code}</span>`}</span></span></button>`).join('');
}
function setHistory(next){clearTimeout(hideTimer);openMode=next;states[mode].open=next==='pinned'?'pinned':'closed';history.hidden=next==='closed';history.dataset.open=next;$('open-history').setAttribute('aria-expanded',String(next!=='closed'));$('history-menu-label').textContent=next==='closed'?'显示命令历史':'隐藏命令历史';$('command-detail').hidden=true;}
function closeHistory(){setHistory('closed');peekArmed=false;}
function feedback(text){$('feedback').textContent=text;clearTimeout(feedbackTimer);feedbackTimer=setTimeout(()=>$('feedback').textContent='',1800);}
function jump(id){document.querySelectorAll('.located').forEach(el=>el.classList.remove('located'));const line=$(`command-${id}`);line.classList.add('located');line.scrollIntoView({block:'center',behavior:'instant'});document.querySelectorAll('[data-jump]').forEach(el=>el.classList.toggle('selected',el.dataset.jump===id));}
function showDetail(id,anchor){const c=commands.find(c=>c.id===Number(id)),el=$('command-detail'),pane=$('terminal-pane').getBoundingClientRect(),a=anchor.getBoundingClientRect();el.innerHTML=`<div class="detail-command">${escapeHtml(c.command)}</div><div class="detail-facts"><time>${c.time}</time><span>${c.duration}</span>${c.ai?'<span class="history-ai">AI</span>':''}<span>${c.code===null?'运行中':`code ${c.code}`}</span></div>`;el.hidden=false;el.style.left=`${Math.min(a.right-pane.left+8,pane.width-300)}px`;el.style.top=`${Math.min(a.top-pane.top,pane.height-el.offsetHeight-48)}px`;}
$('terminal-gutter').addEventListener('pointerover',e=>{const b=e.target.closest('[data-detail]');if(b)showDetail(b.dataset.detail,b);});
$('terminal-gutter').addEventListener('pointerout',e=>{if(!e.relatedTarget?.closest?.('[data-detail]'))$('command-detail').hidden=true;});
$('terminal-gutter').addEventListener('click',e=>{const b=e.target.closest('[data-detail]');if(b){setHistory('pinned');jump(b.dataset.detail);}});
$('open-history').addEventListener('click',()=>{if(openMode==='pinned')closeHistory();else setHistory('pinned');});
$('close-history').addEventListener('click',closeHistory);
$('history-list').addEventListener('click',e=>{const b=e.target.closest('[data-jump]');if(b){if(openMode==='peek')setHistory('pinned');jump(b.dataset.jump);}});
$('takeover').addEventListener('click',()=>{states[mode].takeover=true;$('ai-control').hidden=true;feedback('已接管输入');});
document.querySelectorAll('[data-mode]').forEach(el=>el.addEventListener('click',()=>{mode=el.dataset.mode;renderTerminal();setHistory(states[mode].open);$('terminal-scroll').scrollTop=0;}));
$('sidebar-toggle').addEventListener('click',()=>{const sidebar=document.querySelector('.host-sidebar');sidebar.hidden=!sidebar.hidden;$('sidebar-toggle').setAttribute('aria-label',sidebar.hidden?'显示主机与连接':'隐藏主机与连接');requestAnimationFrame(layoutGutter);});
function leaveHistoryPreview(){if(openMode==='peek'){clearTimeout(hideTimer);hideTimer=setTimeout(()=>setHistory('closed'),140);}}
// A history preview must not interrupt terminal text selection or dragging.
$('open-history').addEventListener('pointerenter',e=>{clearTimeout(hideTimer);const selection=getSelection(),selecting=selection.rangeCount>0&&!selection.isCollapsed&&selection.getRangeAt(0).intersectsNode($('terminal-text'));if(openMode==='closed'&&e.buttons===0&&!selecting)setHistory('peek');});
$('open-history').addEventListener('pointerleave',leaveHistoryPreview);
history.addEventListener('pointerenter',()=>clearTimeout(hideTimer));
history.addEventListener('pointerleave',leaveHistoryPreview);
document.addEventListener('keydown',e=>{if(e.metaKey&&e.shiftKey&&!e.altKey&&!e.ctrlKey&&e.key.toLowerCase()==='b'){e.preventDefault();if(openMode==='pinned')closeHistory();else setHistory('pinned');}});
function openMiddleMenu(e){e.preventDefault();$('command-detail').hidden=true;const menu=$('middle-menu'),p=$('terminal-pane').getBoundingClientRect();menu.hidden=false;menu.style.left=`${Math.max(8,Math.min(e.clientX-p.left,p.width-menu.offsetWidth-8))}px`;menu.style.top=`${Math.max(8,Math.min(e.clientY-p.top,p.height-menu.offsetHeight-8))}px`;}
$('terminal-scroll').addEventListener('mousedown',e=>{if(e.button===1)openMiddleMenu(e);});$('terminal-scroll').addEventListener('auxclick',e=>{if(e.button===1)e.preventDefault();});
$('history-menu-action').addEventListener('click',()=>{if(openMode==='closed')setHistory('pinned');else closeHistory();$('middle-menu').hidden=true;});
$('copy-output').addEventListener('click',async()=>{await navigator.clipboard.writeText($('terminal-text').textContent);$('middle-menu').hidden=true;feedback('已复制终端输出');});
function openBuiltin(){ $('middle-menu').hidden=true;$('builtin-palette').hidden=false;$('builtin-input').value='@';$('builtin-input').focus(); }
$('builtin-menu-action').addEventListener('click',openBuiltin);
function executeBuiltin(value){if(value==='@history'||value==='@history on'){setHistory('pinned');}else if(value==='@history off'){closeHistory();}else{feedback('原型支持 @history on / @history off');return;}$('builtin-palette').hidden=true;}
$('builtin-input').addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();executeBuiltin(e.target.value.trim());}});
document.querySelectorAll('[data-builtin]').forEach(b=>b.addEventListener('click',()=>executeBuiltin(b.dataset.builtin)));
document.addEventListener('keydown',e=>{if(e.key==='Escape'){$('middle-menu').hidden=true;$('builtin-palette').hidden=true;$('command-detail').hidden=true;}else if(e.key==='@'&&e.target.tagName!=='INPUT'){e.preventDefault();openBuiltin();}});
document.addEventListener('pointerdown',e=>{if(!e.target.closest('.middle-menu')&&e.button!==1)$('middle-menu').hidden=true;});
// Plain terminal copying is scoped to text, even if selection crosses UI chrome.
document.addEventListener('copy',e=>{const selection=getSelection();if(!selection.rangeCount||!selection.toString())return;const original=selection.getRangeAt(0),text=$('terminal-text');if(!original.intersectsNode(text))return;const range=original.cloneRange(),all=document.createRange();all.selectNodeContents(text);if(range.compareBoundaryPoints(Range.START_TO_START,all)<0)range.setStart(all.startContainer,all.startOffset);if(range.compareBoundaryPoints(Range.END_TO_END,all)>0)range.setEnd(all.endContainer,all.endOffset);e.clipboardData.setData('text/plain',range.toString());e.preventDefault();});
new ResizeObserver(layoutGutter).observe($('terminal-text'));
renderTerminal();
const requested=new URLSearchParams(location.search).get('history');if(requested==='pinned')setHistory('pinned');
document.fonts.ready.then(layoutGutter);

$('terminal-document').addEventListener('pointermove',e=>{
 const area=$('terminal-text').getBoundingClientRect();
 document.querySelectorAll('[data-meta]').forEach(meta=>{const line=$(`command-${meta.dataset.meta}`).getBoundingClientRect();meta.dataset.hovered=String(e.clientX>=area.left&&e.clientX<=area.right&&e.clientY>=line.top&&e.clientY<=line.bottom);});
});
$('terminal-document').addEventListener('pointerleave',()=>document.querySelectorAll('[data-meta]').forEach(el=>el.dataset.hovered='false'));
document.addEventListener('selectionchange',()=>{const selection=getSelection();$('command-metadata-layer').classList.toggle('selection-active',!!selection.rangeCount&&!!selection.toString()&&selection.getRangeAt(0).intersectsNode($('terminal-text')));});
function updateEffective(){const v=$('host-info-select').value;const enabled=v==='inherit'?preferences.global:v==='on';$('effective-display').textContent=`当前：${enabled?'显示':'隐藏'}${v==='inherit'?'（继承全局）':'（此主机覆盖）'}`;}
function openSettings(type){dialogType=type;draftGlobal=preferences.global;$('settings-shade').hidden=false;$('display-dialog-title').textContent=type==='global'?'终端显示':'主机属性';$('global-options').hidden=type!=='global';$('host-options').hidden=type!=='host';$('global-info-toggle').setAttribute('aria-checked',String(draftGlobal));$('host-info-select').value=preferences.host===null?'inherit':preferences.host?'on':'off';updateEffective();}
function closeSettings(){$('settings-shade').hidden=true;}
$('display-settings').addEventListener('click',()=>openSettings('global'));
document.querySelectorAll('.host-item[data-mode="ssh"]').forEach(el=>el.addEventListener('contextmenu',e=>{e.preventDefault();openSettings('host');}));
$('global-info-toggle').addEventListener('click',()=>{draftGlobal=!draftGlobal;$('global-info-toggle').setAttribute('aria-checked',String(draftGlobal));});
$('host-info-select').addEventListener('change',updateEffective);
$('save-dialog').addEventListener('click',()=>{if(dialogType==='global')preferences.global=draftGlobal;else{const v=$('host-info-select').value;preferences.host=v==='inherit'?null:v==='on';}localStorage.setItem('zw-terminal-info-preview',JSON.stringify(preferences));renderMetadata();requestAnimationFrame(layoutGutter);closeSettings();});
$('cancel-dialog').addEventListener('click',closeSettings);$('cancel-dialog-x').addEventListener('click',closeSettings);
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!$('settings-shade').hidden)closeSettings();});
