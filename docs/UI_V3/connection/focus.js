(() => {
'use strict';
const app=document.querySelector('#app');if(!app)return;
let layer=null,returnFocus=null;
const focusables=root=>[...root.querySelectorAll('button,input,select,textarea,a[href],summary,[tabindex="0"]')].filter(n=>!n.disabled&&n.getClientRects().length);
function top(){return app.querySelector('#overlay [role="dialog"]')||app.querySelector('#popover [role="dialog"]')}
function sync(){const next=top();if(next===layer)return;if(!next){if(returnFocus?.isConnected)returnFocus.focus();layer=null;returnFocus=null;return}if(!layer&&!document.activeElement?.closest('#overlay,#popover'))returnFocus=document.activeElement;const oldId=document.activeElement?.id;layer=next;if(next.contains(document.activeElement))return;const restore=oldId&&next.querySelector('#'+CSS.escape(oldId));(restore||focusables(next)[0])?.focus()}
new MutationObserver(sync).observe(app,{childList:true,subtree:true});sync();
document.addEventListener('keydown',e=>{const active=top();if(!active||app.querySelector('.v3-select-popover'))return;if(e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();active.querySelector('[data-close],[data-close-modal],#close-pop')?.click();return}if(e.key!=='Tab')return;const nodes=focusables(active);if(!nodes.length)return;const i=nodes.indexOf(document.activeElement);if(e.shiftKey&&i<=0){e.preventDefault();nodes.at(-1).focus()}else if(!e.shiftKey&&(i<0||i===nodes.length-1)){e.preventDefault();nodes[0].focus()}},true);
})();
