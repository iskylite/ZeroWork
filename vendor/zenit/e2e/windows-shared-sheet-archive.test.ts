// Real-time driver: captures every submitted frame through the VM archive.
// No fixed frame clock and no intermediate-state claim from delayed HTTP queries.
import { clickAt, clickTestId, mouseMove, query, tree, waitFor, waitForServerReady, runsOnWindowsWorker } from './client';
import { assert, run, test } from './runner';

test('Windows shared Sheet drives three real-time open and close cycles', async () => {
  assert(runsOnWindowsWorker(), 'run through the Windows HTTP harness');
  await waitForServerReady(15000);
  assert((await clickTestId('nav.sheet')).ok, 'Sheet navigation failed');
  await waitFor(async () => (await query('story.sheet.panel'))[0] ?? null, 10000, 50);
  await mouseMove(10, 10);
  for (let cycle = 0; cycle < 3; cycle++) {
    assert((await clickTestId('story.sheet.open')).ok, 'Sheet open failed');
    await waitFor(async () => {
      const panel = (await query('story.sheet.panel'))[0];
      return panel && panel.effective_opacity >= .999 ? panel : null;
    }, 15000, 50);
    const viewport = (await tree()).rect;
    const panel = (await query('story.sheet.panel'))[0].rect;
    assert((await clickAt(panel.x/2, viewport.h/2)).ok, 'Sheet backdrop click failed');
    await mouseMove(10, 10);
    await waitFor(async () => {
      const panel = (await query('story.sheet.panel'))[0];
      return panel && panel.effective_opacity === 0 ? panel : null;
    }, 15000, 50);
  }
});
run();
