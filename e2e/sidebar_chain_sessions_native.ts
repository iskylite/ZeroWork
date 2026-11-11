/** Sidebar chain entry in the actual main Metal window, with owned SSH/SFTP.
 * node e2e/sidebar_chain_sessions_native.ts BUILD_PREFIX OUTPUT_DIRECTORY
 * Uses public synthetic Harness input; no external hosts or user data.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir, mkdtemp, open, readFile, realpath, rm, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';

const prefix = resolve(process.argv[2] ?? 'zig-out');
const out = resolve(process.argv[3] ?? '/tmp/zw-sidebar-chain-sessions');
await mkdir(out, {recursive: true});
const base = await realpath(await mkdtemp('/tmp/zw-chain-sessions-'));
const data = join(base, 'data'), rpc = join(base, 'rpc');
await Promise.all([mkdir(data), mkdir(rpc)]);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(pathToFileURL(join(prefix, 'share/zenit/harness/client.ts')).href);
const peerLog = await open(join(out, 'peer.log'), 'w');
const peer = spawn(process.env.ZW_TEST_PYTHON ?? 'python3', ['e2e/builtin_records_ssh_peer.py', '--out', join(out, 'peer'), '--sftp-root', join(base, 'files')], {env: {...process.env, ZW_TEST_CHANNEL_AUDIT: '1'}, stdio: ['ignore', peerLog.fd, peerLog.fd]});
const peerEnded = new Promise(done => peer.once('close', done));
const log = await open(join(out, 'app.log'), 'w');
let app: ReturnType<typeof spawn> | undefined;
let appEnded: Promise<unknown> | undefined;
const report: any = {status: 'running', checks: [], captures: [], limits: ['Public synthetic mouse/keyboard on the actual native Metal window; no physical input or VoiceOver claim.', 'SSH and SFTP connect only to this run’s owned 127.0.0.1 peer. KVM exercises its real renderer in a failed loopback connection state.']};
const shown = (n: any) => n?.visible !== false && n?.hidden !== true && (n?.effective_opacity ?? 1) > 0.01 && n?.rect?.w > 0 && n?.rect?.h > 0;
const flat = (n: any): any[] => [n, ...(n.children ?? []).flatMap(flat)];
const text = (n: any): string => flat(n).map(n => n.text ?? '').join('');
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
const state = () => h.request('POST', '/zerowork/windows', {action: 'snapshot'});
async function channels(transport: number) { return JSON.parse(await readFile(join(out, 'peer', `channels-${transport}.json`), 'utf8')).channels; }
async function row(name: string) {
  return h.waitFor(async () => (await h.query('sidebar.host')).find((n: any) => shown(n) && flat(n).some(n => n.test_id === 'sidebar.host.name' && n.text === name)) ?? null);
}
async function clickNode(n: any) { assert((await h.clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok); }
async function click(id: string) { await clickNode(await visible(id)); }
async function connect(name: string, expected: number) {
  report.stage = `connect ${name} (${expected})`;
  console.log(report.stage);
  const host = await row(name);
  await h.mouseMove(host.rect.x + 30, host.rect.y + host.rect.h / 2);
  const button = await h.waitFor(async () => flat(await row(name)).find(n => n.test_id === 'sidebar.host.connect' && shown(n)) ?? null);
  await clickNode(button);
  await h.waitFor(async () => (await state()).sessions.filter((s: any) => s.lifecycle === 'attached').length === expected || null, 30000);
}
async function marker(name: string) {
  const host = await row(name);
  await h.mouseMove(host.rect.x + 30, host.rect.y + host.rect.h / 2);
  await h.sleep(120);
  const target = flat(await row(name)).find(n => n.test_id === 'sidebar.host.route' && shown(n));
  assert(target?.focusable, 'The marker is a focusable native Button');
  return target;
}
async function openChain(name: string, expectedName: string) {
  report.stage = `open ${name} from active tab`;
  const before = await state();
  await clickNode(await marker(name));
  await h.waitFor(async () => (await h.query('connection.details')).some((n: any) => shown(n) && text(n).includes(expectedName)) || null);
  // Status projection runs every frame; prove the captured card survives it.
  await h.sleep(1100);
  const card = await visible('connection.details');
  assert(text(card).includes(expectedName));
  assert(card.rect.x > 600 && card.rect.y < 100, 'The chain remains anchored at the upper right');
  const after = await state();
  assert.equal(after.sessions.length, before.sessions.length, 'Opening the marker creates no session');
  assert.equal(after.windows[0].active_tab, before.windows[0].active_tab, 'Opening the marker does not activate another tab');
  assert.equal(after.windows[0].selected_connection, before.windows[0].selected_connection, 'Opening the marker does not select another host');
}
async function capture(name: string) {
  assert((await h.screenshot(join(out, name + '.png'))).ok);
  await writeFile(join(out, name + '.json'), JSON.stringify({state: await state(), details: await h.query('connection.details'), feedback: await h.query('sidebar.chain.feedback')}, null, 2));
  report.captures.push(name);
}
try {
  const ready = await h.waitFor(async () => { try { return JSON.parse(await readFile(join(out, 'peer', 'ready.json'), 'utf8')); } catch { return null; } }, 15000);
  await writeFile(join(data, 'known_hosts'), ready.known_host);
  let hosts = '[registry]\nschema_version=2\nrevision=1\nnext_connection_id=5\nnext_group_id=1\n';
  for (const [i, name] of ['Chain-SSH-A', 'Chain-SSH-B', 'Chain-SFTP'].entries()) {
    hosts += `[[hosts]]\nconnection_id=${i + 1}\nrevision=1\nprotocol="${i === 2 ? 'sftp' : 'ssh'}"\nauth_mode="password"\noptions={strict_host_key=true}\nname="${name}"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`;
  }
  const payload = {endpoint: {host: '127.0.0.1', https_port: 1}, username: 'fixture'};
  hosts += `[[hosts]]\nconnection_id=4\nrevision=1\nprotocol="bmc_ikvm"\nname="Chain-KVM"\npayload_version=1\npayload=${JSON.stringify(JSON.stringify(payload))}\n`;
  await writeFile(join(data, 'hosts.toml'), hosts);
  await writeFile(join(data, 'config.toml'), '[updates]\nauto_check=false\n[ui]\ntheme="dark"\n[ssh]\nreconnect_max=0\n');
  const binary = join(prefix, 'bin/zerowork');
  report.binary_sha256 = createHash('sha256').update(await readFile(binary)).digest('hex');
  app = spawn(binary, [], {env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'}, stdio: ['ignore', log.fd, log.fd]});
  appEnded = new Promise(done => app!.once('close', done));
  await h.waitForServerReady(30000);
  assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
  await h.resizeWindow(1440, 900);
  await connect('Chain-SSH-A', 1);
  const a1 = (await state()).sessions.find((s: any) => s.plugin === 'ssh');
  await openChain('Chain-SSH-A', 'Chain-SSH-A');
  await capture('active-ssh-chain');
  await click('connection.details.close');
  await connect('Chain-SSH-A', 2);
  const a2 = (await state()).sessions.find((s: any) => s.plugin === 'ssh' && s.session !== a1.session);
  const activeBefore = [await channels(1), await channels(2)];
  await openChain('Chain-SSH-A', 'Chain-SSH-A');
  assert.equal(await channels(1), activeBefore[0], 'Inactive older A transport receives no sample');
  assert((await channels(2)) > activeBefore[1], 'Active A2 transport receives the chain sample');
  report.checks.push('Network audit proves current active same-host tab A2 takes precedence');
  await click('connection.details.close');
  await connect('Chain-SSH-B', 3);
  await click(`tabs.tab.${a1.tab}`);
  await click(`tabs.tab.${(await state()).sessions.find((s: any) => s.plugin === 'ssh' && s.session !== a1.session && s.session !== a2.session).tab}`);
  const recentBefore = [await channels(1), await channels(2)];
  await openChain('Chain-SSH-A', 'Chain-SSH-A');
  assert((await channels(1)) > recentBefore[0], 'Recently used A1 receives the chain sample');
  assert.equal(await channels(2), recentBefore[1], 'Later-created A2 receives no sample');
  report.checks.push('Network audit proves recent same-host tab A1 wins over later-created A2 while B is active');
  await capture('other-ssh-chain');
  await click('connection.details.close');
  report.checks.push('Active and non-active host chain opens at upper right with multiple real SSH sessions; tab and host selection remain unchanged');

  await connect('Chain-SFTP', 4);
  await visible('files.presentation');
  // Keep captured local file views inside this run's disposable directory.
  let local = await visible('files.local');
  await clickNode(flat(local).find(n => n.test_id === 'files.path.edit' && shown(n)));
  local = await visible('files.local');
  await clickNode(flat(local).find(n => n.test_id === 'files.path' && shown(n)));
  await h.key('a', {cmd: true}); await h.type_(base); await h.key('return');
  await openChain('Chain-SSH-A', 'Chain-SSH-A');
  await capture('sftp-active-ssh-chain');
  await click('connection.details.close');
  report.checks.push('Captured SSH chain survives 1.1 seconds of real SFTP active-tab status projection');
  const beforeFile = await state();
  await clickNode(await marker('Chain-SFTP'));
  await h.waitFor(async () => (await h.query('sidebar.chain.feedback')).some((n: any) => shown(n) && text(n).includes('SFTP 暂不支持查看实时连接链路')) || null);
  assert(!(await h.query('connection.details')).some(shown));
  assert.equal((await state()).sessions.length, beforeFile.sessions.length);
  await capture('sftp-capability-feedback');
  await h.waitFor(async () => !(await h.query('sidebar.chain.feedback')).some((n: any) => shown(n) && text(n).includes('SFTP 暂不支持查看实时连接链路')) || null, 8000);
  report.checks.push('Connected SFTP reports unsupported live-chain capability, never "not connected"; local info expires');

  // Pointer focus followed by real key dispatch on the native marker Button.
  const keyboardMarker = await marker('Chain-SFTP');
  await clickNode(keyboardMarker);
  await h.key('tab', {shift: true});
  assert.notEqual((await h.focused()).test_id, 'sidebar.host.route');
  await h.key('tab');
  assert.equal((await h.focused()).test_id, 'sidebar.host.route', 'Tab reaches the route marker');
  for (const key of ['return', 'space']) {
    assert.equal((await h.focused()).test_id, 'sidebar.host.route');
    const before = await state();
    assert((await h.key(key)).ok);
    const after = await state();
    assert.equal(after.sessions.length, before.sessions.length);
    assert.equal(after.windows[0].selected_connection, before.windows[0].selected_connection);
  }
  report.checks.push('Tab reaches the marker; Return and Space consume activation without selecting or connecting the host');

  const kvmHost = await row('Chain-KVM');
  report.stage = 'KVM failed loopback renderer';
  await h.mouseMove(kvmHost.rect.x + 30, kvmHost.rect.y + kvmHost.rect.h / 2);
  await clickNode(flat(await row('Chain-KVM')).find(n => n.test_id === 'sidebar.host.connect' && shown(n)));
  await visible('bmc.content');
  await openChain('Chain-SSH-A', 'Chain-SSH-A');
  await capture('kvm-active-ssh-chain');
  await click('connection.details.close');
  report.checks.push('Captured SSH chain survives the actual KVM renderer’s active-tab status projection (owned failed loopback endpoint)');
  report.status = 'passed';
} catch (error) {
  report.status = 'failed'; report.error = String(error); process.exitCode = 1;
  await capture('failure').catch(() => {});
} finally {
  if (app && app.exitCode === null && app.signalCode === null) {
    await h.request('POST', '/zerowork/windows', {action: 'quit'}).catch(() => {});
    await Promise.race([appEnded, h.sleep(5000)]);
    if (app.exitCode === null && app.signalCode === null) { app.kill('SIGTERM'); await appEnded; }
  }
  report.exit_code = app?.exitCode;
  peer.kill('SIGTERM'); await peerEnded;
  await log.close(); await peerLog.close();
  if (app?.pid) await cleanupOwnedBridgeDirectories(app.pid);
  await rm(base, {recursive: true, force: true});
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
}
console.log(JSON.stringify(report));
