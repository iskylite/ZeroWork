/** Browser material service contract, executed without a window or user storage.
 * node e2e/material_contract.mjs */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const source=readFileSync(new URL('../docs/UI_V3/shared/global-background.js',import.meta.url),'utf8');
const native=readFileSync(new URL('../src/ui/app_theme.zig',import.meta.url),'utf8');
const presets=JSON.parse(readFileSync(new URL('../docs/UI_V3/theme-presets.json',import.meta.url),'utf8'));
const constants=name=>Object.fromEntries([...native.match(new RegExp(`pub const ${name} = struct \\{([\\s\\S]*?)\\};`))[1].matchAll(/pub const (\w+): f32 = ([\d.]+);/g)].map(m=>[m[1].replaceAll('_','-'),+m[2]]));
const bases=constants('material_transparency_base'),spans=constants('material_transparency_span'),limits=constants('material_ratio');
for(const values of [bases,spans]){values['card-deep']=values['surface-2'];values['card-deep-ft']=values.well;}
limits['card-deep']=limits['surface-2'];limits['card-deep-ft']=limits.well;
assert.deepEqual(presets.materialProjection.baseTransparency,bases);
assert.deepEqual(presets.materialProjection.sliderTransparencySpan,spans);
assert.deepEqual(presets.materialProjection.maximumTransparency,limits);
// Keep native constants, design tables, default palette bytes and CSS fallbacks aligned.
const css=readFileSync(new URL('../docs/UI_V3/theme-tokens.css',import.meta.url),'utf8');
const guides=['../docs/DESIGN/DESIGN_STANDARDS.md','../docs/UI_V3/GLOBAL_THEME_CONTRACT.md','../docs/UI_V3/LAYER_MATERIALS.md'].map(path=>readFileSync(new URL(path,import.meta.url),'utf8'));
for(const [role,p0] of Object.entries(bases)){
 const alpha=Math.round(255*(1-p0)),percent=(100*alpha/255).toFixed(4)+'%';
 const references=[...css.matchAll(new RegExp('--'+role+'-alpha[:,]([\\d.]+%)','g'))];
 assert(references.length>=2,`Missing CSS default/fallback for ${role}`);
 for(const match of references)assert.equal(match[1],percent,`CSS ${role} alpha`);
 if(role.startsWith('card-deep'))continue;
 for(const guide of guides){
  const row=guide.split('\n').find(line=>line.startsWith('| '+role+' |')&&line.includes(p0.toFixed(9)));
  assert(row&&row.includes(spans[role].toFixed(9))&&Number(row.split('|').at(-2).trim())===limits[role],`Design constants for ${role}`);
  assert(guide.includes(`| ${role} | ${(100*p0).toFixed(8)}% | ${alpha}/255 | ${(100*alpha/255).toFixed(6)}% |`),`Design quantization for ${role}`);
 }
}
let checks=0;
for(const palette of Object.values(presets.themes)){
 const values=new Map(),events={};
 const root={classList:{add(){}}};
 const body={style:{setProperty:(k,v)=>values.set(k,String(v))},dataset:{}};
 const document={body,documentElement:{dataset:{},style:{}},currentScript:null,querySelector:s=>s.startsWith('#desktop,')?root:null,querySelectorAll:()=>[],addEventListener:(k,v)=>events[k]=v};
 const window={addEventListener(){}};
 const context={document,window,parent:window,location:{href:'http://fixture.test/?embed',search:'?embed',origin:'http://fixture.test'},URL,URLSearchParams,localStorage:{getItem:()=>null},MutationObserver:class{observe(){}},getComputedStyle:()=>({colorScheme:'dark',getPropertyValue:k=>palette[k]||''})};
 vm.runInNewContext(source,context);
 for(const t of [0,25,75,100])for(const b of [0,8,24])for(const imageEnabled of [false,true]){
  events['zw-material-draft']({detail:{transparency:t,blur:b,imageEnabled}});
  const alpha=[];
  for(const [role,p0] of Object.entries(bases)){
   const m=limits[role],expected=Math.round(255*(1-Math.min(m,p0+spans[role]*t/100)));
   assert.equal(values.get('--'+role+'-alpha'),(100*expected/255).toFixed(4)+'%');
   if(t===0)assert.equal(palette['--'+role].slice(-2),expected.toString(16).padStart(2,'0'));
   if(['surface-1','surface-2','well','overlay'].includes(role))alpha.push(expected);
   checks++;
  }
  assert(alpha.every((v,i)=>i===0||v>alpha[i-1]));
  assert.equal(values.get('--material-blur'),b+'px');
  assert.equal(values.get('--overlay-blur'),Math.max(12,b)+'px');
  assert(['#fff','#101014'].includes(values.get('--bubble-fg')));
 }
}
console.log(`Material contract passed: ${Object.keys(presets.themes).length} themes, T=0/25/75/100, B=0/8/24, image on/off; ${checks} role alpha checks.`);
