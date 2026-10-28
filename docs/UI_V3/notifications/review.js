'use strict';
// Review controls sit outside the existing product canvas. All events are local
// fixtures and use the production-design policy mounted in the integrated host.
(() => {
  const scenarios={
    ai_complete:{kind:'ai_complete',title:'AI 回合已结束',source:'Local Terminal',description:'答复与回合状态留在 transcript，不弹全局消息、不入全局历史。'},
    ai_failed:{kind:'ai_failed',title:'AI 请求失败',source:'Local Terminal',description:'失败原因和恢复动作留在原回合，不按 error 自动全局提醒。'},
    command_failed:{kind:'command_failed',title:'命令执行失败',source:'Local Terminal',description:'错误留在原终端及助手入口，不作为全局通知。'},
    reconnecting:{kind:'connection_reconnecting',title:'SSH 正在自动重连',source:'prod-api-02',description:'自动恢复过程只更新会话状态；不会逐次弹断线／重连通知。'},
    connection_failed:{kind:'connection_failed',title:'SSH 自动恢复已停止',source:'prod-api-02',detail:'连接仍不可用，正在进行的工作已中断。请检查连接后重试。',requiresAction:true,timeSensitive:true,description:'持续故障影响工作且不在原位置时，提醒一次；恢复更新原提醒。'},
    transfer_blocked:{kind:'transfer_blocked',title:'备份传输已中断',source:'prod-web-01',detail:'备份批次因访问权限不足停止，尚未完成的文件保留在任务中。',requiresAction:true,timeSensitive:true,description:'仅整个后台批次停止、需要介入时升级；普通单文件失败留在任务行。'},
    task_waiting:{kind:'task_waiting',title:'后台任务等待你确认',source:'prod-web-01',detail:'部署检查需要一次必要确认才能继续，请回到原操作查看完整目标和影响。',requiresAction:true,timeSensitive:true,description:'原卡保留；用户离开且任务确实被阻塞时提醒一次。全局只定位，不批准。'},
    outcome_unknown:{kind:'outcome_unknown',title:'变更命令的结果需要核查',source:'prod-web-01',detail:'命令已派发后连接中断，当前影响尚未确认。核查前不重放原命令。',requiresAction:true,timeSensitive:true,description:'有副作用且需要及时核查的未知结果可升级；普通读取失败不升级。'},
    application_risk:{kind:'application_risk',title:'工作记录无法继续保存',source:'ZeroWork',detail:'存储位置不可写，继续工作可能无法保留完整记录。请检查可用空间和权限。',requiresAction:true,timeSensitive:true,description:'应用级持续风险使用持久提醒；关闭横幅不解除风险，待处理项继续保留。'},
    completion:{kind:'completion',title:'备份任务已完成',source:'prod-web-01',description:'默认仅更新任务状态；离开应用且主动开启完成提醒后，才生成一次系统提醒。'},
    outage:{kind:'connection_failed',title:'共享连接中断，自动恢复已停止',requiresAction:true,timeSensitive:true,description:'同一共享链路导致的三个会话故障合并为一项；不会排队连弹三条。'}
  };
  const labels={ai_complete:'AI 正常结束',ai_failed:'AI 请求失败',command_failed:'终端命令失败',reconnecting:'短暂断线／自动重连',connection_failed:'持续连接故障',transfer_blocked:'后台传输批次中断',task_waiting:'后台任务等待确认',outcome_unknown:'有副作用的结果未知',application_risk:'应用级保存风险',completion:'普通后台完成',outage:'同源三会话故障'};
  const controls=document.createElement('section');controls.className='notification-review';controls.setAttribute('aria-label','全局通知策略验证');
  controls.innerHTML=`<label>事件 <select aria-label="通知事件">${Object.entries(labels).map(([key,label])=>`<option value="${key}">${label}</option>`).join('')}</select></label><label>位置 <select aria-label="应用关注状态"><option value="foreground">应用在前台</option><option value="background">已离开应用</option></select></label><label><input type="checkbox" data-notice-visible>正在查看原位置</label><label><input type="checkbox" data-notice-completion>开启后台完成提醒</label><label><input type="checkbox" data-notice-quiet>勿扰时段</label><button type="button" data-notice-emit>模拟事件</button><button type="button" data-notice-repeat>重复同一事件</button><button type="button" data-notice-resolve>模拟来源恢复</button><button type="button" data-notice-center>打开提醒列表</button><output role="status"></output><p data-notice-rule style="flex-basis:100%;margin:0"></p>`;
  document.querySelector('#desktop').after(controls);
  const select=controls.querySelector('select'),output=controls.querySelector('output');select.value='connection_failed';
  let sequence=0,last=[],latestReceipt=null;
  const context=()=>({focused:controls.querySelector('[aria-label="应用关注状态"]').value==='foreground',sourceVisible:controls.querySelector('[data-notice-visible]').checked,notifyOnComplete:controls.querySelector('[data-notice-completion]').checked,quietHours:controls.querySelector('[data-notice-quiet]').checked});
  function report(receipt){if(receipt)latestReceipt=receipt;receipt=receipt||latestReceipt;const state=V3Feedback.notificationSnapshot();output.textContent='上次事件：'+({local:'原位置反馈',indicator:'仅更新来源状态',list:'提醒列表已在查看，直接更新列表',in_app:'应用内提醒一次',system:'系统通知候选（本页不实际发送）',quiet:'勿扰抑制横幅，重要事项仍保留',duplicate:'事件已消费，不重复提醒',resolved:'原事件已更新，无恢复成功弹窗'})[receipt?.channel]||'等待事件';output.textContent+=` · 待处理 ${state.pending} · 最近提醒 ${state.items.length}`;}
  function emit(){sequence++;const scenario=scenarios[select.value],id='review-'+sequence;last=(select.value==='outage'?['prod-api-01','prod-api-02','prod-api-03']:[scenario.source]).map((source,index)=>({...scenario,key:id+'-'+index,revision:1,incidentKey:select.value==='outage'?id:undefined,source,target:{kind:scenario.kind==='transfer_blocked'?'job':'session',value:scenario.kind==='transfer_blocked'?1:2},locate:()=>{V3NotificationHost.locate('workspace',{kind:'session',value:2});output.textContent='已定位原来源；审批、重试及核查仍在原模块处理。';}}));let receipt;for(const event of last)receipt=V3Feedback.publish(event,context());report(receipt);}
  controls.addEventListener('click',e=>{const button=e.target.closest('button');if(!button)return;if(button.hasAttribute('data-notice-emit'))emit();if(button.hasAttribute('data-notice-repeat')){if(!last.length)return;report(V3Feedback.publish(last[0],context()));}if(button.hasAttribute('data-notice-resolve')){let receipt;for(const event of last)receipt=V3Feedback.publish({...event,revision:2,phase:'resolved',title:'来源已恢复',detail:'原故障已经解除，相关业务状态已更新。'},context());report(receipt);}if(button.hasAttribute('data-notice-center'))V3NotificationHost.open();});
  function rule(){controls.querySelector('[data-notice-rule]').textContent=scenarios[select.value].description+' 切换关注位置、权限或偏好不会补发旧事件。';}
  select.addEventListener('change',rule);rule();report();V3Feedback.subscribe(()=>report());
})();
