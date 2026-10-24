import { clickTestId, resizeWindow, screenshot, sleep, stats, tree, waitFor, waitForServerReady } from './client';
import { decodePng } from './png';
import { assert, getSessionDir, run, test } from './runner';

test('Windows screenshots read submitted pixels without producing frames and survive resize', async () => {
  await waitForServerReady(15000);
  assert((await clickTestId('nav.divider')).ok, 'static divider fixture unavailable');
  await sleep(1000);
  const original = (await tree()).rect;
  for (const [stage, size] of [[original.w, original.h], [900, 700], [Math.floor(original.w), Math.floor(original.h)]].entries()) {
    if (stage > 0) {
      assert((await resizeWindow(size[0], size[1])).ok, 'resize failed');
      await waitFor(async () => {
        const rect = (await tree()).rect;
        return Math.abs(rect.w-size[0])<1 && Math.abs(rect.h-size[1])<1 ? rect : null;
      }, 5000, 50);
      await sleep(500);
    }
    const actual = (await tree()).rect;
    const before = await stats();
    assert(Number.isInteger(before.frame_count) && before.frame_count > 0, 'presentation frame counter unavailable');
    let first: ReturnType<typeof decodePng> | undefined;
    for (let i = 0; i < 3; i++) {
      const path = `${getSessionDir()}/submitted-${stage}-${i}.png`;
      assert((await screenshot(path)).ok, 'submitted capture failed');
      const png = decodePng(path);
      assert(Math.abs(png.width - actual.w * before.window_scale!) <= 1 &&
        Math.abs(png.height - actual.h * before.window_scale!) <= 1, 'stale submitted dimensions');
      if (first) {
        assert(png.pixels.length === first.pixels.length && png.pixels.every((v, j) => v === first!.pixels[j]),
          'idle repeated capture changed pixels');
      } else {
        first = png;
        assert(png.pixels.some((v, j) => j % png.channels < 3 && v < 80), 'captured surface has no dark content');
        assert(png.pixels.some((v, j) => j % png.channels < 3 && v > 220), 'captured surface has no light content');
      }
    }
    const after = await stats();
    console.log(`  stage=${stage} frames=${before.frame_count}->${after.frame_count}`);
    assert(after.frame_count === before.frame_count, 'screenshots generated new presentation frames');
  }
});
run();
