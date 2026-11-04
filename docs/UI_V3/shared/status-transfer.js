/* The workspace and the standalone review mount this same bottom-bar markup. */
(function(){
 const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const svg=(path,cls='')=>`<svg class="${cls}" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${path}"/></svg>`;
 function render(value={}){
  const phase=value.phase||'idle',idle=phase==='idle';
  const name=String(value.name||'传输 · 空闲').split(/[\\/]/).at(-1);
  const suffixAt=name.lastIndexOf('.'),suffix=suffixAt>0?name.slice(Math.max(suffixAt,name.length-12)):'';
  const main=suffix?name.slice(0,-suffix.length):name;
  const direction=idle?svg('M5 13V3m-3 3 3-3 3 3m3-3v10m-3-3 3 3 3-3'):value.upload?svg('M3 13 13 3M5 3h8v8'):svg('M13 3 3 13M3 5v8h8');
  const pct=value.percent||'',rate=phase==='running'?(value.rate||'— MiB/s'):'',rawCount=String(value.count||'1'),count=rawCount.match(/^\d+/)?.[0]||'1',capped=Number(count)>99||rawCount.endsWith('+');
  const label=idle?'打开传输列表':[name,pct,rate,count+' 个任务'].filter(Boolean).join(' · ');
  return `<button class="transfer-summary" data-act="transfer-popover" data-phase="${escape(phase)}" aria-label="${escape(label)}" style="--transfer-progress:${Math.min(100,Math.max(0,value.progress||0))}%">${direction}<span class="transfer-name"><span class="transfer-name-main">${escape(main)}</span><span class="transfer-name-suffix">${escape(suffix)}</span></span>${idle?'':`<span class="transfer-percent">${escape(pct)}</span><span class="transfer-rate">${escape(rate)}</span><span class="transfer-count" data-wide="${capped}" title="${escape(count)} 个任务">${capped?'99+':escape(count)}</span><span class="transfer-track"><span class="transfer-fill"></span></span>`}</button>`;
 }
 window.ZeroWorkTransferStatus={render};
})();
