/** Real production settings pages: collapsed summaries, units, editing and scroll. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp, mkdir, writeFile, readFile, open, rm, realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {waitForServerReady, waitFor, query, clickAt, key, type_, resizeWindow, screenshot, sleep, scrollAt, request} from '../vendor/zenit/e2e/client.ts';

const args = process.argv.slice(2);
assert(args.length === 2 || args.length === 3, 'settings_summaries_native.ts BINARY OUTPUT [storage]');
const mode = args[2] ?? 'full'; assert(['full', 'storage'].includes(mode));
const binary = resolve(args[0]), output = resolve(args[1]);
await mkdir(output, {recursive: true});
const report: any = {binary, sha256: createHash('sha256').update(await readFile(binary)).digest('hex'), runs: []};
const pages = ['appearance', 'keys', 'ssh', 'transfer', 'ai', 'plugins', 'notifications', 'data'];
const flat = (n: any): any[] => [n, ...(n.children ?? []).flatMap(flat)];
const shown = (n: any) => n?.visible !== false && n?.rect?.w > 0 && n?.rect?.h > 0 && (n.effective_opacity ?? 1) > 0;
const text = (n: any) => typeof n.text === 'string' ? n.text : (n.text?.content ?? '');
let failure: unknown;

for (const theme of (mode === 'storage' ? ['dark'] : ['dark', 'light', 'sauber'])) {
  const iso = await realpath(await mkdtemp(join(tmpdir(), 'zerowork-settings-summary-')));
  const rpc = join(iso, 'rpc'), data = join(iso, 'data');
  await mkdir(rpc, {mode: 0o700}); await mkdir(data, {mode: 0o700});
  await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`, {mode: 0o600});
  process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
  const log = await open(join(output, `${theme}.app.log`), 'w');
  const app = spawn(binary, [], {env: {...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: ''}, stdio: ['ignore', log.fd, log.fd]});
  const ended = new Promise<void>(done => app.once('close', () => done()));
  const rec: any = {theme, pages: [], captures: []}; report.runs.push(rec);
  const visible = async (id: string): Promise<any> => waitFor(async () => (await query(id)).find(shown) ?? null, 12000);
  async function click(id: string) {const n = await visible(id); assert((await clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok); await sleep(180);}
  async function capture(name: string) {await sleep(240); assert((await screenshot(join(output, name + '.png'))).ok); rec.captures.push(name); console.log(name);}
  async function content() {return flat(await visible('settings.content'));}
  async function scrollTop() {const v = await visible('settings.viewport'); await scrollAt(v.rect.x + v.rect.w / 2, v.rect.y + 12, 0, 3000); await sleep(150);}
  async function scrollTo(id: string) {
    for (let i = 0; i < 12; i++) {
      const v = await visible('settings.viewport'), n = (await query(id)).find(shown);
      if (n && n.rect.y >= v.rect.y && n.rect.y + n.rect.h <= v.rect.y + v.rect.h) return n;
      await scrollAt(v.rect.x + v.rect.w / 2, v.rect.y + v.rect.h / 2, 0, n && n.rect.y < v.rect.y ? 200 : -200); await sleep(120);
    }
    throw new Error('Could not scroll into view: ' + id);
  }
  try {
    await waitForServerReady();
    const owner = JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')); assert.equal(Number(owner.pid), app.pid);
    await resizeWindow(1440, 900); await click('toolbar.settings');
    if (mode === 'storage') {
      await click('settings.nav.ai'); await click('settings.ai.provider.0.connection.header');
      const nodes = await content();
      assert(nodes.some(n => text(n) === 'API Key 存储于 macOS 钥匙串'));
      assert(!nodes.some(n => text(n).includes('明文保存')));
      await capture('dark-provider-keychain');
      rec.provider_storage_contract = 'macOS Keychain';
      await click('settings.nav.appearance'); await scrollTop();
      const currentNames = flat(await visible('settings.theme.current')).map(text).filter(Boolean);
      assert(currentNames.length > 0);
      await click('settings.appearance.themes.header');
      assert.equal(text(await visible('settings.appearance.themes.summary')), currentNames[0]);
      assert(!(await query('settings.appearance.aids.summary')).some(shown));
      await capture('dark-appearance-current-theme');
      rec.selected_theme_summary = currentNames[0];
      const windows = await request('POST', '/zerowork/windows', {action: 'snapshot'});
      assert((await request('POST', '/zerowork/windows', {action: 'close', window: windows.windows[0].window})).ok);
      await Promise.race([ended, sleep(10000)]); assert.equal(app.exitCode, 0);
      rec.normal_close = true; rec.status = 'passed_pending_visual_review';
      continue;
    }
    for (const page of pages) {
      await click('settings.nav.' + page); await scrollTop();
      const nodes = await content();
      const summaries = nodes.filter(n => n.test_id?.endsWith('.summary'));
      const checks: any[] = [];
      for (const s of summaries) {
        const headerId = s.test_id.slice(0, -'.summary'.length) + '.header';
        const h = nodes.find(n => n.test_id === headerId); if (!h) continue;
        if (shown(s) && text(s)) {
          const labels = flat(h).filter(n => text(n) && n.test_id !== s.test_id);
          assert(labels.length > 0); const title = labels[0];
          assert(Math.abs(title.rect.x - s.rect.x) < 1, 'Summary shares title alignment');
          assert(s.rect.y >= title.rect.y + title.rect.h, 'Summary is below title');
        }
        checks.push({id: s.test_id, text: text(s), shown: shown(s), rect: s.rect});
      }
      rec.pages.push({page, summaries: checks});
      if (theme === 'dark' && ['ssh', 'appearance', 'ai', 'plugins'].includes(page)) await capture(`${theme}-${page}`);
    }
    await click('settings.nav.data'); await scrollTop();
    await capture(`${theme}-data-expanded`);
    const input = await scrollTo('settings.field.ring_mb'); await clickAt(input.rect.x + 20, input.rect.y + input.rect.h / 2);
    await key('a', {cmd: true}); assert((await type_('128')).ok); await sleep(180);
    const summaries = (await content()).filter(n => n.test_id?.endsWith('.summary'));
    const history = summaries.find(n => n.test_id === 'settings.data.history.summary');
    assert(history && !shown(history), 'Expanded history has no visible repeated summary');
    await scrollTop(); await scrollTo('settings.data.history.header'); await click('settings.data.history.header');
    const collapsed = await visible('settings.data.history.summary');
    assert.equal(text(collapsed), '缓冲 128 MiB · 每 30 秒快照 · 保留 14 天');
    rec.edited_summary = {text: text(collapsed), rect: collapsed.rect};
    await capture(`${theme}-data-collapsed`);
    await click('settings.save'); await sleep(250);
    assert.match(await readFile(join(data, 'config.toml'), 'utf8'), /ring_mb\s*=\s*128/);
    rec.numeric_value_saved_without_unit = true;
    // Keep the footer fixed while the settings body scrolls on a small window.
    await resizeWindow(860, 480); await click('settings.data.history.header'); await sleep(200);
    const footer = (await visible('settings.footer')).rect, viewport = (await visible('settings.viewport')).rect;
    await scrollAt(viewport.x + viewport.w / 2, viewport.y + viewport.h / 2, 0, -1500); await sleep(250);
    assert.deepEqual((await visible('settings.footer')).rect, footer);
    await scrollTo('settings.data.actions.header');
    await capture(`${theme}-data-small-scrolled`);
    // Search expands a match without exposing its summary alongside the field.
    await click('settings.search'); await key('a', {cmd: true}); await type_('checkpoint_sec'); await sleep(200);
    await scrollTop(); assert((await query('settings.field.checkpoint_sec')).some(shown));
    assert(!(await query('settings.data.history.summary')).some(shown));
    rec.search_expands_without_summary = true;
    const windows = await request('POST', '/zerowork/windows', {action: 'snapshot'});
    assert((await request('POST', '/zerowork/windows', {action: 'close', window: windows.windows[0].window})).ok);
    await Promise.race([ended, sleep(10000)]); assert.equal(app.exitCode, 0); rec.normal_close = true;
    rec.status = 'passed_pending_visual_review';
  } catch (e) {
    failure = e; rec.status = 'failed'; rec.error = String(e);
    try {await capture(theme + '-failure'); await writeFile(join(output, theme + '-failure-tree.json'), JSON.stringify(await query('settings.content'), null, 2));} catch {}
  } finally {
    if (app.exitCode === null && app.signalCode === null) {app.kill('SIGTERM'); await Promise.race([ended, sleep(2000)]); if (app.exitCode === null && app.signalCode === null) app.kill('SIGKILL');}
    rec.exit = {code: app.exitCode, signal: app.signalCode};
    await log.close(); await rm(iso, {recursive: true, force: true});
    await writeFile(join(output, 'report.json'), JSON.stringify(report, null, 2));
  }
  if (failure) break;
}
report.status = failure ? 'failed' : 'passed_pending_visual_review';
await writeFile(join(output, 'report.json'), JSON.stringify(report, null, 2));
if (failure) throw failure;
