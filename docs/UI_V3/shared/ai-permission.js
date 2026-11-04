'use strict';
/* Figma 236:479581 / 236:481193: permission body, mounted beneath the
   caller's anchored popover header. Compact explanations follow each option label. */
window.V3AIPermission=(()=>{
 const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const attrs=o=>Object.entries(o||{}).filter(([,v])=>v!=null).map(([k,v])=>`${esc(k)}="${esc(v)}"`).join(' ');
 const paths={check:'<path d="m5 12 4 4L19 6"/>',circle:'<circle cx="12" cy="12" r="9"/>',hand:'<path d="M8 12V5a1 1 0 0 1 2 0v5-7a1 1 0 0 1 2 0v7-6a1 1 0 0 1 2 0v6-4a1 1 0 0 1 2 0v8l-2 6H9l-5-7a1 1 0 0 1 2-1z"/>',shield:'<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6z"/><path d="m8 12 3 3 5-6"/>',info:'<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7h.01"/>'};
 const icon=n=>`<svg viewBox="0 0 24 24" aria-hidden="true">${paths[n]}</svg>`;
 const modes=Object.freeze([
  Object.freeze({id:'confirm',value:'确认后执行',label:'确认后执行',icon:'hand',hint:'部分读取自动，其余按策略确认',description:'部分读取自动进行，其余按策略决定是否确认。'}),
  Object.freeze({id:'auto',value:'完全控制',label:'自动执行',icon:'shield',hint:'授权内自动执行（含组内写入）',description:'授权范围内可自动执行，包括组内写操作。'})
 ]);
 const scope='仅作用于当前助手范围；禁止项始终不可执行。';
 function modeFor(value){return ['auto','自动执行','完全控制'].includes(value)?'auto':'confirm';}
 function render(p={}){const selected=modeFor(p.selected);return `<div class="v3-ai-permission" role="group" aria-label="执行权限">${modes.map(mode=>{const on=selected===mode.id;return `<button type="button" class="v3-ai-permission-option ${on?'selected':''}" aria-pressed="${on}" data-permission-mode="${mode.id}" data-tip="${esc(mode.description)}" title="${esc(mode.description)}" ${attrs(p.selectAttrs?.(mode))}><span class="v3-ai-permission-marker">${icon(on?'check':'circle')}</span><span class="v3-ai-permission-glyph">${icon(mode.icon)}</span><span>${mode.label}</span><span class="v3-ai-permission-hint">${mode.hint}</span></button>`;}).join('')}<div class="v3-ai-permission-scope"><span>当前助手范围 · 禁止项不可执行</span><button type="button" class="v3-ai-permission-help" aria-label="权限范围说明" data-tip="${scope}" title="${scope}">${icon('info')}</button></div></div>`;}
 return Object.freeze({render,modes,modeFor});
})();
