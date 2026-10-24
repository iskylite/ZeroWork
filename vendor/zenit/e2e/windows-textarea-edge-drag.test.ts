import { clickTestId, imeCommit, inputState, key, mouseDown, mouseMove, mouseUp, query, screenshot, sleep, waitForServerReady } from './client';
import { assert, getSessionDir, run, test } from './runner';

test('Textarea stationary edge drag keeps scrolling and stops on release', async () => {
  await waitForServerReady(15000);
  await clickTestId('input.notes');
  const value=Array.from({length:100},(_,i)=>`row ${i} 中文 abcdefghijklmnop`).join('\n');
  await key('a',{ctrl:true}); await imeCommit(value); await key('home',{ctrl:true});
  const findEditor=(n:any):any=>n.tag==='input'?n:(n.children??[]).map(findEditor).find(Boolean);
  const editor=findEditor((await query('input.notes'))[0]);
  assert(editor,'missing textarea surface');
  const r=editor.rect, x=r.x+60;
  for(const reverse of [false,true]) {
    await key(reverse?'end':'home',{ctrl:true});
    const endpoint=await inputState('input.notes');
    assert(endpoint.cursor_pos===(reverse?new TextEncoder().encode(value).length:0),'Ctrl+Home/End did not reach document boundary');
    await sleep(500);
    const start=reverse?r.y+r.h-20:r.y+20, outside=reverse?r.y-30:r.y+r.h+30;
    await mouseDown(x,start);
    try {
      await mouseMove(x,outside);
      const before=await inputState('input.notes');
      await sleep(900); // Deliberately no pointer events while held outside.
      const after=await inputState('input.notes');
      console.log(JSON.stringify({reverse,anchor:after.anchor,cursor:[before.cursor_pos,after.cursor_pos],scroll:[before.scroll_y,after.scroll_y]}));
      assert(after.anchor===before.anchor && after.anchor>=0,'autoscroll changed selection anchor');
      assert(reverse?after.cursor_pos<before.cursor_pos:after.cursor_pos>before.cursor_pos,
        `stationary drag stopped selecting: ${JSON.stringify({reverse,before,after})}`);

      assert(reverse?after.scroll_y!<before.scroll_y!:after.scroll_y!>before.scroll_y!,'vertical viewport did not follow');
      assert(Math.abs(after.scroll_y!-before.scroll_y!)<800,'caret visibility snapped whole rows and accelerated autoscroll');
      assert((await screenshot(`${getSessionDir()}/textarea-edge-drag-${reverse?'up':'down'}.png`)).ok,'capture failed');
      await mouseMove(x,r.y+r.h/2);
      const inside=await inputState('input.notes'); await sleep(250);
      const heldInside=await inputState('input.notes');
      assert(inside.cursor_pos===heldInside.cursor_pos && inside.scroll_y===heldInside.scroll_y,'autoscroll continued inside the textarea');
    } finally { await mouseUp(x,outside); }
    const released=await inputState('input.notes'); await sleep(250);
    const stopped=await inputState('input.notes');
    assert(released.cursor_pos===stopped.cursor_pos && released.scroll_y===stopped.scroll_y,'drag continued after release');
  }
});
run();
