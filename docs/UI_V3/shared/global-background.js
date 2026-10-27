'use strict';
// Shared effective material settings. The image switch never gates surface derivation.
(()=>{
 const sourceURL=document.currentScript?.src||location.href,query=new URLSearchParams(location.search),embedded=query.has('integrated')||query.has('embed');
 const coefficients={'surface-1':.95,'surface-2':.90,well:.80,overlay:.65,hover:.75,'tab-on':.65,'card-deep':.90,'card-deep-ft':.80};
 const clamp=(v,min,max)=>Math.max(min,Math.min(max,Number.isFinite(+v)?+v:min));
 const stored=()=>{try{return JSON.parse(localStorage.getItem('zw-settings-v3-design')||'{}').values||{}}catch{return {}}};
 const saved=stored();let effective={transparency:clamp(saved.background_transparency??0,0,100),blur:clamp(saved.blur_px??0,0,96),imageEnabled:!!saved.background_enabled,imageURL:/^(data:image\/|blob:)/.test(saved.background_path||'')?saved.background_path:'',fit:saved.background_fit||'fill',alignment:saved.background_alignment||'center'};
 if(query.has('material-t'))effective.transparency=clamp(query.get('material-t'),0,100);if(query.has('material-b'))effective.blur=clamp(query.get('material-b'),0,96);
 let fixture=query.get('background')==='continuity';
 document.documentElement.dataset.globalEmbedded=String(embedded);
 // Match native bubble ink against the theme overlay after material alpha.
 function syncBubbleInk(){
  const styles=getComputedStyle(document.body),rgb=name=>{let hex=styles.getPropertyValue(name).trim().replace('#','');if(hex.length===3)hex=[...hex].map(x=>x+x).join('');return [0,2,4].map(i=>parseInt(hex.slice(i,i+2),16));};
  const surface=rgb('--overlay-base'),accent=rgb('--action-accent'),alpha=Math.round(255*(1-effective.transparency/100*.65))/255;
  const paint=surface.map((v,i)=>Math.floor(v+(accent[i]-v)*alpha));
  const lum=color=>color.reduce((sum,v,i)=>{const x=v/255;return sum+[.2126,.7152,.0722][i]*(x<=.04045?x/12.92:((x+.055)/1.055)**2.4);},0);
  const l=lum(paint),dark=lum([16,16,20]);
  document.body.style.setProperty('--bubble-fg',1.05/(l+.05)>=(Math.max(l,dark)+.05)/(Math.min(l,dark)+.05)?'#fff':'#101014');
 }
 const syncScheme=()=>{document.documentElement.style.colorScheme=getComputedStyle(document.body).colorScheme;syncBubbleInk()};syncScheme();new MutationObserver(syncScheme).observe(document.body,{attributes:true,attributeFilter:['data-theme']});
 const root=document.querySelector('#desktop,#app,#notes-app,.settings-window');if(!root)return;root.classList.add('zw-background-root');
 let image=null;if(!embedded){const layer=document.createElement('div');layer.className='zw-global-background';layer.ariaHidden='true';image=document.createElement('div');image.className='zw-global-background-image';layer.append(image);root.prepend(layer);}
 const frames=()=>[...document.querySelectorAll('object[data-document-host],iframe')].map(n=>n.contentWindow||n.contentDocument?.defaultView).filter(Boolean);
 function apply(value){effective={...effective,...value,transparency:clamp(value.transparency??effective.transparency,0,100),blur:clamp(value.blur??effective.blur,0,96)};const t=effective.transparency/100,style=document.body.style;style.setProperty('--material-transparency',t);style.setProperty('--material-blur',effective.blur+'px');style.setProperty('--material-scrim-alpha',(1-t)*.25);for(const [role,k]of Object.entries(coefficients))style.setProperty('--'+role+'-alpha',(100*(1-Math.min(1,Math.max(0,t*k)))).toFixed(4)+'%');document.body.dataset.materialTransparency=String(effective.transparency);document.body.dataset.materialBlur=String(effective.blur);syncBubbleInk();
  if(image){const url=fixture?new URL('../assets/backgrounds/continuity.svg',sourceURL).href:effective.imageEnabled&&/^(data:image\/|blob:)/.test(effective.imageURL||'')?effective.imageURL:null;image.style.backgroundImage=url?'url("'+url+'")':'none';image.style.opacity=String(1-t);image.style.filter='blur('+effective.blur+'px)';image.style.backgroundSize=effective.fit==='fit'?'contain':effective.fit==='tile'||effective.fit==='center'?'auto':'cover';image.style.backgroundPosition=(effective.alignment||'center').replace('-',' ');image.style.backgroundRepeat=effective.fit==='tile'?'repeat':'no-repeat';}
  const tControl=document.querySelector('#material-review-transparency'),bControl=document.querySelector('#material-review-blur');if(tControl)tControl.value=effective.transparency;if(bControl)bControl.value=effective.blur;
 }
 function broadcast(){for(const f of frames())f.postMessage({type:'zw-material-effective',value:effective},location.origin);}
 function update(value){apply(value);if(embedded&&parent!==window)parent.postMessage({type:'zw-material-draft',value:effective},location.origin);else broadcast();}
 document.addEventListener('zw-material-draft',e=>update(e.detail||{}));
 window.addEventListener('message',e=>{if(e.origin!==location.origin)return;const d=e.data;if(embedded&&e.source===parent&&d?.type==='zw-material-effective'){apply(d.value||{});return;}if(!embedded&&frames().includes(e.source)){if(d?.type==='zw-material-ready')e.source.postMessage({type:'zw-material-effective',value:effective},location.origin);if(d?.type==='zw-material-draft'){apply(d.value||{});broadcast();}}});
 window.addEventListener('storage',e=>{if(e.key!=='zw-settings-v3-design')return;const v=stored();update({transparency:v.background_transparency??0,blur:v.blur_px??0,imageEnabled:!!v.background_enabled});});
 apply(effective);if(embedded&&parent!==window)parent.postMessage({type:'zw-material-ready'},location.origin);
 if(!embedded){const review=document.createElement('details');review.className='review-scenarios material-review';review.innerHTML='<summary>全局材质验证（窗口外）</summary><div class="material-review-controls"><label>透明度 <input id="material-review-transparency" type="number" min="0" max="100" aria-label="评审透明度" value="'+effective.transparency+'"> %</label><label>模糊 <input id="material-review-blur" type="number" min="0" max="96" aria-label="评审模糊" value="'+effective.blur+'"> px</label><label><input id="material-review-image" type="checkbox" '+(fixture?'checked':'')+'>连续性背景</label></div>';root.after(review);review.querySelector('#material-review-transparency').oninput=e=>update({transparency:e.target.value});review.querySelector('#material-review-blur').oninput=e=>update({blur:e.target.value});review.querySelector('#material-review-image').onchange=e=>{fixture=e.target.checked;apply(effective);};}
})();
