/** Reusable assertion for a real visible notification and already-open detail
 * card. Caller owns its private app/RPC/fixture and captures each required
 * global/session, standard/minimum and sidebar state before closing the card.
 * No notification records or UI results are injected.
 */
import assert from 'node:assert/strict';
import {mkdir, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {query, clickAt, screenshot, waitFor, sleep, mouseMove} from '../zig-out/share/zenit/harness/client.ts';
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const separated=(a:any,b:any)=>a.x+a.w<=b.x-8||a.x>=b.x+b.w+8||a.y+a.h<=b.y-8||a.y>=b.y+b.h+8;
export async function verifyNotificationAvoidance(out:string,name:string,options:{close?:boolean,width:number,height:number,cardId?:string}) {
 await mkdir(out,{recursive:true});
 const cardId=options.cardId??'transfer.manager';
 const sample=await waitFor(async()=>{
  const cards=(await query(cardId)).filter(shown);
  const toasts=(await query('notifications.toast.0')).filter(shown);
  return cards.length===1&&toasts.length===1?{card:cards[0],toast:toasts[0]}:null;
 },10000);
 // Hold the existing fact through its supported hover pause while inspecting.
 await mouseMove(sample.toast.rect.x+20,sample.toast.rect.y+20);await sleep(180);
 const card=(await query(cardId)).find(shown)!;
 const toast=(await query('notifications.toast.0')).find(shown)!;
 const presenter=(await query('notifications.presenter')).find(shown)!;
 const close=flat(card).find(n=>n.test_id==='transfer.window.close'&&shown(n));
 assert(close,'actual manager close control');
 const candidates=[{x:options.width-presenter.rect.w-12,y:58},{x:12,y:58},{x:options.width-presenter.rect.w-12,y:options.height-presenter.rect.h-44},{x:12,y:options.height-presenter.rect.h-44}];
 const free=candidates.find(p=>separated({...p,w:presenter.rect.w,h:presenter.rect.h},card.rect));
 if(free)assert(separated(presenter.rect,card.rect),'toast stack clears detail card by 8px');
 const expected=free??candidates[1];
 assert(Math.abs(presenter.rect.x-expected.x)<1&&Math.abs(presenter.rect.y-expected.y)<1,'first V3 free corner uses measured stack size');
 assert(presenter.rect.x>=8&&presenter.rect.x+presenter.rect.w<=options.width-8,'toast within app horizontal bounds');
 assert(presenter.rect.y>=8&&presenter.rect.y+presenter.rect.h<=options.height-8,'toast within app vertical bounds');
 const evidence:any={name,fallback:!free,card:card.rect,toast:toast.rect,presenter:presenter.rect,close:close.rect,width:options.width,height:options.height,clearance:8,synthetic_harness_input:true};
 assert((await screenshot(join(out,name+'.png'))).ok);
 if(options.close){
  const x=close.rect.x+close.rect.w/2,y=close.rect.y+close.rect.h/2;
  evidence.click={x,y,result:await clickAt(x,y)};assert(evidence.click.result.ok);
  await waitFor(async()=>!(await query(cardId)).some(shown)||null,8000);
  evidence.manager_closed=true;
 }
 await writeFile(join(out,name+'.json'),JSON.stringify(evidence,null,2));
 return evidence;
}
