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
];
let hosts = '[registry]\nschema_version=2\nrevision=1\nnext_connection_id=10\nnext_group_id=1\n';
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
    if (fixture.hops === null) {
      assert(!count, `${fixture.name}: unavailable route must not claim zero hops`);
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
    const hint = await h.waitFor(async () => (await h.query('sidebar.host.info')).find((node: any) => shown(node) && text(node).includes(fixture.route)) ?? null);
    const count = visibleFlat(await row(fixture.name)).find(node => node.test_id === 'sidebar.host.hops');
    if (fixture.hops === null) assert(!count, `${fixture.name}: invalid payload must not claim zero hops`);
    else assert.equal(count?.text, String(fixture.hops), `${fixture.name}: hovered hop count`);
    report.checks.push({name: fixture.name, hops: fixture.hops, hint: text(hint)});
    if (fixture.name === 'KVM-multi' || fixture.name === 'KVM-missing') {
      assert((await h.screenshot(join(out, `${fixture.name}.png`))).ok);
    }
    await h.mouseMove(900, 700);
    await h.waitFor(async () => !(await h.query('sidebar.host.info')).some(shown) || null);
  }
  assert((await h.clickTestId('sidebar.collapse')).ok);
  await h.waitFor(async () => (await h.query('sidebar.restore')).some(shown) || null);
  assert((await h.clickTestId('sidebar.restore')).ok);
  await h.waitFor(async () => (await h.query('sidebar.host')).filter(shown).length === fixtures.length || null);
  await h.mouseMove(900, 700);
  await h.waitFor(async () => visibleFlat(await row('Jump-A')).some(node => node.test_id === 'sidebar.host.hops') || null);
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
