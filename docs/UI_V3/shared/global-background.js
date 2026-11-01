'use strict';
// Shared base curves: images get a chrome floor; floating overlays always guard arbitrary RGB.
(()=>{
 const sourceURL=document.currentScript?.src||location.href,query=new URLSearchParams(location.search),embedded=query.has('integrated')||query.has('embed');
 // Final [base transparency P0, slider span D, maximum transparency M].
 const roles={'surface-1':[0.446777856,0.670166784,0.95],'surface-2':[0.305690112,0.752467968,0.9],'well':[0.211631616,0.728953344,0.8],'overlay':[0.04,0.12,0.16],'hover':[0.235146240,0.646652160,0.75],'tab-on':[0.164602368,0.599622912,0.65],'card-deep':[0.305690112,0.752467968,0.9],'card-deep-ft':[0.211631616,0.728953344,0.8]};
 let materialAlphaCache=null;
 const imageVisible=()=>fixture||(embedded&&effective.imageVisible===true)||(effective.imageEnabled&&/^(data:image\/|blob:)/.test(effective.imageURL||''));
 const materialRGB=(styles,name)=>{let hex=styles.getPropertyValue(name).trim().replace('#','');if(hex.length===3)hex=[...hex].map(v=>v+v).join('');return[0,2,4].map(i=>parseInt(hex.slice(i,i+2),16));};
 const materialPaint=(fg,bg,alpha)=>fg.map((v,i)=>Math.floor((v*alpha+bg[i]*(255-alpha)+127)/255));
 function materialAlpha(role,t){
  const [p0,d,m]=roles[role],original=Math.round(255*(1-Math.min(m,p0+d*t))),visible=imageVisible();
  if(!visible&&role!=='overlay')return original/255;
  const styles=getComputedStyle(document.body),names=['--bg-app','--surface-1-base','--surface-2-base','--well-base','--overlay-base','--hover-base','--tab-on-base','--fg-1','--fg-2','--fg-3','--accent-ink','--ok-ink','--warn-ink','--danger-ink','--terminal-default-fg','--action-accent'],colors=names.map(name=>materialRGB(styles,name));
  if(!colors.flat().every(Number.isFinite))return original/255;
  const key=[visible,t,...colors.flat()].join(',');
  if(materialAlphaCache?.key!==key){
   const palette=Object.fromEntries(names.map((name,i)=>[name,colors[i]])),inkNames=names.slice(7,14),veil=Math.round(255*t),imageBounds=[[0,0,0],[255,255,255]].map(pole=>materialPaint(palette['--bg-app'],pole,veil)),alphas={};
   for(const [name,[base,span,cap]]of Object.entries(roles)){
    if(!visible&&name!=='overlay'){alphas[name]=Math.round(255*(1-Math.min(cap,base+span*t)))/255;continue;}
    const nativeRole=name==='card-deep'?'surface-2':name==='card-deep-ft'?'well':name,surface=palette['--'+nativeRole+'-base'],parents=name==='overlay'?[[0,0,0],[255,255,255]]:imageBounds;
    const passes=alpha=>{const paints=parents.map(parent=>materialPaint(surface,parent,alpha)),lumas=paints.map(bubbleLum),lower=Math.min(...lumas),upper=Math.max(...lumas);return(nativeRole==='surface-1'?[...inkNames,'--terminal-default-fg']:inkNames).every(inkName=>{const ink=palette[inkName],luma=bubbleLum(ink),actual=inkName==='--terminal-default-fg'?[...paints,...paints.map(paint=>materialPaint(palette['--action-accent'],paint,15))]:paints,low=Math.min(lower,...actual.map(bubbleLum)),high=Math.max(upper,...actual.map(bubbleLum));return(luma<low||luma>high)&&actual.every(paint=>bubbleContrast(ink,paint)>=4.65);});};
    let low=Math.round(255*(1-Math.min(cap,base+span*t))),high=255;while(low<high){const middle=low+Math.floor((high-low)/2);if(passes(middle))high=middle;else low=middle+1;}alphas[name]=low/255;
   }
   materialAlphaCache={key,alphas};
  }
  return materialAlphaCache.alphas[role];
 }
 const clamp=(v,min,max)=>Math.max(min,Math.min(max,Number.isFinite(+v)?+v:min));
 // Surface boundaries only: component names never select an alpha percentage.
 const floatingSelector='.popover,.context-menu,.modal,.assistant,.v3-ai-model-info,.v3-hover,.design-tooltip,.toast,#tooltip,.utility-layer,#global-notice,#settings-frame,.settings-window,.mode-menu[data-execution-patch-surface],.v3-select-popover[data-execution-patch-surface],.process-panel[data-execution-patch-surface]';
 const owners=new WeakMap();
 const layerAlpha=(level,t)=>level>=3?1:level===2?Math.max(materialAlpha('overlay',t),Math.round(255*(1-(.01+.03*t)))/255):materialAlpha('overlay',t);
 function levelOf(surface,seen=new Set()){
  if(!surface||seen.has(surface))return 0;seen.add(surface);
  const anchor=owners.get(surface),parent=(anchor?.isConnected?anchor:surface.parentElement)?.closest(floatingSelector);
  return Math.min(3,1+levelOf(parent,seen));
 }
 function syncLayers(){for(const surface of document.querySelectorAll(floatingSelector)){
  const level=levelOf(surface),alpha=(100*layerAlpha(level,effective.transparency/100)).toFixed(4)+'%',background='color-mix(in srgb,rgb(from var(--overlay-base) r g b / 1) '+alpha+',transparent)';
  if(surface.dataset.materialLevel!==String(level))surface.dataset.materialLevel=String(level);
  if(surface.style.getPropertyValue('--layer-background')!==background)surface.style.setProperty('--layer-background',background);
 }}
 window.V3Materials=Object.freeze({setOwner(surface,anchor){if(anchor)owners.set(surface,anchor);else owners.delete(surface);syncLayers();},sync:syncLayers});

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
  const surface=rgb('--overlay-base'),from=rgb('--action-accent'),to=rgb('--action-accent-2'),alpha=Math.round(255*materialAlpha('overlay',effective.transparency/100));
  if(![...surface,...from,...to].every(Number.isFinite))return;
  const key=[...surface,...from,...to,alpha].join(',');
  if(key!==bubbleCacheKey){bubbleCacheKey=key;bubbleCache=deriveBubblePaint(surface,from,to,alpha);}
  const hex=color=>'#'+color.map(v=>v.toString(16).padStart(2,'0')).join('');
  document.body.style.setProperty('--bubble-from',hex(bubbleCache.from));document.body.style.setProperty('--bubble-to',hex(bubbleCache.to));document.body.style.setProperty('--bubble-fg',hex(bubbleCache.foreground));
 }
 const syncScheme=()=>{document.documentElement.style.colorScheme=getComputedStyle(document.body).colorScheme;syncBubbleInk()};syncScheme();
 const root=document.querySelector('#desktop,#app,#notes-app,.settings-window');if(!root)return;root.classList.add('zw-background-root');
 let image=null;if(!embedded){const layer=document.createElement('div');layer.className='zw-global-background';layer.ariaHidden='true';image=document.createElement('div');image.className='zw-global-background-image';layer.append(image);root.prepend(layer);}
 const frames=()=>[...document.querySelectorAll('object[data-document-host],iframe')].map(n=>n.contentWindow||n.contentDocument?.defaultView).filter(Boolean);
 function apply(value){effective={...effective,...value,transparency:clamp(value.transparency??effective.transparency,0,100),blur:clamp(value.blur??effective.blur,0,96)};const t=effective.transparency/100,style=document.body.style;style.setProperty('--material-transparency',t);style.setProperty('--material-blur',effective.blur+'px');style.setProperty('--overlay-blur',Math.max(12,effective.blur)+'px');style.setProperty('--material-scrim-alpha',(1-t)*.25);for(const role of Object.keys(roles))style.setProperty('--'+role+'-alpha',(100*materialAlpha(role,t)).toFixed(4)+'%');document.body.dataset.materialTransparency=String(effective.transparency);document.body.dataset.materialBlur=String(effective.blur);syncBubbleInk();syncLayers();
  if(image){const url=fixture?new URL('../assets/backgrounds/continuity.svg',sourceURL).href:effective.imageEnabled&&/^(data:image\/|blob:)/.test(effective.imageURL||'')?effective.imageURL:null;image.style.backgroundImage=url?'url("'+url+'")':'none';image.style.opacity=String(1-t);image.style.filter='blur('+effective.blur+'px)';image.style.backgroundSize=effective.fit==='fit'?'contain':effective.fit==='tile'||effective.fit==='center'?'auto':'cover';image.style.backgroundPosition=(effective.alignment||'center').replace('-',' ');image.style.backgroundRepeat=effective.fit==='tile'?'repeat':'no-repeat';}
  const tControl=document.querySelector('#material-review-transparency'),bControl=document.querySelector('#material-review-blur');if(tControl)tControl.value=effective.transparency;if(bControl)bControl.value=effective.blur;
 }
 function broadcast(){for(const f of frames())f.postMessage({type:'zw-material-effective',value:{...effective,imageVisible:imageVisible()}},location.origin);}
 function update(value){apply(value);if(embedded&&parent!==window)parent.postMessage({type:'zw-material-draft',value:effective},location.origin);else broadcast();}
 document.addEventListener('zw-material-draft',e=>update(e.detail||{}));
 window.addEventListener('message',e=>{if(e.origin!==location.origin)return;const d=e.data;if(embedded&&e.source===parent&&d?.type==='zw-material-effective'){apply(d.value||{});return;}if(!embedded&&frames().includes(e.source)){if(d?.type==='zw-material-ready')e.source.postMessage({type:'zw-material-effective',value:{...effective,imageVisible:imageVisible()}},location.origin);if(d?.type==='zw-material-draft'){apply(d.value||{});broadcast();}}});
 window.addEventListener('storage',e=>{if(e.key!=='zw-settings-v3-design')return;const v=stored();update({transparency:v.background_transparency??0,blur:v.blur_px??0,imageEnabled:!!v.background_enabled});});
 new MutationObserver(syncLayers).observe(root,{subtree:true,childList:true,attributes:true,attributeFilter:['class','hidden','style']});
 new MutationObserver(()=>{syncScheme();apply(effective);}).observe(document.body,{attributes:true,attributeFilter:['data-theme']});
 apply(effective);if(embedded&&parent!==window)parent.postMessage({type:'zw-material-ready'},location.origin);
 if(!embedded){const review=document.createElement('details');review.className='review-scenarios material-review';review.innerHTML='<summary>全局材质验证（窗口外）</summary><div class="material-review-controls"><label>透明度 <input id="material-review-transparency" type="number" min="0" max="100" aria-label="评审透明度" value="'+effective.transparency+'"> %</label><label>模糊 <input id="material-review-blur" type="number" min="0" max="96" aria-label="评审模糊" value="'+effective.blur+'"> px</label><label><input id="material-review-image" type="checkbox" '+(fixture?'checked':'')+'>连续性背景</label></div>';root.after(review);review.querySelector('#material-review-transparency').oninput=e=>update({transparency:e.target.value});review.querySelector('#material-review-blur').oninput=e=>update({blur:e.target.value});review.querySelector('#material-review-image').onchange=e=>{fixture=e.target.checked;apply(effective);};}
})();
