'use strict';
// Local fixtures only. Rendering reuses V3AI; no host notification or model call.
(() => {
  const $ = s => document.querySelector(s), esc = V3AI.escape;
  const query = new URLSearchParams(location.search);
  const rules = {
    rollback: {title:'回退完成，安静地确认',copy:'保留已有的滚动区布局。中性图标和短文案说明结果，可关闭，不追加助手答复。',place:'transcript 的回退位置',life:'关闭、再次发送或切换对话后清除',global:'不进入全局通知，也不制造全局未读'},
    validation: {title:'发送前的问题，留在输入处',copy:'明确指出图片与模型不兼容，并把恢复动作放在同一处。输入问题不占用对话消息。',place:'当前附件及 composer 内',life:'条件变化后重新校验；编辑草稿不清除阻塞',global:'不提醒'},
    failure: {title:'失败跟随原回合，恢复动作就地可达',copy:'沿用已有失败恢复卡，保留问题和附件。原因默认可读，技术详情展开查看，不再叠加全局错误。',place:'失败的原回合',life:'作为该回合结果保留；重试更新当前恢复状态',global:'默认不提醒，未查看状态归属该对话'},
    approval: {title:'待确认是一项操作，不是警报',copy:'命令、目标和影响在原工具卡说明。用户离开此对话后，可以提醒一次；批准仍须回到这张卡。',place:'对应工具卡',life:'处理前保留；批准或拒绝后原位更新',global:'未查看且确实阻塞任务时，按位置提醒一次'},
    unknown: {title:'未知结果保留在产生它的步骤',copy:'区分“本地停止”和“远端是否执行”。禁止直接重放可能已经执行的写入，先提供核查入口。',place:'对应执行卡',life:'核查前保留；新证据更新原卡',global:'本例为已派发的变更命令，需介入且未查看时提醒一次'},
    host: {title:'接管是一条宿主事实',copy:'轻量行内提示说明控制权变化，靠近相关执行。由宿主生成，不伪装成模型答复。',place:'相关执行步骤之后',life:'随相关执行记录保留',global:'用户主动接管，不提醒'},
    stopped: {title:'主动停止，更新当前状态就足够',copy:'保留已有内容，在回合状态行说明已停止。不为用户刚刚执行的动作再弹一条通知。',place:'原回合状态行',life:'随该回合保留',global:'不提醒'},
    complete: {title:'答复本身就是完成反馈',copy:'显示最终结果和回合结束状态。无需再写“已完成”，也无需全局弹窗重复宣布。',place:'答复及回合状态行',life:'随该回合保留',global:'仅离开应用且明确开启后台完成提醒时通知'},
    long: {title:'长路径进详情，不把提示撑成日志',copy:'保留可读的问题与恢复动作。完整路径可展开、换行查看，提示不截断关键原因，也不挤压输入控件。',place:'附件的原步骤卡',life:'重试成功或移除附件后解除',global:'不提醒'}
  };
  let state = rules[query.get('state')] ? query.get('state') : 'rollback';
  let draft = '检查部署日志，确认服务是否恢复。';
  let resolved = false, retries = 0, delivered = false, hasImage = true, compatibleModel = false, reminderNode = null, noticeSequence = 0;
  const question = '<div class="notice-question">检查部署日志，确认服务是否恢复。</div>';
  const activity = (label,detail) => `<footer class="notice-lifecycle"><img src="../assets/ai/assistant-logo.png" alt=""><span>${esc(label)}</span><i></i><span>${esc(detail)}</span></footer>`;
  const action = (id,label,primary=false) => `<button type="button" data-action="${id}" class="${primary?'primary':''}">${label}</button>`;
  function commandCard(title,status,body,footer='') {
    return `<section class="notice-command" data-testid="ai-notice-step"><header>${V3AI.icon('terminal')}<strong>${esc(title)}</strong><span>${esc(status)}</span></header>${body}${footer?`<footer>${footer}</footer>`:''}</section>`;
  }
  function transcript() {
    if(state==='rollback')return resolved?'':V3AI.localNotice({kind:'rollback',message:'已回退，原消息已恢复到输入框。',detail:'此回合及后续对话已移除。',rootAttrs:{'data-testid':'ai-local-notice'}});
    if(state==='validation')return question+'<article class="notice-answer"><p>部署日志显示服务已经恢复。可继续补充截图，检查页面状态。</p></article>'+activity('回合结束','已运行 12 秒');
    if(state==='failure')return question+(resolved?'<article class="notice-answer"><p>服务已恢复，最近一次健康检查返回正常。</p></article>'+activity('回合结束','已运行 18 秒'):V3AI.recoveryCard({status:'HTTP 429',reason:'模型服务暂时限流，请稍后重试。',detail:'rate_limit_exceeded\n请求未继续生成答复。已完成的工具调用不会重复执行。',retries,retained:'问题和附件已保留',retryAttrs:{'data-action':'retry'},editAttrs:{'data-action':'edit'}}));
    if(state==='approval')return question+commandCard('执行命令',resolved?'已拒绝 · 未派发':'等待你确认','<p>prod-web-01 · /srv/app</p><pre>systemctl restart app</pre><p>将重启应用服务，现有请求可能短暂中断。</p>',resolved?'':action('reject','拒绝此调用')+action('approve','批准此调用',true))+activity(resolved?'回合已停止':'等待你确认','已运行 8 秒');
    if(state==='unknown')return question+commandCard('执行命令',resolved?'已核查':'结果待核查','<p>prod-web-01 · /srv/app</p><pre>systemctl restart app</pre><p>'+(resolved?'服务当前运行正常。原命令退出状态仍未确认。':'命令已派发，连接随后中断，尚未确认退出状态。')+'</p><details><summary>查看执行详情</summary><p>本地请求已结束。'+(resolved?'核查返回服务状态为 active；这不能证明原命令的退出码。':'服务是否已经重启尚未确认。核查前不重新执行原命令。')+'</p></details>',resolved?'':action('verify','核查服务状态',true));
    if(state==='host')return question+commandCard('执行命令','控制权已交回','<pre>tail -f /var/log/app.log</pre>')+V3AI.localNotice({kind:'host',message:'你已接管终端，AI 不再向此终端输入。',detail:'终端内的进程仍可能运行。',rootAttrs:{'data-testid':'ai-local-notice'}});
    if(state==='stopped')return question+'<article class="notice-answer"><p>已读取到最近一次启动记录。</p></article>'+activity('已停止','已运行 6 秒');
    if(state==='complete')return question+'<article class="notice-answer"><p>服务已恢复。</p><p>最近一次健康检查返回 200，部署后未出现新的启动错误。</p></article>'+activity('回合结束','已运行 12 秒 · Token 846');
    const path='/srv/app/'+('发布记录/').repeat(24)+'deployment-2026-10-29.log';
    return question+commandCard('读取附件',resolved?'已移除':'读取失败','<p>'+(resolved?'此附件已从待发送内容中移除，其他草稿保留。':'deployment-2026-10-29.log · 没有读取权限。')+'</p>'+(resolved?'':`<details><summary>查看完整路径</summary><p>${esc(path)}</p></details>`),resolved?'':action('remove-file','移除附件')+action('retry-file','重试读取',true));
  }
  function issue() {
    if(state!=='validation'||!hasImage||compatibleModel)return undefined;
    return {message:'当前模型不支持图片，截图尚未发送。',actions:[{label:'选择兼容模型',attrs:{'data-action':'fix-model'}},{label:'移除图片',attrs:{'data-action':'remove-image'}}]};
  }
  function render() {
    const card=$('#assistant');
    card.innerHTML=V3AI.header({owner:'prod-web-01',newAttrs:{disabled:''},historyAttrs:{disabled:''},controls:[{label:'收起助手',attrs:{disabled:''}},{label:'展开助手',attrs:{disabled:''}},{label:'关闭助手',attrs:{disabled:''}}]})+`<div class="assistant-body" id="ai-transcript" tabindex="0" aria-label="对话记录">${transcript()}</div>`+V3AI.composer({inputId:'ai-notice-draft',draft,model:state==='validation'&&!compatibleModel?'reasoning-text-1':'sonnet-4',effort:'中',permission:'确认后执行',usage:18,state:'send',disabled:!!issue()||!draft.trim(),issue:issue(),attachments:state==='validation'&&hasImage?`<div class="notice-chip">${V3AI.icon('image')}<span>screenshot.png</span></div>`:'',sendAttrs:{'data-action':'send'},modelAttrs:{'data-action':'model',disabled:state==='validation'&&!resolved?null:''},attachAttrs:{disabled:''},permissionAttrs:{disabled:''},usageAttrs:{disabled:''}});
    if(issue())$('#ai-notice-draft').setAttribute('aria-describedby','composer-problem');
    const problem=card.querySelector('.v3-ai-composer-issue');if(problem)problem.id='composer-problem';
    const view=$('#ai-transcript');view.scrollTop=view.scrollHeight;
    updateRule();
  }
  function updateRule() {
    const r=rules[state];$('#rule-title').textContent=r.title;$('#rule-copy').textContent=r.copy;$('#rule-place').textContent=r.place;$('#rule-life').textContent=r.life;$('#rule-global').textContent=r.global;
  }
  function hideReminder() {reminderNode?.remove();reminderNode=null;}
  function locate(){hideReminder();$('#review-attention').value='viewing';$('#ai-transcript').focus();$('#ai-transcript').scrollTop=$('#ai-transcript').scrollHeight;$('#delivery-receipt').textContent='已定位原对话；查看不会代替批准、拒绝或核查。';}
  function publish() {
    const where=$('#review-attention').value,complete=$('#review-completion').checked;
    if(delivered){$('#delivery-receipt').textContent='此事件已消费，不重复提醒。';return;}
    delivered=true;
    const actionable=(state==='approval'||state==='unknown')&&!resolved;
    const reminder=where!=='viewing'&&actionable||where==='away'&&state==='complete'&&complete;
    if(!reminder){hideReminder();$('#delivery-receipt').textContent=where==='viewing'?'原位置已呈现，不再全局提醒。':actionable?'待处理状态保留在原对话。':state==='complete'?'已完成状态留在对话入口。':'局部结果留在原位置，不产生全局未读。';return;}
    const title=state==='complete'?'AI 任务已完成':state==='approval'?'AI 任务等待你确认':'执行结果需要核查';
    reminderNode=V3Feedback.publish({key:'ai-preview-'+(++noticeSequence),kind:state==='complete'?'completion':state==='approval'?'task_waiting':'outcome_unknown',title,source:'prod-web-01 · 部署日志排查',requiresAction:state!=='complete',timeSensitive:state!=='complete',locate},{focused:where!=='away',sourceVisible:false,notifyOnComplete:complete}).node;
    $('#delivery-receipt').textContent=where==='away'?'系统通知预览：只提供定位入口，不直接批准或重试。':'应用内提醒一次，待处理状态仍保留在原对话。';
  }
  $('#assistant').addEventListener('input',e=>{if(e.target.matches('textarea')){draft=e.target.value;const send=$('[data-action="send"]');send.disabled=!!issue()||!draft.trim();}});
  document.addEventListener('click',e=>{
    const id=e.target.closest('[data-action]')?.dataset.action;if(!id)return;
    if(id==='fix-model'||id==='remove-image'||id==='model'&&state==='validation'){resolved=true;if(id==='remove-image')hasImage=false;else compatibleModel=true;render();$('#ai-notice-draft').focus();}
    if(id==='retry'){retries++;resolved=true;render();}
    if(id==='edit'){draft='检查部署日志，确认服务是否恢复。';render();$('#ai-notice-draft').focus();}
    if(id==='reject'||id==='verify'||id==='remove-file'){resolved=true;hideReminder();render();}
    if(id==='retry-file'){$('#delivery-receipt').textContent='读取仍无权限，保留原卡和草稿；没有生成第二条错误。';}
    if(id==='approve'){state='complete';resolved=true;hideReminder();render();$('#delivery-receipt').textContent='本地演示已批准并切换为完成状态，未执行命令。';}
    if(id==='send'&&draft.trim()&&!issue()){
      const view=$('#ai-transcript'),message=document.createElement('div');message.className='notice-question';message.textContent=draft;
      if(state==='rollback')view.replaceChildren();view.append(message);view.querySelectorAll('.v3-ai-notice:not(.is-host)').forEach(n=>n.remove());draft='';$('#ai-notice-draft').value='';$('[data-action="send"]').disabled=true;view.scrollTop=view.scrollHeight;
      $('#delivery-receipt').textContent='新消息已加入本地预览，未请求模型。';
    }
  });
  $('#review-state').value=state;
  $('#review-state').addEventListener('change',e=>{state=e.target.value;resolved=false;retries=0;hasImage=true;compatibleModel=false;delivered=false;hideReminder();$('#delivery-receipt').textContent='新事件就绪；切换位置不会自动补发。';render();});
  function resize(){const size=$('#review-size').value;$('#assistant').style.width=size==='narrow'?'min(360px,100%)':'min(600px,100%)';$('#assistant').style.height=size==='compact'?'358px':'456px';$('#stage-size').textContent=size==='narrow'?'360 × 456':size==='compact'?'600 × 358':'600 × 456';}
  $('#review-size').value=['compact','narrow'].includes(query.get('size'))?query.get('size'):'default';$('#review-size').addEventListener('change',resize);resize();
  $('#review-theme').value=['light','sauber'].includes(query.get('theme'))?query.get('theme'):'dark';document.body.dataset.theme=$('#review-theme').value;
  $('#review-theme').addEventListener('change',e=>document.body.dataset.theme=e.target.value);
  $('#review-attention').addEventListener('change',()=>{hideReminder();$('#delivery-receipt').textContent='仅改变关注位置，不补发已发生的事件。';});
  $('#emit-event').addEventListener('click',publish);
  render();
})();
