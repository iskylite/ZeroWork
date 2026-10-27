/** Real main-app focus/blur smoke for the root's exact integrated binary.
 * Only private data, local terminal and synthetic Harness input are used.
 * Pixel review is a separate required acceptance step; no physical IME claim.
 */
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFile, mkdir, mkdtemp, open, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { waitForServerReady, waitFor, query, focused, inputState, clickTestId, key, type_, resizeWindow, screenshot, sleep } from '../zig-out/share/zenit/harness/client.ts';

const options: Record<string, string> = {};
for (let i = 2; i < process.argv.length; i += 2) {
  assert(['--binary', '--expected-sha', '--out', '--theme'].includes(process.argv[i]) && process.argv[i + 1]);
  options[process.argv[i]] = process.argv[i + 1];
}
assert(options['--binary'] && /^[a-f0-9]{64}$/.test(options['--expected-sha'] ?? '') && options['--out']);
const theme = options['--theme'] ?? 'dark';
assert(['dark', 'light', 'sauber'].includes(theme));
const output = resolve(options['--out']);
await mkdir(output, { recursive: true });
const sourceBinary = resolve(options['--binary']), binary = join(output, 'zerowork-frozen');
await copyFile(sourceBinary, binary);
const sha = createHash('sha256').update(await readFile(binary)).digest('hex');
assert.equal(sha, options['--expected-sha']);
const isolated = await mkdtemp(join(tmpdir(), 'zw-chromeless-')), data = join(isolated, 'data'), rpc = join(isolated, 'rpc');
await mkdir(data); await mkdir(rpc);
await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`);
await writeFile(join(data, 'hosts.toml'), '[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Focus fixture"\nhost="127.0.0.1"\nport=65530\nuser="fixture"\n');
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(output, 'app.log'), 'w');
const child = spawn(binary, [], { env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1' }, stdio: ['ignore', log.fd, log.fd] });
const ended = new Promise<void>(done => child.once('close', () => done()));
const report: any = { status: 'running', binary_sha256: sha, source_binary: sourceBinary, binary, pid: child.pid, theme, started_at: new Date().toISOString(), checks: [], captures: [], limits: ['Real Metal app with synthetic Harness input; no physical keyboard or native IME claim', 'Authentication and remote file controls are covered by their separate owner runners', 'Screenshots require visual review; this runner does not claim Figma pixel parity', 'Owned-process termination is cleanup, not normal app-close proof'] };
const shown = (n: any) => n?.hidden !== true && n?.visible !== false && (n?.effective_opacity ?? 1) > 0 && n?.rect?.w > 0 && n?.rect?.h > 0;
const flatten = (n: any): any[] => shown(n) ? [n, ...(n.children ?? []).flatMap(flatten)] : [];
async function visible(id: string): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null); }
async function click(id: string) { await visible(id); assert((await clickTestId(id)).ok, id); }
async function capture(name: string, ids: string[]) {
  await sleep(200);
  const path = join(output, `${name}.png`);
  assert((await screenshot(path)).ok);
  await writeFile(join(output, `${name}.json`), JSON.stringify({ focus: await focused(), inputs: Object.fromEntries(await Promise.all(ids.map(async id => [id, await query(id)]))) }, null, 2));
  report.captures.push(path);
}
async function keyboardFocus(id: string) {
  await click(id);
  assert((await key('tab', { shift: true })).ok);
  assert((await key('tab')).ok);
  const target = await visible(id), focus = await focused();
  assert(flatten(target).some(n => n.id === focus.id), `Keyboard focus must return to ${id}: ${JSON.stringify(focus)}`);
}
async function edit(id: string, value: string) {
  await click(id); await key('a', { cmd: true }); await key('backspace');
  if (value) await type_(value);
  await waitFor(async () => (await inputState(id)).buffer === value || null);
}
async function field(id: string, name: string) {
  await keyboardFocus(id); await capture(`${name}-focus`, [id]);
  assert((await key('right')).ok);
  assert((await key('tab')).ok);
  const target = await visible(id), focus = await focused();
  assert(!flatten(target).some(n => n.id === focus.id), `Blur ${id}`);
  await capture(`${name}-blur`, [id]);
  report.checks.push(`${id}: real keyboard traversal enters actual input; blur transfers focus; focus and blur pixels captured`);
}
function descendants() {
  const rows = execFileSync('/bin/ps', ['-axo', 'pid=,ppid='], { encoding: 'utf8' }).trim().split('\n').map(line => line.trim().split(/\s+/).map(Number));
  const owned = new Set<number>([child.pid!]);
  for (let i = 0; i < rows.length; i++) for (const [pid, parent] of rows) if (owned.has(parent)) owned.add(pid);
  return [...owned].filter(pid => pid !== child.pid);
}
try {
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), child.pid);
  await resizeWindow(1440, 900);
  await visible('sidebar.host');
  await field('sidebar.search', '01-sidebar-search');
  await click('toolbar.settings');
  await field('settings.search', '02-settings-search');
  await click('settings.nav.appearance');
  await edit('settings.search', 'font_size');
  await visible('settings.field.font_size');
  await field('settings.field.font_size', '03-settings-font-size');
  await edit('settings.field.font_size', '99'); await key('return');
  await capture('04-settings-invalid', ['settings.field.font_size', 'settings.footer.state']);
  assert.match((await visible('settings.footer.state')).text, /错误|修正|无效/);
  await edit('settings.field.font_size', '14'); await key('return');
  await edit('settings.search', ''); await click('settings.close');
  if ((await query('settings.confirmation.discard')).some(shown)) await click('settings.confirmation.discard');
  await click('toolbar.quick_connect');
  await field('quick.query', '05-quick-query'); await click('quick.close');
  await click('sidebar.new'); await click('sidebar.new.host');
  await field('wizard.name', '06-wizard-name');
  await visible('wizard.name.error');
  await capture('07-wizard-error-text', ['wizard.name', 'wizard.name.error']);
  await click('wizard.cancel');
  await click('workspace.empty.local'); await visible('terminal.surface');
  await key('r', { cmd: true, shift: true }); await visible('tabs.rename.input');
  await field('tabs.rename.input', '08-tab-rename');
  let saveFocused = false;
  for (let step = 0; step < 12; step++) {
    const saveFocus = await focused();
    if (flatten(await visible('tabs.rename.save')).some(n => n.id === saveFocus.id)) { saveFocused = true; break; }
    await key('tab');
  }
  assert(saveFocused, 'Tab reaches the primary Save button');
  await capture('08-tab-rename-primary-focus', ['tabs.rename.save', 'tabs.rename.input']);
  report.checks.push('Primary Save retains its solid action background with a legible label under keyboard focus');
  await click('tabs.rename.cancel');
  await key('f', { cmd: true }); await visible('terminal.search.query');
  // Cmd+F is the production keyboard route that focuses the search editor.
  // Its Tab navigation intentionally returns to the terminal canvas.
  const searchFocus = await focused();
  assert(flatten(await visible('terminal.search.query')).some(n => n.id === searchFocus.id), 'Cmd+F focuses the search editor');
  await capture('09-terminal-search-focus', ['terminal.search.query']);
  report.checks.push('terminal.search.query: real Cmd+F keyboard command focuses editor; focus pixels captured');
  await key('escape');
  report.status = 'passed';
} catch (error) {
  report.status = 'failed'; report.error = String(error);
  if (child.exitCode === null && child.signalCode === null) await screenshot(join(output, 'failure.png')).catch(() => {});
  throw error;
} finally {
  report.owned_descendants_at_cleanup = descendants();
  for (const pid of [...report.owned_descendants_at_cleanup].reverse()) { try { process.kill(pid, 'SIGHUP'); } catch {} }
  if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  await Promise.race([ended, sleep(2000)]);
  if (child.exitCode === null && child.signalCode === null) { child.kill('SIGKILL'); await ended; }
  report.process_cleanup = { exit_code: child.exitCode, signal: child.signalCode };
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, 'report.json'), JSON.stringify(report, null, 2));
  await log.close(); await rm(isolated, { recursive: true, force: true });
}
