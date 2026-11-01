/** Exercise the same editable HTML material implementation on native palette data. */
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
const source=readFileSync(new URL('../docs/UI_V3/shared/global-background.js',import.meta.url),'utf8'),data=JSON.parse(readFileSync(new URL('../docs/UI_V3/theme-presets.json',import.meta.url),'utf8'));
const roleLiteral=source.match(/const roles=(\{[^\n]+\});/)[1],logic=source.slice(source.indexOf(' let materialAlphaCache='),source.indexOf(' const clamp='));
const luminance=c=>c.reduce((s,v,i)=>{const x=v/255;return s+(x<=.04045?x/12.92:((x+.055)/1.055)**2.4)*[.2126,.7152,.0722][i]},0);
const contrast=(a,b)=>{const [lo,hi]=[luminance(a),luminance(b)].sort((x,y)=>x-y);return(hi+.05)/(lo+.05)};
const rgb=s=>[1,3,5].map(i=>parseInt(s.slice(i,i+2),16)),paint=(fg,bg,alpha)=>fg.map((v,i)=>Math.floor((v*alpha+bg[i]*(255-alpha)+127)/255));
let palette;const effective={imageEnabled:true,imageURL:'data:image/png;base64,fixture'},styles={getPropertyValue:name=>palette[name]??''};
const factory=new Function('getComputedStyle','document','fixture','embedded','effective','bubbleLum','bubbleContrast',`const roles=${roleLiteral};${logic};return {materialAlpha,roles};`);
const api=factory(()=>styles,{body:{}},false,false,effective,luminance,contrast),report=[];let cases=0,minimum=Infinity;
for(const [id,colors]of Object.entries(data.themes)){
 palette={...colors,'--terminal-default-fg':data.terminalPalettes[id].foreground};
 for(const t of [0,.5,1]){
  effective.imageEnabled=false;for(const [role,[base,span,cap]]of Object.entries(api.roles)){
   const alpha=Math.round(api.materialAlpha(role,t)*255),baseline=Math.round(255*(1-Math.min(cap,base+span*t)));
   if(role==='overlay'){
    assert(alpha>=baseline,`${id} no-image floating overlay floor`);
    for(const gray of [0,64,128,192,255])for(const ink of ['fg-1','fg-2','fg-3','accent-ink','ok-ink','warn-ink','danger-ink'])assert(contrast(rgb(palette['--'+ink]),paint(rgb(palette['--overlay-base']),[gray,gray,gray],alpha))>=4.5,`${id} arbitrary app RGB ${gray} ${ink}`);
   }else assert.equal(alpha,baseline,`${id} no-image ${role}`);
  }
  effective.imageEnabled=true;const alphas=Object.fromEntries(Object.keys(api.roles).map(role=>[role,Math.round(255*api.materialAlpha(role,t))]));let weakest=Infinity;
  for(const role of ['surface-1','surface-2','well','overlay','hover','tab-on'])for(const gray of [0,64,128,192,255]){
   const parent=role==='overlay'?[gray,gray,gray]:paint(rgb(colors['--bg-app']),[gray,gray,gray],Math.round(255*t)),background=paint(rgb(colors['--'+role+'-base']),parent,alphas[role]);
   const inks=['fg-1','fg-2','fg-3','accent-ink','ok-ink','warn-ink','danger-ink',...(role==='surface-1'?['terminal-default-fg']:[])];
   for(const ink of inks){const backgrounds=ink==='terminal-default-fg'?[background,paint(rgb(palette['--action-accent']),background,15)]:[background];for(const actual of backgrounds){const value=contrast(rgb(palette['--'+ink]),actual);assert(value>=4.5,`${id} T=${t*100} ${role} gray=${gray} ${ink} ${value}`);weakest=Math.min(weakest,value);cases++;}}
  }
  const before=alphas['surface-1'];effective.imageEnabled=false;api.materialAlpha('surface-1',t);effective.imageEnabled=true;assert.equal(Math.round(255*api.materialAlpha('surface-1',t)),before,'image visibility cache');
  minimum=Math.min(minimum,weakest);report.push({theme:id,transparency:t*100,alphas,minimum:weakest});
 }
}
if(process.argv[2])writeFileSync(process.argv[2],JSON.stringify({cases,minimum,report},null,2));
console.log(`PASS: HTML image-floor ${report.length} theme/transparency states, ${cases} actual alpha8/gray/ink combinations, minimum ${minimum.toFixed(5)}:1; no-image chrome curves/image-toggle cache preserved; floating overlays guard arbitrary RGB`);
