/** Retained settings/Provider folds: real Metal frames, isolated draft, no network. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, realpath, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';

const [binaryArg, outArg] = process.argv.slice(2);
assert(binaryArg && outArg, 'binary output-directory');
const binary = resolve(binaryArg), out = resolve(outArg);
const iso = await realpath(await mkdtemp('/private/tmp/zw-fold-motion-'));
const data = join(iso, 'data'), rpc = join(iso, 'rpc');
await Promise.all([mkdir(out, {recursive: true}), mkdir(data), mkdir(rpc)]);
const initial = `[ui]
theme="dark"
[ai]
default_provider="Fold fixture"
[[ai.providers]]
id="Fold fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:9/v1/chat/completions"
enabled=false
[[ai.providers.models]]
name="fixture-model"
default=true
context_window=128000
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
const app = spawn(binary, [], {
  env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'},
  stdio: ['ignore', log.fd, log.fd],
});
const ended = new Promise(resolve => app.once('close', resolve));
const report: any = {status: 'running', cases: [], limits: ['Synthetic input into the real native window; no physical IME or display latency measurement.']};
const flat = (n: any): any[] => [n, ...(n.children ?? []).flatMap(flat)];
const node = async (id: string) => {
  const found = (await h.query(id))[0];
  assert(found, id);
  return found;
};
const content = (n: any) => {
  const found = flat(n).find(n => n.test_id === 'accordion.content');
  assert(found, 'accordion content');
  return found;
};
async function click(id: string) {
  assert((await h.clickTestId(id)).ok, id);
}
async function sample(id: string, ms = 420) {
  const started = Date.now(), frames: any[] = [];
  do {
    const n = await node(id);
    frames.push({ms: Date.now() - started, height: content(n).rect.h});
    await h.sleep(15);
  } while (Date.now() - started < ms);
  return frames;
}
async function checkFold(label: string, cardId: string, headerId: string, fieldId?: string, summaryId?: string) {
  await h.screenPos(headerId);
  await h.sleep(100);
  const card = await node(cardId), header = await node(headerId), field = fieldId ? await node(fieldId) : null;
  const page = await node('settings.content');
  const height = content(card).rect.h;
  assert(height > 0, label + ' starts open');
  await h.resetTiming();
  await click(headerId);
  const entry: any = {label, cardId: card.id, fieldId: field?.id, initial_height: height};
  report.cases.push(entry);
  const closing = await sample(cardId);
  entry.closing = closing;
  entry.afterClosing = {card: (await node(cardId)).id, header: (await node(headerId)).id};
  assert(closing.some(n => n.height > 0.5 && n.height < height - 0.5), label + ' has collapse intermediate frames');
  assert(content(await node(cardId)).rect.h < 0.5, label + ' finishes closed');
  if (summaryId) assert((await node(summaryId)).visible !== false, label + ' collapsed summary');
  await h.screenshot(join(out, label + '-closed.png'));
  await click(headerId);
  const opening = await sample(cardId);
  entry.opening = opening;
  assert(opening.some(n => n.height > 0.5 && n.height < height - 0.5), label + ' has expand intermediate frames');
  assert(Math.abs(content(await node(cardId)).rect.h - height) < 1, label + ' finishes open');
  // Reverse while collapsing, then let both content and title settle.
  await click(headerId);
  await h.sleep(60);
  await click(headerId);
  await h.sleep(450);
  assert(Math.abs(content(await node(cardId)).rect.h - height) < 1, label + ' reverses to open');
  assert.equal((await node(cardId)).id, card.id, label + ' card retained');
  assert.equal((await node(headerId)).id, header.id, label + ' header retained');
  assert.equal((await node('settings.content')).id, page.id, label + ' page retained');
  if (field) assert.equal((await node(fieldId!)).id, field.id, label + ' field retained');
  await h.screenshot(join(out, label + '-open.png'));
  entry.stats = await h.stats();
}
try {
  await h.waitForServerReady(60000);
  assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
  await h.resizeWindow(1440, 900);
  await click('toolbar.settings');
  await h.sleep(400);
  // Settle each initial card state independently of default folds.
  for (const [page, card, header, field, summary] of [
    ['appearance', 'settings.appearance.materials', 'settings.materials.header', 'settings.field.fit', 'settings.appearance.materials.summary'],
    ['ssh', 'settings.ssh.connection', 'settings.ssh.connection.header', 'settings.field.keepalive_sec', 'settings.ssh.connection.summary'],
    ['plugins', '已内置', '已内置', 'settings.plugin.ssh.row', '已内置.summary'],
  ]) {
    await click('settings.nav.' + page);
    await h.sleep(250);
    // Header subtree is small; hidden summary denotes the expanded state.
    if ((await node(summary)).visible !== false) {
      await click(header);
      await h.sleep(450);
    }
    // Plugin item and trigger deliberately have distinct selectors.
    const cardId = page === 'plugins' ? 'settings.plugins.builtin' : card;
    await checkFold(page, cardId, header, field, summary);
  }
  await click('settings.nav.ai');
  await h.sleep(300);
  await checkFold('provider', 'settings.ai.provider.0.card', 'settings.ai.provider.0.header', 'settings.ai.provider.0.endpoint');
  await h.resizeWindow(860, 480);
  await h.sleep(200);
  await checkFold('provider-compact', 'settings.ai.provider.0.card', 'settings.ai.provider.0.header', 'settings.ai.provider.0.endpoint');
  assert.equal(await readFile(join(data, 'config.toml'), 'utf8'), initial, 'folds never save configuration');
  report.status = 'passed';
} catch (error) {
  report.status = 'failed';
  report.error = String(error);
  await h.screenshot(join(out, 'failure.png')).catch(() => {});
  throw error;
} finally {
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  if (app.exitCode === null) app.kill('SIGTERM');
  await ended;
  await log.close();
}
