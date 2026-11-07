/** Every settings category: default folds, manual toggles, page remount and reopening. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, realpath, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';

const [binaryArg, outputArg] = process.argv.slice(2);
assert(binaryArg && outputArg, 'settings_default_folds_native.ts BINARY OUTPUT');
const out = resolve(outputArg), iso = await realpath(await mkdtemp('/private/tmp/zw-default-folds-'));
const data = join(iso, 'data'), rpc = join(iso, 'rpc');
await Promise.all([mkdir(out, {recursive: true}), mkdir(data), mkdir(rpc)]);
const initial = `[ui]
theme="dark"
[[ai.providers]]
id="First fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:9/v1"
enabled=false
[[ai.providers]]
id="Second fixture"
kind="ollama"
endpoint="http://127.0.0.1:9"
enabled=false
`;
await writeFile(join(data, 'config.toml'), initial);
await writeFile(join(data, 'hosts.toml'), '');
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(resolve(binaryArg), [], {
  env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'},
  stdio: ['ignore', log.fd, log.fd],
});
const ended = new Promise(resolve => app.once('close', resolve));
const flat = (n: any): any[] => [n, ...(n.children ?? []).flatMap(flat)];
const node = (id: string): Promise<any> => h.waitFor(async () => (await h.query(id))[0] ?? null);
const bodyHeight = async (id: string) => {
  const body = flat(await node(id)).find(n => n.test_id === 'accordion.content');
  assert(body, id + ' has a disclosure body');
  return body.rect.h;
};
async function click(id: string) {
  const result = await h.clickTestId(id);
  assert(result.ok, id + ': ' + JSON.stringify(result));
  await h.sleep(90);
}
async function reveal(id: string) {
  for (let i = 0; i < 24; i++) {
    const target = await node(id), viewport = await node('settings.viewport');
    if (target.rect.y >= viewport.rect.y && target.rect.y + target.rect.h <= viewport.rect.y + viewport.rect.h) return;
    await h.scrollAt(viewport.rect.x + viewport.rect.w - 5, viewport.rect.y + viewport.rect.h / 2, 0, target.rect.y < viewport.rect.y ? 180 : -180);
    await h.sleep(70);
  }
  throw new Error('Cannot reveal ' + id);
}
const sections = (ids: string[]): [string, string][] => ids.map(id => [id, id + '.header']);
const pages: Record<string, [string, string][]> = {
  appearance: sections(['settings.appearance.app_icon', 'settings.appearance.themes', 'settings.appearance.materials', 'settings.appearance.font', 'settings.appearance.aids']),
  keys: sections(['settings.keys.tabs', 'settings.keys.terminal']),
  ssh: sections(['settings.ssh.connection', 'settings.ssh.reconnect', 'settings.ssh.socks', 'settings.ssh.authentication']),
  transfer: sections(['settings.transfer.connection', 'settings.transfer.engine', 'settings.transfer.defaults']),
  ai: [...sections(['settings.ai.provider.0.card', 'settings.ai.provider.1.card']).map(([id]) => [id, id.replace('.card', '.header')] as [string, string]), ...sections(['settings.ai.permissions', 'settings.ai.execution', 'settings.ai.conversation', 'settings.ai.context', 'settings.ai.attachments', 'settings.ai.behavior', 'settings.ai.skills', 'settings.ai.mcp'])],
  plugins: [['settings.plugins.builtin', '已内置'], ['settings.plugins.bundled', '随应用提供']],
  notifications: sections(['settings.notifications.events', 'settings.notifications.attention']),
  data: sections(['settings.data.location', 'settings.data.history', 'settings.data.actions']),
};
pages.appearance[2][1] = 'settings.materials.header';
const report: any = {status: 'running', pages: [], checks: []};
async function expectCollapsed(cards: [string, string][]) {
  for (const [id] of cards) assert((await bodyHeight(id)) < 0.5, id + ' starts collapsed');
}
try {
  await h.waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
  await h.resizeWindow(1440, 1000);
  await click('toolbar.settings');
  for (const [page, candidates] of Object.entries(pages)) {
    await click('settings.nav.' + page);
    const cards: [string, string][] = [];
    for (const candidate of candidates) {
      if (page === 'plugins' && !(await h.query(candidate[0])).length) continue;
      cards.push(candidate);
    }
    assert(cards.length > 0, page);
    await expectCollapsed(cards);
    await h.screenshot(join(out, page + '-initial.png'));
    for (const [i, [id, header]] of cards.entries()) {
      await reveal(header); await click(header);
      await h.waitFor(async () => (await bodyHeight(id)) > 1 || null);
      if (i < cards.length - 1) {
        await reveal(header); await click(header);
        await h.waitFor(async () => (await bodyHeight(id)) < 0.5 || null);
      }
    }
    const last = cards.at(-1)!;
    await click('settings.nav.' + (page === 'ssh' ? 'keys' : 'ssh'));
    await click('settings.nav.' + page);
    assert((await bodyHeight(last[0])) > 1, page + ' preserves manual expansion within settings');
    await click('settings.close'); await click('toolbar.settings');
    await expectCollapsed(cards);
    await h.screenshot(join(out, page + '-reopened.png'));
    report.pages.push({page, sections: cards.map(([id]) => id), defaultCollapsed: true, toggles: true, remountPreserved: true, reopenedCollapsed: true});
  }
  await click('settings.nav.updates');
  assert((await bodyHeight('settings.updates.preferences')) > 1, 'About update preferences are a static card');
  await h.screenshot(join(out, 'updates-static.png'));
  report.checks.push('About/update information and its static preferences remain visible');
  await click('settings.nav.ssh'); await click('settings.search'); await h.type_('keepalive_sec');
  await node('settings.search.results');
  assert((await bodyHeight('settings.ssh.connection')) > 1, 'Search reveals matching fields');
  await click('settings.close'); await click('toolbar.settings');
  assert.equal((await h.inputState('settings.search')).buffer, '');
  assert.equal((await h.query('settings.search.results')).length, 0);
  await expectCollapsed(pages.ssh);
  report.checks.push('Reopening clears a previous search; searching still expands matching settings');
  await h.resizeWindow(860, 600);
  await click('settings.nav.appearance'); await expectCollapsed(pages.appearance);
  await h.screenshot(join(out, 'compact-collapsed.png'));
  assert.equal(await readFile(join(data, 'config.toml'), 'utf8'), initial, 'Fold changes do not save configuration');
  report.checks.push('Compact window defaults remain collapsed; configuration file is unchanged');
  await h.request('POST', '/zerowork/windows', {action: 'quit'});
  await Promise.race([ended, h.sleep(10000)]);
  assert.equal(app.exitCode, 0, 'Normal application exit');
  report.status = 'passed';
} catch (error) {
  report.status = 'failed'; report.error = String(error);
  await h.screenshot(join(out, 'failure.png')).catch(() => {});
  throw error;
} finally {
  if (app.exitCode === null && app.signalCode === null) {app.kill('SIGTERM'); await ended;}
  await log.close();
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report));
}
