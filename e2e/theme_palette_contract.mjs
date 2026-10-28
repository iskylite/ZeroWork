/** Keep the editable design colors and all native builtin UI palettes aligned. */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const native=readFileSync(new URL('../src/config/theme_presets.zig',import.meta.url),'utf8');
const design=JSON.parse(readFileSync(new URL('../docs/UI_V3/theme-presets.json',import.meta.url),'utf8')).themes;
const css=readFileSync(new URL('../docs/UI_V3/theme-tokens.css',import.meta.url),'utf8');
const quick=JSON.parse(readFileSync(new URL('../docs/UI_V3/workspace/quick-connect/palettes.js',import.meta.url),'utf8').replace(/^const palettes\s*=\s*/,'').replace(/;\s*$/,''));
const roles={app:'bg-app',surface_1:'surface-1-base',surface_2:'surface-2-base',well:'well-base',well_border:'well-bd',terminal:'bg-term-base',overlay:'overlay-base',hover:'hover-base',tab_on:'tab-on-base',fg_1:'fg-1',fg_2:'fg-2',fg_3:'fg-3',accent:'accent-base',accent_ink:'accent-ink',action_accent:'action-accent',action_accent_2:'action-accent-2',action_danger:'action-danger',ok:'ok',ok_ink:'ok-ink',warn:'warn',warn_ink:'warn-ink',danger:'danger-base',danger_ink:'danger-ink',selection:'sel-bg'};
const palettes=[...native.matchAll(/if \(std\.mem\.eql\(u8, id, "([^"]+)"\)\) return \.\{(.*?)\n    \};/gs)].map(m=>[m[1],Object.fromEntries([...m[2].matchAll(/\.(\w+) = 0x([\da-f]+)/g)].map(v=>[v[1],v[2]]))]);
assert.equal(palettes.length,17);assert.equal(Object.keys(design).length,17);assert.equal(Object.keys(quick).length,17);
let checked=0;
for(const [id,colors] of palettes){
 assert.equal(Object.keys(colors).length,26,id+' role completeness');
 const rule=[...css.matchAll(new RegExp('body\\[data-theme="'+id+'"\\]\\{([^}]+)\\}','g'))].at(-1);assert(rule,id+' CSS');
 const vars=Object.fromEntries([...rule[1].matchAll(/(--[\w-]+):([^;]+);/g)].map(m=>[m[1],m[2]]));
 for(const [role,key] of Object.entries(roles)){
  const full='#'+colors[role],value=full.endsWith('ff')?full.slice(0,-2):full;
  assert.equal(design[id]['--'+key],value,id+' JSON '+role);
  assert.equal(vars['--'+key],value,id+' CSS '+role);
  assert.equal(quick[id][role],full.slice(0,7),id+' quick-connect '+role);checked++;
 }
}
console.log(`PASS: 17 themes, 26 native roles, ${checked} shared design/native color pairs`);
