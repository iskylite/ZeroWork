// State driver for --audit-modal-frames target. Pixel acceptance is performed
// on every native submitted frame by the host archive auditor, not by sleeps.
import {clickTestId,query,waitFor,waitForServerReady,mouseMove,request,stats,tree} from './client';
import {test,run,assert} from './runner';
test('Windows shared Modal drives three cycles for submitted frame audit',async()=>{
 await waitForServerReady(15000);
 assert((await clickTestId('nav.modal')).ok,'modal navigation failed');
 await waitFor(async()=>(await query('story.modal.dialog'))[0]??null,10000,50);
 for(let cycle=0;cycle<3;cycle++){
  assert((await clickTestId('story.modal.open')).ok,'modal open failed');
  await waitFor(async()=>{
   const node=(await query('story.modal.dialog'))[0];
   return node && (node.effective_opacity??0)>=.999 ? node:null;
  },15000,50);
  assert((await clickTestId('modal.close')).ok,'modal close failed');
  await mouseMove((await tree()).rect.w-20,(await tree()).rect.h-20);
  await waitFor(async()=>{
   const node=(await query('story.modal.dialog'))[0];
   return node && (node.effective_opacity??1)===0 ? node:null;
  },15000,50);
 }
});
test('Windows frame archive finish is idempotent while later frames still render',async()=>{
 const before=(await stats()).frame_count;
 for(let i=0;i<2;i++){
  const result=await request('POST','/frames/capture/finish',{});
  assert(result.ok===true && result.finished===true,'capture finish was not acknowledged');
 }
 // Deliberately submit more UI frames after the capture interval. The host
 // archive auditor must still find exactly the three captured cycles above.
 assert((await clickTestId('story.modal.open')).ok,'post-finish modal open failed');
 await waitFor(async()=>{
  const node=(await query('story.modal.dialog'))[0];
  return node && (node.effective_opacity??0)>=.999 ? node:null;
 },15000,50);
 assert((await clickTestId('modal.close')).ok,'post-finish modal close failed');
 await waitFor(async()=>{
  const node=(await query('story.modal.dialog'))[0];
  return node && (node.effective_opacity??1)===0 ? node:null;
 },15000,50);
 assert((await stats()).frame_count>before,'app stopped rendering after capture finish');
});
run();
