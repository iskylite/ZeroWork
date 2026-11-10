/** Live output keeps the current bottom as the wheel origin after switching tabs. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, open, realpath, rm, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';

const prefix = resolve(process.argv[2] ?? '/tmp/zw-tab-scroll-build');
const out = resolve(process.argv[3] ?? '/tmp/zw-tab-scroll-verification');
await mkdir(out, {recursive: true});
const isolated = await realpath(await mkdtemp('/tmp/zw-tab-follow-'));
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc');
await mkdir(data); await mkdir(rpc);
await writeFile(join(data, 'config.toml'), '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n');
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(join(prefix, 'bin/zerowork'), [], {
  env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'},
  stdio: ['ignore', log.fd, log.fd],
});
const ended = new Promise(r => app.once('close', r));
const report: any = {status: 'running', checks: [], captures: []};
const flat = (n: any): any[] => [n, ...(n.children ?? []).flatMap(flat)];
const shown = (n: any) => n?.rect?.w > 0 && n.rect.h > 0 && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0;
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
async function click(id: string) {
  const n = await visible(id);
  assert((await h.clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok);
}
async function rows() {
  const root = await visible('terminal.surface');
  return flat(root).filter(shown).flatMap(n => {
    const match = n.text?.match(/^TAB-LIVE-(\d+)$/);
    return match ? [{line: Number(match[1]), y: n.rect.y}] : [];
  }).sort((a, b) => a.line - b.line);
}
async function lastLine() { return (await rows()).at(-1)?.line ?? -1; }
async function wheel(delta: number) {
  const n = await visible('terminal.surface');
  assert((await h.scrollAt(n.rect.x + n.rect.w * .6, n.rect.y + n.rect.h * .5, 0, delta)).ok);
}
async function capture(name: string) {
  const path = join(out, name + '.png');
  assert((await h.screenshot(path)).ok); report.captures.push(path);
}
try {
  await h.waitForServerReady(60000); await h.resizeWindow(1100, 760);
  await click('workspace.empty.local'); await click('terminal.surface');
  await h.sleep(800);
  await h.type_("/usr/bin/perl -e '$|=1; for(0..100000){printf \"TAB-LIVE-%06d\\n\",$_;select undef,undef,undef,0.015}'");
  await h.key('return');
  await h.waitFor(async () => (await lastLine()) >= 60 || null, 15000);
  // Seed a history cache, then resume the live native viewport.
  await wheel(0.5); await h.sleep(200); await wheel(-100000); await h.sleep(200);
  const leaving = await lastLine();
  await click('toolbar.new_session'); await click('session.menu.local');
  await visible('tabs.tab.2'); await h.sleep(2200);
  await click('tabs.tab.1');
  const returned = await h.waitFor(async () => {
    const line = await lastLine(); return line > leaving + 80 ? line : null;
  }, 15000);
  await capture('returned-live');
  await wheel(0.5);
  await h.waitFor(async () => {
    const metrics = await h.request('POST', '/zerowork/terminal', {action: 'metrics'});
    return metrics.composite_bytes > 0 && !metrics.composite_search_pending && !metrics.glyphs_pending || null;
  }, 15000);
  const afterWheel = await lastLine();
  assert(afterWheel >= returned - 2, `Wheel jumped from current line ${returned} to ${afterWheel}; tab was left at ${leaving}`);
  const reading = (await rows())[0]; assert(reading);
  await h.sleep(400);
  const held = (await rows())[0];
  assert.equal(held.line, reading.line); assert(Math.abs(held.y - reading.y) < .01);
  await capture('after-first-wheel');
  report.checks.push({check: 'first wheel starts at latest output and holds reading position', leaving, returned, afterWheel, reading});
  await click('tabs.tab.2'); await h.sleep(500); await click('tabs.tab.1'); await h.sleep(200);
  const restored = (await rows())[0];
  assert.equal(restored.line, reading.line); assert(Math.abs(restored.y - reading.y) < .01);
  report.checks.push('Switching tabs preserves a deliberate historical reading position');
  await wheel(-100000);
  const resumed = await h.waitFor(async () => {
    const line = await lastLine(); return line > afterWheel + 20 ? line : null;
  }, 15000);
  await h.waitFor(async () => (await lastLine()) > resumed + 10 || null, 15000);
  await capture('resumed-following');
  report.checks.push('Returning to the bottom resumes following continuous output');
  await click('terminal.surface'); await h.key('c', {ctrl: true}); await h.sleep(150);
  await h.type_('exit'); await h.key('return'); await visible('local.ended.close');
  await click('tabs.tab.2'); await click('terminal.surface'); await h.type_('exit'); await h.key('return');
  await visible('local.ended.close');
  report.status = 'passed';
} catch (error) {
  report.status = 'failed'; report.error = String(error); process.exitCode = 1;
  await capture('failure').catch(() => {});
} finally {
  if (app.exitCode === null && app.signalCode === null) app.kill('SIGTERM');
  await ended;
  if (app.pid) await cleanupOwnedBridgeDirectories(app.pid);
  await log.close(); await rm(isolated, {recursive: true, force: true});
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report));
}
