import { clickTestId, imeCommit, inputState, key, mouseMove, query, request, resizeWindow, screenshot, stats, tree, waitFor, waitForServerReady } from './client';
import { decodePng } from './png';
import { assert, getSessionDir, run, test } from './runner';

test('Windows renderer resize preserves pixels, input state and background focus', async () => {
  await waitForServerReady(15000);
  const backend = (await stats()).renderer_backend;
  assert(backend === 'd3d12' || backend === 'd3d11' || backend === 'legacy', 'requires a Windows renderer');
  const foreground = await request('POST', '/windows/native-input', {action:'status'});
  await clickTestId('input.name');
  await key('a', {ctrl:true});
  const value = 'Resize 中文 abcdefghijklmnopqrstuvwxyz';
  await imeCommit(value);
  await mouseMove((await tree()).rect.w-10, (await tree()).rect.h-10);
  let baseline: ReturnType<typeof decodePng> | undefined;
  for (const [index, [width, height]] of [[600,540],[800,650],[560,520],[720,600],[600,540]].entries()) {
    // stats scale has three decimal places; integer Windows DPI is recoverable.
    const dpi = Math.round((await stats()).window_scale!*96);
    const scale = Math.fround(dpi/96);
    const expectedWidth = Math.floor((width*dpi+95)/96);
    const expectedHeight = Math.floor((height*dpi+95)/96);
    // The harness serializes f32 geometry to three decimal places.
    const logicalWidth = Number(Math.fround(expectedWidth/scale).toFixed(3));
    const logicalHeight = Number(Math.fround(expectedHeight/scale).toFixed(3));
    assert((await resizeWindow(width, height)).ok, 'resize request failed');
    await waitFor(async () => {
      const r = (await tree()).rect;
      return r.w === logicalWidth && r.h === logicalHeight ? r : null;
    }, 10000, 50);
    const path = `${getSessionDir()}/shared-resize-${index}.png`;
    assert((await screenshot(path)).ok, 'resized surface capture failed');
    const png = decodePng(path);
    assert(png.width === expectedWidth && png.height === expectedHeight,
      `stale drawable size ${png.width}x${png.height}, expected ${expectedWidth}x${expectedHeight}`);
    assert((await inputState('input.name')).buffer === value, 'resize lost text');
    const rect = (await query('input.name'))[0].rect;
    // Compare against the input's own top padding. Counting bright pixels
    // alone falsely accepts an empty input when the active theme is light.
    const bgOffset = (Math.floor((rect.y + 3) * scale) * png.width +
      Math.floor((rect.x + rect.w / 2) * scale)) * png.channels;
    const background = [0, 1, 2].map(c => png.pixels[bgOffset + c]);
    let ink = 0;
    for (let y=Math.ceil((rect.y+4)*scale); y<Math.floor((rect.y+rect.h-4)*scale); y++) {
      for (let x=Math.ceil((rect.x+4)*scale); x<Math.floor((rect.x+rect.w-4)*scale); x++) {
        const p=(y*png.width+x)*png.channels;
        if ([0, 1, 2].some(c => Math.abs(png.pixels[p + c] - background[c]) > 60)) ink++;
      }
    }
    assert(ink > 100, 'resize lost visible input text');
    const focus = await request('POST', '/windows/native-input', {action:'status'});
    assert(!focus.foreground_owned && focus.foreground_hwnd===foreground.foreground_hwnd,
      'resize changed system foreground');
    if (index === 0) baseline = png;
    if (index === 4) {
      let changed=0;
      for(let p=0;p<png.pixels.length;p+=png.channels) {
        if([0,1,2].some(c=>Math.abs(png.pixels[p+c]-baseline!.pixels[p+c])>3)) changed++;
      }
      assert(changed < 500, `restored window retained ${changed} changed pixels`);
    }
    // Exercise hit testing and caret movement on every newly sized surface.
    await clickTestId('input.name');
    await key('home');
    assert((await inputState('input.name')).cursor_pos===0, 'Home failed after resize');
    await key('end');
    assert((await inputState('input.name')).cursor_pos===new TextEncoder().encode(value).length,
      'End failed after resize');
    await mouseMove((await tree()).rect.w-10, (await tree()).rect.h-10);
  }
});
run();
