'use strict';
/* HTML design only: keep the original composer, controls, draft and attachments mounted. */
window.V3AIComposerInteraction=(()=>{
 const esc=value=>V3AI.escape(value);
 const paths={info:'M12 8h.01M12 11v6M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0',skip:'M5 4l10 8-10 8zM19 4v16',clock:'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18M12 7v5l3 2',copy:'M9 8V3h12v13h-5M3 8h13v13H3z',chevron:'m9 6 6 6-6 6'};
 const glyph=name=>paths[name]?`<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${paths[name]}"/></svg>`:V3AI.icon(name);
 const button=(action,label,icon,primary=false)=>`<button type="button" class="ai-control v3-ai-interaction-action${primary?' is-primary':''}" data-ai-interaction="${action}" title="${esc(label)}">${glyph(icon)}<span>${esc(label)}</span></button>`;

 function mount(root,request,callbacks){
  const composer=root.querySelector('.v3-ai-composer'),input=composer.querySelector('textarea'),row=composer.querySelector('.v3-ai-control-row');
  composer.dataset.interactionState=request.expanded?'expanded':'pending';
  const key=request.id;
  const live=()=>callbacks.current()===request&&request.status==='pending'&&request.id===key;
  if(!request.expanded){
   const main=root.querySelector('#ai-messages');
   root.style.setProperty('--ai-interaction-scroll-padding',`${parseFloat(getComputedStyle(main).paddingBottom)+32}px`);
   root.dataset.interactionPending='true';
   const pending=document.createElement('button');
   pending.type='button';pending.className='v3-ai-pending-interaction';pending.title='继续处理：'+request.title;
   pending.setAttribute('aria-label',pending.title);
   pending.innerHTML=glyph('clock')+`<span>待${request.kind==='question'?'回答':'确认'} · ${esc(request.shortTitle)}</span>`+glyph('chevron');
   pending.onclick=()=>{if(!live())return;request.selection={start:input.selectionStart,end:input.selectionEnd};request.expanded=true;callbacks.render();};
   composer.append(pending);
   return;
  }
  const panel=document.createElement('section');
  panel.className='v3-ai-interaction-panel';panel.dataset.kind=request.kind;
  panel.setAttribute('aria-label',request.title);
  panel.innerHTML=`<div><div class="v3-ai-interaction-heading">${glyph(request.kind==='question'?'list':'terminal')}<strong>${esc(request.title)}</strong></div><p class="v3-ai-interaction-target">${esc(request.target)}</p></div>`;
  if(request.kind==='approval'){
   panel.insertAdjacentHTML('beforeend',`<div class="v3-ai-interaction-command"><pre>${esc(request.command)}</pre><button type="button" class="icon-btn v3-ai-interaction-copy" aria-label="复制完整命令" title="复制完整命令">${glyph('copy')}</button></div><p class="v3-ai-interaction-impact">${glyph('info')}<span>${esc(request.impact)}</span></p>`);
   panel.querySelector('.v3-ai-interaction-copy').onclick=async event=>{const control=event.currentTarget;try{await navigator.clipboard.writeText(request.command);if(live())control.setAttribute('title','已复制');}catch{control.setAttribute('title','请选择命令并按 ⌘C 复制');}};
  }else{
   const options=document.createElement('fieldset');options.className='v3-ai-interaction-options';options.setAttribute('aria-label',request.title);
   options.innerHTML=request.options.map(option=>`<label class="v3-ai-interaction-option"><input type="radio" name="${esc(key)}" value="${esc(option.id)}"${request.selected===option.id?' checked':''}><span class="v3-ai-interaction-option-copy"><strong>${esc(option.label)}${option.recommended?'<em>推荐</em>':''}</strong><small>${esc(option.detail)}</small></span></label>`).join('')+`<label class="v3-ai-interaction-option"><input type="radio" name="${esc(key)}" value="custom"${request.selected==='custom'?' checked':''}><span class="v3-ai-interaction-other"${request.selected==='custom'?' hidden':''}>其他</span><input class="v3-ai-interaction-custom" aria-label="其他处理方式" placeholder="输入你的答案…" value="${esc(request.custom||'')}"${request.selected==='custom'?'':' hidden'}></label>`;
   const custom=options.querySelector('.v3-ai-interaction-custom'),other=options.querySelector('.v3-ai-interaction-other');
   const syncCustom=focus=>{const selected=request.selected==='custom';custom.hidden=!selected;other.hidden=selected;if(selected&&focus)custom.focus({preventScroll:true});};
   options.onchange=event=>{if(event.target.type==='radio'&&live()){request.selected=event.target.value;syncCustom(true);}};
   custom.oninput=()=>{if(!live())return;request.custom=custom.value;request.selected='custom';options.querySelector('[value="custom"]').checked=true;};
   custom.onfocus=()=>{if(live()){request.selected='custom';options.querySelector('[value="custom"]').checked=true;}};
   panel.append(options);
  }
  const error=document.createElement('p');error.className='v3-ai-interaction-error';error.hidden=true;error.setAttribute('role','alert');panel.append(error);
  composer.prepend(panel);
  const actions=document.createElement('div');actions.className='v3-ai-interaction-actions';
  actions.innerHTML='<span class="spacer"></span>'+button('postpone','稍后处理','skip')+(request.kind==='approval'?button('reject','拒绝','x'):'')+button('submit',request.kind==='approval'?'允许执行':'提交答案','check');
  row.prepend(actions);
  actions.onclick=event=>{
   const action=event.target.closest('[data-ai-interaction]')?.dataset.aiInteraction;
   if(!action||!live())return;
   if(action==='postpone'){
    request.expanded=false;callbacks.render();
    const restored=root.querySelector('textarea');restored.focus({preventScroll:true});
    if(request.selection)restored.setSelectionRange(request.selection.start,request.selection.end);
    return;
   }
   if(action==='submit'&&request.kind==='question'&&(!request.selected||request.selected==='custom'&&!request.custom?.trim())){
    error.textContent='请选择一个选项，或填写其他处理方式。';error.hidden=false;return;
   }
   request.status='submitting';actions.querySelectorAll('button').forEach(control=>control.disabled=true);
   Promise.resolve().then(()=>{if(callbacks.current()!==request||request.status!=='submitting')return;callbacks.decide(action==='reject'?'rejected':'accepted',request);});
  };
  panel.addEventListener('keydown',event=>{if(event.isComposing)return;if(event.key==='Escape'){event.preventDefault();event.stopPropagation();actions.querySelector('[data-ai-interaction="postpone"]').click();}});
 }

 function fixture(kind,target){
  return {id:'composer-review-'+kind,status:'pending',kind:kind==='question'?'question':'approval',expanded:kind!=='pending',title:kind==='question'?'选择配置应用方式':'确认重启 Nginx',shortTitle:kind==='question'?'配置应用方式':'重启 Nginx',target,command:'sudo systemctl restart nginx',impact:'重启会短暂中断连接。',selected:'reload',custom:'',options:[{id:'reload',label:'仅重载配置',detail:'保留现有连接，平滑应用配置。',recommended:true},{id:'restart',label:'重启整个服务',detail:'重新启动服务，会短暂中断连接。'}]};
 }
 return Object.freeze({mount,fixture});
})();

// Opt-in review route: the ordinary workspace and other AI reference states stay untouched.
(()=>{
 const state=new URLSearchParams(location.search).get('composer-interaction');
 if(!['approval','question','pending','baseline'].includes(state))return;
 const originalRender=renderAssistant;
 renderAssistant=function(...args){
  const previous=document.querySelector('#ai-messages'),waiting=aiData().composerInteraction?.status==='pending';
  const reading=waiting&&previous?{top:previous.scrollTop,atEnd:previous.scrollHeight-previous.clientHeight-previous.scrollTop<2}:null;
  originalRender.apply(this,args);
  const root=document.querySelector('#assistant'),data=aiData(),request=data.composerInteraction;
  delete root.dataset.interactionPending;root.style.removeProperty('--ai-interaction-scroll-padding');
  if(!request||request.status!=='pending')return;
  V3AIComposerInteraction.mount(root,request,{
   current:()=>aiData().composerInteraction,
   render:()=>renderAssistant(),
   decide:(decision,answered)=>{
    if(data.composerInteraction!==answered)return;
    answered.status=decision;data.prototypePrimaryState='send';data.sessionStatus='success';
    const answer=answered.kind==='question'?(answered.selected==='custom'?answered.custom:answered.options.find(option=>option.id===answered.selected).label):'';
    data.messages.push(answer?`<div class="assistant-question">${V3AI.escape(answered.title)}<br>${V3AI.escape(answer)}</div>`:`<div class="assistant-answer">${decision==='rejected'?'已拒绝此调用，命令未执行。':'已批准本次操作。'}</div>`);
    renderAssistant();
   }
  });
  // Reuse the original primary control and stop dispatch; only project the new request's state.
  const stop=root.querySelector('.ai-send');stop.querySelector('.ai-primary-rest').innerHTML=V3AI.icon('stop');
  if(reading){const viewport=root.querySelector('#ai-messages');viewport.scrollTop=reading.atEnd?viewport.scrollHeight:reading.top;}
 };
 document.addEventListener('click',event=>{
  const stop=event.target.closest('#assistant .ai-send');if(!stop)return;
  const request=aiData().composerInteraction;
  if(request&&['pending','submitting'].includes(request.status))request.status='cancelled';
 },true);
 const data=aiData();
 data.draft='先确认当前连接数，超过 100 就暂不重启。';
 data.messages=['<div class="assistant-question">检查配置，应用前先让我确认。</div>','<div class="assistant-answer">配置检查已通过，可以应用新配置。</div>'];
 if(state!=='baseline'){data.composerInteraction=V3AIComposerInteraction.fixture(state,current()?.name||'当前会话');data.prototypePrimaryState='approval';data.sessionStatus='approval';}
 renderAssistant();
})();
