'use strict';
// Painted surfaces target final composited transmission; portals compensate uncovered owners.
(()=>{
 const sourceURL=document.currentScript?.src||location.href,query=new URLSearchParams(location.search),embedded=query.has('integrated')||query.has('embed');
 // Final [base transparency P0, slider span D, maximum transparency M].
 const roles={'surface-1':[0,1,1],'surface-2':[0.72,0.18,0.9],'well':[0.64,0.2,0.84],'overlay':[0,0.5,0.5],'hover':[0.82,0.08,0.9],'tab-on':[0.68,0.14,0.82],'card-deep':[0.72,0.18,0.9],'card-deep-ft':[0.64,0.2,0.84]};
 let materialAlphaCache=null;
 const imageVisible=()=>fixture||(embedded&&effective.imageVisible===true)||(effective.imageEnabled&&/^(data:image\/|blob:)/.test(effective.imageURL||''));
 const materialRGB=(styles,name)=>{let hex=(name.startsWith('#')?name:styles.getPropertyValue(name).trim()).replace('#','');if(hex.length===3)hex=[...hex].map(v=>v+v).join('');return[0,2,4].map(i=>parseInt(hex.slice(i,i+2),16));};
 const materialPaint=(fg,bg,alpha)=>fg.map((v,i)=>Math.floor((v*alpha+bg[i]*(255-alpha)+127)/255));
 function materialAlpha(role,t){const [base,span,cap]=roles[role];return Math.round(255*(1-Math.min(cap,base+span*t)))/255;}
 const clamp=(v,min,max)=>Math.max(min,Math.min(max,Number.isFinite(+v)?+v:min));
 // Surface boundaries only: component names never select an alpha percentage.
 const floatingSelector='.popover,.context-menu,.modal,.assistant,.v3-ai-model-info,.v3-hover,.design-tooltip,.app-tooltip,.hint-text,.choice-menu,.v3-ai-session-list,.toast,#tooltip,.utility-layer,#global-notice,#settings-frame,.settings-window,.mode-menu[data-execution-patch-surface],.v3-select-popover[data-execution-patch-surface],.process-panel[data-execution-patch-surface]';
 const cardSelector='.assistant .approval,.host-group,.file-panel,.card,.provider,.provider-card,.model-card,.model-row,.ap-card,.ap-extra,.ap-user-bubble,.ai-tool-card,.ap-live-result,.ai-draft-attachment,.v3-ai-notice,.v3-ai-conversation,.assistant pre,.copy-path-well,.multiline-preview,.permission-panel,.model-test';
 const notificationSelector='.zw-feedback:not(.zw-feedback-local),.zw-notification-center';
 const surfaceSelector=floatingSelector+','+cardSelector+','+notificationSelector;
 const owners=new WeakMap(),frameMaterials=new WeakMap(),maskCache=new WeakMap(),ownStyles=new WeakMap();
 const transferTables=new Map(),observed=new Set();
 let surfaces=[],treeDirty=true,framePending=false,canvasDirty=true,inSync=false,resizeObserver=null;
 const metrics={frames:0,sceneQueries:0,maskBuilds:0,maskHits:0,canvasMessages:0};
 function schedule(tree=false,canvas=false){
  treeDirty=treeDirty||tree;canvasDirty=canvasDirty||canvas;
  if(framePending||inSync)return;
  if(typeof requestAnimationFrame==='function'){framePending=true;requestAnimationFrame(flush);}else flush();
 }
 function flush(){
  framePending=false;inSync=true;metrics.frames++;
  try{const writes=syncLayers();if(canvasDirty&&root?.getBoundingClientRect&&root.querySelectorAll){canvasDirty=false;syncCanvas();}for(const write of writes)write();}
  finally{inSync=false;}
 }
 function stamp(node){if(node.getAttribute)ownStyles.set(node,node.getAttribute('style'));}
 const clipRect=(a,b)=>{const x=Math.max(a.x,b.x),y=Math.max(a.y,b.y);return{x,y,width:Math.max(0,Math.min(a.x+a.width,b.x+b.width)-x),height:Math.max(0,Math.min(a.y+a.height,b.y+b.height)-y)};};
 function rectOf(node,cache){if(!cache.has(node))cache.set(node,node.getBoundingClientRect());return cache.get(node);}
 function visibleRect(node,r,rects,styles){
  let clip={x:0,y:0,width:window.innerWidth||1e9,height:window.innerHeight||1e9};
  for(let parent=node.parentElement;parent;parent=parent.parentElement){
   if(!styles.has(parent))styles.set(parent,getComputedStyle(parent));const style=styles.get(parent);
   if(style.display==='none'||style.visibility==='hidden')return{x:0,y:0,width:0,height:0};
   if(!parent.getBoundingClientRect)continue;
   const ox=style.overflowX||style.overflow,oy=style.overflowY||style.overflow;
   if(ox&&ox!=='visible'||oy&&oy!=='visible'){
    const b=rectOf(parent,rects),limit={x:ox&&ox!=='visible'?b.x:clip.x,y:oy&&oy!=='visible'?b.y:clip.y,width:ox&&ox!=='visible'?b.width:clip.width,height:oy&&oy!=='visible'?b.height:clip.height};clip=clipRect(clip,limit);
   }
  }
  return clipRect(r,clip);
 }
 const transmission=level=>(5-Math.min(level,4))/5;
 const layerAlpha=(level,t)=>Math.round(255*(level===0?1-t:t===0?1:1-transmission(level)/transmission(level-1)))/255;
 const ownerOf=surface=>{const anchor=owners.get(surface);return(anchor?.isConnected?anchor:surface.parentElement)?.closest(surfaceSelector);};
 function compensate(surface,level,base,background,underlays,ownAlpha,record,palette){
  if(!surface.getBoundingClientRect||surface.matches('.settings-window,.ap-user-bubble')||ownAlpha===1||(level===1&&ownAlpha>0))return background;
  const r=record.r;if(!r.width||!r.height)return background;
  const blur=record.blur,pad=3*blur;
  const shapes=underlays.filter(a=>a.x<r.right+pad&&a.x+a.w>r.x-pad&&a.y<r.bottom+pad&&a.y+a.h>r.y-pad).map(a=>({...a,x:a.x-r.x,y:a.y-r.y,clip:a.clip?{x:a.clip.x-r.x,y:a.clip.y-r.y,w:a.clip.width,h:a.clip.height}:null}));
  const rgb=materialRGB(palette,base);if(!rgb.every(Number.isFinite))return background;
  const localClip={x:record.visible.x-r.x,y:record.visible.y-r.y,w:record.visible.width,h:record.visible.height};
  const key=JSON.stringify([level,ownAlpha,r.width,r.height,blur,rgb,localClip,shapes.map(a=>[a.x,a.y,a.w,a.h,a.r,Math.min(a.level,4),a.clip])]);
  const cached=maskCache.get(surface);if(cached?.key===key){metrics.maskHits++;return cached.image+','+background;}
  metrics.maskBuilds++;
  // Filter only an opacity map. The surface's existing backdrop supplies pixels;
  // neither the wallpaper nor foreground content is duplicated or filtered here.
  const tableKey=level+':'+ownAlpha;let table=transferTables.get(tableKey);if(!table){table=Array.from({length:257},(_,i)=>Math.max(0,1-transmission(level)/(Math.max(.2,i/256)*(1-ownAlpha))).toFixed(6)).join(' ');if(transferTables.size>32)transferTables.clear();transferTables.set(tableKey,table);}
  const rect=`x="${-pad}" y="${-pad}" width="${r.width+2*pad}" height="${r.height+2*pad}"`;
  let svg=`<svg xmlns="http://www.w3.org/2000/svg" width="${r.width}" height="${r.height}" viewBox="0 0 ${r.width} ${r.height}"><filter id="f" filterUnits="userSpaceOnUse" ${rect} color-interpolation-filters="sRGB">`;
  if(blur)svg+=`<feGaussianBlur stdDeviation="${blur}"/>`;
  svg+=`<feColorMatrix type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  1 0 0 0 0"/><feComponentTransfer result="mask"><feFuncA type="table" tableValues="${table}"/></feComponentTransfer><feFlood flood-color="rgb(${rgb.join(',')})"/><feComposite in2="mask" operator="in"/></filter><g filter="url(#f)"><rect ${rect} fill="white"/>`;
  for(const [i,a] of shapes.sort((a,b)=>a.level-b.level).entries()){const q=255*transmission(a.level),c=a.clip;if(c)svg+=`<defs><clipPath id="c${i}"><rect x="${c.x}" y="${c.y}" width="${c.w}" height="${c.h}"/></clipPath></defs>`;svg+=`<rect x="${a.x}" y="${a.y}" width="${a.w}" height="${a.h}" rx="${a.r}" fill="rgb(${q},${q},${q})"${c?` clip-path="url(#c${i})"`:''}/>`;}
  svg+='</g></svg>';const image=`url("data:image/svg+xml,${encodeURIComponent(svg)}")`;maskCache.set(surface,{key,image});return image+','+background;
 }
 function levelOf(surface,seen=new Set()){
  if(!surface||seen.has(surface))return 0;seen.add(surface);
  if(surface.matches(notificationSelector))return 4;
  const parent=ownerOf(surface);
  return 1+levelOf(parent,seen);
 }
 function frameUnderlays(){
  const result=[];
  for(const frame of document.querySelectorAll('object[data-document-host],iframe')){
   if(!frame.getBoundingClientRect||frame.closest(surfaceSelector))continue;
   const win=frame.contentWindow||frame.contentDocument?.defaultView,items=frameMaterials.get(win),r=frame.getBoundingClientRect();if(!items||!r.width||!r.height)continue;
   const sx=r.width/(frame.clientWidth||r.width),sy=r.height/(frame.clientHeight||r.height);
   for(const a of items)result.push({...a,x:r.x+a.x*sx,y:r.y+a.y*sy,w:a.w*sx,h:a.h*sy,r:a.r*Math.min(sx,sy),clip:a.clip?{x:r.x+a.clip.x*sx,y:r.y+a.clip.y*sy,width:a.clip.width*sx,height:a.clip.height*sy}:null});
  }
  return result;
 }
 function syncLayers(){
  if(treeDirty){surfaces=[...document.querySelectorAll(surfaceSelector)];treeDirty=false;metrics.sceneQueries++;if(resizeObserver){const next=new Set([root,...surfaces,...root.querySelectorAll?.(canvasSelector)||[]]);for(const n of observed)if(!next.has(n)){resizeObserver.unobserve(n);observed.delete(n);}for(const n of next)if(!observed.has(n)){resizeObserver.observe(n);observed.add(n);}}}
  const rects=new Map(),styles=new Map(),palette=getComputedStyle(document.body),underlays=frameUnderlays();
  // Match native settingsCard(): light surfaces keep a quiet, uncompensated tint.
  const overlay=materialRGB(palette,'--overlay-base'),ink=materialRGB(palette,'--fg-2'),app=materialRGB(palette,'--bg-app');
  const dark=app[0]*299+app[1]*587+app[2]*114<128000,strength=dark?Math.min(1,.12/layerAlpha(2,effective.transparency/100)):.12;
  const settingsBase='#'+overlay.map((v,i)=>Math.trunc(v+(ink[i]-v)*strength).toString(16).padStart(2,'0')).join('');
  // Measure all surfaces before writing a single style, including clip ancestors.
  const records=surfaces.filter(n=>n.isConnected!==false).map(surface=>{
   const style=getComputedStyle(surface);styles.set(surface,style);const r=surface.getBoundingClientRect?rectOf(surface,rects):null;
   const visible=r?visibleRect(surface,r,rects,styles):null;
   return{surface,style,r,visible,level:levelOf(surface),blur:parseFloat(style.backdropFilter?.match(/blur\(([^)]+)/)?.[1])||0};
  });
  const bySurface=new Map(records.map(record=>[record.surface,record])),writes=[];
  for(const record of records){
   const{surface,style,r,visible,level,blur}=record;
   const kind=surface.matches(cardSelector)?'card':'floating',base=kind==='floating'?'--overlay-base':surface.matches('.v3-ai-pending-surface')?'--state-control-base':surface.matches('.file-panel')?'--surface-1-base':surface.matches('.provider')?'--provider-material-base':surface.matches('.model-row')?'--well-base':surface.matches('.settings-window .settings-scroll > .card')?settingsBase:surface.matches('.host-group,.card,.provider-card,.model-card')?'--surface-2-base':surface.matches('.ap-extra,.ap-live-result,.assistant pre,.copy-path-well,.multiline-preview')?'--well-base':'--state-action-base';
   const hostedSettings=embedded&&surface.matches('.settings-window'),shown=!r||r.width>0&&r.height>0&&visible.width>0&&visible.height>0&&style.visibility!=='hidden'&&style.display!=='none';
   if(!shown)continue;
   const pad=3*blur,coveredByPeer=r&&effective.transparency>0&&underlays.some(a=>a.level>=level&&a.x<visible.x+visible.width+pad&&a.x+a.w>visible.x-pad&&a.y<visible.y+visible.height+pad&&a.y+a.h>visible.y-pad);
   const ownAlpha=coveredByPeer?0:layerAlpha(level,effective.transparency/100),alpha=(100*ownAlpha).toFixed(4)+'%',background=hostedSettings||surface.matches('.ap-user-bubble')?'transparent':'color-mix(in srgb,rgb(from '+(base.startsWith('#')?base:'var('+base+')')+' r g b / 1) '+alpha+',transparent)';
   const owner=ownerOf(surface),parentRecord=bySurface.get(owner),parentClips=parentRecord&&['hidden','clip','scroll','auto'].includes(parentRecord.style.overflow)&&owner.contains?.(surface);
   const contained=!surface.matches(notificationSelector)&&level>1&&parentRecord?.r&&visible&&(parentClips||visible.x>=parentRecord.r.x+parseFloat(parentRecord.style.borderRadius||0)&&visible.y>=parentRecord.r.y+parseFloat(parentRecord.style.borderRadius||0)&&visible.x+visible.width<=parentRecord.r.x+parentRecord.r.width-parseFloat(parentRecord.style.borderRadius||0)&&visible.y+visible.height<=parentRecord.r.y+parentRecord.r.height-parseFloat(parentRecord.style.borderRadius||0));
   const paint=hostedSettings||effective.transparency===0||contained&&!coveredByPeer?background:compensate(surface,level,base,background,underlays,ownAlpha,record,palette);
   const image=paint===background?'none':paint.slice(0,-background.length-1),hasImage=image!=='none';
   writes.push(()=>{
    if(surface.dataset.materialKind!==kind)surface.dataset.materialKind=kind;
    if(surface.dataset.materialLevel!==String(level))surface.dataset.materialLevel=String(level);
    if(surface.dataset.materialCompensation!==String(hasImage))surface.dataset.materialCompensation=String(hasImage);
    if(surface.style.getPropertyValue('--layer-background')!==background)surface.style.setProperty('--layer-background',background);
    if(surface.style.getPropertyValue('--layer-compensation')!==image)surface.style.setProperty('--layer-compensation',image);
    stamp(surface);
   });
   if(r&&visible?.width&&visible?.height)underlays.push({x:r.x,y:r.y,w:r.width,h:r.height,r:parseFloat(style.borderRadius)||0,clip:visible,level});
  }
  return writes;
 }
 window.V3Materials=Object.freeze({setOwner(surface,anchor){if(anchor?.closest?.(surfaceSelector)===surface)return;if(anchor)owners.set(surface,anchor);else owners.delete(surface);schedule();},sync:()=>schedule(),stats:()=>({...metrics})});

 const stored=()=>{try{return JSON.parse(localStorage.getItem('zw-settings-v3-design')||'{}').values||{}}catch{return {}}};
 const saved=stored();let effective={transparency:clamp(saved.background_transparency??0,0,100),blur:clamp(saved.blur_px??0,0,96),imageEnabled:!!saved.background_enabled,imageURL:/^(data:image\/|blob:)/.test(saved.background_path||'')?saved.background_path:'',fit:saved.background_fit||'fill',alignment:saved.background_alignment||'center'};
 if(query.has('material-t'))effective.transparency=clamp(query.get('material-t'),0,100);if(query.has('material-b'))effective.blur=clamp(query.get('material-b'),0,96);
 let fixture=query.get('background')==='continuity';
 document.documentElement.dataset.globalEmbedded=String(embedded);
 // Match native userBubblePaint: sample the whole sRGB gradient, then keep
 // one ink and alpha while nudging both stops only when contrast needs margin.
 let bubbleCacheKey='',bubbleCache=null;
 const bubbleLum=color=>color.reduce((sum,v,i)=>{const x=v/255;return sum+[.2126,.7152,.0722][i]*(x<=.04045?x/12.92:((x+.055)/1.055)**2.4);},0);
 const bubbleContrast=(a,b)=>{const x=bubbleLum(a),y=bubbleLum(b);return(Math.max(x,y)+.05)/(Math.min(x,y)+.05);};
 const bubbleLerp=(from,to,t,fromAlpha,toAlpha=fromAlpha)=>{
  if(fromAlpha===toAlpha)return from.map((v,i)=>Math.trunc(v+(to[i]-v)*t));
  const a=fromAlpha/255,b=toAlpha/255,mixed=a+(b-a)*t;
  return from.map((v,i)=>Math.round((v*a+(to[i]*b-v*a)*t)/mixed));
 };
 function deriveBubblePaint(surface,from,to,alpha){
  const minimum=(ink,start,end)=>{let result=Infinity;for(let step=0;step<256;step++){
   const color=bubbleLerp(start,end,step/255,alpha),paint=color.map((v,i)=>Math.floor((v*alpha+surface[i]*(255-alpha)+127)/255));
   result=Math.min(result,bubbleContrast(ink,paint));
  }return result;};
  const white=[255,255,255],black=[0,0,0],w=minimum(white,from,to),b=minimum(black,from,to),ink=w>=b?white:black;
  let start=from,end=to;
  if(Math.max(w,b)<4.85){const pole=ink===white?black:white;let low=1,high=255;
   while(low<high){const middle=low+Math.floor((high-low)/2),t=middle/255;
    if(minimum(ink,bubbleLerp(from,pole,t,alpha,255),bubbleLerp(to,pole,t,alpha,255))>=4.85)high=middle;else low=middle+1;
   }
   start=bubbleLerp(from,pole,low/255,alpha,255);end=bubbleLerp(to,pole,low/255,alpha,255);
  }
  return{from:start,to:end,foreground:ink,minimum:minimum(ink,start,end)};
 }
 function syncBubbleInk(){
  const styles=getComputedStyle(document.body),rgb=name=>{let hex=styles.getPropertyValue(name).trim().replace('#','');if(hex.length===3)hex=[...hex].map(x=>x+x).join('');return[0,2,4].map(i=>parseInt(hex.slice(i,i+2),16));};
  const surface=rgb('--overlay-base'),from=rgb('--action-accent'),to=rgb('--action-accent-2'),alpha=Math.round(255*layerAlpha(2,effective.transparency/100));
  if(![...surface,...from,...to].every(Number.isFinite))return;
  const key=[...surface,...from,...to,alpha].join(',');
  if(key!==bubbleCacheKey){bubbleCacheKey=key;bubbleCache=deriveBubblePaint(surface,from,to,alpha);}
  const hex=color=>'#'+color.map(v=>v.toString(16).padStart(2,'0')).join('');
  document.body.style.setProperty('--bubble-alpha',(100*alpha/255).toFixed(4)+'%');document.body.style.setProperty('--bubble-from',hex(bubbleCache.from));document.body.style.setProperty('--bubble-to',hex(bubbleCache.to));document.body.style.setProperty('--bubble-fg',hex(bubbleCache.foreground));
 }
 const syncScheme=()=>{document.documentElement.style.colorScheme=getComputedStyle(document.body).colorScheme;syncBubbleInk()};syncScheme();
 const root=document.querySelector('#desktop,#app,.settings-window');if(!root)return;root.classList.add('zw-background-root');
 let tint=null,image=null;if(!embedded){const layer=document.createElement('div');layer.className='zw-global-background';layer.ariaHidden='true';image=document.createElement('div');image.className='zw-global-background-image';layer.append(image);tint=document.createElement('div');tint.className='zw-canvas-tint';layer.append(tint);root.prepend(layer);}
 const frames=()=>[...document.querySelectorAll('object[data-document-host],iframe')].map(n=>n.contentWindow||n.contentDocument?.defaultView).filter(Boolean);
 // Canvas colours are one opaque background group before the one global alpha.
 // Text, controls and shadows stay in the foreground tree.
 const canvasSelector='#app .titlebar,#app #sidebar,#app #content,#app .statusbar,.window-title,.host-sidebar,.terminal-pane,.window-status,#ai-edge';
 const frameCards=new WeakMap();let lastCanvasMessage='';
 function scheduleCanvas(){schedule(false,true);}
 function syncCanvas(){
  const region=root.getBoundingClientRect(),cards=[];
  for(const node of root.querySelectorAll(canvasSelector)){
   if(node.id==='content'&&node.querySelector('.group-split')){delete node.dataset.canvasCard;continue;}
   if(node.classList.contains('terminal-pane')&&node.closest('#content')&&!node.closest('.group-split'))continue;
   if(node.dataset.canvasCard!=='true')node.dataset.canvasCard='true';
   const r=node.getBoundingClientRect(),style=getComputedStyle(node);if(!r.width||!r.height||style.visibility==='hidden')continue;
   cards.push({x:r.x,y:r.y,w:r.width,h:r.height,radius:style.borderRadius});
  }
  if(embedded){
   const rects=new Map(),styles=new Map(),surfaces=[...root.querySelectorAll(surfaceSelector)].filter(n=>!n.matches('.settings-window')).map(n=>{const r=rectOf(n,rects),s=getComputedStyle(n),clip=visibleRect(n,r,rects,styles);return{x:r.x,y:r.y,w:r.width,h:r.height,r:parseFloat(s.borderRadius)||0,clip,level:levelOf(n),visible:s.visibility!=='hidden'&&s.display!=='none'};}).filter(r=>r.w&&r.h&&r.clip.width&&r.clip.height&&r.visible);
   const message={type:'zw-material-canvas',cards,surfaces},key=JSON.stringify(message);if(key!==lastCanvasMessage){lastCanvasMessage=key;metrics.canvasMessages++;parent.postMessage(message,location.origin);}return;
  }
  const all=cards.map(c=>({...c,x:c.x-region.x,y:c.y-region.y}));
  for(const frame of document.querySelectorAll('object[data-document-host],iframe')){
   const win=frame.contentWindow||frame.contentDocument?.defaultView,items=frameCards.get(win),r=frame.getBoundingClientRect();
   if(!items||!r.width||!r.height)continue;
   const sx=r.width/(frame.clientWidth||r.width),sy=r.height/(frame.clientHeight||r.height);
   for(const c of items)all.push({...c,x:r.x-region.x+c.x*sx,y:r.y-region.y+c.y*sy,w:c.w*sx,h:c.h*sy});
  }
  const markup=all.map(c=>`<i class="zw-canvas-card" style="left:${c.x}px;top:${c.y}px;width:${c.w}px;height:${c.h}px;border-radius:${c.radius}"></i>`).join('');
  if(tint&&tint.innerHTML!==markup)tint.innerHTML=markup;
 }
 if(typeof ResizeObserver==='function'&&root.querySelectorAll){resizeObserver=new ResizeObserver(()=>schedule(false,true));resizeObserver.observe(root);window.addEventListener('resize',()=>schedule(false,true));window.addEventListener('scroll',()=>schedule(false,embedded),true);}
 function apply(value){effective={...effective,...value,transparency:clamp(value.transparency??effective.transparency,0,100),blur:clamp(value.blur??effective.blur,0,96)};const t=effective.transparency/100,style=document.body.style;style.setProperty('--material-transparency',t);style.setProperty('--material-blur',effective.blur+'px');style.setProperty('--overlay-blur',Math.max(12,effective.blur)+'px');style.setProperty('--material-scrim-alpha',(1-t)*.25);for(const role of Object.keys(roles))style.setProperty('--'+role+'-alpha',(100*materialAlpha(role,t)).toFixed(4)+'%');document.body.dataset.materialTransparency=String(effective.transparency);document.body.dataset.materialBlur=String(effective.blur);syncBubbleInk();schedule();
  if(image){const url=fixture?new URL('../../../assets/backgrounds/continuity.svg',sourceURL).href:effective.imageEnabled&&/^(data:image\/|blob:)/.test(effective.imageURL||'')?effective.imageURL:null;image.style.backgroundImage=url?'url("'+url+'")':'none';image.style.opacity='1';if(tint)tint.style.opacity=String(1-t);image.style.filter='blur('+effective.blur+'px)';image.style.backgroundSize=effective.fit==='fit'?'contain':effective.fit==='tile'||effective.fit==='center'?'auto':'cover';image.style.backgroundPosition=(effective.alignment||'center').replace('-',' ');image.style.backgroundRepeat=effective.fit==='tile'?'repeat':'no-repeat';}
  scheduleCanvas();
  const tControl=document.querySelector('#material-review-transparency'),bControl=document.querySelector('#material-review-blur');if(tControl)tControl.value=effective.transparency;if(bControl)bControl.value=effective.blur;
 }
 function broadcast(){for(const f of frames())f.postMessage({type:'zw-material-effective',value:{...effective,imageVisible:imageVisible()}},location.origin);}
 function update(value){apply(value);if(embedded&&parent!==window)parent.postMessage({type:'zw-material-draft',value:effective},location.origin);else broadcast();}
 document.addEventListener('zw-material-draft',e=>update(e.detail||{}));
 window.addEventListener('message',e=>{if(e.origin!==location.origin)return;const d=e.data;if(embedded&&e.source===parent&&d?.type==='zw-material-effective'){apply(d.value||{});return;}if(!embedded&&frames().includes(e.source)){if(d?.type==='zw-material-canvas'){frameCards.set(e.source,d.cards||[]);frameMaterials.set(e.source,d.surfaces||[]);scheduleCanvas();return;}if(d?.type==='zw-material-ready')e.source.postMessage({type:'zw-material-effective',value:{...effective,imageVisible:imageVisible()}},location.origin);if(d?.type==='zw-material-draft'){apply(d.value||{});broadcast();}}});
 window.addEventListener('storage',e=>{if(e.key!=='zw-settings-v3-design')return;const v=stored();update({transparency:v.background_transparency??0,blur:v.blur_px??0,imageEnabled:!!v.background_enabled});});
 new MutationObserver(changes=>{
  let tree=false,changed=false;
  for(const change of changes){
   if(change.target.closest?.('.zw-global-background'))continue;
   if(change.type==='attributes'&&change.attributeName==='style'&&ownStyles.get(change.target)===change.target.getAttribute?.('style'))continue;
   changed=true;
   if(change.type==='childList'){for(const n of [...change.addedNodes,...change.removedNodes])if(n.nodeType===1&&(n.matches?.(surfaceSelector)||n.querySelector?.(surfaceSelector)||n.matches?.(canvasSelector)||n.querySelector?.(canvasSelector)||n.dataset?.canvasCard==='true'||n.querySelector?.('[data-canvas-card=true]')))tree=true;}
   if(change.attributeName==='class')tree=true;
  }
  if(changed)schedule(tree,embedded||tree);
 }).observe(root,{subtree:true,childList:true,attributes:true,attributeFilter:['class','hidden','style']});
 new MutationObserver(()=>{syncScheme();apply(effective);}).observe(document.body,{attributes:true,attributeFilter:['data-theme']});
 apply(effective);if(embedded&&parent!==window)parent.postMessage({type:'zw-material-ready'},location.origin);
 if(!embedded){const review=document.createElement('details');review.className='review-scenarios material-review';review.innerHTML='<summary>全局材质验证（窗口外）</summary><div class="material-review-controls"><label>透明度 <input id="material-review-transparency" type="number" min="0" max="100" aria-label="评审透明度" value="'+effective.transparency+'"> %</label><label>模糊 <input id="material-review-blur" type="number" min="0" max="96" aria-label="评审模糊" value="'+effective.blur+'"> px</label><label><input id="material-review-image" type="checkbox" '+(fixture?'checked':'')+'>连续性背景</label></div>';root.after(review);review.querySelector('#material-review-transparency').oninput=e=>update({transparency:e.target.value});review.querySelector('#material-review-blur').oninput=e=>update({blur:e.target.value});review.querySelector('#material-review-image').onchange=e=>{fixture=e.target.checked;apply(effective);};}
})();
