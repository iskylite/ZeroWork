/** Text selection on production SSH/BMC fields, using isolated native windows.
 * node e2e/input_selection_native.ts BINARY OUT [theme,theme]
 */
import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, realpath, rm, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';

const binary = resolve(process.argv[2]), out = resolve(process.argv[3]);
const themes = process.argv[4]?.split(',') ?? ['dark', 'light', 'sauber', 'nord'];
await mkdir(out, {recursive: true});
const report: any = {status: 'running', binary, cases: [], limits: 'Isolated storage and synthetic pointer/keys on real Metal windows; no network or real input method.'};
const shown = (n: any) => n.visible !== false && n.hidden !== true && (n.effective_opacity ?? 1) > 0 && n.rect.w > 0 && n.rect.h > 0;
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null);
async function click(id: string) { console.log('click', id); await visible(id); assert((await h.clickTestId(id)).ok, id); await h.sleep(180); }
try {
  for (const theme of themes) {
    const iso = await realpath(await mkdtemp('/tmp/zw-input-selection-'));
    const data = join(iso, 'data'), rpc = join(iso, 'rpc');
    await mkdir(data); await mkdir(rpc); process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
    await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\n`);
    const log = await open(join(out, `${theme}.log`), 'w');
    const app = spawn(binary, [], {env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZENIT_E2E_ISOLATE_KEYBOARD: '1'}, stdio: ['ignore', log.fd, log.fd]});
    const ended = new Promise<void>(done => app.once('close', () => done()));
    try {
      await h.waitForServerReady(); await h.resizeWindow(1440, 900);
      await click('sidebar.empty.new');
      for (const protocol of ['ssh', 'bmc_ikvm']) {
        await click(`wizard.protocol.${protocol}`);
        const id = protocol === 'ssh' ? 'wizard.name' : 'bmc.editor.name';
        await click(id); await h.key('a', {cmd: true}); await h.type_('https://172.20.3.225');
        await h.key('right'); await h.mouseMove(3, 3); await h.sleep(180);
        const field = await visible(id), rect = field.rect;
        const prefix = join(out, `${theme}-${protocol}`);
        assert((await h.screenshot(prefix + '-before.png')).ok);
        const x = rect.x + 12, y = rect.y + rect.h / 2;
        assert((await h.mouseDown(x, y)).ok);
        for (let i = 1; i <= 12; i++) { await h.mouseMove(x + i * 7, y); }
        assert((await h.mouseUp(x + 84, y)).ok); await h.mouseMove(3, 3); await h.sleep(180);
        const selection = await h.inputState(id);
        assert((selection.anchor ?? -1) >= 0 && selection.anchor !== selection.cursor_pos, 'Drag creates a non-empty selection');
        assert.equal(selection.buffer, 'https://172.20.3.225');
        assert((await h.screenshot(prefix + '-selected.png')).ok);
        // Sample a horizontal band above the glyphs: text/caret changes alone
        // cannot satisfy the assertion that the selected background was painted.
        const pixels = spawnSync('python3', ['-c', `
import json,sys
from PIL import Image
before,after=[Image.open(p).convert('RGB') for p in sys.argv[1:3]]
r=json.loads(sys.argv[3]);s=after.width/1440
y=round((r['y']+r['h']/2-6)*s)
changed=sum(max(abs(a-b) for a,b in zip(before.getpixel((x,y)),after.getpixel((x,y))))>24 for x in range(round((r['x']+14)*s),round((r['x']+88)*s)))
print(json.dumps({'changed_background_pixels':changed,'scale':s}))
assert changed>40*s, 'Selected text background is indistinguishable from focused field'
`, prefix + '-before.png', prefix + '-selected.png', JSON.stringify(rect)], {encoding: 'utf8'});
        const result = {theme, protocol, rect, selection, pixels: pixels.stdout.trim()};
        report.cases.push(result); await writeFile(prefix + '.json', JSON.stringify(result, null, 2));
        assert.equal(pixels.status, 0, pixels.stderr);
        // Replacing precisely the dragged range still uses the widget's editing path.
        const lo = Math.min(selection.anchor!, selection.cursor_pos), hi = Math.max(selection.anchor!, selection.cursor_pos);
        await h.type_('X'); assert.equal((await h.inputState(id)).buffer, selection.buffer.slice(0, lo) + 'X' + selection.buffer.slice(hi));
      }
      assert((await h.request('POST', '/quit')).ok); await Promise.race([ended, h.sleep(5000)]);
      assert.equal(app.exitCode, 0);
    } catch (error) {
      await h.screenshot(join(out, `${theme}-failure.png`)).catch(() => {});
      for (const id of ['sidebar.new', 'wizard.dialog', 'wizard.protocol', 'bmc.editor'])
        await writeFile(join(out, `${theme}-${id}.json`), JSON.stringify(await h.query(id), null, 2)).catch(() => {});
      throw error;
    } finally {
      if (app.exitCode === null && app.signalCode === null) { app.kill('SIGTERM'); await ended; }
      await log.close(); await rm(iso, {recursive: true, force: true});
    }
  }
  report.status = 'passed';
} catch (error) { report.status = 'failed'; report.error = String(error); process.exitCode = 1; }
finally { await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2)); }
console.log(JSON.stringify({status: report.status, report: join(out, 'report.json'), error: report.error}));
