/** Keep the editable design colors and all native builtin UI palettes aligned. */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const native=readFileSync(new URL('../src/config/theme_presets.zig',import.meta.url),'utf8');
const catalogData=JSON.parse(readFileSync(new URL('../docs/UI_V3/theme-presets.json',import.meta.url),'utf8'));
const design=catalogData.themes;
const css=readFileSync(new URL('../docs/UI_V3/theme-tokens.css',import.meta.url),'utf8');
const quick=JSON.parse(readFileSync(new URL('../docs/UI_V3/workspace/quick-connect/palettes.js',import.meta.url),'utf8').replace(/^const palettes\s*=\s*/,'').replace(/;\s*$/,''));
const workspace=readFileSync(new URL('../docs/UI_V3/workspace/app.js',import.meta.url),'utf8');
const catalog=workspace.match(/const themeCatalog=(\[[^\n]+);/);assert(catalog,'workspace theme catalogue');
const workspaceIds=[...catalog[1].matchAll(/\['([^']+)',/g)].map(m=>m[1]);
assert.deepEqual(workspaceIds.sort(),Object.keys(design).sort(),'workspace catalogue covers all shared themes');
const roles={app:'bg-app',surface_1:'surface-1-base',surface_2:'surface-2-base',well:'well-base',well_border:'well-bd',terminal:'bg-term-base',overlay:'overlay-base',hover:'hover-base',tab_on:'tab-on-base',fg_1:'fg-1',fg_2:'fg-2',fg_3:'fg-3',accent:'accent-base',accent_ink:'accent-ink',action_accent:'action-accent',action_accent_2:'action-accent-2',action_danger:'action-danger',ok:'ok',ok_ink:'ok-ink',warn:'warn',warn_ink:'warn-ink',danger:'danger-base',danger_ink:'danger-ink',selection:'sel-bg'};
const palettes=[...native.matchAll(/if \(std\.mem\.eql\(u8, id, "([^"]+)"\)\) return \.\{(.*?)\n    \};/gs)].map(m=>[m[1],Object.fromEntries([...m[2].matchAll(/\.(\w+) = 0x([\da-f]+)/g)].map(v=>[v[1],v[2]]))]);
assert.equal(palettes.length,39);assert.equal(Object.keys(design).length,palettes.length);assert.equal(Object.keys(quick).length,palettes.length);
let checked=0;
for(const [id,colors] of palettes){
 assert.equal(Object.keys(colors).length,26,id+' role completeness');
 const rule=[...css.matchAll(new RegExp('body\\[data-theme="'+id+'"\\]\\{([^}]+)\\}','g'))].at(-1);assert(rule,id+' CSS');
 const vars=Object.fromEntries([...rule[1].matchAll(/(--[\w-]+):([^;]+);/g)].map(m=>[m[1],m[2]]));
 assert.equal(vars['--terminal-default-fg'],catalogData.terminalPalettes[id].foreground,id+' independent terminal foreground guard');
 for(const [role,key] of Object.entries(roles)){
  const full='#'+colors[role],value=full.endsWith('ff')?full.slice(0,-2):full;
  assert.equal(design[id]['--'+key],value,id+' JSON '+role);
  assert.equal(vars['--'+key],value,id+' CSS '+role);
  assert.equal(quick[id][role],full.slice(0,7),id+' quick-connect '+role);checked++;
 }
}
console.log(`PASS: ${palettes.length} themes, 26 native roles, ${checked} shared design/native color pairs, workspace catalogue ${workspaceIds.length}`);
// ANSI content has its own palette; keep all sixteen native slots aligned with
// the editable terminal preview independently of UI contrast adjustments.
const ansiSource=native.slice(native.indexOf('pub fn ansi'),native.indexOf('pub fn name'));
let ansiChecks=0;
for(const match of ansiSource.matchAll(/if \(std\.mem\.eql\(u8, id, "([^"]+)"\)\) return \.\{([^\n]+)\};/g)){
 const id=match[1],colors=[...match[2].matchAll(/0x([\da-f]+)/gi)].map(value=>'#'+value[1].slice(0,6).toLowerCase());
 assert.equal(colors.length,16,id+' native ANSI completeness');
 assert.deepEqual(colors,catalogData.terminalPalettes[id].ansi.map(value=>value.toLowerCase()),id+' terminal ANSI source parity');
 assert.equal(catalogData.terminalPalettes[id].background.toLowerCase(),design[id]['--bg-term-base'].toLowerCase(),id+' terminal background parity');
 ansiChecks++;
}
assert.equal(ansiChecks,palettes.length,'all native ANSI palettes checked');
console.log(`PASS: ${ansiChecks} terminal palettes × 16 ANSI slots match the editable preview`);
const terminalSource=native.slice(native.indexOf('pub fn terminalDefaults'));
for(const match of terminalSource.matchAll(/if \(std\.mem\.eql\(u8, id, "([^"]+)"\)\) return \.\{([^\n]+)\};/g)){
 const id=match[1],fields=Object.fromEntries([...match[2].matchAll(/\.(foreground|cursor|selection) = 0x([\da-f]+)/gi)].map(value=>[value[1],value[2].toLowerCase()]));
 for(const [role,value]of Object.entries(fields))assert.equal(catalogData.terminalPalettes[id][role].toLowerCase(),'#'+(value.endsWith('ff')?value.slice(0,-2):value),id+' terminal '+role+' RGBA');
}
// Helper text is small readable content: it uses the same 4.5 floor as normal
// copy, including actual alpha8 composites and focused/selected neutral fills.
const rgb=value=>[1,3,5].map(i=>parseInt(value.slice(i,i+2),16));
const mix=(a,b,t)=>a.map((v,i)=>Math.trunc(v+(b[i]-v)*t));
const luminance=c=>c.reduce((sum,v,i)=>{const s=v/255;return sum+(s<=.04045?s/12.92:((s+.055)/1.055)**2.4)*[.2126,.7152,.0722][i]},0);
const contrast=(a,b)=>{const values=[luminance(a),luminance(b)].sort((x,y)=>x-y);return(values[1]+.05)/(values[0]+.05)};
const materials={'surface-1':[.446777856,.670166784,.95],'surface-2':[.305690112,.752467968,.9],well:[.211631616,.728953344,.8],overlay:[.04,.12,.16],hover:[.23514624,.64665216,.75],'tab-on':[.164602368,.599622912,.65]};
let helperChecks=0,minHelper=Infinity,insetChecks=0;
for(const [id,palette] of Object.entries(design)){
 const c=Object.fromEntries(Object.entries(palette).filter(([,value])=>value.startsWith('#')).map(([key,value])=>[key.slice(2),rgb(value)]));
 // Match native insetColor's alpha-255 RGB interpolation and 1.1 boundary.
 const inset=c['overlay-base'].map((value,i)=>Math.trunc(Math.fround(value+Math.fround(Math.fround(c['well-base'][i]-value)*Math.fround(.3)))));
 const insetStrength=contrast(c['overlay-base'],inset)>=1.1?'30%':'100%';
 assert.equal(palette['--control-inset-well-strength'],insetStrength,id+' JSON native inset strength');
 const rule=[...css.matchAll(new RegExp('body\\[data-theme="'+id+'"\\]\\{([^}]+)\\}','g'))].at(-1);
 assert.equal(rule[1].match(/--control-inset-well-strength:([^;]+);/)[1],insetStrength,id+' CSS native inset strength');insetChecks++;
 const dark=c['bg-app'].reduce((sum,v,i)=>sum+v*[299,587,114][i],0)<128000;
 for(const t of [0,50,100]){
  const backgrounds=[c['bg-app'],c['overlay-base'],mix(c['overlay-base'],c['well-base'],.3),mix(c['overlay-base'],c['fg-2'],.12),mix(c['overlay-base'],c['accent-base'],dark?.16:.10),...Object.entries(materials).map(([role,[base,span,cap]])=>mix(c['bg-app'],c[role+'-base'],Math.round(255*(1-Math.min(cap,base+span*t/100)))/255))];
  for(const background of backgrounds){
   const values=['fg-1','fg-2','fg-3'].map(role=>contrast(c[role],background));
   assert(values.every(value=>value>=4.5),`${id} T=${t}: readable text ${values}`);
   assert(values[0]>values[1]&&values[1]>values[2],`${id} T=${t}: text hierarchy ${values}`);
   minHelper=Math.min(minHelper,values[2]);helperChecks++;
  }
 }
}
console.log(`PASS: ${helperChecks} auxiliary text/material cases at 4.5:1; minimum ${minHelper.toFixed(3)}:1 with three distinct ink levels`);
console.log(`PASS: ${insetChecks} HTML inset strengths match native opaque fill derivation`);

// State palettes are generated from the same bases; drift is a theme failure.
const {publish}=await import('../scripts/sync_theme_states.mjs');publish(true);
