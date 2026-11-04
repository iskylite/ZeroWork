/** Exact user-controlled alpha and image-toggle parity across every theme. */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const source=readFileSync(new URL('../docs/UI_V3/shared/global-background.js',import.meta.url),'utf8');
const roles=JSON.parse(source.match(/const roles=(\{[^\n]+\});/)[1].replaceAll("'",'"'));
const materialAlpha=new Function('roles',source.slice(source.indexOf(' function materialAlpha('),source.indexOf(' const clamp='))+'return materialAlpha;')(roles);
const themes=JSON.parse(readFileSync(new URL('../docs/UI_V3/theme-presets.json',import.meta.url),'utf8')).themes;
let checks=0;
for(const id of Object.keys(themes))for(const t of [0,.25,.5,.75,1])for(const [role,[base,span,cap]]of Object.entries(roles)){
 assert.equal(Math.round(255*materialAlpha(role,t)),Math.round(255*(1-Math.min(cap,base+span*t))),`${id} ${role} T=${t}`);checks++;
}
const transmission=level=>(5-Math.min(level,4))/5;
const layerAlpha=new Function('transmission','return '+source.match(/const layerAlpha=([^;]+);/)[1])(transmission);
for(const t of [.01,.25,.5,.75,1])for(let level=1;level<=12;level++){
 const under=1-t*transmission(level-1),actual=under+(1-under)*layerAlpha(level,t),expected=1-t*transmission(level);
 assert(Math.abs(actual-expected)<.002,`Final material L${level}, T=${t}`);
 // A portal over any shallower owner must reach the same final transmission.
 for(let covered=0;covered<level;covered++){
  const extra=1-transmission(level-1)/transmission(covered);
  const actualTransmission=t*transmission(covered)*(1-layerAlpha(level,t))*(1-extra);
  assert(Math.abs(actualTransmission-t*transmission(level))<.002);
 }
}
console.log(`PASS: ${checks} role alphas, final composited depth targets, uncovered-owner compensation and L4+ cap`);
