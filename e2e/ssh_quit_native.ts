/** Real native Quit with independent and reused SSH sessions on an owned peer. */
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir, mkdtemp, open, readFile, writeFile, readdir, rm} from 'node:fs/promises';
import {resolve, join} from 'node:path';
import {pathToFileURL} from 'node:url';

const prefix = resolve(process.argv[2] ?? 'zig-out');
const out = resolve(process.argv[3] ?? '/tmp/zw-ssh-quit');
const scenario = process.argv[4] ?? 'live';
assert(['live', 'disconnected', 'held-close'].includes(scenario));
const h = await import(pathToFileURL(join(prefix, 'share/zenit/harness/client.ts')).href);
await mkdir(out, {recursive: true});
const isolated = await mkdtemp('/private/tmp/zw-ssh-quit-');
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc'), peerDir = join(isolated, 'peer');
await mkdir(data); await mkdir(rpc);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const peerLog = await open(join(out, 'peer.log'), 'w');
const peer = spawn('python3', ['e2e/ssh_tab_connections_peer.py', '--out', peerDir, ...(scenario === 'held-close' ? ['--hold-close'] : [])], {stdio: ['ignore', peerLog.fd, peerLog.fd]});
const peerEnd = new Promise<void>(done => peer.once('close', () => done()));
let app: ReturnType<typeof spawn> | undefined, ended: Promise<void>, appLog: Awaited<ReturnType<typeof open>>;
const report: any = {scenario, status: 'running', checks: [], captures: [], forced_cleanup: false};
const shown = (n: any) => n.visible !== false && !n.hidden && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const flat = (n: any): any[] => [n, ...(n.children ?? []).flatMap(flat)];
const visible = async (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
async function click(id: string) {const n = await visible(id); assert((await h.clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok);}
const state = () => h.request('POST', '/zerowork/windows', {action: 'snapshot'});
async function attached(count: number) {
  return h.waitFor(async () => {
    const modal = (await h.query('plugin.challenge.modal')).find(shown);
    if (modal) {
      const choice = flat(modal).find((n: any) => n.test_id === 'plugin.challenge.choice.1' && shown(n));
      if (choice) await click('plugin.challenge.choice.1');
      else if (flat(modal).some((n: any) => n.test_id === 'plugin.challenge.secret' && shown(n))) {
        await click('plugin.challenge.secret'); await h.type_('records-secret'); await click('plugin.challenge.submit');
      }
    }
    const s = await state();
    return s.sessions.length === count && s.sessions.every((v: any) => v.lifecycle === 'attached') ? s : null;
  }, 25000);
}
async function capture(name: string) {
  const path = join(out, name + '.png');
  assert((await h.screenshot(path)).ok); report.captures.push(path);
  await writeFile(join(out, name + '.state.json'), JSON.stringify(await state(), null, 2));
}
async function peerFiles(prefix: string) {return (await readdir(peerDir)).filter(name => name.startsWith(prefix));}
try {
  const ready = await h.waitFor(async () => {try {return JSON.parse(await readFile(join(peerDir, 'ready.json'), 'utf8'));} catch {return null;}}, 10000);
  await writeFile(join(data, 'known_hosts'), ready.known_host);
  await writeFile(join(data, 'config.toml'), '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ssh]\nauto_reconnect=false\nconnect_timeout_sec=2\n');
  await writeFile(join(data, 'hosts.toml'), `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="Quit loopback SSH"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
  const binary = join(prefix, 'bin/zerowork');
  report.binary_sha256 = createHash('sha256').update(await readFile(binary)).digest('hex');
  appLog = await open(join(out, 'app.log'), 'w');
  app = spawn(binary, [], {env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'}, stdio: ['ignore', appLog.fd, appLog.fd]});
  ended = new Promise<void>(done => app!.once('close', () => done()));
  report.pid = app.pid;
  await h.waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
  await h.resizeWindow(1280, 800);
  for (let count = 1; count <= 3; count++) {
    const row = await visible('sidebar.host');
    const point = {x: row.rect.x + 10, y: row.rect.y + row.rect.h / 2, button: 'right'};
    await h.request('POST', '/mouse_down', point); await h.request('POST', '/mouse_up', point);
    await click('context.menu.new_tab');
    await attached(count);
  }
  for (let count = 4; count <= 5; count++) {
    const tabs = (await h.query('tabs.strip'))[0];
    const tab = flat(tabs).filter((n: any) => /^tabs\.tab\.\d+$/.test(n.test_id ?? '') && shown(n)).at(-1);
    assert(tab);
    const point = {x: tab.rect.x + 45, y: tab.rect.y + tab.rect.h / 2, button: 'right'};
    await h.request('POST', '/mouse_down', point); await h.request('POST', '/mouse_up', point);
    await click('context.menu.reuse_connection');
    await attached(count);
  }
  assert.equal((await peerFiles('connection-')).length, 3);
  await h.waitFor(async () => (await peerFiles('shell-')).length === 5 || null, 10000);
  const shells = await Promise.all((await peerFiles('shell-')).map(async name => JSON.parse(await readFile(join(peerDir, name), 'utf8'))));
  assert.equal(new Set(shells.map(s => s.pid)).size, 5);
  report.shells = shells;
  report.checks.push('Five real SSH PTYs attached across three transports; two tabs reuse a transport.');
  if (scenario === 'held-close') {
    // A single child close must keep live siblings usable even when the peer
    // never acknowledges that child's close. Quit will then drain them all.
    const shared = (await state()).sessions.filter((s: any) => s.session >= 3);
    await click('tabs.tab.' + shared[0].tab);
    await click('tabs.close.' + shared[0].tab);
    await h.waitFor(async () => (await state()).sessions.find((s: any) => s.session === shared[0].session)?.lifecycle === 'closing' || null);
    await click('tabs.tab.' + shared[2].tab);
    await h.sleep(650);
    await click('terminal.input'); await h.type_("printf 'QUIT_%s\\n' SURVIVOR"); await h.key('return');
    await h.waitFor(async () => (await h.query('terminal.input')).some((n: any) => shown(n) && flat(n).map((v: any) => v.text ?? '').join('').includes('QUIT_SURVIVOR')) || null);
    assert((await state()).sessions.filter((s: any) => s.session >= 4).every((s: any) => s.lifecycle === 'attached'));
    report.checks.push('Closing one shared tab without a peer acknowledgement preserves both live siblings and real shell output.');
  }
  if (scenario === 'disconnected') {
    await writeFile(join(peerDir, 'drop-first'), '1');
    await h.waitFor(async () => (await state()).sessions.some((s: any) => s.lifecycle === 'ended' || s.lifecycle === 'failed') || null, 15000);
    report.checks.push('One original transport actually disconnected before Quit.');
  }
  await capture('before-quit');
  const started = Date.now();
  await h.request('POST', '/zerowork/windows', {action: 'quit'});
  await Promise.race([ended, h.sleep(12000)]);
  if (app.exitCode === null && app.signalCode === null) {
    await capture('stuck');
    try {execFileSync('/usr/bin/sample', [String(app.pid), '1', '-file', join(out, 'stuck.sample.txt')], {timeout: 5000});} catch {}
  }
  assert.equal(app.exitCode, 0, 'Quit must exit normally without forced cleanup');
  assert.equal(app.signalCode, null);
  report.quit_elapsed_ms = Date.now() - started;
  await h.waitFor(async () => (await peerFiles('closed-')).length === 3 || null, 10000);
  if (scenario === 'held-close') assert((await peerFiles('held-close-')).length > 0, 'Peer actually withheld a close reply');
  const live = new Set(execFileSync('/bin/ps', ['-axo', 'pid='], {encoding: 'utf8'}).trim().split(/\s+/).map(Number));
  assert(shells.every(s => !live.has(s.pid)), 'All original remote fixture shell processes exited');
  report.checks.push('Normal application Quit returned exit code 0; all three transports and five original shells closed.');
  report.status = 'passed';
} catch (error) {
  if (app && app.exitCode === null && app.signalCode === null) {
    try {await capture('failure'); await writeFile(join(out, 'failure.tree.json'), JSON.stringify(await h.tree(), null, 2));} catch {}
  }
  report.error = String(error); report.stack = (error as Error).stack; report.status = 'failed'; process.exitCode = 1;
} finally {
  if (app && app.exitCode === null && app.signalCode === null) {
    report.forced_cleanup = true; app.kill('SIGTERM'); await Promise.race([ended!, h.sleep(2000)]);
    if (app.exitCode === null && app.signalCode === null) {app.kill('SIGKILL'); await ended!;}
  }
  report.process_exit = app ? {code: app.exitCode, signal: app.signalCode} : null;
  peer.kill('SIGTERM'); await Promise.race([peerEnd, h.sleep(5000)]);
  if (peer.exitCode === null && peer.signalCode === null) {peer.kill('SIGKILL'); await peerEnd;}
  await mkdir(join(out, 'diagnostics'), {recursive: true});
  try {for (const name of await readdir(join(data, 'logs'))) await writeFile(join(out, 'diagnostics', name), await readFile(join(data, 'logs', name)));} catch {}
  await appLog!?.close(); await peerLog.close();
  await rm(isolated, {recursive: true, force: true});
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  console.log(report.status + ': ' + join(out, 'report.json'));
}
