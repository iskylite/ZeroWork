/** Responsive KVM toolbar in the production renderer, using local typed services.
 * node e2e/kvm_toolbar_native.ts /absolute/bmc-kvm-preview /tmp/evidence
 * No device, credentials, remote input or management writes.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, rm, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';

const binary = resolve(process.argv[2]), out = resolve(process.argv[3]);
await mkdir(out, {recursive: true});
const base = await mkdtemp('/private/tmp/zw-kvm-toolbar-');
const rpc = join(base, 'rpc'), data = join(base, 'data');
await Promise.all([mkdir(rpc), mkdir(data)]);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(binary, ['--theme=reference-light', '--state=controlled'], {
  env: {...process.env, ZEROWORK_DATA_DIR: data, ZENIT_E2E_BACKGROUND: '1',
    ZENIT_E2E_ISOLATE_POINTER: '1', ZENIT_E2E_ISOLATE_KEYBOARD: '1'},
  stdio: ['ignore', log.fd, log.fd],
});
const ended = new Promise<void>(done => app.once('close', () => done()));
const report: any = {status: 'running', binary, checks: [],
  limits: ['Production native renderer with synthetic local video and services; no live BMC or physical input.']};
const shown = (n: any) => n?.rect?.w > 0 && n.rect.h > 0 && n.hidden !== true &&
  n.visible !== false && (n.effective_opacity ?? 1) > .98;
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 10000);
const hidden = (id: string) => h.waitFor(async () => (await h.query(id)).every(n => n.hidden === true || n.visible === false || (n.effective_opacity ?? 1) < .01 || n.rect.w <= 0 || n.rect.h <= 0) || null, 10000);
async function click(id: string) { await visible(id); assert((await h.clickTestId(id)).ok, id); }
function inside(r: any, outer: any, label: string) {
  assert(r.x >= outer.x - .5 && r.y >= outer.y - .5 &&
    r.x + r.w <= outer.x + outer.w + .5 && r.y + r.h <= outer.y + outer.h + .5, label);
}
function contrast(a: number[], b: number[]) {
  const luminance = (rgb: number[]) => rgb.reduce((v, c, i) => {
    const s = c / 255, linear = s <= .04045 ? s / 12.92 : ((s + .055) / 1.055) ** 2.4;
    return v + linear * [.2126, .7152, .0722][i];
  }, 0);
  const [x, y] = [luminance(a), luminance(b)].sort((x, y) => x - y);
  return (y + .05) / (x + .05);
}
async function capture(name: string) {
  await h.mouseMove(4, 4); await h.sleep(180);
  assert((await h.screenshot(join(out, name + '.png'))).ok);
  const ids = ['bmc.toolbar', 'bmc.title', 'bmc.title.icon', 'bmc.disconnect', 'bmc.more', 'bmc.more.popover',
    'bmc.control', 'bmc.keys', 'bmc.display', 'bmc.power', 'bmc.boot', 'bmc.viewport'];
  const nodes = Object.fromEntries(await Promise.all(ids.map(async id => [id, await h.query(id)])));
  await writeFile(join(out, name + '.json'), JSON.stringify(nodes, null, 2));
}
async function width(value: number) {
  assert((await h.request('POST', '/app/bmc-fixture/content-width', {width: value})).ok);
  await h.waitFor(async () => Math.abs((await visible('bmc.toolbar')).rect.w - value) < .5 || null, 10000);
  if (value < 264) await visible('bmc.more'); else await hidden('bmc.more');
  await h.sleep(180);
}
try {
  await h.waitForServerReady(); await h.resizeWindow(1440, 900);
  assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
  for (const theme of ['reference-light', 'dark']) {
    assert((await h.request('POST', '/app/bmc-fixture/appearance', {theme, transparency: 0, blur: 24})).ok);
    for (const size of [1000, 520, 336, 280, 240]) {
      await width(size);
      const bar = (await visible('bmc.toolbar')).rect;
      assert.equal(bar.h, 44);
      const icon = (await visible('bmc.title.icon')).rect;
      const status = (await visible('bmc.disconnect')).rect;
      inside(icon, bar, 'host icon inside toolbar');
      inside(status, bar, 'connection action inside toolbar');
      assert(icon.x + icon.w <= status.x, 'host identity precedes status');
      if (size >= 280) {
        const title = (await visible('bmc.title')).rect;
        inside(title, bar, 'hostname inside toolbar');
        assert(icon.x + icon.w <= title.x && title.x + title.w <= status.x + .5, 'hostname is between icon and status');
      }
      for (const menu of ['control', 'keys', 'display']) {
        const button = await visible('bmc.' + menu);
        inside(button.rect, bar, menu + ' button inside toolbar');
        assert.equal(button.rect.w, size < 480 ? 32 : 64);
        await click('bmc.' + menu); await visible('bmc.' + menu + '.popover');
        await h.key('escape'); await hidden('bmc.' + menu + '.popover');
      }
      assert.equal((await visible('bmc.disconnect')).rect.w, size < 480 ? 32 : 82);
      if (size >= 264) {
        await hidden('bmc.more');
        const video = (await visible('bmc.viewport')).rect;
        for (const menu of ['power', 'boot']) {
          const tool = (await visible('bmc.' + menu)).rect;
          inside(tool, bar, menu + ' direct button');
          assert.equal(tool.w, size < 480 ? 32 : 64);
          await click('bmc.' + menu); await visible('bmc.' + menu + '.popover');
          assert.deepEqual((await visible('bmc.viewport')).rect, video);
          await h.key('escape'); await hidden('bmc.' + menu + '.popover');
          if (size === 336) {
            await h.mouseMove(tool.x + tool.w / 2, tool.y + tool.h / 2);
            await visible('bmc.' + menu + '.tooltip');
            await h.mouseMove(4, 4); await hidden('bmc.' + menu + '.tooltip');
          }
        }
        if (size === 336) {
          const state = (await visible('bmc.disconnect')).rect;
          await h.mouseMove(state.x + state.w / 2, state.y + state.h / 2);
          await visible('bmc.disconnect.tooltip');
          await h.mouseMove(4, 4); await hidden('bmc.disconnect.tooltip');
        }
        await capture(theme + (size >= 480 ? '-wide-' + size : '-icons-' + size));
        report.checks.push({theme, width: size, allFiveDirect: true, iconStatus: size < 480});
        continue;
      }
      await hidden('bmc.power'); await hidden('bmc.boot');
      inside((await visible('bmc.more')).rect, bar, 'more button');
      const video = (await visible('bmc.viewport')).rect;
      for (const menu of ['power', 'boot']) {
        await click('bmc.more');
        const popup = (await visible('bmc.more.popover')).rect;
        assert(popup.x >= bar.x && popup.x + popup.w <= bar.x + bar.w + .5);
        assert(popup.y >= bar.y + bar.h, 'more menu opens downwards');
        assert.deepEqual((await visible('bmc.viewport')).rect, video, 'opening menu preserves video bounds');
        if (menu === 'power') await capture(theme + '-narrow-' + size + '-more');
        await click('bmc.more.' + menu); await hidden('bmc.more.popover');
        await visible('bmc.' + menu + '.popover');
        await capture(theme + '-overflow-' + menu);
        await h.key('escape'); await hidden('bmc.' + menu + '.popover');
        await h.waitFor(async () => (await h.focused()).test_id === 'bmc.more' || null, 5000);
        report.checks.push({theme, width: size, menu, returnedFocus: await h.focused()});
      }
      await click('bmc.more'); await visible('bmc.more.popover');
      await h.key('escape'); await hidden('bmc.more.popover');
      await h.waitFor(async () => (await h.focused()).test_id === 'bmc.more' || null, 5000);
      // A keyboard activation uses the same retained Button and Popover.
      await h.key('return'); await visible('bmc.more.popover');
      await h.waitFor(async () => (await h.focused()).test_id === 'bmc.more.power' || null, 5000);
      await h.key('tab');
      const focus = await h.focused();
      assert.equal(focus.test_id, 'bmc.more.boot', 'Tab reaches the next overflow action');
      await h.key('return'); await visible('bmc.boot.popover');
      await h.key('escape'); await hidden('bmc.boot.popover');
      await click('bmc.more'); await visible('bmc.more.popover');
      await h.clickAt(bar.x + 4, bar.y - 8); await hidden('bmc.more.popover');
      await click('bmc.more'); await visible('bmc.more.popover');
      await width(520); await hidden('bmc.more.popover');
      await visible('bmc.power'); await visible('bmc.boot');
      report.checks.push({theme, width: size, escape: true, keyboard: true, outsideClick: true, resize: true});
    }
    await width(1000);
    assert((await h.request('POST', '/app/bmc-fixture/appearance', {theme, transparency: 100, blur: 24})).ok);
    for (const channel of [0, 255]) {
      assert((await h.request('POST', '/app/bmc-fixture/frame', {red: channel, green: channel, blue: channel})).ok);
      await h.sleep(250); await click('bmc.keys'); await h.sleep(250);
      const popup: any = await h.request('POST', '/app/bmc-fixture/material-node', {id: 'bmc.keys.popover'});
      assert(popup.background.a > popup.layer_alpha[0], 'readability protection applies at 100% transparency');
      const opacity = popup.background.a / 255;
      const fill = ['r', 'g', 'b'].map(k => Math.round(popup.background[k] * opacity + channel * (1 - opacity)));
      for (const role of ['foreground', 'foreground_secondary']) {
        assert.equal(popup[role].a, 255, role + ' remains opaque');
        assert(contrast(fill, ['r', 'g', 'b'].map(k => popup[role][k])) >= 4.5, role + ' remains readable');
      }
      await capture(theme + '-t100-keys-' + (channel ? 'white' : 'black'));
      report.checks.push({theme, transparency: 100, channel, popup});
      await h.key('escape'); await hidden('bmc.keys.popover');
    }
  }
  const stats = await h.request('GET', '/app/bmc-fixture/stats');
  assert.equal(stats.power_writes, 0); assert.equal(stats.boot_writes, 0);
  assert((await h.request('POST', '/quit')).ok);
  await Promise.race([ended, h.sleep(5000)]); assert.equal(app.exitCode, 0);
  assert.match(await readFile(join(out, 'app.log'), 'utf8'), /BMC_FIXTURE_CLEANUP budget_used=0 keys=0 buttons=0 power_writes=0 boot_writes=0/);
  report.status = 'passed';
} catch (error) {
  report.status = 'failed'; report.error = String(error); process.exitCode = 1;
  if (app.exitCode === null) await h.screenshot(join(out, 'failure.png')).catch(() => {});
  console.error(error);
} finally {
  if (app.exitCode === null && app.signalCode === null) {
    await h.request('POST', '/quit').catch(() => {});
    await Promise.race([ended, h.sleep(3000)]);
    if (app.exitCode === null && app.signalCode === null) { app.kill('SIGTERM'); await ended; }
  }
  await log.close(); await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  await rm(base, {recursive: true, force: true});
}
console.log(`${report.status}: ${out}`);
