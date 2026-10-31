// Ordered transcript reference. Review controls stay outside the product frame.
(() => {
 const query = new URLSearchParams(location.search);
 if (!query.has('timeline')) return;
 const main = document.querySelector('main'), user = main.querySelector('.user'), footer = main.querySelector('#turn');
 const events = [
  {kind:'thinking',id:'t1',text:'先确认当前会话。'},
  {kind:'thinking',id:'t1',text:'再读取会话身份。'},
  {kind:'message',id:'m1',text:'我先读取当前会话的信息。'},
  {kind:'tool',id:'c1',text:'读取当前上下文',detail:'当前会话 · Local Terminal',elapsed:'14ms'},
  {kind:'thinking',id:'t2',text:'已取得身份，接着检查连接状态。'},
  {kind:'message',id:'m2',text:'当前是本地终端，继续检查会话状态。'},
  {kind:'tool',id:'c2',text:'查看会话',detail:'Local Terminal · 已就绪',elapsed:'12ms'},
  {kind:'thinking',id:'t3',text:'会话已就绪，可以汇总结果。'},
  {kind:'message',id:'m3',text:'检查完成。'},
  {kind:'message',id:'m3',text:'当前会话已就绪。'},
 ];
 main.replaceChildren(user,footer);
 let index=0,open=null;
 const append = event => {
  if(open?.dataset.segmentId===event.id){
   if(event.kind==='message')open.textContent+=event.text;
   else{open.querySelector('.projection').textContent+=event.text;open.querySelector('.details').textContent+=event.text;}
   return;
  }
  const node=document.createElement(event.kind==='message'?'article':'details');
  node.dataset.segmentId=event.id;
  if(event.kind==='message'){node.className='answer';node.textContent=event.text;}
  else{node.innerHTML='<summary><span class="slot"><span class="status">✓</span><span class="chevron">›</span></span><strong></strong><span class="projection"></span><span class="elapsed"></span></summary><div class="details"></div>';node.querySelector('strong').textContent=event.kind==='thinking'?'思考':event.text;node.querySelector('.projection').textContent=event.kind==='thinking'?event.text:event.detail;node.querySelector('.details').textContent=event.kind==='thinking'?event.text:event.detail;node.querySelector('.elapsed').textContent=event.elapsed||'0.2s';}
  footer.before(node);open=node;
 };
 const advance=()=>{if(index<events.length)append(events[index++]);footer.querySelector('.label').textContent=index===events.length?'回合结束':'正在输出';main.scrollTop=main.scrollHeight;};
 if(query.has('stream')){
  advance();const control=document.createElement('button');control.textContent='下一步输出';control.onclick=advance;document.querySelector('nav').append(' · ',control);
 }else while(index<events.length)advance();
})();
