/** Material scheduling, clipping, cache invalidation and observer lifetime.
 * Uses a deterministic DOM/RAF adapter; real pixels remain native/browser E2E. */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const source=readFileSync(new URL('../docs/UI_V3/shared/global-background.js',import.meta.url),'utf8');
const frames=[],events={},observers=[],watched=new Set();
let removed=0;
const body={dataset:{},parentElement:null,style:{setProperty(){}}};
function element(name,x,y,width,height,parent=body,overflow='visible'){
 const paint=new Map();
 return {nodeType:1,name,parentElement:parent,isConnected:true,dataset:{},style:{getPropertyValue:k=>paint.get(k)||'',setProperty:(k,v)=>paint.set(k,v)},
  bounds:{x,y,width,height},getBoundingClientRect(){return{...this.bounds,right:this.bounds.x+this.bounds.width,bottom:this.bounds.y+this.bounds.height};},
  css:{overflow,overflowX:overflow,overflowY:overflow,borderRadius:'12px',backdropFilter:'blur(24px)',display:'block',visibility:'visible',getPropertyValue:()=> '#ffffff'},
  getAttribute:()=>JSON.stringify([...paint]),matches(selector){return selector.split(',').some(s=>s.trim()==='.'+name);},
  closest(selector){return this.matches(selector)?this:this.parentElement?.closest?.(selector)||null;},
  contains(node){for(let p=node;p;p=p.parentElement)if(p===this)return true;return false;},querySelector(){return null;}
 };
}
const root=element('root',0,0,1000,800);root.classList={add(){}};
const owner=element('assistant',100,100,240,300,root,'hidden');
const inline=element('ap-card',100,100,240,900,owner);
const popup=element('popover',280,120,280,160,root);
const hidden=element('ap-card',100,2000,200,100,owner);
let surfaces=[owner,inline,popup,hidden];
root.querySelectorAll=selector=>selector.startsWith('.popover,')?surfaces:[];
const document={body,documentElement:{dataset:{},style:{}},currentScript:null,
 querySelector:selector=>selector.startsWith('#desktop,')?root:null,
 querySelectorAll:selector=>selector.startsWith('.popover,')?surfaces:[],addEventListener:(key,fn)=>events[key]=fn};
const window={innerWidth:1000,innerHeight:800,addEventListener:(key,fn)=>events[key]=fn,postMessage(){}};
vm.runInNewContext(source,{document,window,parent:window,location:{href:'http://fixture.test/?embed&material-t=50',search:'?embed&material-t=50',origin:'http://fixture.test'},URL,URLSearchParams,
 localStorage:{getItem:()=>null},requestAnimationFrame:fn=>frames.push(fn),
 ResizeObserver:class{observe(n){watched.add(n);}unobserve(n){assert(watched.delete(n));removed++;}},
 MutationObserver:class{constructor(fn){this.fn=fn;observers.push(this);}observe(){}},
 getComputedStyle:node=>node.css||{colorScheme:'light',getPropertyValue:()=> '#ffffff'}});
const api=window.V3Materials;
function flush(){assert.equal(frames.length,1,'one material job per animation frame');frames.shift()();assert.equal(frames.length,0,'sync must not recursively queue itself');}
api.setOwner(popup,owner);for(let i=0;i<30;i++)api.sync();flush();
assert.equal(api.stats().sceneQueries,1);assert.equal(inline.dataset.materialCompensation,'false','physical clip cannot escape its owner');
assert.equal(popup.dataset.materialCompensation,'true','escaped portal still compensates');
assert.equal(hidden.dataset.materialLevel,undefined,'offscreen work is skipped');
const initial=api.stats();
for(let i=0;i<30;i++)events.scroll();flush();
assert.equal(api.stats().sceneQueries,initial.sceneQueries,'scroll does not query the scene again');
assert.equal(api.stats().maskBuilds,initial.maskBuilds,'unchanged masks are retained');
assert.equal(api.stats().canvasMessages,initial.canvasMessages,'unchanged embedded geometry is not sent again');
assert(api.stats().maskHits>initial.maskHits);
observers[0].fn(surfaces.filter(target=>target.dataset.materialLevel).map(target=>({type:'attributes',attributeName:'style',target})));
assert.equal(frames.length,0,'own style writes do not feed the mutation observer');
observers[0].fn([{type:'childList',target:inline,addedNodes:[{nodeType:3}],removedNodes:[]}]);flush();
assert.equal(api.stats().sceneQueries,initial.sceneQueries,'streamed text does not rebuild the material index');
popup.bounds.x+=30;events.scroll();flush();
assert(api.stats().maskBuilds>initial.maskBuilds,'relative geometry invalidates compensation');
surfaces=surfaces.filter(n=>n!==popup);popup.isConnected=false;
observers[0].fn([{type:'childList',target:root,addedNodes:[],removedNodes:[popup]}]);flush();
assert.equal(removed,1);assert(!watched.has(popup),'removed surfaces release ResizeObserver ownership');
console.log('PASS: single RAF, clipped inline cards, escaped portals, mask reuse/invalidation, text-only updates, self-mutation suppression and observer cleanup');
