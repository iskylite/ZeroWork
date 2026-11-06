import { UpdateDesignModel, stateNames } from './model.mjs';
'use strict';
// Local design fixtures only. No updater, process control or application data writes.
const q = new URLSearchParams(location.search);
const $ = s => document.querySelector(s);
document.body.dataset.freeze = String(q.get('freeze') === 'true');
const paths = {
  settings:'<path d="M4 6h16M4 12h16M4 18h16M8 3v6m8 0v6M9 15v6"/>',
  search:'<circle cx="10" cy="10" r="7"/><path d="m15 15 6 6"/>',
  close:'<path d="m6 6 12 12M18 6 6 18"/>',
  shield:'<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6Z"/><path d="m8 12 3 3 5-6"/>',
  terminal:'<path d="m5 7 5 5-5 5m8 0h6"/>',
  external:'<path d="M14 3h7v7m0-7L10 14M10 3H3v18h18v-7"/>',
  refresh:'<path d="M20 7v5h-5M4 17v-5h5M6 7a7 7 0 0 1 12-2l2 2M4 17l2 2a7 7 0 0 0 12-2"/>',
  download:'<path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5"/>',
  check:'<path d="m5 12 4 4L19 6"/>',
  info:'<circle cx="12" cy="12" r="9"/><path d="M12 7v6m0 4v.1"/>',
  alert:'<path d="m12 3 10 18H2ZM12 9v5m0 3v.1"/>',
  folder:'<path d="M3 5h7l2 3h9v12H3Z"/>',
  network:'<path d="M12 3v6M4 21v-6h16v6M12 15v6M8 9h8v6H8Z"/>',
  transfer:'<path d="M7 3v18m-4-4 4 4 4-4M17 21V3m-4 4 4-4 4 4"/>',
  spark:'<path d="m12 2 3 7 7 3-7 3-3 7-3-7-7-3 7-3Z"/>',
  key:'<circle cx="8" cy="10" r="5"/><path d="M13 10h9m-3 0v4"/>',
  bell:'<path d="M5 17h14l-2-3V9a5 5 0 0 0-10 0v5Zm5 3h4"/>',
  plug:'<path d="M8 3v5m8-5v5M6 8h12v3a6 6 0 0 1-12 0Zm6 9v5"/>',
  database:'<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v12c0 4 16 4 16 0V6M4 12c0 4 16 4 16 0"/>'
};
const icon = name => `<svg viewBox="0 0 24 24" aria-hidden="true">${paths[name] || paths.refresh}</svg>`;
document.querySelectorAll('[data-icon]').forEach(e => e.innerHTML = icon(e.dataset.icon));
const pages = [['外观与主题','settings'],['快捷键','key'],['SSH 与网络','network'],['文件传输','transfer'],['AI 辅助','spark'],['协议插件','plug'],['通知','bell'],['数据与日志','database'],['关于与更新','refresh']];
$('#nav').innerHTML = pages.map(([title,name],i) => `<button ${i===8?'class="active" aria-current="page"':''}><span>${icon(name)}</span><span>${title}</span>${i===8?'<span class="nav-dot"></span>':''}</button>`).join('');
const states = stateNames;
$('#scenario').innerHTML = Object.entries(states).map(([value,label]) => `<option value="${value}">${label}</option>`).join('');
let fixtureBusy=q.get('busy')!=='false';
const model = new UpdateDesignModel(q.get('state')||'confirm',fixtureBusy);
let state=model.state, draft=true, saved=true, incomplete=false;
const timers = new Map();
$('#busy').checked=fixtureBusy;
const taskRows = mode => model.tasks.filter(t=>mode!=='confirm'||t.status!=='released').map(t=>{
  const labels={active:mode==='draining'?'继续运行':'等待结束',closing:'正在结束',released:'已结束',unknown:'等待资源释放'};
  const status=mode==='confirm'?(t.status==='active'?`${t.count} 个`:'仍在结束'):labels[t.status];
  return `<div class="task-row"><span>${icon(t.icon)}<span>${t.label}</span></span><span class="task-state ${t.status==='released'?'done':t.status==='closing'?'active':t.status==='unknown'?'blocked':''}">${status}</span></div>`;
}).join('');
const locked=()=>['installing','startup_blocked','recovery_pending','cancel_pending','recovery_saved'].includes(state);
const closeButton=()=>`<button class="icon-button" data-action="dismiss" aria-label="关闭更新窗口" ${locked()?'disabled':''}>${icon('close')}</button>`;
const helpText=()=>({downloading:'下载完成后会验证更新包。取消下载会删除未完成的更新包。',verifying:'取消校验会删除未验证的更新包。',ready:'安装前会检查未保存的内容并保存工作区快照，随后退出并重新打开 ZeroWork。'})[state]||'';
const help=()=>helpText()?`<span class="update-help"><button class="icon-button" aria-label="更新说明" aria-describedby="update-help-tooltip">${icon('info')}</button><span class="update-help-tooltip" id="update-help-tooltip" role="tooltip">${helpText()}</span></span>`:'';
const header=(title,name='download',tone='')=>`<header class="dialog-head ${tone}"><span class="heading-icon ${['closing','handoff','installing','verifying','saving','cancel_pending','commit_pending'].includes(state)?'spinning':''}">${icon(name)}</span><h2 id="dialog-title">${title}</h2>${help()}${closeButton()}</header>`;
const footer=(secondary,primary,action,tone='primary',status='',secondaryAction='dismiss')=>`<footer class="dialog-footer">${status?`<span class="status" role="status">${status}</span>`:''}${secondary?`<button data-action="${secondaryAction}">${secondary}</button>`:''}${primary?`<button class="${tone}" data-action="${action}">${primary}</button>`:''}</footer>`;
const checkFooter=()=>footer('关闭','重新检查','recheck').replace('<footer class="dialog-footer">','<footer class="dialog-footer"><button data-action="release">发布页</button>');
const backup=`<div class="summary recovery-path"><h3>备份位置</h3><p>/Applications/.ZeroWork-update-TX/ZeroWork.app</p><p>事务记录与备份会保留，不会随下载缓存清理。</p></div>`;
function content(){
  switch(state){
    case 'no_stable':return header('暂无可用的正式版更新','refresh')+`<div class="dialog-body"><p id="dialog-description">正式版通道尚未发布可用版本，当前未开始下载或安装。</p></div>`+checkFooter();
    case 'check_failed':return header('检查更新失败','alert','warning')+`<div class="dialog-body"><p id="dialog-description">正式版缺少自动更新清单 update.json，请从官方发布页手动下载</p><p>尚未开始下载或安装。可重新检查，或查看官方发布页。</p></div>`+checkFooter();
    case 'download_failed':return header('更新下载失败','alert','warning')+`<div class="dialog-body"><p id="dialog-description">更新包下载失败（HTTP 503）</p><p>尚未开始安装。可重新检查，或从官方发布页下载安装包。</p></div>`+checkFooter();
    case 'available':return header('ZeroWork 0.3.0 已发布')+`<div class="dialog-body"><p id="dialog-description">当前 0.3.0-rc1 → 新版 0.3.0 · 42.8 MB</p><div class="summary"><h3>本次更新</h3><p>改进连接与文件传输的稳定性</p><p>修复已知问题</p></div><a href="https://github.com/iskylite/ZeroWork/releases" target="_blank" rel="noopener">完整更新说明 ↗</a></div>`+footer('稍后','下载更新','download');
    case 'downloading':return header('正在下载更新')+`<div class="dialog-body"><p id="dialog-description">已下载 7.5 MB / 20.2 MB</p><div class="download-progress"><div class="progress-track" role="progressbar" aria-valuenow="37" aria-valuemin="0" aria-valuemax="100"><div class="progress-fill" style="width:37%"></div></div><span>37%</span></div></div>`+footer('取消下载','','','primary','','cancel-download').replace('<footer class="dialog-footer">','<footer class="dialog-footer"><button data-action="release">发布页</button>');
    case 'verifying':return header('正在检查更新包','shield')+`<div class="dialog-body"><p id="dialog-description">ZeroWork 0.3.0</p><div class="summary"><div class="task-row"><span>完整性与发布签名</span><span class="task-state done">已通过</span></div><div class="task-row"><span>应用身份与系统兼容性</span><span class="task-state active">检查中</span></div></div><p>后台检查可继续；取消会清除未验证的包。</p></div>`+footer('取消校验','后台检查','dismiss','primary','','cancel-verify');
    case 'ready':return header('更新已准备好安装','check')+`<div class="dialog-body"><p id="dialog-description">ZeroWork 0.3.0 · 更新包校验通过</p></div>`+footer('稍后安装','安装并重启','install').replace('<footer class="dialog-footer">','<footer class="dialog-footer"><button data-action="release">发布页</button>');
    case 'drafts':return header('暂时无法安装更新','alert','warning')+`<div class="dialog-body"><p id="dialog-description">当前 AI 会话有未发送的输入</p><p class="consequence">可返回处理，也可选择仍然安装。未保存的内容可能丢失。</p></div>`+footer('返回处理','仍然安装…','discard-drafts','danger-solid');
    case 'saving':return header('正在保存工作区快照','refresh')+`<div class="dialog-body"><p id="dialog-description">正在记录更新前的窗口、分栏与工作区结构。</p><div class="summary"><p>保存成功后才会发送结束请求。</p><p>若保存失败，当前工作会继续保留。</p></div></div>`+footer('取消更新','','','primary','','cancel-update');
    case 'snapshot_failed':return header('工作区快照未能保存','alert','warning')+`<div class="dialog-body"><p id="dialog-description">尚未发送任何结束请求，当前工作保持运行。</p><div class="summary"><p>请检查本地可用空间后重试。</p><p>已验证的更新包会保留。</p></div></div>`+footer('稍后更新','重试保存','retry-snapshot');
    case 'confirm':if(model.allowUnsaved)return header('仍然安装更新？','alert','warning')+`<div class="dialog-body"><p class="description" id="dialog-description">未保存的设置、编辑内容和未发送输入可能丢失。</p>${model.remaining.length?`<div class="summary">${taskRows('confirm')}</div>`:''}<p class="consequence">确认后保存工作区快照并结束当前工作，随后安装更新并重启。</p></div>`+footer('取消','仍然安装并重启','confirm-close','danger-solid');return header('结束当前工作并安装更新？','alert','warning')+`<div class="dialog-body"><p class="description" id="dialog-description">保存工作区快照后，由 ZeroWork 统一结束以下工作。</p><div class="summary">${taskRows('confirm')}</div><p class="consequence">未完成的传输和 AI 任务将被取消，历史记录会保留。</p><p class="consequence">已结束的工作不会自动恢复；断开连接不保证远端命令停止。</p></div>`+footer('取消','结束任务并安装','confirm-close','danger-solid');
    case 'closing':return header('正在结束任务','refresh')+`<div class="dialog-body"><p id="dialog-description">结束完成后，将准备安装更新并重新打开 ZeroWork。</p><div class="summary" aria-live="polite">${taskRows('closing')}</div><p class="consequence">正在等待任务与连接释放资源。</p><p class="consequence">取消后不再继续关闭其他工作，已发请求仍会收尾。</p></div>`+footer('取消更新','','','primary',`已结束 ${model.released} / ${model.total} 项工作`,'cancel-update');
    case 'blocked':return header('仍有任务未结束','alert','warning')+`<div class="dialog-body"><p id="dialog-description">仍在等待资源释放，尚未进入安装阶段。</p><div class="summary">${taskRows('closing')}</div><p>重试会继续检查原关闭请求，不会重复执行远端操作。</p><p class="consequence">已结束的工作不会自动恢复。</p></div>`+footer('取消更新','重试结束','retry-close','primary','','cancel-update');
    case 'draining':return header('更新已取消，仍在结束部分工作','refresh')+`<div class="dialog-body"><p id="dialog-description">已发出的结束请求继续收尾，不会再安装更新。</p><div class="summary" aria-live="polite">${taskRows('draining')}</div><p>其余工作继续运行，已经结束的工作不会恢复。</p></div>`+footer('返回工作区','','');
    case 'handoff':return header('正在准备安装','refresh')+`<div class="dialog-body"><p id="dialog-description">工作区快照已保存，全部工作已结束。</p><div class="summary"><h3>等待安装程序准备就绪</h3><p>此时尚未授权替换应用，仍可取消更新。</p></div><p class="consequence">取消需要安装程序确认，已结束的工作不会恢复。</p></div>`+footer('取消更新','','','primary','','cancel-update');
    case 'commit_pending':return header('正在确认安装状态','refresh')+`<div class="dialog-body"><p id="dialog-description">安装程序已就绪，正在确认是否进入安装阶段。</p><div class="summary"><p>安装程序确认开始安装后，应用才会退出。</p><p>取消请求将由安装程序确认最终结果。</p></div></div>`+footer('请求取消','','','primary','','cancel-update');
    case 'cancel_pending':return header('正在确认取消更新','refresh')+`<div class="dialog-body"><p id="dialog-description">已发送取消请求，正在等待安装程序确认。</p><div class="summary"><p>确认取消后，应用将继续运行。</p><p>如果安装已经开始，将显示安装进度。</p></div><p class="consequence">请等待确认取消或开始安装的结果。</p></div>`;
    case 'handoff_failed':return header('安装程序未能准备就绪','alert','warning')+`<div class="dialog-body"><p id="dialog-description">应用尚未退出，也没有替换任何文件。</p><div class="summary"><p>工作区快照和更新包已保留。</p><p>已结束的工作不会自动恢复。</p></div></div>`+footer('稍后安装','重试安装','retry-handoff');
    case 'parent_exit_timeout':return header('应用尚未完全退出','alert','warning')+`<div class="dialog-body"><p id="dialog-description">等待退出已超时，已撤销本次安装授权。</p><div class="summary"><p>没有替换应用，也不会强制终止进程。</p><p>应用之后退出也不会触发这次安装。</p></div></div>`+footer('','返回应用','return-app');
    case 'installing':return header('正在安装更新','refresh')+`<div class="dialog-body"><p id="dialog-description">安装提交已确认，正在等待退出并替换应用。</p><div class="summary"><h3>安装完成后会自动打开 ZeroWork</h3><p>新启动请求将等待安装事务完成。</p></div><p>请稍候，当前阶段无法取消。</p></div>`;
    case 'startup_blocked':return header('ZeroWork 正在更新','refresh')+`<div class="dialog-body"><p id="dialog-description">已有安装事务正在进行，暂不打开新的工作区。</p><div class="summary"><p>安装结束后会进入可用版本。</p><p>此时不会新建任务或迁移用户数据。</p></div></div>`;
    case 'recovery_pending':return header('正在恢复中断的安装','refresh')+`<div class="dialog-body"><p id="dialog-description">检测到替换未完成，正在核对应用与备份。</p>${backup}<p>核对完成前，不会启动版本不明的应用。</p></div>`+footer('','恢复已验证的旧版本','restore-old');
    case 'restore_failed':return header('旧版本未能恢复','alert','error')+`<div class="dialog-body"><p id="dialog-description">尚未确认存在可启动的应用，请勿重复替换文件。</p>${backup}<p>请使用官方安装包修复。现有用户数据不会被删除。</p></div>`+footer('查看备份位置','打开下载页面','release','primary','','show-backup');
    case 'launch_failed':return header('新版未能正常启动','alert','warning')+`<div class="dialog-body"><p id="dialog-description">新版未取得就绪回执，已确认用户数据尚未变更。</p>${backup}<p>可以恢复已验证的旧版本，或使用安装包修复。</p></div>`+footer('打开下载页面','恢复旧版本','restore-old','primary','','release');
    case 'incompatible_data':return header('暂时无法恢复旧版本','alert','warning')+`<div class="dialog-body"><p id="dialog-description">新版已修改数据格式，旧版本的兼容性尚未确认。</p>${backup}<p>已保留备份与诊断；请安装兼容当前数据的版本。</p><p class="consequence">不会启动旧版本读取已迁移的数据。</p></div>`+footer('查看备份位置','打开下载页面','release','primary','','show-backup');
    case 'recovery_saved':return header('恢复信息已保留','folder')+`<div class="dialog-body"><p id="dialog-description">已收起错误详情，尚未解除安装恢复限制。</p><div class="summary"><p>备份与事务记录保持原样。</p><p>下次启动仍会进入恢复检查，不会打开普通工作区。</p></div></div>`+footer('','查看恢复信息','reopen-recovery');
    case 'done':return header('已更新到 ZeroWork 0.3.0','check')+`<div class="dialog-body"><p id="dialog-description">新版已取得就绪回执，配置与历史记录已保留。</p><div class="summary"><p>之前结束的任务不会自动恢复。</p><p>可恢复的工作区结构来自结束任务前的快照。</p></div></div>`+footer('','继续使用','finish');
    case 'invalid':return header('更新包未通过验证','shield','error')+`<div class="dialog-body"><p id="dialog-description">已停止更新，应用与运行工作没有被修改。</p><div class="summary"><p>失败包已清除，请重新检查官方更新。</p></div></div>`+footer('关闭','重新检查','recheck');
    case 'manual':return header('请手动安装这个版本','folder')+`<div class="dialog-body"><p id="dialog-description">安装位置无法写入，尚未结束任何工作。</p><div class="summary"><p>下载官方 DMG，退出后替换应用并重新打开。</p></div></div>`+footer('稍后','打开下载页面','release');
    case 'failed':return header('未能完成更新','alert','warning')+`<div class="dialog-body"><p id="dialog-description">已恢复并验证旧版本，数据兼容性检查通过。</p><div class="summary"><h3>ZeroWork 0.3.0-rc1 可以继续使用</h3><p>配置与历史保留；已结束的工作不会自动恢复。</p></div></div>`+footer('打开下载页面','打开旧版本','return-app','primary','','release');
    default:return '';
  }
}
function paint({focus=true}={}){
  state=model.state;
  $('#current-version').textContent=`${model.installed?'0.3.0':'0.3.0-rc1'} · main@1a2b3c4d5e6f* · 2026-11-04 18:00:00 +0800`;
  $('#version-badge').textContent=model.installed?'已是最新':'有新版本';$('#available-title').textContent=model.installed?'你正在使用最新版本':'0.3.0 正式版可用';
  $('#open-update').textContent=model.installed?'已是最新':model.operation==='downloading'?'查看下载':model.operation==='verifying'?'查看校验':'查看更新';$('#open-update').disabled=model.installed;
  if(state!=='settings')incomplete=['invalid','snapshot_failed','handoff_failed','parent_exit_timeout','failed','restore_failed','launch_failed','incompatible_data'].includes(state);
  if(model.installed)incomplete=false;
  $('#version-badge').dataset.tone=incomplete||state==='draining'?'warning':model.installed||model.operation==='ready'?'success':'accent';
  if(incomplete){$('#version-badge').textContent='更新未完成';$('#available-title').textContent='本次更新未完成';$('#open-update').textContent='检查更新';}
  if(['no_stable','check_failed','download_failed'].includes(state)){
    $('#version-badge').textContent=state==='no_stable'?'暂无正式版':state==='check_failed'?'检查失败':'下载失败';
    $('#version-badge').dataset.tone=state==='no_stable'?'accent':'warning';
    $('#available-title').textContent=state==='no_stable'?'暂无可用的正式版更新':state==='check_failed'?'检查更新失败':'更新下载失败';
    $('#open-update').textContent='检查更新';
  }
  if(state==='draining')$('#version-badge').textContent='正在收尾';
  $('#app').dataset.state=state;$('#app').dataset.surface=model.helperSurface?'helper':'application';$('#app').dataset.operation=model.operation;
  $('#app').dataset.gate=String(model.gate);$('#app').dataset.pendingCloses=String(model.tasks.filter(t=>t.status==='closing'||t.status==='unknown').length);
  $('#app').dataset.transaction=model.transactionStage;$('#scenario').value=state;
  if(model.message)$('#check-note').textContent=model.message;
  $('#cleanup-details').hidden=model.intent||!model.tasks.some(t=>['closing','unknown'].includes(t.status));
  const open=state!=='settings';$('#modal-layer').hidden=!open;$('.main-pane').inert=open;$('.settings-layout aside').inert=open;$('.window-head').inert=open;
  const previousAction=$('#update-dialog').contains(document.activeElement)?document.activeElement?.dataset.action:null;
  $('#update-dialog').innerHTML=open?content():'';
  if(open&&focus)requestAnimationFrame(()=>($('#update-dialog button[data-action="dismiss"]:not(.icon-button),#update-dialog button[data-action="cancel-update"],#update-dialog button[data-action="cancel-download"],#update-dialog button[data-action="cancel-verify"]')||$('#update-dialog')).focus());
  if(open&&!focus&&previousAction)$('#update-dialog').querySelector(`[data-action="${previousAction}"]`)?.focus();
  if(!open&&focus)$('#open-update').focus();
  const next=new URL(location.href);next.searchParams.set('state',state);next.searchParams.set('theme',document.body.dataset.theme);next.searchParams.set('busy',String(fixtureBusy));history.replaceState(null,'',next);
  $('#step').disabled=!model.pendingReceipt&&!['downloading','verifying','recovery_pending'].includes(model.state);
  window.V3Materials?.sync();pump();
}
function pump(){
  if(q.get('freeze')==='true')return;
  const event=model.pendingReceipt;if(!event)return;
  const key=JSON.stringify(event);if(timers.has(key))return;
  timers.set(key,setTimeout(()=>{timers.delete(key);model.receipt(event);paint({focus:false});},450));
}
function step(){if(model.pendingReceipt)model.receipt();else if(model.operation==='downloading')model.downloadComplete();else if(model.operation==='verifying')model.verificationComplete();else if(model.state==='recovery_pending')model.restoreOld();paint();}
function action(name){
  if(name==='dismiss')model.dismiss();
  if(name==='cancel-update')model.cancelInstall();
  if(name==='cancel-download'||name==='cancel-verify')model.cancelOperation();
  if(name==='download')model.download();
  if(name==='install'){model.unsaved=model.unsaved||draft!==saved;model.requestInstall();}
  if(name==='discard-drafts')model.discardDrafts();
  if(name==='confirm-close')model.confirmClose();
  if(name==='retry-close')model.retryClose();
  if(name==='retry-snapshot'){model.intent=true;model.gate=true;model.state='saving';}
  if(name==='retry-handoff')model.requestInstall();
  if(name==='restore-old')model.restoreOld();
  if(name==='reopen-recovery')model.state=model.recoveryState||'restore_failed';
  if(name==='return-app'){model.state='settings';model.gate=false;model.message='已返回原版本；已结束的工作不会自动恢复。';}
  if(name==='recheck'){model.checkState=null;model.state='available';model.operation='idle';}
  if(name==='finish'){model.state='settings';model.operation='idle';}
  if(name==='show-backup')$('#review-status').textContent='备份与事务记录位置已在窗口中显示；本地原型不会访问文件。';
  if(name==='release')window.open('https://github.com/iskylite/ZeroWork/releases','_blank','noopener');
  paint();
}
$('#update-dialog').addEventListener('click',e=>{const button=e.target.closest('[data-action]');if(button&&!button.disabled)action(button.dataset.action);});
document.addEventListener('keydown',e=>{
  if($('#modal-layer').hidden)return;
  if(e.key==='Escape'){e.preventDefault();model.dismiss();paint();}
  if(e.key==='Tab'){const items=[...$('#update-dialog').querySelectorAll('button:not(:disabled),a[href]')];if(!items.length){e.preventDefault();return;}const i=items.indexOf(document.activeElement);if(i<0||(e.shiftKey&&i===0)||(!e.shiftKey&&i===items.length-1)){e.preventDefault();items[e.shiftKey?items.length-1:0].focus();}}
});
$('#open-update').onclick=()=>{model.open();paint();};
$('#cleanup-details').onclick=()=>{model.state='draining';paint();};
$('#scenario').onchange=e=>{for(const timer of timers.values())clearTimeout(timer);timers.clear();incomplete=false;model.loadFixture(e.target.value,fixtureBusy);paint();};
$('#busy').onchange=e=>{fixtureBusy=e.target.checked;for(const timer of timers.values())clearTimeout(timer);timers.clear();model.loadFixture(model.state,fixtureBusy);paint({focus:false});};
$('#step').onclick=step;
$('#automatic').onclick=()=>{draft=!draft;$('#automatic').setAttribute('aria-checked',String(draft));$('#save-state').textContent=draft===saved?'偏好设置在保存后生效':'有未保存的偏好设置';};
$('#save-preference').onclick=()=>{saved=draft;$('#save-state').textContent='偏好设置已保存';};
$('#reset-preference').onclick=()=>{draft=saved;$('#automatic').setAttribute('aria-checked',String(draft));$('#save-state').textContent='偏好设置在保存后生效';};
$('#settings-close').onclick=()=>$('#review-status').textContent='已触发关闭设置；原型保留当前窗口以便评审。';

// Export the actual DOM geometry and computed theme paint, not a second palette.
// Text and shapes remain editable. Native blur and live motion are not embedded.
const xml=s=>String(s).replace(/[<>&"]/g,c=>({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;'}[c]));
function snapshotSVG(){
  const root=$('#app'),bounds=root.getBoundingClientRect(),out=[];
  const canvas=document.createElement('canvas');canvas.width=canvas.height=1;const ctx=canvas.getContext('2d');
  const color=value=>{ctx.clearRect(0,0,1,1);ctx.fillStyle=value;ctx.fillRect(0,0,1,1);const [r,g,b,a]=ctx.getImageData(0,0,1,1).data;return a?`rgba(${r},${g},${b},${(a/255).toFixed(4)})`:'none';};
  const style=getComputedStyle(document.body),w=bounds.width,h=bounds.height;
  const dialog=$('#update-dialog').getBoundingClientRect();
  const contract={theme:document.body.dataset.theme,state,viewport:{width:innerWidth,height:innerHeight},dpr:devicePixelRatio,region:{x:dialog.left-bounds.left,y:dialog.top-bounds.top,width:dialog.width,height:dialog.height}};
  out.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}"><title>ZeroWork 0.3 应用更新 · ${xml(document.body.dataset.theme)} · ${xml(states[state])}</title><desc>由 HTML 原型的实际计算样式与布局导出；任务和结果为本地模拟。</desc><defs><linearGradient id="primary" x2="1" y2="1"><stop stop-color="${color(style.getPropertyValue('--action-accent'))}"/><stop offset="1" stop-color="${color(style.getPropertyValue('--action-accent-2'))}"/></linearGradient><clipPath id="root"><rect width="${w}" height="${h}" rx="14"/></clipPath></defs><g clip-path="url(#root)"><rect width="${w}" height="${h}" fill="${color(style.getPropertyValue('--bg-app'))}"/>`);
  out.push(`<metadata id="render-contract">${xml(JSON.stringify(contract))}</metadata>`);
  function walk(el){
    if(el.nodeType!==1||el.hidden)return;
    const r=el.getBoundingClientRect(),s=getComputedStyle(el);
    if(s.display==='none'||s.visibility==='hidden'||!r.width||!r.height)return;
    const x=r.left-bounds.left,y=r.top-bounds.top;
    const translucent=Number(s.opacity)<1;if(translucent)out.push(`<g opacity="${s.opacity}">`);
    if(el.tagName.toLowerCase()==='svg'){
      const copy=el.cloneNode(true);copy.setAttribute('x',x);copy.setAttribute('y',y);copy.setAttribute('width',r.width);copy.setAttribute('height',r.height);copy.setAttribute('color',color(s.color));copy.setAttribute('stroke',color(s.color));copy.setAttribute('fill','none');copy.setAttribute('stroke-width','1.7');copy.setAttribute('stroke-linecap','round');copy.setAttribute('stroke-linejoin','round');out.push(copy.outerHTML);if(translucent)out.push('</g>');return;
    }
    const bg=color(s.backgroundColor),fill=el.classList.contains('primary')||el.classList.contains('app-mark')?'url(#primary)':bg;
    if(fill!=='none')out.push(`<rect x="${x}" y="${y}" width="${r.width}" height="${r.height}" rx="${parseFloat(s.borderTopLeftRadius)||0}" fill="${fill}"/>`);
    if(parseFloat(s.borderTopWidth)>0)out.push(`<path d="M${x} ${y}h${r.width}" stroke="${color(s.borderTopColor)}" stroke-width="${parseFloat(s.borderTopWidth)}"/>`);
    for(const node of el.childNodes){
      if(node.nodeType===1){walk(node);continue;}
      if(node.nodeType!==3||!node.textContent.trim())continue;
      let row=null;
      const flush=()=>{if(row?.text.trim())out.push(`<text x="${row.x}" y="${row.y}" fill="${color(s.color)}" font-family="${xml(s.fontFamily)}" font-size="${s.fontSize}" font-weight="${s.fontWeight}">${xml(row.text)}</text>`);row=null;};
      for(let i=0;i<node.length;i++){const range=document.createRange();range.setStart(node,i);range.setEnd(node,i+1);const b=range.getBoundingClientRect();if(!b.width&&!b.height)continue;if(b.bottom<bounds.top||b.top>bounds.bottom)continue;if(!row||Math.abs(row.top-b.top)>1){flush();row={x:b.left-bounds.left,y:b.bottom-bounds.top-(b.height-parseFloat(s.fontSize))/2-parseFloat(s.fontSize)*.14,top:b.top,text:''};}row.text+=node.textContent[i];}flush();
    }
    if(translucent)out.push('</g>');
  }
  walk(root);out.push('</g></svg>');return out.join('\n');
}
$('#export').onclick=async()=>{await document.fonts.ready;const blob=new Blob([snapshotSVG()],{type:'image/svg+xml'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=`zerowork-update-${document.body.dataset.theme}-${state}.svg`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);$('#review-status').textContent='已导出当前主题与状态的可编辑 SVG。';};
fetch('../theme-presets.json').then(r=>{if(!r.ok)throw new Error('主题清单加载失败');return r.json();}).then(data=>{
  const names={dark:'Dark',light:'Light',sauber:'Sauber'};
  $('#theme').innerHTML=Object.keys(data.themes).map(id=>`<option value="${id}">${names[id]||id}</option>`).join('');
  const theme=data.themes[q.get('theme')]?q.get('theme'):'sauber';document.body.dataset.theme=theme;$('#theme').value=theme;
  $('#theme').onchange=e=>{document.body.dataset.theme=e.target.value;paint({focus:false});};
  paint();document.body.dataset.ready='true';
}).catch(error=>{$('#review-status').textContent=error.message;});
