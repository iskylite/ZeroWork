import { clickTestId, imeCommit, inputState, key, mouseDown, mouseMove, mouseUp, query, screenshot, sleep, waitForServerReady } from './client';
import { assert, getSessionDir, run, test } from './runner';

test('Input stationary edge drag keeps scrolling and stops on release', async () => {
  await waitForServerReady(15000);
  await clickTestId('input.name');
  const value='abcdefghijklmnopqrstuvwxyz'.repeat(20);
  await key('a',{ctrl:true}); await imeCommit(value); await key('home');
  const r=(await query('input.name'))[0].rect, y=r.y+r.h/2;
  for(const reverse of [false,true]) {
    await key(reverse?'end':'home');
    await sleep(500);
    const start=reverse?r.x+r.w-40:r.x+40, outside=reverse?r.x-30:r.x+r.w+30;
    await mouseDown(start,y);
    try {
      await mouseMove(outside,y);
      const before=await inputState('input.name');
      await sleep(900); // Deliberately no pointer events while held outside.
      const after=await inputState('input.name');
      console.log(JSON.stringify({reverse,anchor:after.anchor,cursor:[before.cursor_pos,after.cursor_pos],scroll:[before.scroll_x,after.scroll_x]}));
      assert(after.anchor===before.anchor && after.anchor>=0,'autoscroll changed selection anchor');
      assert(reverse?after.cursor_pos<before.cursor_pos:after.cursor_pos>before.cursor_pos,
        `stationary drag stopped selecting: ${JSON.stringify({reverse,before,after})}`);
      assert(reverse?after.scroll_x<before.scroll_x:after.scroll_x>before.scroll_x,'viewport did not follow stationary drag');
      assert((await screenshot(`${getSessionDir()}/edge-drag-${reverse?'left':'right'}.png`)).ok,'capture failed');
      await mouseMove(r.x+r.w/2,y);
      const inside=await inputState('input.name'); await sleep(250);
      const heldInside=await inputState('input.name');
      assert(inside.cursor_pos===heldInside.cursor_pos && inside.scroll_x===heldInside.scroll_x,'autoscroll continued inside the input');
    } finally { await mouseUp(outside,y); }
    const released=await inputState('input.name'); await sleep(250);
    const stopped=await inputState('input.name');
    assert(released.cursor_pos===stopped.cursor_pos && released.scroll_x===stopped.scroll_x,'drag continued after release');
  }
});
run();
