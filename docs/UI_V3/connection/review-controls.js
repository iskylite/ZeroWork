(() => {
'use strict';
const app=document.querySelector('#app');if(!app)return;
const host=document.createElement('section');host.className='review-scenarios';host.setAttribute('aria-label','原型状态控制');app.after(host);
const moved=new Map();
const testIds=new Set(['first-frame','save-fail','simulate-fail','changed-key','trust','simulate-failure','simulate-success','test-error','ai-observe-fail']);
const testLabels=new Set(['模型不支持图像','拒绝申请','批准申请','读回一致','读回超时','继续验证','演示批准','演示拒绝']);
function scan(){
 for(const [node,parent] of moved){if(!parent.isConnected){node.remove();moved.delete(node)}}
 for(const node of app.querySelectorAll('button,select,input[id^="simulate"]')){
  if(node.closest('.review'))continue;
  const text=node.textContent.trim();
  const isSelect=node.tagName==='SELECT'&&['attempt-stage','challenge-kind'].includes(node.id);
  const isTestInput=node.tagName==='INPUT'&&node.id.startsWith('simulate');
  const shouldMove=isTestInput||isSelect||testIds.has(node.id)||testLabels.has(text)||(/^(演示|模拟)/.test(text)&&!/^模拟画面/.test(text));
  if(!shouldMove)continue;
  if(isSelect&&node.closest('label')?.querySelector('input')){const original=node.parentNode,wrap=document.createElement('label');wrap.textContent='认证挑战';if(node.previousElementSibling?.tagName==='SPAN')node.previousElementSibling.remove();wrap.append(node);moved.set(wrap,original);host.append(wrap);continue}
  const item=(isSelect||isTestInput)?node.closest('label')||node:node;
  if(moved.has(item))continue;
  moved.set(item,item.parentNode);host.append(item);
 }
 if(host.children.length&&!host.querySelector('strong')){const title=document.createElement('strong');title.textContent='评审状态';host.prepend(title)}
 if(host.children.length===1&&host.firstElementChild.tagName==='STRONG')host.replaceChildren();host.hidden=![...host.children].some(n=>n.tagName!=='STRONG'&&!n.hidden);
}
new MutationObserver(scan).observe(app,{childList:true,subtree:true});scan();
})();
