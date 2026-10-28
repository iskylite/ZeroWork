// Shared notification policy and center. The integrated host owns these facts;
// individual modules publish structured events, never promote rendered error text.
(() => {
  const renderer = window.V3Feedback;
  if(renderer.publish)return;
  const rawShow=renderer.show.bind(renderer);
  // Untyped UI receipts stay inside their originating module. Only publish()
  // may request global delivery. Severity and text never grant that right.
  renderer.show=payload=>rawShow({...payload,scope:'local',severity:payload.severity||'info'});
  const stylesheet=document.createElement('link');stylesheet.rel='stylesheet';stylesheet.href=new URL('notification-policy.css',document.currentScript.src).href;document.head.append(stylesheet);
  const initialQuery=new URLSearchParams(location.search);
  const records = new Map(), versions = new Map(), listeners = new Set();
  const localKinds = new Set(['feedback','command_failed','ai_progress','ai_complete','ai_failed','cancelled']);
  const attentionKinds = new Set(['connection_failed','transfer_blocked','task_waiting','outcome_unknown','application_risk']);
  let banner = null, centerVisible = false;
  const escape = text => String(text ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function summary(record) {
    const members=[...record.members.values()],pending=members.some(m=>!m.resolved),sources=[...new Set(members.map(m=>m.source).filter(Boolean))];
    return {...record,members:undefined,pending,sources,count:members.length};
  }
  function snapshot() {
    const items=[...records.values()].map(summary).reverse();
    return {items,pending:items.filter(r=>r.pending).length,unread:items.filter(r=>!r.seen).length};
  }
  function changed(){const state=snapshot();listeners.forEach(fn=>fn(state));}
  function decide(event,context={}) {
    if(event.phase==='resolved')return 'resolved';
    if(localKinds.has(event.kind))return 'local';
    if(event.kind==='completion')return context.focused===false&&context.notifyOnComplete===true?'system':'indicator';
    if(!attentionKinds.has(event.kind))return 'indicator';
    // Failure severity is deliberately absent: actionable impact and timeliness
    // are explicit facts supplied by the source, not guessed from wording.
    if(!event.requiresAction||!event.timeSensitive)return 'indicator';
    if(context.sourceVisible&&event.kind!=='application_risk')return 'local';
    return context.focused===false?'system':'in_app';
  }
  function locate(record){record.seen=true;changed();record.locate?.();}
  function publish(event,context={}) {
    if(!event.key||!event.kind||!event.title)throw new Error('Notification needs a stable key, kind and title');
    if(parent!==window&&new URLSearchParams(location.search).has('integrated')) {
      const {locate,...serializable}=event;
      parent.postMessage({type:'zw-app-child',action:'notification-event',event:serializable,context},location.origin);
      return {channel:'host',record:null,node:null};
    }
    const revision=event.revision??1;
    if(!Number.isSafeInteger(revision)||revision<1)throw new Error('Invalid notification revision');
    if((versions.get(event.key)||0)>=revision)return {channel:'duplicate',record:null,node:null};
    versions.set(event.key,revision);
    const id=event.incidentKey||event.key;
    let record=records.get(id);
    const channel=decide(event,context);
    if(channel==='resolved') {
      if(record){const member=record.members.get(event.key);if(member)member.resolved=true;record.updatedAt=Date.now();if(!summary(record).pending){record.title=event.title;record.detail=event.detail||record.detail;if(banner?.id===id){banner.node.remove();banner=null;}}changed();}
      return {channel,record:record?summary(record):null,node:null};
    }
    if(channel!=='in_app'&&channel!=='system'){if(record){record.title=event.title;record.detail=event.detail||record.detail;record.updatedAt=Date.now();changed();}return {channel,record:record?summary(record):null,node:null};}
    const first=!record;
    if(!record){record={id,title:event.title,detail:event.detail||'',severity:event.severity||'warning',members:new Map(),seen:false,updatedAt:Date.now(),createdAt:Date.now(),locate:event.locate,target:event.target,channel,critical:event.kind==='application_risk',notified:false};records.set(id,record);}
    record.members.set(event.key,{source:event.source||'',resolved:!event.requiresAction});
    record.title=event.title;record.detail=event.detail||'';record.updatedAt=Date.now();record.locate=event.locate||record.locate;
    // An updated incident is one entry. It never regenerates a dismissed banner.
    let node=null;
    if(centerVisible&&context.focused!==false)record.seen=true;
    if(channel==='in_app'&&!context.quietHours&&!centerVisible&&(first||banner?.id===id)) {
      if(!banner||banner.id===id||!banner.critical){
        banner?.node.remove();
        const item=summary(record),source=item.sources.length>1?`${item.sources[0]} 等 ${item.sources.length} 个来源`:item.sources[0]||'';
        node=rawShow({text:record.title,detail:record.detail,source,status:item.pending?'待处理':'已完成',severity:record.critical?'error':'warning',scope:'global',action:()=>{if(banner?.id===id)banner=null;locate(record);},actionLabel:'查看来源'});
        banner={id,node,critical:record.critical};record.notified=true;
        node.querySelector('[data-feedback-close]').addEventListener('click',()=>{record.seen=true;if(banner?.id===id)banner=null;changed();});
      }
    }
    while(records.size>100){const old=[...records.values()].find(r=>!summary(r).pending);if(!old)break;records.delete(old.id);}
    changed();
    return {channel:context.quietHours?'quiet':centerVisible&&context.focused!==false?'list':channel,record:summary(record),node};
  }
  function clearResolved(){for(const [id,record]of records)if(!summary(record).pending)records.delete(id);changed();}
  function markSeen(){for(const record of records.values())record.seen=true;changed();}
  function mountCenter(root,{onLocate=()=>{}}={}) {
    let filter='pending',open=false,returnFocus=null;
    root.classList.add('zw-notification-root');
    root.innerHTML='<section class="zw-notification-center" role="dialog" aria-label="重要提醒" hidden><header><strong>提醒</strong><button type="button" data-center-close aria-label="关闭提醒列表">×</button></header><nav><button type="button" data-center-filter="pending">待处理</button><button type="button" data-center-filter="recent">最近提醒</button></nav><div class="zw-notification-list"></div><footer><span>只保留重要提醒，完整记录在原模块</span><button type="button" data-center-clear>清除已结束</button></footer></section>';
    const panel=root.querySelector('section'),list=root.querySelector('.zw-notification-list');
    function render(state=snapshot()) {
      const pending=state.items.filter(r=>r.pending),items=filter==='pending'?pending:state.items;
      root.querySelector('[data-center-filter="pending"]').textContent='待处理'+(pending.length?' '+pending.length:'');
      root.querySelectorAll('[data-center-filter]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.centerFilter===filter)));
      root.querySelector('[data-center-clear]').disabled=!state.items.some(r=>!r.pending);
      list.innerHTML=items.length?items.map(item=>`<article class="zw-notification-record" data-notification-id="${escape(item.id)}"><div><span class="zw-notification-state ${item.pending?'pending':''}">${item.pending?'待处理':'已结束'}</span><strong>${escape(item.title)}</strong></div><div class="zw-notification-summary"><p title="${escape(item.sources.join('、'))}">${escape(item.sources.join('、'))}</p><button type="button" data-center-locate="${escape(item.id)}">查看来源</button>${item.detail?'<button type="button" data-center-expand aria-label="展开提醒详情" aria-expanded="false">⌄</button>':''}</div>${item.detail?`<div class="zw-notification-detail" hidden><p>${escape(item.detail)}</p></div>`:''}</article>`).join(''):`<p class="zw-notification-empty">${filter==='pending'?'当前没有待处理提醒':'暂无重要提醒'}</p>`;
    }
    root.addEventListener('click',e=>{
      const button=e.target.closest('button');if(!button)return;
      if(button.hasAttribute('data-center-close')){open=false;centerVisible=false;panel.hidden=true;returnFocus?.focus({preventScroll:true});}
      if(button.dataset.centerFilter){filter=button.dataset.centerFilter;render();}
      if(button.hasAttribute('data-center-clear'))clearResolved();
      if(button.hasAttribute('data-center-expand')){const detail=button.closest('article').querySelector('.zw-notification-detail');detail.hidden=!detail.hidden;button.setAttribute('aria-expanded',String(!detail.hidden));button.setAttribute('aria-label',detail.hidden?'展开提醒详情':'收起提醒详情');button.textContent=detail.hidden?'⌄':'⌃';}
      if(button.dataset.centerLocate){const record=records.get(button.dataset.centerLocate);if(record){record.seen=true;changed();if(record.locate)record.locate();else onLocate(record.target,record);}open=false;centerVisible=false;panel.hidden=true;}
    });
    document.addEventListener('keydown',e=>{if(open&&e.key==='Escape'){open=false;centerVisible=false;panel.hidden=true;returnFocus?.focus({preventScroll:true});}});
    listeners.add(render);render();
    return {open(anchor,trigger){returnFocus=trigger||document.activeElement;open=true;centerVisible=true;panel.hidden=false;if(banner){banner.node.remove();banner=null;}const box=root.getBoundingClientRect();panel.style.top=(anchor?Math.max(8,Math.min(anchor.bottom+6,box.height-panel.offsetHeight-12)):50)+'px';panel.style.right='12px';markSeen();panel.querySelector('[data-center-filter]')?.focus();},close(){open=false;centerVisible=false;panel.hidden=true;},isOpen(){return open;}};
  }
  Object.assign(renderer,{notificationReviewMode:initialQuery.has('notification-review'),notificationCenterInitiallyOpen:initialQuery.has('notification-center'),publish,decide,notificationSnapshot:snapshot,clearResolved,markSeen,mountCenter,subscribe(fn){listeners.add(fn);fn(snapshot());return()=>listeners.delete(fn);}});
})();
