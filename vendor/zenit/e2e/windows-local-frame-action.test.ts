import { clickTestId, key, query, readFrameObservation, request, tree, sleep, startFrameObservation, waitForServerReady } from './client';
import { assert, run, test } from './runner';

test('Windows frame observation starts with a local click and cancels failed actions', async () => {
  await waitForServerReady(15000);
  assert((await clickTestId('nav.sheet')).ok, 'Sheet navigation failed');
  await sleep(400);
  for (const badId of ['', 'missing.local.click.target']) {
    let failed = false;
    try { const result = await request('POST', '/frames/start', { test_id: 'story.sheet.panel', click_test_id: badId }); failed = typeof result.error === 'string'; }
    catch { failed = true; }
    assert(failed, 'invalid local action accepted');
    assert((await readFrameObservation()).frames.length === 0, 'failed action left an observer armed');
    assert((await query('story.sheet.panel'))[0]?.visible === false, 'failed action opened Sheet');
  }
  let rejectedType = false;
  try { const result = await request('POST', '/frames/start', { test_id: 'story.sheet.panel', click_test_id: 42 }); rejectedType = typeof result.error === 'string'; }
  catch { rejectedType = true; }
  assert(rejectedType, 'non-string click target silently accepted');
  const foreground = await request('POST', '/windows/native-input', { action: 'status' });
  for (let cycle = 0; cycle < 3; cycle++) {
    const start = Date.now();
    assert((await startFrameObservation('story.sheet.panel', undefined, 'story.sheet.open')).supported,
      'local action observation unavailable');
    console.log(`  cycle=${cycle} action RPC roundtrip=${Date.now() - start}ms`);
    await sleep(700);
    const observed = await readFrameObservation();
    console.log(`  cycle=${cycle} frames=${JSON.stringify(observed)}`);
    assert(!observed.overflow && observed.missing === 0 && observed.frames.length >= 3, 'incomplete local frame observation');
    const viewport = (await tree()).rect;
    const panel = (await query('story.sheet.panel'))[0].rect;
    const left = viewport.w-panel.w;
    assert(observed.frames.some(f => f.x > left+8 && f.x < viewport.w-2), 'no submitted intermediate geometry');
    assert(Math.abs(observed.frames.at(-1)!.x - left) < 2, 'Sheet did not settle at its edge');
    const after = await request('POST', '/windows/native-input', { action: 'status' });
    assert(!after.foreground_owned && after.foreground_hwnd === foreground.foreground_hwnd, 'local action changed system foreground');
    await key('escape');
    await sleep(600);
    assert((await query('story.sheet.panel'))[0]?.visible === false, 'Sheet did not close');
  }
});
run();
