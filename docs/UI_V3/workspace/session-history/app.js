(() => {
// History content uses the current shared global theme tokens. A recording's
// former UI theme never overrides this editable workspace; explicit terminal
// RGB is source content, not a saved UI theme. Typography/layout stay separate.
const params = new URLSearchParams(location.search);
const css = document.createElement('style');
css.textContent = `
.history-list-panel{display:flex;flex-direction:column;position:absolute;z-index:90;width:440px;max-width:calc(100% - 32px);padding:16px;background:var(--overlay);backdrop-filter:blur(var(--overlay-blur,12px));border-radius:12px;box-shadow:var(--shadow);color:var(--fg)}
.history-list-panel[hidden]{display:none}.history-list-heading{display:flex;align-items:center;gap:8px;height:26px;margin-bottom:12px}.history-list-heading>svg{width:18px;height:18px;color:var(--accent)}.history-list-heading strong{font-size:14px;font-weight:600;flex:1}.history-list-heading small{font-size:12px;color:var(--muted)}
.history-query{display:flex;gap:8px;align-items:center;padding:0 10px;background:var(--control-bg);height:36px;border-radius:8px;color:var(--muted)}.history-query:focus-within{background:var(--popup-selected)}.history-query svg{width:16px;height:16px}.history-query input{width:100%;height:36px;padding:0;background:transparent!important;box-shadow:none!important;font-size:13px}
.history-filters{display:flex;gap:4px;margin-top:10px}.history-filters button{font-size:12px;padding:5px 10px;border-radius:6px;color:var(--muted)}.history-filters button[aria-pressed=true]{background:var(--sel);color:var(--accent)}
.history-results{max-height:412px;min-height:0;flex:1;overflow:auto;margin:10px -6px 0;padding:0 6px}.history-date{font-size:12px;color:var(--muted);margin:12px 4px 6px}.history-row{display:flex;align-items:flex-start;gap:10px;width:100%;min-height:60px;padding:10px 9px;text-align:left;border-radius:8px}.history-row:hover,.history-row:focus-visible{background:var(--hover);outline:0}.history-row>svg{width:16px;height:16px;flex-shrink:0;color:var(--muted);margin-top:3px}.history-row-main{display:flex;flex-direction:column;gap:4px;flex:1;min-width:0}.history-row-head,.history-row-tail{display:flex;align-items:center;gap:12px;min-width:0}.history-row-name{flex:1;min-width:0;font-size:13px;font-weight:500;line-height:18px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--fg)}.history-row-meta{font-size:12px;color:var(--muted);line-height:17px}.history-row-time{font-size:12px;line-height:18px;color:var(--muted);white-space:nowrap}.history-row-tail>.history-row-meta{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.history-row-state{font-size:11px;color:var(--muted);white-space:nowrap;padding-top:2px}.history-list-foot{display:flex;align-items:center;gap:8px;margin-top:12px;font-size:12px;color:var(--muted)}.history-list-foot kbd{margin-left:auto;font-size:11px}.history-empty{padding:30px 12px;text-align:center;font-size:13px;color:var(--muted);line-height:22px}.history-empty strong{display:block;color:var(--fg);font-size:14px;font-weight:500}.history-list-panel button:focus-visible{outline:0;background:var(--sel)}
.history-readonly-status{color:var(--muted)}.history-readonly-status svg{color:var(--accent)}.history-readonly-tab .session-glyph{color:var(--muted)!important}.history-tab-caption{font-size:11px;color:var(--muted);margin-left:4px}.history-replay-prompt{opacity:.7}.history-list-heading,.history-query,.history-filters,.history-list-foot{flex-shrink:0}.history-list-panel .icon-btn{width:22px;height:22px}.history-menu-context{padding:8px 10px;font-size:11px;line-height:17px;color:var(--muted)}
/* The original history card remains a sibling above the terminal content card. */
.history-reading-scroll{overflow-anchor:none;overscroll-behavior:contain}.terminal-content-stack{display:flex;flex-direction:column;flex:1;min-width:0;min-height:0;gap:8px}.history-time-card{display:flex;align-items:center;gap:12px;height:44px;min-height:44px;flex-shrink:0;padding:0 14px;background:var(--panel);border:0;border-radius:11px;box-shadow:none}.history-time-card[hidden]{display:none}.history-time-title{display:flex;align-items:center;gap:6px;white-space:nowrap;font-size:12px;color:var(--muted)}.history-time-title svg{width:16px;height:16px;color:var(--accent)}.history-time-start,.history-time-end,.history-time-current{font:11px/18px var(--mono);font-variant-numeric:tabular-nums;white-space:nowrap;color:var(--muted)}.history-time-current{min-width:105px;text-align:right}.history-time-card input[type=range]{flex:1;min-width:64px;width:0;height:18px;margin:0;padding:0;accent-color:var(--accent);cursor:pointer;background:transparent;border:0;outline:0;box-shadow:none}.history-time-card input[type=range]:disabled{cursor:default;opacity:.5}.history-time-card input[type=range]:focus-visible{outline:0;background:var(--sel);border-radius:8px}.history-time-card .text-button{flex-shrink:0;font-size:12px}.app-window[data-size=compact] .history-time-start,.app-window[data-size=compact] .history-time-end{display:none}
@media(prefers-reduced-motion:no-preference){.history-list-panel{animation:history-enter 130ms ease-out}.history-row{transition:background 100ms ease-out}}@keyframes history-enter{from{opacity:0;transform:translateY(-3px)}to{opacity:1;transform:translateY(0)}}
`;
document.head.append(css);
const sourceSessions=sessions.some(s=>s.id===2)?sessions:(emptySceneSessions||sessions);
const source = structuredClone(sourceSessions.find(s=>s.id===2));
source.log = [
 {kind:'text',text:'Last login: Wed Oct 28 09:42:16 2026 from 10.0.0.8',dim:true,at:'09:42:16'},
 {kind:'shell',command:'pwd',output:'/var/www/app',at:'09:42:21'},
 {kind:'shell',command:'git log -1 --oneline',output:'8c2e91a fix: handle upstream timeout',at:'09:44:08'},
 {kind:'app',command:'@ts',output:'时间戳显示已开启。再次执行 @ts 可关闭。',state:'success',at:'09:45:12'},
 {kind:'shell',command:'systemctl status app --no-pager',output:'● app.service - Application server\n     Loaded: loaded (/etc/systemd/system/app.service; enabled)\n     Active: active (running) since Wed 2026-10-28 09:46:02 CST\n   Main PID: 18426 (app)\n      Tasks: 12 (limit: 9385)\n     Memory: 84.2M',at:'09:46:08'},
 {kind:'shell',command:'curl -I http://127.0.0.1:8080/health',output:'HTTP/1.1 200 OK\nContent-Type: application/json\nContent-Length: 15',at:'09:47:32'},
 {kind:'shell',command:'exit',output:'logout\nConnection to 10.0.1.24 closed.',at:'09:48:05'}
];
// A recorded command with enough real document rows to demonstrate natural scrolling.
source.log.splice(5,0,{kind:'shell',command:'journalctl -u app -n 48 --no-pager',at:'09:47:08',output:Array.from({length:48},(_,i)=>`Oct 28 09:46:${String(i+10).padStart(2,'0')} prod-web-01 app[18426]: request ${String(i+1).padStart(3,'0')} completed · status=200`).join('\n')});
const initialSessions=structuredClone(sourceSessions);
const records = [
 {key:'ssh-20261028-094216',name:'prod-web-01',user:'deploy',address:'10.0.1.24',source:'ssh',connection:101,date:'今天',time:'09:42–09:48',duration:'5 分 49 秒',result:'正常结束',snapshot:source},
 {key:'local-20261028-091020',name:'Local Terminal',user:'developer',address:'本地 zsh',source:'local',date:'今天',time:'09:10–09:26',duration:'16 分 12 秒',result:'exit 0',snapshot:structuredClone(sourceSessions.find(s=>s.id===1))},
 {key:'ssh-20261027-181400',name:'prod-db-02',user:'root',address:'10.0.1.28',source:'ssh',connection:102,date:'昨天',time:'18:14–18:39',duration:'25 分 03 秒',result:'连接中断',snapshot:{...structuredClone(source),name:'prod-db-02',user:'root',address:'10.0.1.28',shellHost:'prod-db-02'}},
 {key:'ssh-20261027-143100',name:'staging-api-old · production deployment session from the archived workspace',user:'deploy',address:'10.0.3.12',source:'ssh',connection:999,date:'昨天',time:'14:31–14:46',duration:'15 分 08 秒',result:'主机配置已删除',snapshot:{...structuredClone(source),name:'staging-api-old',address:'10.0.3.12',shellHost:'staging-api-old'}}
];
hosts.forEach((h,i)=>h.connectionId=i+101);
let filter='all', panelEmpty=false, panelFailed=false;
const entry=$('.title-actions [data-act="patch-history-list"]');
entry.dataset.act='patch-history-list';entry.dataset.tip='回看日志';entry.dataset.icon='history';entry.setAttribute('aria-label','回看日志');entry.setAttribute('aria-expanded','false');entry.innerHTML=icon('history');
const panel=document.createElement('section');panel.className='history-list-panel popover';panel.id='history-list-panel';panel.hidden=true;panel.setAttribute('aria-label','历史会话列表');$('#app').append(panel);
const originalRenderContent=renderContent,originalRenderTabs=renderTabs,originalRenderStatus=renderStatus,originalTabMenu=showTabMenu,originalExecute=execute;
const readingStates=new Map();
const content=$('#content'),contentStack=document.createElement('div');
contentStack.className='terminal-content-stack';content.parentNode.insertBefore(contentStack,content);contentStack.append(content);
const timeCard=document.createElement('section');timeCard.className='history-time-card';timeCard.hidden=true;timeCard.setAttribute('aria-label','日志时间滑轮');contentStack.prepend(timeCard);
function isReading(s){return !!(s?.isHistory||s?.logMode);}
function readingState(s){
 let state=readingStates.get(s.id);
 if(!state||state.owner!==s){state={owner:s,entries:structuredClone(s.log),progress:1,anchor:null};readingStates.set(s.id,state);}
 return state;
}
function historyScroll(s){return $(`#content .terminal-scroll[data-session="${s.id}"]`);}
function sourceTime(entry){return /^\d{2}:\d{2}:\d{2}$/.test(entry?.at||'')?entry.at:'--:--:--';}
// Persist a logical entry/text offset, independent of wrapping and viewport size.
function captureAnchor(scroll){
 const bounds=scroll.getBoundingClientRect(),rows=[...scroll.querySelectorAll('[data-history-row]')];
 const row=rows.find(n=>n.getBoundingClientRect().bottom>bounds.top+1)||rows.at(-1);if(!row)return null;
 const textBox=(row.querySelector('.terminal-row-content')||row).getBoundingClientRect();
 const caret=document.caretRangeFromPoint?.(Math.min(bounds.right-2,textBox.left+2),bounds.top+2);
 let textOffset=0;
 if(caret&&row.contains(caret.startContainer)){
  const prefix=document.createRange();prefix.selectNodeContents(row);prefix.setEnd(caret.startContainer,caret.startOffset);textOffset=prefix.toString().length;
 }
 return {entry:+row.dataset.historyEntry,part:+row.dataset.historyRow,textOffset,atEnd:Math.abs(scroll.scrollTop-(scroll.scrollHeight-scroll.clientHeight))<2};
}
function restoreAnchor(s,scroll){
 const anchor=readingState(s).anchor;if(!anchor)return;
 if(anchor.atEnd){scroll.scrollTop=scroll.scrollHeight;return;}
 const row=scroll.querySelector(`[data-history-entry="${anchor.entry}"][data-history-row="${anchor.part??0}"]`);if(!row)return;
 let remaining=anchor.textOffset,node;const walker=document.createTreeWalker(row,NodeFilter.SHOW_TEXT);
 while((node=walker.nextNode())){if(remaining<=node.length)break;remaining-=node.length;}
 let top=row.getBoundingClientRect().top;
 if(node){const range=document.createRange();range.setStart(node,Math.min(remaining,node.length));range.setEnd(node,Math.min(remaining+1,node.length));top=range.getBoundingClientRect().top;}
 scroll.scrollTop+=top-scroll.getBoundingClientRect().top;
}
function updateReading(s,scroll){
 const state=readingState(s),max=Math.max(0,scroll.scrollHeight-scroll.clientHeight);
 state.progress=max>1?Math.min(1,Math.max(0,scroll.scrollTop/max)):1;
 if(current()!==s)return;
 const range=timeCard.querySelector('input'),output=timeCard.querySelector('output');
 if(!range||!output)return;
 range.value=String(Math.round(state.progress*1000));range.disabled=max<=1;
 const point=scroll.getBoundingClientRect().top-scroll.scrollTop+state.progress*scroll.scrollHeight;
 let index=0;
 for(const row of scroll.querySelectorAll('[data-history-entry]')){if(row.getBoundingClientRect().top<=point+1)index=+row.dataset.historyEntry;else break;}
 const time=sourceTime(state.entries[index]);
 output.textContent=time+' · '+Math.round(state.progress*100)+'%';
 range.setAttribute('aria-valuetext',time+'，'+Math.round(state.progress*100)+'%');
 range.title=max<=1?'当前记录已完整显示，无需滚动':'拖动定位历史内容';
 scroll.dataset.historyProgress=String(state.progress);
 state.anchor=captureAnchor(scroll);scroll.dataset.historyAnchor=JSON.stringify(state.anchor);
}
function seekReading(s,fraction){
 const scroll=historyScroll(s);if(!scroll)return;
 const state=readingState(s);state.progress=Math.min(1,Math.max(0,fraction));
 scroll.scrollTop=state.progress*Math.max(0,scroll.scrollHeight-scroll.clientHeight);updateReading(s,scroll);
}
function mountTimeCard(s){
 const state=readingState(s),times=state.entries.map(sourceTime).filter(t=>t!=='--:--:--');
 timeCard.innerHTML=`<span class="history-time-title">${icon('history')}历史回溯 · 只读</span><time class="history-time-start">${esc(times[0]||'--:--:--')}</time><input id="history-reading-position" type="range" min="0" max="1000" step="1" value="${Math.round(state.progress*1000)}" aria-label="历史时间位置"><output class="history-time-current" for="history-reading-position"></output><time class="history-time-end">${esc(times.at(-1)||'--:--:--')}</time>${s.logMode?'<button class="text-button" data-act="patch-history-live">返回实时</button>':''}`;
 timeCard.hidden=false;
 timeCard.querySelector('input').addEventListener('input',e=>{seekReading(s,+e.target.value/1000);e.stopImmediatePropagation();});
}
renderContent=function(){
 const s=current(),savedState=s?.state,savedHistory=isReading(s);
 if(s?.isHistory)s.state='online';historyOn=false;
 try{originalRenderContent();}finally{if(s?.isHistory)s.state=savedState;historyOn=savedHistory;}
 timeCard.hidden=!isReading(s);
 if(!isReading(s)){content.removeAttribute('data-history-key');return;}
 const state=readingState(s),scroll=historyScroll(s);if(!scroll)return;
 content.setAttribute('data-history-key',s.archiveKey||'live-'+s.id);
 scroll.classList.add('history-reading-scroll');scroll.replaceChildren();
 state.entries.forEach((entry,index)=>{
  const template=document.createElement('template');template.innerHTML=logMarkup(entry,s,index);
  for(const row of template.content.children)row.dataset.historyEntry=String(index);
  template.content.querySelectorAll('.terminal-line,.command-top,.command-result-row').forEach((row,part)=>{row.dataset.historyEntry=String(index);row.dataset.historyRow=String(part);});
  scroll.append(template.content);
 });
 content.querySelectorAll(`[data-session="${s.id}"] .input-row,#palette-${s.id}`).forEach(n=>n.remove());
 scroll.querySelectorAll('.app-command').forEach(n=>{const stamp=n.querySelector('.command-executed-at');if(stamp&&s.recordTime)stamp.textContent=s.recordTime.slice(0,10)+' '+sourceTime(state.entries[+n.dataset.command]);});
 scroll.querySelectorAll('.app-command [data-act]').forEach(n=>{n.disabled=true;n.title='历史记录中的操作不可再次执行';});
 mountTimeCard(s);
 if(state.anchor)restoreAnchor(s,scroll);else scroll.scrollTop=state.progress*Math.max(0,scroll.scrollHeight-scroll.clientHeight);
 scroll.addEventListener('scroll',()=>updateReading(s,scroll),{passive:true});updateReading(s,scroll);
};
renderTabs=function(){originalRenderTabs();sessions.forEach(s=>{if(!s.isHistory&&!s.logMode)return;const tab=$(`#tabs .tab[data-value="${s.id}"]`);if(!tab)return;tab.classList.add('history-readonly-tab');const glyph=tab.querySelector('.connection-glyph');if(glyph)glyph.innerHTML=icon('history');tab.dataset.tip=s.name+' · '+(s.recordTime||'当前会话')+' · 日志';});};
renderStatus=function(){originalRenderStatus();const s=current();if(!s?.isHistory)return;const identity=$('#statusbar .status-identity');if(identity){identity.innerHTML=icon('history')+'历史记录 · 只读'+icon('up');identity.classList.add('history-readonly-status');identity.dataset.tip=s.recordTime+' · '+s.recordResult;}
 const broadcast=$('#statusbar [data-act="broadcast"]');if(broadcast){broadcast.disabled=true;broadcast.dataset.tip='历史记录只读，不参与输入广播';broadcast.title=broadcast.dataset.tip;}
 const forward=$('#statusbar [data-act="forward"]');if(forward){forward.disabled=!hasHost(s);forward.dataset.tip=hasHost(s)?'为原主机建立连接并配置转发':'原主机配置已删除';forward.title=forward.dataset.tip;}
 const summary=$('#statusbar .summary-text');if(summary)summary.textContent='文件传输 · 无活动任务';
};
const originalWorkspaceTooltip=showWorkspaceTooltip;
showWorkspaceTooltip=function(n){
 const s=n?.closest('.tab')?sessions.find(s=>s.id===+n.closest('.tab').dataset.value):current();
 if(!s?.isHistory||(!n?.closest('.tab')&&!['identity','chain','broadcast'].includes(n?.dataset.act)))return originalWorkspaceTooltip(n);
 if(!$('#popover').hidden||!$('#context-menu').hidden||!$('#modal-root').hidden)return;
 const t=$('#tooltip');t.innerHTML=`<strong>${icon('history')}${esc(s.name)}</strong><code>${esc(s.user||'')} ${esc(s.type==='local'?s.cwd:s.address)}</code><small>${esc(s.recordTime)} · ${esc(s.recordResult)}</small><small>历史记录 · 只读</small>`;t.hidden=false;placeOverlay(t,n.getBoundingClientRect(),!!n.closest('.statusbar'));
};
function hasHost(s){return s.type==='local'||hosts.some(h=>h.connectionId===s.connectionId);}
function hideHistory(){panel.hidden=true;entry.setAttribute('aria-expanded','false');}
function positionHistory(){window.V3Materials?.setOwner(panel,entry);const app=$('#app').getBoundingClientRect(),r=entry.getBoundingClientRect();panel.style.left=Math.max(12,Math.min(r.right-app.left-panel.offsetWidth,app.width-panel.offsetWidth-12))+'px';panel.style.top=(r.bottom-app.top+12)+'px';panel.style.maxHeight=(app.height-80)+'px';}
function renderRows(query=''){
 const matches=panelEmpty?[]:records.filter(r=>(filter==='all'||filter===r.source)&&(r.name+' '+r.user+' '+r.address+' '+r.time).toLowerCase().includes(query.toLowerCase()));
 const root=panel.querySelector('.history-results');
 panel.querySelector('.history-list-heading small').textContent=panelFailed?'':matches.length+' 条记录';
 if(panelFailed){root.innerHTML='<div class="history-empty"><strong>无法读取会话历史</strong>历史索引读取失败，请重试。<br><button class="text-button" data-act="patch-history-retry">重新读取</button></div>';return;}
 if(!matches.length){root.innerHTML=`<div class="history-empty"><strong>${query?'没有匹配的历史会话':'还没有会话历史'}</strong>${query?'试试其他主机名、用户或地址。':'启用会话日志后，已关闭的会话会保留在这里。'}</div>`;return;}
 let last='';root.innerHTML=matches.map(r=>{const heading=r.date!==last?`<div class="history-date">${esc(r.date)}</div>`:'';last=r.date;return heading+`<button class="history-row" data-act="patch-open-record" data-value="${r.key}" aria-label="回看 ${r.name} ${r.time}">${icon('history')}<span class="history-row-main"><span class="history-row-head"><span class="history-row-name" title="${esc(r.name)}">${esc(r.name)}</span><span class="history-row-time">${esc(r.time)}</span></span><span class="history-row-tail"><span class="history-row-meta" title="${esc(r.user)}@${esc(r.address)} · ${esc(r.duration)}">${esc(r.user)}${r.source==='local'?' · ':'@'}${esc(r.address)} · ${esc(r.duration)}</span><span class="history-row-state">${esc(r.result)}</span></span></span></button>`;}).join('');
}
function showHistory(){filter='all';hidePopover();closeContext();$('#tooltip').hidden=true;panel.innerHTML=`<header class="history-list-heading">${icon('history')}<strong>回看日志</strong><small>${panelEmpty?'0':records.length} 条记录</small><button class="icon-btn" data-act="patch-history-close" aria-label="关闭历史列表">${icon('x')}</button></header><label class="history-query">${icon('search')}<input id="history-query" placeholder="搜索主机、用户或地址" aria-label="搜索历史会话" autocomplete="off"></label><nav class="history-filters" aria-label="会话类型">${[['all','全部'],['ssh','SSH'],['local','本地']].map(([id,label])=>`<button data-act="patch-history-filter" data-value="${id}" aria-pressed="${id===filter}">${label}</button>`).join('')}</nav><div class="history-results"></div><footer class="history-list-foot">已关闭会话 · 按结束时间排序<kbd>Esc 关闭</kbd></footer>`;panel.hidden=false;entry.setAttribute('aria-expanded','true');renderRows();positionHistory();$('#history-query').focus();}
function openRecord(key,options={}){const record=records.find(r=>r.key===key);if(!record)return;let tab=sessions.find(s=>s.archiveKey===key);if(!tab){tab={...structuredClone(record.snapshot),id:nextId++,type:record.source==='local'?'local':'ssh',name:record.name,user:record.user,address:record.address,isHistory:true,archiveKey:key,connectionId:record.connection,recordTime:'2026-10-'+(record.date==='今天'?'28':'27')+' '+record.time,recordResult:record.result,state:'archive',draft:'',socks:false,logMode:false};sessions.push(tab);}active=tab.id;groupMode=false;historyOn=false;hideHistory();closeContext();render();
 const index=record.executionRanges?.[options.executionRef];
 if(index!=null){const scroll=historyScroll(tab),row=scroll?.querySelector(`[data-history-entry="${index}"]`);if(row){scroll.scrollTop+=row.getBoundingClientRect().top-scroll.getBoundingClientRect().top;updateReading(tab,scroll);}}
 return tab.id;
}
// Both prototype entry points resolve the same catalog and use the same renderer.
window.ZeroWorkHistory={
 register(record){const i=records.findIndex(r=>r.key===record.key);if(i<0)records.push(structuredClone(record));else records[i]=structuredClone(record);},
 open:openRecord
};
showTabMenu=function(anchor,id){const s=sessions.find(s=>s.id===+id);if(!s?.isHistory)return originalTabMenu(anchor,id);const available=hasHost(s);const items=[
 {act:'patch-new-session',session:s.id,label:s.type==='local'?'新建本地会话':'新建同主机会话',icon:'plus',disabled:!available,reason:available?'':'原主机配置已删除'},
 {act:'patch-duplicate',session:s.id,label:s.type==='local'?'复制会话与目录':'镜像复制会话',icon:'copy',disabled:!available,reason:available?'':'原主机配置已删除'},
 {act:'rename-tab',session:s.id,label:'重命名页签',icon:'edit'},
 {act:'tab-color',session:s.id,label:'页签颜色',icon:'palette'},
 ...(s.type==='local'?[]:[{act:'host-edit',value:hosts.findIndex(h=>h.connectionId===s.connectionId),session:s.id,label:'编辑主机配置',icon:'settings',disabled:!available,reason:available?'':'原主机配置已删除'},
 {act:'chain',session:s.id,label:'通信链路',icon:'network'},
 {act:'patch-forward',session:s.id,label:'端口转发…',icon:'plug',disabled:!available,reason:available?'':'原主机配置已删除'}]),
 {act:'terminal-search',session:s.id,label:'搜索终端',icon:'search',key:'⌘F'},
 {act:'theme',label:'全局主题',icon:'palette'},
 {act:'export-log',session:s.id,label:'导出会话记录',icon:'download'},
 {act:'close-others',session:s.id,label:'关闭其他页签',icon:'x',disabled:sessions.length<2},null,
 {act:'close-tab',value:s.id,label:'关闭页签',icon:'x',key:'⌘W'}
 ];menu(anchor,items);
};
function enterLog(s){if(!s||s.isHistory)return;s.draft='';s.logMode=true;historyOn=true;readingStates.delete(s.id);readingState(s);render();}
execute=function(s,raw,origin){if(raw.trim()==='@log'&&!s.isHistory){enterLog(s);return;}return originalExecute(s,raw,origin);};
openHistory=function(s){enterLog(s);};
function showHistoryForward(s){closeContext();modal('端口转发',s.name+' · '+s.user+'@'+s.address,`<p>使用当前保存的主机配置建立连接。历史记录保持只读。</p><label class="field"><span>转发方式</span><select aria-label="转发方式"><option>SOCKS5 · 动态转发</option></select></label><label class="field"><span>本机监听地址与端口</span><input value="127.0.0.1:1080" aria-label="监听地址与端口"></label><p>连接与转发由后台转发管理。关闭回看页签不会停止转发。</p>`,`<button class="button secondary" data-act="close-modal">取消</button><button class="button primary" data-act="patch-forward-connect">连接并启动转发</button>`);}
document.addEventListener('click',e=>{
 const button=e.target.closest('[data-act]'),act=button?.dataset.act;
 if(!act){if(!panel.hidden&&!panel.contains(e.target))hideHistory();return;}
 if(!act.startsWith('patch-')){
  if(act==='close-tab'){const closing=sessions.find(s=>s.id===+button.dataset.value);if(closing?.isHistory){e.preventDefault();e.stopImmediatePropagation();readingStates.delete(closing.id);sessions=sessions.filter(s=>s!==closing);if(active===closing.id)active=sessions.at(-1)?.id??null;closeContext();render();return;}}
  if(current()?.isHistory&&act==='identity'){e.preventDefault();e.stopImmediatePropagation();const s=current();popover(button,'会话记录','history',details([['主机',esc(s.name)],['录制时间',esc(s.recordTime)],['结束状态',esc(s.recordResult)],['目录',esc(s.cwd||'未记录')]]));return;}
  if(current()?.isHistory&&act==='chain'){e.preventDefault();e.stopImmediatePropagation();const s=current();popover(button,'通信链路','network',details([['记录时间',esc(s.recordTime)],['录制时路径',esc('本机 → '+(s.route||[]).map(h=>h.name+' → ').join('')+s.name)],['结束状态',esc(s.recordResult)]]),hasHost(s)?`<button class="button secondary" data-act="patch-new-session" data-session="${s.id}">新建同主机会话</button>`:'');return;}
  if(current()?.isHistory&&act==='forward'){e.preventDefault();e.stopImmediatePropagation();showHistoryForward(current());return;}
  if(current()?.isHistory&&['terminal-paste','terminal-selection-ai','upload','download','run-new','run-dup'].includes(act)){e.preventDefault();e.stopImmediatePropagation();return;}
  if(!panel.hidden&&!panel.contains(button))hideHistory();return;
 }
 e.preventDefault();e.stopImmediatePropagation();
 switch(act){
 case 'patch-history-list':panel.hidden?showHistory():hideHistory();break;
 case 'patch-history-close':hideHistory();entry.focus();break;
 case 'patch-history-live':if(current()?.logMode){current().logMode=false;historyOn=false;render();}break;
 case 'patch-history-filter':filter=button.dataset.value;panel.querySelectorAll('.history-filters button').forEach(n=>n.setAttribute('aria-pressed',n===button));renderRows($('#history-query').value);break;
 case 'patch-history-retry':panelFailed=false;renderRows($('#history-query').value);break;
 case 'patch-open-record':openRecord(button.dataset.value);break;
 case 'patch-forward':showHistoryForward(sessions.find(s=>s.id===+button.dataset.session));break;
 case 'patch-forward-connect':$('#modal-root .modal-body').innerHTML='<p>正在建立独立转发连接…</p>';$('#modal-root .modal footer').innerHTML='<button class="button secondary" data-act="close-modal">关闭</button>';break;
 case 'patch-new-session':case 'patch-duplicate':{const s=sessions.find(s=>s.id===+button.dataset.session);const host=hosts.find(h=>h.connectionId===s.connectionId);const tab={id:nextId++,type:s.type,name:host?.name||'Local Terminal',address:host?.address,user:host?.user,port:host?.port||22,cwd:act==='patch-duplicate'?s.cwd:'/home/'+(host?.user||'developer'),state:'connecting',log:[],draft:''};sessions.push(tab);active=tab.id;groupMode=false;closeContext();render();break;}
 }
},true);
document.addEventListener('input',e=>{if(e.target.id==='history-query')renderRows(e.target.value);});
document.addEventListener('keydown',e=>{
 if(e.key==='Escape'&&!panel.hidden){hideHistory();entry.focus();e.preventDefault();e.stopImmediatePropagation();return;}
 if(e.key==='Escape'&&current()?.logMode&&$('#context-menu').hidden&&$('#popover').hidden&&$('#modal-root').hidden&&!showSearch){current().logMode=false;historyOn=false;render();e.preventDefault();e.stopImmediatePropagation();return;}
 if(isReading(current())&&e.target.closest('#content')&&!e.target.matches('input,textarea')&&['PageUp','PageDown','Home','End'].includes(e.key)){
  const scroll=historyScroll(current());if(scroll){const max=Math.max(0,scroll.scrollHeight-scroll.clientHeight);scroll.scrollTop=e.key==='Home'?0:e.key==='End'?max:scroll.scrollTop+(e.key==='PageUp'?-1:1)*scroll.clientHeight;updateReading(current(),scroll);e.preventDefault();e.stopImmediatePropagation();return;}
 }
 if(panel.hidden)return;
 if(e.key==='Tab'){const controls=[...panel.querySelectorAll('button:not(:disabled),input:not(:disabled)')],i=controls.indexOf(document.activeElement);e.preventDefault();e.stopImmediatePropagation();controls[(i+(e.shiftKey?-1:1)+controls.length)%controls.length]?.focus();return;}
 const rows=[...panel.querySelectorAll('.history-row')],i=rows.indexOf(document.activeElement);
 if(e.key==='ArrowDown'||e.key==='ArrowUp'){e.preventDefault();e.stopImmediatePropagation();rows[i<0?(e.key==='ArrowDown'?0:rows.length-1):(i+(e.key==='ArrowDown'?1:-1)+rows.length)%rows.length]?.focus();}
 if(e.key==='Enter'&&e.target.id==='history-query'){rows[0]?.click();e.preventDefault();e.stopImmediatePropagation();}
},true);
function refreshHistoryLayout(){if(!panel.hidden)positionHistory();if(isReading(current())){const scroll=historyScroll(current());if(scroll){restoreAnchor(current(),scroll);updateReading(current(),scroll);}}}
window.addEventListener('resize',refreshHistoryLayout);
new ResizeObserver(refreshHistoryLayout).observe($('#app'));
// Keep one workspace scene selector instead of adding another review toolbar.
$('#scene').insertAdjacentHTML('beforeend',`${[['list','历史会话列表'],['menu','日志页签右键'],['deleted','原主机已删除'],['log','当前会话 @log'],['closed','无活动会话的历史'],['empty','历史空记录'],['error','历史读取失败']].map(([id,label])=>`<option value="history-${id}">${label}</option>`).join('')}`);
function setState(state){if(!sessions.some(s=>s.id===2))sessions=structuredClone(initialSessions);hideHistory();closeContext();closeModal();historyOn=false;sessions.forEach(s=>s.logMode=false);panelEmpty=false;panelFailed=false;
 if(state==='tab'||state==='menu'){openRecord(records[0].key);if(state==='menu'){requestAnimationFrame(()=>{const t=$(`#tabs .tab[data-value="${active}"]`);if(t)showTabMenu(t,active);});}}
 else if(state==='deleted'){openRecord(records[3].key);requestAnimationFrame(()=>{const t=$(`#tabs .tab[data-value="${active}"]`);if(t)showTabMenu(t,active);});}
 else if(state==='log'){active=2;current().log=structuredClone(source.log);enterLog(current());}
 else if(state==='closed'){sessions=[];active=null;render();showHistory();}
 else {active=2;render();panelEmpty=state==='empty';panelFailed=state==='error';showHistory();}
 $('#scene').value=state==='tab'?'history':'history-'+state;
}
document.addEventListener('change',e=>{if(e.target.id!=='scene')return;const value=e.target.value;if(value==='history'||value.startsWith('history-')){e.stopImmediatePropagation();setState(value==='history'?'tab':value.slice(8));}},true);
const requestedState=params.get('historyScene');
if(requestedState)setState(requestedState);else if(params.get('mode')==='history'){sessions=sessions.filter(s=>s.type!=='history');setState('tab');}else render();
document.documentElement.dataset.historyReady='true';
})();
