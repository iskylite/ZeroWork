// The pending request occupies the same transcript slot as its later execution.
(() => {
 const query = new URLSearchParams(location.search);
 if (!query.has('approval')) return;
 const main = document.querySelector('main'), footer = document.querySelector('#turn');
 main.querySelectorAll('details,.answer').forEach(node => node.remove());
 const prose = document.createElement('article');
 prose.className = 'answer'; prose.dataset.testid = 'ai.message.assistant';
 prose.textContent = '我会先请求确认，再在当前终端执行这条命令。';
 const card = document.createElement('section');
 card.className = 'approval'; card.dataset.testid = 'ai.host_approval';
 card.innerHTML = `<div class="approval-head"><span>⌘</span><strong>请求执行命令</strong><span class="approval-target">当前终端 · 会话 #1</span><span class="approval-state">待确认</span></div><div class="approval-body"><div class="approval-command"><pre>printf APPROVAL_NATIVE_OK</pre><button aria-label="复制完整命令">⧉</button></div><div class="approval-impact"><span>⚠</span><span>批准后将在此终端执行。执行期间由 AI 控制输入，可随时停止或接管。</span></div></div><div class="approval-footer"><button data-decision="reject">拒绝此调用</button><button class="primary" data-decision="approve">批准此调用</button></div>`;
 footer.before(prose, card);
 let expired = query.has('expired'), timer;
 const state = () => {
  card.dataset.state = expired ? 'expired' : 'pending';
  card.querySelector('.approval-state').textContent = expired ? '已过期 · 流程暂停' : '待确认';
  card.querySelector('[data-decision="approve"]').textContent = expired ? '重新确认' : '批准此调用';
  footer.querySelector('.label').textContent = expired ? '审批已过期 · 流程暂停' : '等待确认 · 流程暂停';
  footer.querySelector('.label').setAttribute('aria-label',footer.querySelector('.label').textContent);
 };
 const arm = () => { clearTimeout(timer); timer = setTimeout(() => { expired = true; state(); }, 120000); };
 card.querySelector('[data-decision="approve"]').onclick = () => {
  if (expired) { expired = false; state(); arm(); return; }
  clearTimeout(timer);
  const step = document.createElement('details'); step.dataset.testid = 'ai.step.tool';
  step.innerHTML = `<summary><span class="slot"><span class="status">✓</span><span class="chevron">›</span></span><strong>执行命令</strong><span class="projection">已批准 · printf APPROVAL_NATIVE_OK</span><span class="elapsed">97ms</span></summary><div class="details"><pre>APPROVAL_NATIVE_OK
exit 0</pre></div>`;
  card.replaceWith(step);
  const answer = document.createElement('article'); answer.className = 'answer'; answer.textContent = '命令已执行，退出码为 0。'; footer.before(answer);
  footer.querySelector('.label').textContent = '回合结束'; footer.querySelector('.label').setAttribute('aria-label','回合结束');
 };
 card.querySelector('[data-decision="reject"]').onclick = () => {
  clearTimeout(timer); const notice = document.createElement('article'); notice.className = 'answer'; notice.textContent = '已拒绝此调用，命令未执行。'; card.replaceWith(notice); footer.querySelector('.label').textContent = '已停止'; footer.querySelector('.label').setAttribute('aria-label','已停止');
 };
 card.querySelector('[aria-label="复制完整命令"]').onclick = () => navigator.clipboard?.writeText('printf APPROVAL_NATIVE_OK');
 state(); main.scrollTop = main.scrollHeight; if (!expired) arm();
})();
