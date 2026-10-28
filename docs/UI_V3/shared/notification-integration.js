'use strict';
// Prototype adapter: compose the existing app and module renderers. No second
// workspace or notification queue; shared policy facts live in the parent host.
(() => {
  const base=new URL('.',document.currentScript.src),host=document.querySelector('#desktop');
  if(!host||!window.V3Feedback?.publish)return;
  const center=V3Feedback.mountCenter(document.querySelector('#notification-center-root'));
  function locate(owner,target){const frame=views.get(owner);if(!frame)return;activate(owner,frame.src);if(target)send(owner,target.kind==='job'?'task-locate':'notice-locate',{id:target.value});}
  function syncCounts(state){for(const frame of views.values()){const button=frame.contentDocument?.querySelector('[data-global-notifications]');if(!button)continue;const badge=button.querySelector('i');badge.hidden=!state.pending&&!state.unread;badge.textContent=state.pending||'·';button.setAttribute('aria-label',state.pending?'重要提醒，'+state.pending+' 项待处理':'重要提醒');}}
  function connect(frame,owner){
    const doc=frame.contentDocument;if(!doc?.body||doc.URL==='about:blank'||doc.body.dataset.notificationPolicyConnected)return;
    doc.body.dataset.notificationPolicyConnected='true';
    const script=doc.createElement('script');script.src=new URL('notification-policy.js?v=global-policy-20261029',base).href;doc.head.append(script);
    const bar=doc.querySelector('.titlebar .title-actions,.titlebar');
    if(bar){const button=doc.createElement('button');button.className='zw-global-notifications';button.dataset.globalNotifications='';button.setAttribute('aria-label','重要提醒');button.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4"/></svg><i hidden></i>';button.onclick=()=>{center.open(undefined,button);};bar.append(button);}
    syncCounts(V3Feedback.notificationSnapshot());
  }
  function bindFrames(){for(const [owner,frame]of views){if(frame.dataset.notificationPolicyBound)continue;frame.dataset.notificationPolicyBound='true';frame.addEventListener('load',()=>connect(frame,owner));if(frame.contentDocument?.readyState==='complete')connect(frame,owner);}}
  new MutationObserver(bindFrames).observe(host,{childList:true,subtree:true});bindFrames();
  V3Feedback.subscribe(syncCounts);
  window.addEventListener('message',e=>{
    if(e.origin!==location.origin||e.data?.type!=='zw-app-child')return;
    const owner=[...views].find(([,frame])=>frame.contentWindow===e.source)?.[0];if(!owner)return;
    if(e.data.action==='notice'){e.stopImmediatePropagation();views.get(owner).contentWindow.V3Feedback?.show({...e.data,scope:'local'});return;}
    if(e.data.action!=='notification-event'||!e.data.event)return;
    const event=e.data.event,context=e.data.context||{};
    V3Feedback.publish({...event,key:owner+':'+event.key,incidentKey:event.incidentKey?owner+':'+event.incidentKey:undefined,locate:()=>locate(owner,event.target)},{...context,focused:document.hasFocus(),sourceVisible:owner===active&&context.sourceVisible===true});
  },{capture:true});
  // Explicitly published review fixtures use this same host, center and routes.
  window.V3NotificationHost={open:()=>center.open(),locate};
  if(V3Feedback.notificationReviewMode){const url=new URL(location.href);url.searchParams.set('notification-review','1');history.replaceState(null,'',url);document.body.dataset.size='compact';document.querySelector('#size').value='compact';const script=document.createElement('script');script.src=new URL('../notifications/review.js',base).href;document.body.append(script);}
  if(V3Feedback.notificationCenterInitiallyOpen)center.open();
})();
