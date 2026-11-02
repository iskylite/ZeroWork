'use strict';
// Layout-only prototype: member content keeps the existing terminal/file renderers.
const GroupPreview=(()=>{
 const key=g=>'zerowork.v3.group-layout.'+g.name;
 const leaves=n=>typeof n==='number'?[n]:n?[...leaves(n.first),...leaves(n.second)]:[];
 const split=(axis,first,second,ratio=.5)=>({axis,ratio,first,second});
 const prune=(n,ids)=>typeof n==='number'?(ids.includes(n)?n:null):n?(()=>{const a=prune(n.first,ids),b=prune(n.second,ids);return a===null?b:b===null?a:{...n,first:a,second:b};})():null;
 const map=(n,fn)=>typeof n==='number'?fn(n):{...n,first:map(n.first,fn),second:map(n.second,fn)};
 const valid=(n,ids,depth=0)=>depth<128&&(typeof n==='number'?ids.includes(n):n&&['row','column'].includes(n.axis)&&Number.isFinite(n.ratio)&&n.ratio>0&&n.ratio<1&&valid(n.first,ids,depth+1)&&valid(n.second,ids,depth+1));
 function save(g){try{const tree=map(g.tree,id=>g.members.indexOf(id)+1);localStorage.setItem(key(g),JSON.stringify({version:2,count:g.members.length,tree}));}catch{}}
 function restore(g){try{const data=JSON.parse(localStorage.getItem(key(g)));const ids=g.members.map((_,i)=>i+1),found=leaves(data?.tree);if(data?.version===2&&data.count===ids.length&&valid(data.tree,ids)&&found.length===ids.length&&new Set(found).size===ids.length)g.tree=map(data.tree,id=>g.members[id-1]);}catch{}}
 function sync(g){const ids=g.members.filter(id=>sessions.some(s=>s.id===id));g.tree=prune(g.tree,ids);for(const id of ids)if(!leaves(g.tree).includes(id))g.tree=g.tree===null?id:split(g.direction||'row',g.tree,id);}
 function scene(){let g=groups.find(g=>g.name==='production');if(!g){g={id:101,name:'production',members:[3,1,2],tree:split('column',3,split('row',1,2,.6),.55)};groups.push(g);restore(g);}active=1;groupMode=true;}
 function header(s){return `<div class="pane-head" draggable="true"><span aria-hidden="true">⠿</span><span class="pane-title">SFTP · ${esc(s.name.replace(/ · SFTP$/,''))} · #${s.id}</span><span class="dot ${s.state==='online'?'':'failed'}"></span><span>${s.state==='online'?'在线':'已断开'}</span>${ib('pin-pane','pin','置顶成员',`data-session="${s.id}"`)}${ib('pane-menu','more','成员菜单',`data-session="${s.id}"`)}</div>`;}
 function member(id,g){const s=sessions.find(s=>s.id===id);if(!s)return '';if(s.type==='sftp')return `<section class="terminal-pane group-file-pane ${active===id?'focused':''}" data-pane="${id}" aria-label="${esc(s.name)} SFTP 会话">${header(s)}<div class="sftp-workspace"><div class="sftp-dual">${fileColumn('local',s)}${fileColumn('remote',s)}</div></div></section>`;return terminalPane(s,g);}
 function render(g){sync(g);const walk=(n,path='')=>{if(typeof n==='number')return member(n,g);return `<div class="group-split" data-split-path="${path}" data-axis="${n.axis}" style="flex-direction:${n.axis}"><div class="group-branch" style="flex:${n.ratio} 1 0">${walk(n.first,path+'0')}</div><div class="group-divider" role="separator" tabindex="0" aria-label="${n.axis==='row'?'调整左右卡片宽度':'调整上下卡片高度'}" aria-orientation="${n.axis==='row'?'vertical':'horizontal'}" aria-valuemin="1" aria-valuemax="99" aria-valuenow="${Math.round(n.ratio*100)}" data-split="${path}"></div><div class="group-branch" style="flex:${1-n.ratio} 1 0">${walk(n.second,path+'1')}</div></div>`;};return g.tree===null?'':walk(g.tree);}
 function arrange(g,axis){g.direction=axis;g.tree=g.members.reduce((a,id)=>a===null?id:split(axis,a,id),null);save(g);}
 function edge(e,pane){const r=pane.getBoundingClientRect(),x=(e.clientX-r.left)/r.width,y=(e.clientY-r.top)/r.height;return [['left',x],['right',1-x],['top',y],['bottom',1-y]].sort((a,b)=>a[1]-b[1])[0][0];}
 function dock(g,source,target,edge){sync(g);const tree=prune(g.tree,g.members.filter(id=>id!==source));g.tree=map(tree,id=>id===target?split(['left','right'].includes(edge)?'row':'column',...(['left','top'].includes(edge)?[source,target]:[target,source])):id);save(g);}
 function pin(g,id,on){sync(g);if(on){const first=leaves(g.tree)[0];g.tree=map(g.tree,value=>value===id?first:value===first?id:value);}save(g);}
 function node(g,path){return [...path].reduce((n,c)=>c==='0'?n.first:n.second,g.tree);}
 function minimum(n,axis){if(typeof n==='number')return axis==='row'?160:100;const a=minimum(n.first,axis),b=minimum(n.second,axis);return n.axis===axis?a+b+4:Math.max(a,b);}
 let resizing=null;
 function apply(r,ratio){const total=(r.n.axis==='row'?r.rect.width:r.rect.height)-4,minA=minimum(r.n.first,r.n.axis),minB=minimum(r.n.second,r.n.axis),scale=Math.min(1,total/(minA+minB));r.n.ratio=Math.max(minA*scale/total,Math.min(1-minB*scale/total,ratio));r.host.children[0].style.flex=`${r.n.ratio} 1 0`;r.host.children[2].style.flex=`${1-r.n.ratio} 1 0`;r.el.setAttribute('aria-valuenow',Math.round(r.n.ratio*100));}
 function finish(cancel){if(!resizing)return;const r=resizing;resizing=null;if(cancel)apply(r,r.initial);else save(r.g);r.el.releasePointerCapture?.(r.pointer);}
 document.addEventListener('pointerdown',e=>{const el=e.target.closest('.group-divider');if(!el||e.button!==0)return;e.preventDefault();const g=currentGroup(),host=el.parentElement,n=node(g,el.dataset.split);resizing={el,host,g,n,rect:host.getBoundingClientRect(),initial:n.ratio,start:n.axis==='row'?e.clientX:e.clientY,pointer:e.pointerId};el.setPointerCapture(e.pointerId);});
 document.addEventListener('pointermove',e=>{if(resizing){const r=resizing;apply(r,r.initial+((r.n.axis==='row'?e.clientX:e.clientY)-r.start)/((r.n.axis==='row'?r.rect.width:r.rect.height)-4));}});
 document.addEventListener('pointerup',()=>finish(false));
 document.addEventListener('pointercancel',()=>finish(true));
 document.addEventListener('keydown',e=>{if(e.key==='Escape'&&resizing){finish(true);return;}const el=e.target.closest('.group-divider');if(!el||!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key))return;const g=currentGroup(),n=node(g,el.dataset.split);if(!(n.axis==='row'?['ArrowLeft','ArrowRight']:['ArrowUp','ArrowDown']).includes(e.key))return;e.preventDefault();apply({el,host:el.parentElement,g,n,rect:el.parentElement.getBoundingClientRect()},n.ratio+(['ArrowLeft','ArrowUp'].includes(e.key)?-.02:.02));save(g);});
 // Route file controls to their owning member before existing delegated handlers run.
 const focusFile=e=>{const pane=e.target.closest('.group-file-pane');if(!pane)return;active=+pane.dataset.pane;document.querySelectorAll('[data-pane]').forEach(n=>n.classList.toggle('focused',+n.dataset.pane===active));};
 for(const event of ['click','contextmenu','dblclick','input'])document.addEventListener(event,focusFile,true);
 const clearDrop=()=>document.querySelectorAll('[data-group-drop]').forEach(n=>delete n.dataset.groupDrop);
 document.addEventListener('dragover',e=>{clearDrop();const pane=e.target.closest('[data-pane]');if(dragPane&&pane&&+pane.dataset.pane!==dragPane)pane.dataset.groupDrop=edge(e,pane);});
 for(const event of ['drop','dragend'])document.addEventListener(event,clearDrop);
 return {scene,render,arrange,dock,edge,pin};
})();
