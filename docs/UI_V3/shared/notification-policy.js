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
  let banner = null, centerVisible = false, nextFactOrder = 0;
  const escape = text => String(text ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function summary(record) {
    const members=[...record.members.values()].sort((a,b)=>a.order-b.order),pending=members.some(m=>!m.resolved),sources=[...new Set(members.map(m=>m.source).filter(Boolean))];
    return {...record,members:undefined,pending,sources,count:members.length};
  }
  function sourceLabel(record){const sources=summary(record).sources;return sources.length>1?`${sources[0]} 等 ${sources.length} 个来源`:sources[0]||'';}
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
  function reconcile(record){
    const members=[...record.members.values()].sort((a,b)=>a.order-b.order);
    // Match the native coordinator: first pending fact, then first fact.
    const selected=members.find(member=>!member.resolved)||members[0];
    record.representativeKey=selected.key;
    for(const field of ['title','detail','severity','locate','target'])record[field]=selected[field];
    record.updatedAt=Date.now();
  }
  function publish(event,context={}) {
    if(!event.key||!event.kind||!event.title)throw new Error('Notification needs a stable key, kind and title');
    if(parent!==window&&new URLSearchParams(location.search).has('integrated')) {
      const {locate,...serializable}=event;
      parent.postMessage({type:'zw-app-child',action:'notification-event',event:serializable,context},location.origin);
      return {channel:'host',record:null,node:null};
    }
    const revision=event.revision??1;
    if(!Number.isSafeInteger(revision)||revision<1)throw new Error('Invalid notification revision');
    const previousVersion=versions.get(event.key);
    if((previousVersion?.revision||0)>=revision)return {channel:'duplicate',record:null,node:null};
    const order=previousVersion?.order??++nextFactOrder;
    versions.set(event.key,{revision,order});
    const id=event.incidentKey||event.key;
    const channel=decide(event,context);
    if(banner&&!banner.node.isConnected)banner=null;
    const movingBanner=banner?.key===event.key&&banner.id!==id;
    // A retained banner must never outlive the revision behind its action.
    // In-app replacements below replace it atomically; other routes expire it.
    if(banner?.key===event.key&&(channel!=='in_app'||context.quietHours||centerVisible)){
      banner.node.remove();banner=null;
    }
    // A fact has one incident membership even if its incident key changes.
    let moved=null,movedSeen=false;
    for(const [otherId,other]of records)if(otherId!==id&&other.members.has(event.key)){
      moved=other.members.get(event.key);movedSeen=other.seen;other.members.delete(event.key);
      if(other.members.size){reconcile(other);if(banner?.id===otherId&&banner.key!==event.key)renderer.updateSource(banner.node,sourceLabel(other));}else records.delete(otherId);
    }
    let record=records.get(id);
    const first=!record&&(!moved||movingBanner);
    if(!record&&!moved&&channel!=='in_app'&&channel!=='system')return {channel,record:null,node:null};
    if(!record){record={id,title:event.title,detail:event.detail||'',severity:event.severity||'warning',members:new Map(),seen:movedSeen,updatedAt:Date.now(),createdAt:Date.now(),locate:event.locate,target:event.target,channel,critical:event.kind==='application_risk',notified:false};records.set(id,record);}
    const previous=record.members.get(event.key)||moved;
    if(channel!=='resolved'||previous){
      record.members.set(event.key,{key:event.key,order,revision,critical:event.kind==='application_risk',source:event.source??previous?.source??'',resolved:channel==='resolved'||!event.requiresAction,title:event.title,detail:event.detail??previous?.detail??'',severity:event.severity??previous?.severity??'warning',locate:event.locate??previous?.locate,target:event.target??previous?.target});
      reconcile(record);
    }
    if(!summary(record).pending&&banner?.id===id){banner.node.remove();banner=null;}
    if(channel!=='in_app'&&channel!=='system'){changed();return {channel,record:summary(record),node:null};}
    // An updated incident is one entry. It never regenerates a dismissed banner.
    let node=null;
    if(centerVisible&&context.focused!==false)record.seen=true;
    if(channel==='in_app'&&!context.quietHours&&!centerVisible&&(first||movingBanner||banner?.id===id)) {
      if(!banner||banner.id===id||movingBanner||!banner.critical){
        const item=summary(record),source=sourceLabel(record);
        const shown=record.members.get(movingBanner?event.key:banner?.id===id?banner.key:event.key)||record.members.get(record.representativeKey);
        const actionKey=shown.key,actionRevision=shown.revision,actionTarget=shown.locate;
        const retained=banner?.key===actionKey?banner.node:null;if(!retained)banner?.node.remove();
        const payload={text:shown.title,detail:shown.detail,source,status:item.pending?'待处理':'已完成',severity:shown.critical?'error':'warning',scope:'global',action:()=>{if(versions.get(actionKey)?.revision!==actionRevision||records.get(id)!==record||banner?.node!==node||!node.isConnected)return;if(banner?.id===id)banner=null;record.seen=true;changed();actionTarget?.();},actionLabel:'查看来源'};
        if(retained&&banner.id===id&&banner.revision===actionRevision){node=retained;renderer.updateSource(node,source);}else node=retained?renderer.update(retained,payload):rawShow(payload);
        banner={id,key:actionKey,revision:actionRevision,node,critical:shown.critical};record.notified=true;
        node.querySelector('[data-feedback-close]').addEventListener('click',()=>{if(banner?.node!==node||banner.id!==id||versions.get(actionKey)?.revision!==actionRevision)return;record.seen=true;banner=null;changed();});
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
