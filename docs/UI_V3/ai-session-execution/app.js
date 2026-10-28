/* Reuse the existing workspace renderer. Only the control tag/button is new. */
const patchWorkspace = (() => {
  let fixtureKey = '', controlledId = null;
  function paintControl() {
    document.querySelectorAll('.session-ai-control').forEach(n => n.remove());
    document.querySelectorAll('#content [data-pane]').forEach(pane => {
      const controlled = Number(pane.dataset.pane) === controlledId;
      pane.toggleAttribute('data-ai-readonly', controlled);
      pane.querySelectorAll('.command-input').forEach(input => { input.readOnly = controlled; });
      if (controlled) pane.insertAdjacentHTML('beforeend', '<div class="session-ai-control" data-testid="session-ai-control"><span class="badge accent" data-testid="ai-control-tag">AI 控制<span aria-hidden="true">•</span>只读</span><button type="button" class="button secondary" data-patch-act="takeover" data-testid="takeover-terminal">接管</button></div>');
    });
  }
  function sync(options) {
    const key = JSON.stringify(options);
    controlledId = options.controlled ? (options.existing ? 7 : 18) : null;
    document.querySelector('#app').dataset.size = options.size;
    if (key !== fixtureKey) {
      fixtureKey = key;
      const prior = new Map(sessions.map(session => [session.id, session]));
      const source = { id:7, type:'ssh', name:'app-prod-01', user:'deploy', address:'10.20.1.18', port:22, shellHost:'app-prod-01', route:[], cwd:'/srv/zerowork', state:'online', timestamp:false, draft:'', log:[{kind:'text',text:'Last login: Wed Oct 28 14:06:32 2026 from 10.20.0.8',dim:true},{kind:'shell',command:'git status --short',output:' M deploy/production.env'},{kind:'shell',command:'pwd',output:'/srv/zerowork'}] };
      const ending = options.waiting ? 'Restart zerowork-api service? [y/N]' : options.running ? 'Checking service health…' : '✓ Service health: healthy\nRelease checks passed.';
      const command = {kind:'shell',command:'./deploy/check-release.sh --interactive',at:'14:08:12',output:'[14:08:12] Checking release 0.2.6…\n✓ Package checksum verified\n✓ Database connection ready\n'+ending};
      const work = {...source,id:18,log:[{kind:'text',text:'Last login: Wed Oct 28 14:08:11 2026 from 10.20.0.8',dim:true},command]};
      if (prior.has(7)) { source.draft=prior.get(7).draft; source.log=prior.get(7).log; }
      if (prior.has(18)) work.draft=prior.get(18).draft;
      if (options.handedOff && prior.has(18)) work.log=prior.get(18).log;
      if (options.existing && options.pty && !source.log.some(entry=>entry.command===command.command)) source.log.push(command);
      sessions = [source];
      if (options.group && !options.closed) sessions.push(work);
      groups = options.group ? [{id:3,name:'部署检查',members:options.closed?[7]:[7,18],direction:'row'}] : [];
      if (options.closed) {
        window.ZeroWorkHistory.register({key:'ai-recording-session-18',name:work.name,user:work.user,address:work.address,source:'ssh',date:'今天',time:'14:08–14:09',duration:'1 分钟',result:'已结束 · 记录已封存',snapshot:work,executionRanges:{'cmd-42':1}});
        window.ZeroWorkHistory.open('ai-recording-session-18');
      }
      active=7;groupMode=options.group;historyOn=false;approvals={};broadcast=false;theme=options.theme;
      document.body.dataset.theme=theme;
      render();
    }
    paintControl();
  }
  function locate(closed, existing) {
    if (closed) { window.ZeroWorkHistory.open('ai-recording-session-18',{executionRef:'cmd-42'});return; }
    else { active=existing?7:18;groupMode=groups.length>0; }
    render();paintControl();
  }
  // Reapply the single annotation when an existing workspace action redraws a pane.
  new MutationObserver(paintControl).observe(document.querySelector('#content'),{childList:true});
  function blockInput(event) {
    if (!event.target.closest('[data-ai-readonly]') || event.target.closest('.session-ai-control')) return;
    if (event.type==='keydown' && (event.key==='Escape'||event.key==='Tab'||event.key==='Home'||event.key==='End'||event.key.startsWith('Arrow')||event.key==='PageUp'||event.key==='PageDown'||((event.metaKey||event.ctrlKey)&&['c','f','a'].includes(event.key.toLowerCase())))) return;
    event.preventDefault();event.stopImmediatePropagation();
  }
  for (const kind of ['beforeinput','paste','drop','compositionstart','keydown','contextmenu']) document.querySelector('#content').addEventListener(kind,blockInput,true);
  return {sync,locate};
})();
/* Editable, deterministic design fixture. No terminal, network, or host execution. */
(() => {
  'use strict';
  const KEY = 'zerowork.v3.ai-session-execution.v1';
  const MODES = {
    auto: ['自行判断', '按命令需要选择批处理或交互式会话。'],
    ask: ['每次询问', '执行前选择运行方式，并在同一处确认命令。'],
    exec: ['批处理', '独立执行命令，回收 stdout、stderr 和退出码。'],
    attach: ['附加现有 PTY', '在选定的已有终端中交互执行，临时交出该终端输入权。'],
    new: ['新建 PTY', '新建可见的 AI 工作会话；当前是单会话时先建立会话组。']
  };
  const POLICIES = { auto_idle: '空闲后关闭', ask: '每次询问', keep: '保留任务会话' };
  const SCENES = {
    settings: '全局运行方式',
    'mode-menu': '输入框运行方式',
    exec: '批处理命令结果',
    ask: '运行方式与执行审批',
    'pty-running': '新 PTY · 运行中',
    'pty-waiting': 'PTY · 等待输入',
    takeover: 'PTY · 用户已接管',
    'pty-done': 'PTY · 已完成',
    'pty-sealing': 'PTY · 记录封存中',
    'pty-stopping': 'PTY · 停止待确认',
    'pty-unknown': 'PTY · 停止结果未知',
    history: '已关闭 · @log 历史',
    cleanup: '任务结束与清理',
    'settings-error': '设置保存失败'
  };
  const ICONS = {
    terminal: '<path d="m4 5 6 7-6 7M13 19h7"/>', plus: '<path d="M12 5v14M5 12h14"/>',
    x: '<path d="m6 6 12 12M18 6 6 18"/>', server: '<rect x="3" y="3" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="7" rx="2"/><path d="M7 6h.01M7 17h.01"/>',
    sidebar: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M8 4v16"/>',
    sparkles: '<path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5zM20 2v4M18 4h4"/>',
    settings: '<path d="m10 3-.8 2.3-2 .9L5 5.8 3 9l1.5 1.8v2.4L3 15l2 3.2 2.2-.4 2 .9L10 21h4l.8-2.3 2-.9 2.2.4 2-3.2-1.5-1.8v-2.4L21 9l-2-3.2-2.2.4-2-.9L14 3z"/><circle cx="12" cy="12" r="3"/>',
    chevron: '<path d="m9 5 7 7-7 7"/>', down: '<path d="m6 9 6 6 6-6"/>',
    folder: '<path d="M3 7V5a2 2 0 0 1 2-2h5l2 3h7a2 2 0 0 1 2 2v11H3z"/>',
    copy: '<rect x="8" y="8" width="12" height="13" rx="2"/><path d="M16 8V3H3v13h5"/>',
    split: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M12 4v16"/>',
    check: '<path d="m5 12 4 4L19 6"/>', lock: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V6a4 4 0 0 1 8 0v4"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    history: '<path d="M3 3v6h6M4 8a9 9 0 1 1-1 8M12 7v5l4 2"/>',
    external: '<path d="M4 5h9v14H4zM9 12h12m-4-4 4 4-4 4"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7h.01"/>',
    alert: '<path d="m12 3 10 18H2zM12 9v5m0 3h.01"/>',
    group: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M10 9v11"/>',
    expand: '<path d="M8 3H3v5m13-5h5v5M3 16v5h5m8 0h5v-5"/>',
    stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    up: '<path d="M12 19V5m-6 6 6-6 6 6"/>',
    more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
    eye: '<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>'
  };
  const esc = value => String(value ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
  const icon = name => `<svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[name] || ICONS.info}</svg>`;
  const iconButton = (name, label, action, extra = '') => `<button class="icon-button" aria-label="${esc(label)}" title="${esc(label)}" data-patch-act="${action}" ${extra}>${icon(name)}</button>`;
  let storageError = false;
  const defaults = { globalMode: 'auto', endPolicy: 'auto_idle', override: 'inherit', overrideEnd: 'inherit', draft: '', permission: 'confirm', settingsDraft: null };
  let saved;
  try { saved = { ...defaults, ...JSON.parse(localStorage.getItem(KEY) || '{}') }; } catch (_) { saved = { ...defaults }; storageError = true; }
  if (!MODES[saved.globalMode]) saved.globalMode = 'auto';
  if (!POLICIES[saved.endPolicy]) saved.endPolicy = 'auto_idle';
  if (saved.override !== 'inherit' && !MODES[saved.override]) saved.override = 'inherit';
  if (saved.overrideEnd !== 'inherit' && !POLICIES[saved.overrideEnd]) saved.overrideEnd = 'inherit';
  if (saved.settingsDraft && (!MODES[saved.settingsDraft.globalMode] || !POLICIES[saved.settingsDraft.endPolicy])) saved.settingsDraft = null;
  const params = new URLSearchParams(location.search);
  let scene = SCENES[params.get('state')] ? params.get('state') : 'pty-running';
  let theme = ['dark', 'light', 'sauber'].includes(params.get('theme')) ? params.get('theme') : 'dark';
  let viewport = params.get('viewport') === 'compact' ? 'compact' : 'default';
  let menuOpen = scene === 'mode-menu';
  assistantOpen = !scene.startsWith('settings');
  let fixtureRequested = true;
  let settingsOpen = scene.startsWith('settings');
  let settingsDraft = saved.settingsDraft || { globalMode: saved.globalMode, endPolicy: saved.endPolicy };
  let saveFailed = scene === 'settings-error';
  let simulateSaveFailure = scene === 'settings-error';
  let askPath = 'new';
  let cleanupState = ['pending', 'cleaned', 'kept'].includes(params.get('cleanup')) ? params.get('cleanup') : 'ready';
  let showProcess = false;
  let focusedPane = null;
  let groupWasExisting = params.get('group') === 'existing';
  let actualTarget = params.get('target') === 'existing' ? 'existing' : 'new';
  let takeoverWaiting = scene === 'takeover';
  let toastText = '';
  let toastTimer;
  const app = document.querySelector('#patch-root');
  const workspaceApp = document.querySelector('#app');
  function persist() {
    try { localStorage.setItem(KEY, JSON.stringify(saved)); storageError = false; return true; }
    catch (_) { storageError = true; return false; }
  }
  function setURL() {
    const next = new URL(location.href);
    next.searchParams.set('state', scene); next.searchParams.set('theme', theme); next.searchParams.set('viewport', viewport);
    if (scene === 'cleanup') next.searchParams.set('cleanup', cleanupState); else next.searchParams.delete('cleanup');
    if (actualTarget === 'existing') next.searchParams.set('target', 'existing'); else next.searchParams.delete('target');
    history.replaceState({}, '', next);
  }
  function go(next) {
    if (next === 'history' || next === 'cleanup') actualTarget = 'new';
    fixtureRequested = true;
    scene = next; menuOpen = next === 'mode-menu'; settingsOpen = next.startsWith('settings');
    assistantOpen = !settingsOpen; showProcess = false; focusedPane = next === 'history' ? 'log' : null;
    saveFailed = next === 'settings-error'; simulateSaveFailure = next === 'settings-error';
    if (next === 'cleanup') cleanupState = 'ready';
    setURL(); render();
  }
  function flash(message) {
    toastText = message; clearTimeout(toastTimer); renderToast();
    toastTimer = setTimeout(() => { toastText = ''; renderToast(); }, 3200);
  }
  function renderToast() {
    app.querySelector('.toast')?.remove();
    if (toastText) app.insertAdjacentHTML('beforeend', `<div class="toast" role="status" data-testid="prototype-toast">${icon('check')}${esc(toastText)}</div>`);
  }
  const isPTY = () => !['settings', 'settings-error', 'exec', 'ask', 'mode-menu'].includes(scene);
  const isActive = () => ['pty-running', 'pty-waiting'].includes(scene);
  const isControlling = () => isActive() || scene === 'pty-stopping';
  const isUnverified = () => ['pty-stopping','pty-unknown'].includes(scene);
  const isClosed = () => scene === 'history' || (scene === 'cleanup' && cleanupState === 'cleaned');
  const hasGroup = () => groupWasExisting || (isPTY() && actualTarget !== 'existing') || scene === 'mode-menu';
  const targetName = () => actualTarget === 'existing' ? 'app-prod-01 · #7' : 'app-prod-01 · #18';
  const targetID = () => actualTarget === 'existing' ? 'session-07' : 'session-18';
  const effectiveMode = () => saved.override === 'inherit' ? saved.globalMode : saved.override;
  const currentPolicy = () => saved.overrideEnd === 'inherit' ? saved.endPolicy : saved.overrideEnd;
  function hostNotice(text) { return `<div class="host-notice" role="note" aria-label="外部消息 · 宿主更新" data-testid="host-notice">${icon('external')}<div><span class="host-notice-source">外部消息<span>宿主更新</span></span><span class="host-notice-text">${text}</span></div></div>`; }
  function statusSlot(status) {
    return `<span class="ap-state-toggle"><span class="ap-status">${V3AI.icon(status==='waiting'?'loader':status==='running'?'loader':'check')}</span><span class="ap-chevron">›</span></span>`;
  }
  function toolCard({ id, name, projection, elapsed, type = '', status = 'done', open = false, detail, actions = '' }) {
    return `<details class="ap-card tool-card ${status}" data-state="${status}" ${open ? 'open' : ''} data-testid="${id}"><summary>${statusSlot(status)}<strong>${name}</strong>${type ? `<span class="type-badge">${type}</span>` : ''}<span class="ap-projection">${esc(projection)}</span><small>${elapsed}</small></summary><div class="ap-card-body tool-detail">${detail}</div>${actions ? `<div class="tool-actions">${actions}</div>` : ''}</details>`;
  }
  function identity(pty) {
    return `<dl class="identity-grid"><dt>主机</dt><dd>app-prod-01</dd><dt>身份</dt><dd>deploy</dd><dt>连接</dt><dd>10.20.1.18:22</dd><dt>目标</dt><dd>${pty ? esc(targetID()) : 'exec-24'}</dd><dt>cwd</dt><dd class="full">/srv/zerowork</dd><dt>命令</dt><dd class="full">${pty ? 'cmd-42' : 'cmd-41'} · 2026-10-28 14:08:12</dd></dl>`;
  }
  function commandCard(pty) {
    const waiting = scene === 'pty-waiting';
    const active = isActive();
    const taken = scene === 'takeover';
    const unverified = isUnverified(), sealing = scene === 'pty-sealing';
    const ended = !active && !taken && !unverified;
    const command = pty ? './deploy/check-release.sh --interactive' : 'git status --short && ./deploy/check-release.sh --check';
    const output = pty ? `Checking release 0.2.6…\n✓ Package checksum verified\n✓ Database connection ready\n${waiting ? 'Restart zerowork-api service? [y/N]' : taken ? 'Restart zerowork-api service? [y/N]' : unverified ? 'Checking service health…' : ended ? '✓ Service health: healthy\nRelease checks passed.' : 'Checking service health…'}` : ' M deploy/production.env\n✓ Package checksum verified\n✓ Database connection ready\nRelease checks passed.';
    const outcome = unverified ? (scene==='pty-stopping'?'中断已请求 · 等待执行证据':'停止结果未知 · AI授权已撤销') : sealing ? '进程已结束 · 记录封存中' : active ? (waiting ? '等待终端输入' : '运行中') : taken ? '用户接管 · 前台仍运行' : '已完成';
    const actions = pty ? `<span class="${waiting ? 'warn' : ''}">${unverified ? '未确认进程退出 · 不自动关闭' : sealing ? '输出边界已确认 · 等待持久化收据' : waiting ? '等待输入 · AI 将在获批后继续' : taken ? 'AI 输入权已撤销' : isClosed() ? '会话已关闭 · 记录可回查' : ended ? '前台已结束 · 输出已保留' : `AI 持有 ${targetID()} 输入权`}</span><button class="text-button" data-patch-act="view-terminal" data-testid="view-terminal">${isClosed() ? '查看记录' : '查看终端'}</button><button class="text-button" data-patch-act="process" data-testid="view-process">查看过程</button>${active || unverified ? `<button class="text-button" data-patch-act="takeover" data-testid="takeover-card">接管输入</button>${waiting ? '<button class="text-button" data-patch-act="confirm-input" data-testid="confirm-pty-input">允许输入 y</button>' : ''}` : ''}` : '<span>命令结果已保留</span><button class="text-button" data-patch-act="copy-command" data-testid="copy-command-result">复制输出</button><button class="text-button" data-patch-act="copy-command-text" data-testid="copy-command-text">复制命令</button>';
    return toolCard({ id: pty ? 'pty-command-card' : 'exec-command-card', name: '执行命令', type: pty ? '交互式' : '批处理', projection: command, elapsed: active ? '3.2s' : '6.8s', status: waiting || taken || unverified || sealing ? 'waiting' : active ? 'running' : 'done', open: true,
      detail: `${identity(pty)}<pre class="code-block" data-copy-command="${esc(command)}">$ ${esc(command)}</pre><div class="output-label">${pty ? '终端输出 · stdout / stderr 合流' : 'stdout'}</div><pre class="code-block" data-copy-output>${esc(output)}</pre>${!pty ? '<div class="output-label">stderr</div><pre class="code-block muted">（无输出）</pre>' : ''}<div class="result-row"><span class="${taken ? 'warn' : active ? waiting ? 'warn' : 'accent' : 'good'}">${outcome}</span><span>${pty ? 'exit —（PTY 未提供）' : 'exit 0'}</span><span>elapsed ${active ? '3.2s' : '6.8s'}</span><span>${pty ? esc(targetID()) : 'exec-24'}</span></div>`, actions });
  }
  function setupCards() {
    if (actualTarget === 'existing') return '';
    return `${!groupWasExisting ? toolCard({ id: 'create-group-step', name: '创建会话组', projection: '部署检查 · 原会话 #7', elapsed: '24ms', detail: '<dl class="identity-grid"><dt>会话组</dt><dd>部署检查 · #3</dd><dt>初始成员</dt><dd>app-prod-01 · #7</dd></dl><p>原会话已加入，当前对话、草稿与历史继续保留。</p>' }) : ''}${toolCard({ id: 'open-session-step', name: '新建会话', projection: 'app-prod-01 · 工作会话 #18', elapsed: '186ms', detail: '<dl class="identity-grid"><dt>会话组</dt><dd>部署检查 · #3</dd><dt>工作会话</dt><dd>app-prod-01 · #18</dd><dt>目录</dt><dd class="full">/srv/zerowork</dd></dl><p>工作终端已就绪，后续命令在此任务内复用。</p>' })}`;
  }
  function approvalCard() {
    const paths = { exec: '批处理', attach: '现有 PTY', new: '新建 PTY' };
    const target = askPath === 'exec' ? '独立 exec · deploy@10.20.1.18' : askPath === 'attach' ? '用户终端 · session-07（已有）' : hasGroup() ? '当前组新建 AI · 部署检查' : '将当前会话建组，再新建工作会话';
    const impact = askPath === 'exec' ? '读取部署检查结果；不改变终端输入权。' : askPath === 'attach' ? 'AI 临时持有当前 session-07 的输入权，可随时接管；不会创建会话或会话组。' : hasGroup() ? '在当前组新建任务会话；用户终端继续接收输入。' : '将 session-07 正式加入新会话组，再新建 session-18；原会话继续接收输入。';
    return `<section class="approval" data-testid="execution-approval"><div class="approval-head">${icon('alert')}<strong>选择运行方式并确认执行</strong></div><div class="approval-body"><p class="approval-intro">这条检查需要确认后继续。</p><div class="approval-paths" role="group" aria-label="本次运行方式">${Object.entries(paths).map(([key, label]) => `<button class="${askPath === key ? 'selected' : ''}" data-patch-act="ask-path" data-value="${key}" aria-pressed="${askPath === key}" data-testid="approval-path-${key}">${label}</button>`).join('')}</div><div class="approval-target">目标：${target}<br>目录：/srv/zerowork</div><pre class="code-block">./deploy/check-release.sh ${askPath === 'exec' ? '--check' : '--interactive'}</pre><p>${impact}</p></div><div class="approval-footer"><button class="button subtle" data-patch-act="reject-execution" data-testid="reject-execution">拒绝</button><button class="button primary" data-patch-act="approve-execution" data-testid="approve-execution">确认并执行</button></div></section>`;
  }
  function cleanupCard() {
    const labels = { ready: ['任务已结束', '只处理 AI 创建的 session-18。'], pending: ['清理待核实', '关闭请求未获确认，暂不标记已清理。'], cleaned: ['已清理任务会话', 'session-18 已关闭，记录已保留。'], kept: ['已保留任务会话', 'session-18 继续留在当前会话组。'] };
    const label = labels[cleanupState];
    return `<div class="cleanup-row" data-testid="cleanup-status">${icon(cleanupState === 'pending' ? 'alert' : 'check')}<div><strong>${label[0]}</strong><small>${label[1]} 原会话与会话组保持打开。</small></div>${cleanupState === 'ready' ? '<button class="button subtle" data-patch-act="keep-session" data-testid="keep-task-session">保留</button><button class="button secondary" data-patch-act="close-task" data-testid="close-task-session">关闭任务会话</button>' : cleanupState === 'pending' ? '<button class="text-button" data-patch-act="verify-cleanup" data-testid="verify-cleanup">核实状态</button>' : cleanupState === 'cleaned' ? '<button class="text-button" data-patch-act="view-terminal">查看记录</button>' : '<button class="text-button" data-patch-act="close-task">关闭任务会话</button>'}</div>`;
  }
  function transcript() {
    if (scene === 'ask') return `<div class="assistant-question ap-user-bubble question">帮我检查 0.2.6 的部署环境。</div><div class="assistant-answer answer">我会在 app-prod-01 检查发布环境和服务状态。</div>${approvalCard()}`;
    if (scene === 'exec') return `<div class="assistant-question ap-user-bubble question">检查部署环境，不要占用我的终端。</div>${commandCard(false)}<div class="assistant-answer answer">检查通过。发现一处尚未提交的部署配置，请发布前核对。</div>${turnStatus(false)}`;
    if (scene === 'mode-menu') return `<div class="assistant-question ap-user-bubble question">检查 0.2.6 的部署环境。</div><div class="assistant-answer answer">在这里选择当前对话的运行方式。当前沿用全局设置：${MODES[saved.globalMode][0]}。</div>${turnStatus(false)}`;
    let notices = actualTarget === 'existing' ? hostNotice('<strong>已使用现有终端</strong> · session-07 输入权交给 AI') : groupWasExisting ? hostNotice('<strong>已在当前组新建会话</strong> · AI · 部署检查') : hostNotice('<strong>已创建会话组</strong> · 部署检查 · 原会话保留');
    if(isUnverified()) notices+=hostNotice('<strong>停止请求已受理</strong> · 进程退出与记录边界尚未确认，不自动清理');
    if (scene === 'takeover') notices += hostNotice('<strong>用户已接管</strong> · AI 后续写入已撤销');
    if (isClosed()) notices += hostNotice('<strong>会话已关闭，记录已保留</strong> · session-18');
    return `<div class="assistant-question ap-user-bubble question">检查 0.2.6 的部署环境，保留执行过程。</div>${notices}${setupCards()}${commandCard(true)}${scene==='pty-stopping'?'<button class="text-button" data-patch-act="verify-stop" data-testid="verify-stop">核实停止状态</button>':''}${scene==='pty-sealing'?'<button class="text-button" data-patch-act="seal-record" data-testid="seal-record">确认记录封存收据</button>':''}${scene === 'pty-done' ? actualTarget === 'existing' ? '<div class="assistant-answer answer">检查已结束，已有终端的输入权已交还。该会话随任务保留。</div>' : '<div class="assistant-answer answer">检查已结束，输出与过程已保留。</div><div class="cleanup-row"><div><strong>任务会话 · session-18</strong><small>当前策略：' + esc(POLICIES[currentPolicy()]) + (currentPolicy() === 'auto_idle' ? ' · 空闲状态待核实' : '') + '</small></div><button class="text-button" data-patch-act="open-cleanup">处理任务会话</button></div>' : ''}${scene === 'cleanup' ? cleanupCard() : ''}${scene === 'takeover' ? '<div class="assistant-answer answer">输入权已交还，前台程序仍在等待。需要我继续时，将重新请求输入权。</div>' : ''}${turnStatus(isActive())}`;
  }
  function turnStatus(running) {
    return `<div class="turn-status">${icon('sparkles')}<span class="label">${scene==='pty-stopping'?'停止请求待核实':scene==='pty-unknown'?'AI控制已结束 · 执行结果未知':scene==='pty-sealing'?'进程已结束 · 记录封存中':running ? scene === 'pty-waiting' ? '等待确认输入' : '正在检查部署环境' : scene === 'takeover' ? 'AI 已暂停' : '回合结束'}</span><span>·</span><span>${running ? '3.2 秒' : '6.8 秒'}</span><span>·</span><span>Token 1,286</span></div>`;
  }
  function modeMenu() {
    if (!menuOpen) return '';
    return `<div class="mode-menu" role="menu" aria-label="当前对话运行方式" data-testid="run-mode-menu"><div class="menu-heading"><span>当前对话运行方式</span><span>⌥R</span></div><div class="mode-menu-body"><button class="mode-option ${saved.override === 'inherit' ? 'selected' : ''}" data-patch-act="mode-select" data-value="inherit" role="menuitemradio" aria-checked="${saved.override === 'inherit'}" data-testid="mode-inherit"><span class="check">${saved.override === 'inherit' ? '✓' : ''}</span><span class="option-label">沿用全局</span><small>${MODES[saved.globalMode][0]}</small></button><div class="menu-divider"></div>${Object.entries(MODES).map(([key, value]) => `<button class="mode-option ${saved.override === key ? 'selected' : ''}" data-patch-act="mode-select" data-value="${key}" role="menuitemradio" aria-checked="${saved.override === key}" data-testid="mode-${key}"><span class="check">${saved.override === key ? '✓' : ''}</span><span class="option-label">${value[0]}</span>${key === 'attach' || key === 'new' ? '<small>交互式</small>' : ''}</button>`).join('')}<div class="menu-divider"></div><div class="menu-policy"><label for="override-end-policy">任务结束后</label><select id="override-end-policy" data-testid="override-end-policy"><option value="inherit" ${saved.overrideEnd === 'inherit' ? 'selected' : ''}>沿用全局 · ${POLICIES[saved.endPolicy]}</option>${Object.entries(POLICIES).map(([key, value]) => `<option value="${key}" ${saved.overrideEnd === key ? 'selected' : ''}>${value}</option>`).join('')}</select></div></div><div class="menu-bottom"><button class="text-button" data-patch-act="settings">全局 AI 设置</button><button class="text-button" data-patch-act="close-menu" data-testid="close-mode-menu">完成</button></div></div>`;
  }
  // The existing workspace owns the only assistant shell, header and composer.
  const renderWorkspaceAssistant = renderAssistant;
  renderAssistant = function () {
    renderWorkspaceAssistant();
    const root=document.querySelector('#assistant');
    root.dataset.executionPatch='true';root.dataset.testid='assistant';
    if(!assistantOpen)return;
    const messages=root.querySelector('#ai-messages');
    messages.classList.toggle('patch-transcript',!!aiData().executionPatch);
    const composer=root.querySelector('.v3-ai-composer'),row=root.querySelector('.v3-ai-control-row');
    if(!row)return;
    const permission=row.querySelector('[data-act="ai-permission"]');
    permission.dataset.testid='permission-trigger';
    permission.insertAdjacentHTML('afterend',`<button class="ai-control" data-patch-act="toggle-mode" data-testid="run-mode-trigger" aria-haspopup="menu" aria-expanded="${menuOpen}" title="当前对话运行方式">${V3AI.icon('terminal')}<span>${MODES[effectiveMode()][0]}</span>${V3AI.icon('down')}</button>`);
    // Preserve the actual shared controls and their listeners; only reorder them.
    const usage=row.querySelector('[data-act="ai-context-usage"]'),model=row.querySelector('[data-act="ai-model"]'),send=row.querySelector('.ai-send');
    const gap=row.querySelector('.spacer');
    gap.after(usage,model);
    usage.dataset.testid='context-budget';
    model.dataset.testid='model-trigger';
    send.dataset.testid=isActive()?'stop-execution':'send-message';
    row.querySelector('[data-act="ai-attach"]').dataset.testid='attachment-trigger';
    const input=root.querySelector('#ai-input');input.dataset.testid='composer-draft';
    composer.insertAdjacentHTML('beforeend',modeMenu());
  };
  function settings() {
    if (!settingsOpen) return '';
    return `<div class="settings-layer"><section class="settings-window" role="dialog" aria-modal="true" aria-labelledby="settings-title" data-testid="ai-settings"><header class="settings-title"><span id="settings-title">偏好设置</span>${iconButton('x', '关闭偏好设置', 'close-settings')}</header><div class="settings-layout"><nav class="settings-nav" aria-label="偏好设置分类"><button data-patch-act="settings-nav" data-value="通用">${icon('settings')}通用</button><button data-patch-act="settings-nav" data-value="外观">${icon('eye')}外观</button><button data-patch-act="settings-nav" data-value="终端">${icon('terminal')}终端</button><button class="active" data-patch-act="settings-ai">${icon('sparkles')}AI 助手</button><button data-patch-act="settings-nav" data-value="连接">${icon('server')}连接</button></nav><div class="settings-main"><h2>AI 助手</h2><p class="subtitle">设置后续执行的默认运行方式。对话可单独调整。</p><section class="setting-section"><h3>默认运行方式</h3><div class="setting-card">${Object.entries(MODES).map(([key, value]) => `<label class="setting-radio"><input type="radio" name="global-mode" value="${key}" ${settingsDraft.globalMode === key ? 'checked' : ''} data-testid="global-mode-${key}"><span><strong>${value[0]}${key === 'auto' ? '<span class="default-label">默认</span>' : key === 'attach' || key === 'new' ? '<span class="default-label">交互式</span>' : ''}</strong><p>${value[1]}</p></span></label>`).join('')}</div></section><section class="setting-section"><h3>任务结束后</h3><div class="setting-card"><div class="setting-inline"><div><strong>任务会话处理</strong><p>只作用于 AI 创建的任务会话，关闭后保留记录。</p></div><select id="global-end-policy" data-testid="global-end-policy" aria-label="任务结束策略">${Object.entries(POLICIES).map(([key, value]) => `<option value="${key}" ${settingsDraft.endPolicy === key ? 'selected' : ''}>${value}</option>`).join('')}</select></div></div></section></div></div><footer class="settings-footer">${saveFailed ? `<span class="save-error" role="alert" data-testid="settings-save-error">${icon('alert')}保存失败，修改已保留。请重试。</span>` : '<span class="save-note">用于后续执行，当前执行不变。</span>'}<button class="button subtle" data-patch-act="revert-settings" data-testid="revert-settings">还原</button><button class="button primary" data-patch-act="save-settings" data-testid="save-settings">${saveFailed ? '重试保存' : '保存'}</button></footer></section></div>`;
  }
  function processPanel() {
    if (!showProcess) return '';
    const steps = actualTarget === 'existing' ? [['14:08:12', '交互式执行', 'session-07 · 临时输入权授予 AI']] : [...(!groupWasExisting ? [['14:08:11', '创建会话组', 'group-03 · 原 session-07 正式进入组']] : []), ['14:08:11', '新建工作会话', 'group-03 / session-18 · app-prod-01'], ['14:08:12', '交互式执行', 'session-18 / cmd-42 · /srv/zerowork']];
    if(isUnverified()) steps.push(['14:08:15','停止执行','停止已请求 · 退出证据待核实']);
    if (scene === 'takeover') steps.push(['14:08:15', '外部消息', '用户已接管 · AI 写入权已撤销']);
    if (isClosed()) steps.push(['14:08:19', '外部消息', '会话已关闭，记录已保留 · @log / cmd-42']);
    return `<section class="process-panel" data-testid="process-panel" aria-label="执行过程"><header class="process-head"><strong>执行过程</strong><span class="spacer"></span>${iconButton('x', '关闭过程', 'close-process')}</header><div class="host-notice">${icon(hasGroup() ? 'group' : 'terminal')}${hasGroup() ? '部署检查 · 组 #3' : 'app-prod-01 · 会话 #7'}</div>${steps.map(([time, name, detail]) => `<div class="process-line"><time>${time}</time><div><code>${name}</code><p>${detail}</p></div></div>`).join('')}<div class="menu-divider"></div><div class="process-line"><time>输入权</time><div><p>${isControlling() ? `${targetName()} · AI（停止待确认时禁止后续派发）` : isUnverified() ? `${targetName()} · AI授权已撤销，结果未知` : scene === 'takeover' ? `${targetName()} · 用户接管` : isClosed() ? '任务会话已关闭 · 历史只读' : `${targetName()} · 已交还用户`}</p></div></div></section>`;
  }
  function render() {
    document.body.dataset.theme = theme; document.body.dataset.viewport = viewport;
    document.querySelector('#review-state').innerHTML = Object.entries(SCENES).map(([key, value]) => `<option value="${key}" ${scene === key ? 'selected' : ''}>${value}</option>`).join('');
    document.querySelector('#review-theme').value = theme; document.querySelector('#review-viewport').value = viewport;
    patchWorkspace.sync({group:hasGroup(),closed:isClosed(),existing:actualTarget==='existing',controlled:isControlling(),pty:isPTY(),waiting:scene==='pty-waiting'||(scene==='takeover'&&takeoverWaiting),handedOff:scene==='takeover',running:isActive()||isUnverified(),theme,size:viewport});
    const d=aiData();
    if(fixtureRequested||d.executionPatch){
      d.executionPatch=true;d.messages=[transcript()];d.draft=saved.draft;
      d.running=isActive();d.stopping=scene==='pty-stopping';
      d.prototypePrimaryState=scene==='ask'?'approval':'send';
      fixtureRequested=false;
    }
    app.innerHTML = settings() + processPanel();
    renderAssistant();
    renderToast();
    if ((isPTY() || (viewport === 'compact' && scene === 'ask')) && assistantOpen) {
      const transcript = document.querySelector('#ai-messages');
      transcript.scrollTop = transcript.scrollHeight - transcript.clientHeight;
    }
  }
  function openSettings() {
    settingsDraft = saved.settingsDraft || { globalMode: saved.globalMode, endPolicy: saved.endPolicy };
    settingsOpen = true; menuOpen = false; render();
    app.querySelector('input[name="global-mode"]:checked')?.focus();
  }
  workspaceApp.addEventListener('click', async event => {
    const button = event.target.closest('[data-patch-act]'); if (!button) return;
    const action = button.dataset.patchAct;
    switch (action) {
      case 'settings': openSettings(); break;
      case 'close-settings': settingsOpen = false; saveFailed = false; if (scene.startsWith('settings')) go('mode-menu'); else { render(); app.querySelector('[data-testid="open-settings"]')?.focus(); } break;
      case 'revert-settings': settingsDraft = { globalMode: saved.globalMode, endPolicy: saved.endPolicy }; saved.settingsDraft = null; persist(); saveFailed = false; render(); break;
      case 'save-settings':
        saved.settingsDraft = { ...settingsDraft };
        if (simulateSaveFailure) {
          simulateSaveFailure = false; persist(); saveFailed = true; render();
        } else {
          const previous = { globalMode: saved.globalMode, endPolicy: saved.endPolicy };
          saved.globalMode = settingsDraft.globalMode; saved.endPolicy = settingsDraft.endPolicy; saved.settingsDraft = null;
          if (persist()) { saveFailed = false; render(); flash('默认运行方式已保存'); }
          else { Object.assign(saved, previous); saved.settingsDraft = { ...settingsDraft }; saveFailed = true; render(); }
        }
        break;
      case 'toggle-mode': menuOpen = !menuOpen; render(); if (menuOpen) workspaceApp.querySelector('.mode-option.selected')?.focus(); break;
      case 'close-menu': menuOpen = false; render(); workspaceApp.querySelector('[data-testid="run-mode-trigger"]')?.focus(); break;
      case 'mode-select': saved.override = button.dataset.value; persist(); menuOpen = false; render(); flash(saved.override === 'inherit' ? `已沿用全局：${MODES[saved.globalMode][0]}` : `当前对话：${MODES[saved.override][0]}`); workspaceApp.querySelector('[data-testid="run-mode-trigger"]')?.focus(); break;
      case 'ask-path': askPath = button.dataset.value; render(); app.querySelector(`[data-testid="approval-path-${askPath}"]`)?.focus(); break;
      case 'approve-execution': actualTarget = askPath === 'attach' ? 'existing' : 'new'; go(askPath === 'exec' ? 'exec' : 'pty-running'); flash('已批准本次执行'); break;
      case 'reject-execution': go('mode-menu'); menuOpen = false; render(); flash('本次执行已拒绝'); break;
      case 'takeover': takeoverWaiting=scene==='pty-waiting';go('takeover'); flash('已接管输入，AI 后续写入已撤销'); break;
      case 'stop': go('pty-stopping');flash('已请求中断，等待执行证据');break;
      case 'verify-stop': go('pty-unknown');flash('未取得退出证据，已撤销AI输入授权；会话保留');break;
      case 'seal-record': go('pty-done');flash('记录封存已确认，可按空闲资格处理会话');break;
      case 'complete': go('pty-sealing'); flash('前台已结束，正在封存输出记录'); break;
      case 'confirm-input': go('pty-running'); flash(`已批准向 ${targetID()} 输入 y`); break;
      case 'open-cleanup': go('cleanup'); break;
      case 'keep-session': cleanupState = 'kept'; setURL(); render(); flash('任务会话已保留'); break;
      case 'close-task': cleanupState = 'pending'; setURL(); render(); flash('正在核实任务会话关闭状态'); break;
      case 'verify-cleanup': cleanupState = 'cleaned'; focusedPane = 'log'; setURL(); render(); flash('任务会话已关闭，记录已保留'); break;
      case 'view-terminal': focusedPane = isClosed() ? 'log' : actualTarget === 'existing' ? 'user' : 'ai'; assistantOpen = false; menuOpen = false; render(); patchWorkspace.locate(isClosed(),actualTarget==='existing'); flash(isClosed() ? '已打开 @log 历史 · cmd-42' : `已定位 ${targetName()} · cmd-42`); break;
      case 'toggle-assistant': assistantOpen = !assistantOpen; menuOpen = false; render(); break;
      case 'process': showProcess = !showProcess; render(); break;
      case 'close-process': showProcess = false; render(); break;
      case 'send': {
        if (!saved.draft.trim()) { document.querySelector('#ai-input')?.focus(); break; }
        const text = saved.draft; saved.draft = ''; persist();
        const mode = effectiveMode(); actualTarget = mode === 'attach' ? 'existing' : 'new';
        go(mode === 'ask' ? 'ask' : mode === 'exec' ? 'exec' : 'pty-running');
        const question = app.querySelector('.question'); if (question) question.textContent = text;
        flash(mode === 'ask' ? '等待选择运行方式并确认' : '已开始检查部署环境'); break;
      }
      case 'copy-command': case 'copy-command-text': {
        const card=button.closest('.tool-card');
        const text=action==='copy-command-text'?card.querySelector('[data-copy-command]').dataset.copyCommand:card.querySelector('[data-copy-output]').textContent;
        try { await navigator.clipboard.writeText(text); flash('已复制'); } catch (_) { flash('复制受限，请选中文本后复制'); } break;
      }

      case 'close-tab': flash('当前会话组保留，任务会话可在回合结束后处理'); break;
      case 'new-session': flash('当前组的新会话入口'); break;
      case 'new-connection': flash('连接配置沿用现有 V3 入口'); break;
      case 'select-host': focusedPane = 'user'; render(); flash('已定位 app-prod-01'); break;
      case 'select-staging': case 'select-local': flash('当前任务保持在 app-prod-01'); break;
      case 'split-view': flash(hasGroup() ? '当前为双会话并排布局' : '新建 PTY 后显示双会话'); break;
      case 'settings-nav': flash(`${button.dataset.value}设置沿用现有 V3 页面`); break;
      default: break;
    }
  });
  workspaceApp.addEventListener('input', event => {
    if (event.target.id === 'ai-input') {
      saved.draft = event.target.value; persist();
      const send=workspaceApp.querySelector('#assistant .ai-send');
      if(aiData().executionPatch&&send)send.disabled=scene==='pty-stopping'||(!isActive()&&!saved.draft.trim());
    }
    if (event.target.name === 'global-mode') { settingsDraft.globalMode = event.target.value; saved.settingsDraft = { ...settingsDraft }; persist(); }
  });
  workspaceApp.addEventListener('change', event => {
    if (event.target.id === 'global-end-policy') { settingsDraft.endPolicy = event.target.value; saved.settingsDraft = { ...settingsDraft }; persist(); }
    if (event.target.id === 'override-end-policy') { saved.overrideEnd = event.target.value; persist(); flash('当前对话任务结束策略已保存'); }
  });
  document.querySelector('#review-state').addEventListener('change', event => go(event.target.value));
  document.querySelector('#review-theme').addEventListener('change', event => { theme = event.target.value; setURL(); render(); });
  document.querySelector('#review-viewport').addEventListener('change', event => { viewport = event.target.value; setURL(); render(); });
  document.querySelector('[data-patch-act="reset"]').addEventListener('click', () => {
    try { localStorage.removeItem(KEY); } catch (_) { /* Leave unrelated keys intact. */ }
    saved = { ...defaults }; settingsDraft = { globalMode: 'auto', endPolicy: 'auto_idle' }; cleanupState = 'ready'; actualTarget = 'new';
    go('pty-running'); flash('已重置本原型的设置与草稿');
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') {
      if (showProcess) { showProcess = false; render(); }

      else if (menuOpen) { menuOpen = false; render(); workspaceApp.querySelector('[data-testid="run-mode-trigger"]')?.focus(); }
      else if (settingsOpen) { settingsOpen = false; if (scene.startsWith('settings')) go('mode-menu'); else render(); }
    }

    if (event.altKey && event.key.toLowerCase() === 'r') { event.preventDefault(); assistantOpen = true; menuOpen = !menuOpen; render(); workspaceApp.querySelector('.mode-option.selected')?.focus(); }

  });
  workspaceApp.addEventListener('click',event=>{
    const action=event.target.closest('[data-act]')?.dataset.act;
    if(!aiData().executionPatch||!['ai-send','ai-stop'].includes(action))return;
    event.preventDefault();event.stopImmediatePropagation();
    if(action==='ai-stop'){go('pty-stopping');flash('已请求中断，等待执行证据');return;}
    const input=document.querySelector('#ai-input');
    if(!input.value.trim())return;
    saved.draft=input.value;
    // Dispatch through the same fixture action as its review controls.
    const mode=effectiveMode();actualTarget=mode==='attach'?'existing':'new';
    const question=saved.draft;saved.draft='';persist();
    go(mode==='ask'?'ask':mode==='exec'?'exec':'pty-running');
    const bubble=document.querySelector('#ai-messages .question');if(bubble)bubble.textContent=question;
  },true);
  setURL(); render();
})();
