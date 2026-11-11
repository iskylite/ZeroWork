/** Saved KVM routes in the production sidebar; isolated config, no connections.
 * node e2e/sidebar_kvm_route_native.ts BUILD_PREFIX [OUTPUT_DIRECTORY]
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, open, realpath, rm, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';

const prefix = resolve(process.argv[2] ?? 'zig-out');
const out = resolve(process.argv[3] ?? '/tmp/zerowork-kvm-route-evidence');
await mkdir(out, {recursive: true});
const base = await realpath(await mkdtemp('/tmp/zw-kvm-route-'));
const data = join(base, 'data'), rpc = join(base, 'rpc');
await Promise.all([mkdir(data), mkdir(rpc)]);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(pathToFileURL(join(prefix, 'share/zenit/harness/client.ts')).href);

const fixtures = [
  {name: 'Jump-A', hops: 0, route: '本机 → Jump-A'},
  {name: 'Jump-B', hops: 1, route: '本机 → Jump-A → Jump-B'},
  {name: 'KVM-direct', hops: 0, route: '本机 → KVM-direct'},
  {name: 'KVM-single', hops: 1, route: '本机 → Jump-B → KVM-single'},
  {name: 'KVM-multi', hops: 2, route: '本机 → Jump-A → Jump-B → KVM-multi'},
  {name: 'KVM-reversed', hops: 2, route: '本机 → Jump-B → Jump-A → KVM-reversed'},
  {name: 'KVM-missing', hops: 1, route: '本机 → 缺失的跳板 → KVM-missing'},
  {name: 'KVM-invalid', hops: null, route: '路径不可用'},
  {name: 'SFTP-single', hops: 1, route: '本机 → Jump-A → SFTP-single'},
  {name: '长路径验收主机名称用于检查完整中文提示内容'.repeat(2) + '最终节点', hops: 0, route: '本机 → ' + '长路径验收主机名称用于检查完整中文提示内容'.repeat(2) + '最终节点'},
];
let hosts = '[registry]\nschema_version=2\nrevision=1\nnext_connection_id=11\nnext_group_id=1\n';
for (const [index, fixture] of fixtures.entries()) {
  const kvm = fixture.name.startsWith('KVM-');
  hosts += `[[hosts]]\nconnection_id=${index + 1}\nrevision=1\nprotocol="${kvm ? 'bmc_ikvm' : index === 8 ? 'sftp' : 'ssh'}"\nname="${fixture.name}"\n`;
  if (kvm) {
    const ids = index === 3 ? [2] : index === 4 ? [1, 2] : index === 5 ? [2, 1] : index === 6 ? [999] : [];
    const payload = index === 7 ? {} : {
      endpoint: {host: '192.0.2.10', https_port: 443}, username: 'demo',
      ...(ids.length ? {access: {ssh_route: {hops: ids.map(asset_id => ({asset_id}))}}} : {}),
    };
    hosts += `payload_version=1\npayload=${JSON.stringify(JSON.stringify(payload))}\n`;
  } else {
    hosts += `host="192.0.2.${index + 1}"\nuser="demo"\nroute=${index === 1 || index === 8 ? '[1]' : '[]'}\n`;
  }
}
await writeFile(join(data, 'config.toml'), '[updates]\nauto_check=false\n[ui]\ntheme="dark"\n');
await writeFile(join(data, 'hosts.toml'), hosts);
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(join(prefix, 'bin/zerowork'), [], {
  env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'},
  stdio: ['ignore', log.fd, log.fd],
});
const ended = new Promise(resolve => app.once('close', resolve));
const shown = (node: any) => node?.visible !== false && node?.hidden !== true && node?.rect?.w > 0 && node?.rect?.h > 0;
const flat = (node: any): any[] => [node, ...(node.children ?? []).flatMap(flat)];
const visibleFlat = (node: any): any[] => shown(node) ? [node, ...(node.children ?? []).flatMap(visibleFlat)] : [];
const text = (node: any) => flat(node).map(node => node.text ?? '').join('');
const report: any = {status: 'running', checks: []};
async function row(name: string) {
  const rows = await h.query('sidebar.host');
  const found = rows.find((node: any) => shown(node) && flat(node).some(child => child.test_id === 'sidebar.host.name' && child.text === name));
  assert(found, `${name}: row visible`);
  return found;
}
async function checkCounts() {
  let alignedX: number | undefined;
  for (const fixture of fixtures) {
    const host = await row(fixture.name);
    const count = visibleFlat(host).find(node => node.test_id === 'sidebar.host.hops');
    if (fixture.hops === null || fixture.hops === 0) {
      assert(!count, `${fixture.name}: only multi-hop routes are marked at rest`);
      continue;
    }
    assert.equal(count?.text, String(fixture.hops), `${fixture.name}: hop count`);
    const icon = visibleFlat(host).find(node => node.test_id === 'sidebar.host.route-icon');
    const badge = visibleFlat(host).find(node => node.test_id === 'sidebar.host.route-badge');
    assert(icon && badge, `${fixture.name}: route icon and badge visible`);
    assert(Math.abs(badge.rect.x - (icon.rect.x + 12)) < 0.5, `${fixture.name}: badge anchored to icon corner`);
    assert(Math.abs(badge.rect.y - (icon.rect.y - 4)) < 0.5, `${fixture.name}: badge anchored above icon`);
    if (alignedX === undefined) alignedX = badge.rect.x;
    else assert(Math.abs(badge.rect.x - alignedX) < 0.5, `${fixture.name}: badges share a column`);
  }
}
try {
  await h.waitForServerReady();
  await h.resizeWindow(1440, 900);
  await h.waitFor(async () => (await h.query('sidebar.host')).filter(shown).length === fixtures.length || null);
  await checkCounts();
  assert((await h.screenshot(join(out, 'sidebar.png'))).ok);
  for (const fixture of fixtures) {
    const host = await row(fixture.name);
    const name = flat(host).find(node => node.test_id === 'sidebar.host.name');
    await h.mouseMove(name.rect.x + Math.min(10, name.rect.w / 2), name.rect.y + name.rect.h / 2);
    const identityExpected = fixture.name.startsWith('长路径') ? fixture.name : fixture.route;
    const hint = await h.waitFor(async () => (await h.query('sidebar.host.info')).find((node: any) => shown(node) && text(node).includes(identityExpected)) ?? null);
    const count = visibleFlat(await row(fixture.name)).find(node => node.test_id === 'sidebar.host.hops');
    if (fixture.hops === null) assert(!count, `${fixture.name}: invalid payload must not claim zero hops`);
    else assert.equal(count?.text, String(fixture.hops), `${fixture.name}: hovered hop count`);
    report.checks.push({name: fixture.name, hops: fixture.hops, hint: text(hint)});
    if (fixture.name === 'KVM-multi' || fixture.name === 'KVM-missing') {
      assert((await h.screenshot(join(out, `${fixture.name}.png`))).ok);
    }
    // The row-tail marker is its own entry: it must explain itself and the
    // click target must never fall back to row selection. An unusable route
    // hides the marker entirely, so it has nothing to hover.
    if (fixture.hops !== null) {
      const route_icon = visibleFlat(await row(fixture.name)).find(node => node.test_id === 'sidebar.host.route-icon');
      assert(route_icon, `${fixture.name}: route marker visible for hover`);
      await h.mouseMove(route_icon.rect.x + route_icon.rect.w / 2, route_icon.rect.y + route_icon.rect.h / 2);
      const action = fixture.name.startsWith('KVM-') ? '点击查看连接详情' : fixture.name === 'SFTP-single' ? 'SFTP 暂不支持查看实时连接链路' : '点击查看连接链路';
      const expected = fixture.hops === 0 ? '连接链路 · 直连' : `连接链路 · 经 ${fixture.hops} 台跳板`;
      const chain_hint = await h.waitFor(async () => (await h.query('sidebar.host.chain-hint')).find((node: any) => shown(node) && text(node).includes(expected)) ?? null);
      assert(text(chain_hint).includes(action));
      if (fixture.name.startsWith('长路径')) assert(Buffer.byteLength(text(chain_hint)) > 192, 'Long hint exceeds the former buffer size');
      assert(text(chain_hint).includes(expected), `${fixture.name}: chain hint "${expected}" in "${text(chain_hint)}"`);
      assert(text(chain_hint).includes(fixture.route), 'Full ordered path survives in the marker hint');
      assert(!(await h.query('sidebar.host.info')).some(shown), 'Identity and marker hints are mutually exclusive');
      if (fixture.name === 'KVM-multi') assert((await h.screenshot(join(out, 'chain-hint.png'))).ok);
      if (fixture.name.startsWith('长路径')) assert((await h.screenshot(join(out, 'long-chain-hint.png'))).ok);
      report.checks.push({name: fixture.name, chainHint: text(chain_hint)});
    }
    await h.mouseMove(900, 700);
    await h.waitFor(async () => !(await h.query('sidebar.host.chain-hint')).some(shown) || null);
    await h.waitFor(async () => !(await h.query('sidebar.host.info')).some(shown) || null);
  }
  // No session exists in this fixture set: the marker must report that instead
  // of opening an invented chain. Hover first so the row's action group has
  // already claimed its width; the marker never moves under the pointer.
  const jump_name = flat(await row('Jump-A')).find(node => node.test_id === 'sidebar.host.name');
  await h.mouseMove(jump_name.rect.x + Math.min(10, jump_name.rect.w / 2), jump_name.rect.y + jump_name.rect.h / 2);
  await h.waitFor(async () => visibleFlat(await row('Jump-A')).some(node => node.test_id === 'sidebar.host.connect') || null);
  const marker = visibleFlat(await row('Jump-A')).find(node => node.test_id === 'sidebar.host.route-icon');
  assert(marker, 'Jump-A: route marker visible');
  await h.mouseMove(marker.rect.x + marker.rect.w / 2, marker.rect.y + marker.rect.h / 2);
  await h.waitFor(async () => (await h.query('sidebar.host.chain-hint')).some(shown) || null);
  const stable = visibleFlat(await row('Jump-A')).find(node => node.test_id === 'sidebar.host.route-icon');
  const before = await h.request('POST', '/zerowork/windows', {action: 'snapshot'});
  assert((await h.clickAt(stable.rect.x + stable.rect.w / 2, stable.rect.y + stable.rect.h / 2)).ok);
  // The marker consumes its own click: the hint it owns closes and the row is
  // not connected by the pass-through status area.
  await h.waitFor(async () => !(await h.query('sidebar.host.chain-hint')).some(shown) || null);
  await h.waitFor(async () => (await h.query('sidebar.chain.feedback')).some((node: any) => shown(node) && text(node).includes('当前没有可查看连接链路的会话')) || null);
  const after = await h.request('POST', '/zerowork/windows', {action: 'snapshot'});
  assert.equal(after.sessions.length, before.sessions.length, 'Marker click does not create a session');
  assert.equal(after.windows[0].selected_connection, before.windows[0].selected_connection, 'Marker click does not select the row');
  assert(!(await h.query('connection.details')).some(shown), 'No invented chain without a session');
  report.checks.push({name: 'no-session', feedback: 'visible', selection: 'unchanged', sessions: after.sessions.length});
  assert((await h.screenshot(join(out, 'chain-click.png'))).ok);
  assert((await h.clickTestId('sidebar.collapse')).ok);
  await h.waitFor(async () => (await h.query('sidebar.restore')).some(shown) || null);
  assert((await h.clickTestId('sidebar.restore')).ok);
  await h.waitFor(async () => (await h.query('sidebar.host')).filter(shown).length === fixtures.length || null);
  await h.mouseMove(900, 700);
  await checkCounts();
  report.status = 'passed';
} catch (error) {
  report.status = 'failed';
  report.error = String(error);
  await h.screenshot(join(out, 'failure.png')).catch(() => {});
  process.exitCode = 1;
} finally {
  if (app.exitCode === null && app.signalCode === null) app.kill('SIGTERM');
  await ended;
  await log.close();
  await cleanupOwnedBridgeDirectories(app.pid!);
  await rm(base, {recursive: true, force: true});
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
}
console.log(`${report.status}: ${out}`);
