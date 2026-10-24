import { clickTestId, imeCommit, inputState, key, screenshot, waitForServerReady, runsOnWindowsWorker } from './client';
import { assert, getSessionDir, run, test } from './runner';

test('Windows input viewport repeated End restoration diagnostic', async () => {
  assert(runsOnWindowsWorker(), 'run through tools/windows_vm_http.py e2e');
  await waitForServerReady(15000);
  await clickTestId('input.name');
  const failures: object[] = [];
  for (let cycle = 0; cycle < 20; cycle++) {
    await key('a', {ctrl:true});
    await key('backspace');
    await imeCommit('abcdefghijklmnopqrstuvwxyz'.repeat(4));
    const initial = await inputState('input.name');
    assert((await screenshot(`${getSessionDir()}/end-${cycle}.png`)).ok, 'end capture');
    const painted = await inputState('input.name');
    await key('a', {ctrl:true});
    await key('home');
    assert((await screenshot(`${getSessionDir()}/home-${cycle}.png`)).ok, 'home capture');
    await key('end');
    const restored = await inputState('input.name');
    const row = {cycle, initial, painted, restored};
    console.log(JSON.stringify(row));
    if (restored.cursor_pos !== 104 || Math.abs(restored.scroll_x - initial.scroll_x) >= 1) failures.push(row);
  }
  assert(failures.length === 0, JSON.stringify(failures));
});
run();
