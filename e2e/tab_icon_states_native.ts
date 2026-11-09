/** OS colour states, background icon motion, and real native menu projection.
 * node e2e/tab_icon_states_native.ts BUILD_PREFIX PYTHON [OUTPUT_DIRECTORY] [PRIMARY_OS]
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, realpath, rm, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
const prefix = resolve(process.argv[2]), python = process.argv[3];
const out = resolve(process.argv[4] ?? '/tmp/zerowork-tab-icons-evidence');
const primary = process.argv[5] ?? 'kylin';
const expectedBackdrop = primary === 'isoft' ? 0xffffffff : 0;
const assetRegistry = await readFile('src/ui/host_os_assets.zig', 'utf8');
const iconIds = Object.fromEntries([...assetRegistry.matchAll(/pub const (\w+) = source\("[^"]+", (\d+)\);/g)].map(match => [match[1], Number(match[2])]));
await mkdir(out, {recursive: true});
const base = await realpath(await mkdtemp('/tmp/zw-tab-icons-'));
const rpc = join(base, 'rpc'), data = join(base, 'data'), peerOut = join(base, 'peer');
await Promise.all([mkdir(rpc), mkdir(data)]);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(pathToFileURL(join(prefix, 'share/zenit/harness/client.ts')).href);
const peerLog = await open(join(out, 'peer.log'), 'w');
const peer = spawn(python, ['e2e/domestic_os_peer.py', '--out', peerOut], {stdio: ['ignore', peerLog.fd, peerLog.fd]});
const peerEnded = new Promise(resolve => peer.once('close', resolve));
let app: ReturnType<typeof spawn> | undefined, ended: Promise<unknown> | undefined, log: any;
const shown = (node: any) => node?.visible !== false && node?.hidden !== true && node?.rect?.w > 0 && node?.rect?.h > 0;
const flat = (node: any): any[] => [node, ...(node.children ?? []).flatMap(flat)];
const report: any = {status: 'running', checks: [], captures: []};
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
const menu = () => h.request('GET', '/zerowork/menu-bar');
const tabs = () => h.request('GET', '/zerowork/tab-icons');
async function tabState(title: string, state: string) {
  return h.waitFor(async () => (await tabs()).find((row: any) => row.title === title && row.state === state && (title !== 'isoft' || (row.rendered_background?.r === 255 && row.rendered_background?.g === 255 && row.rendered_background?.b === 255 && row.rendered_background?.a === 255 && row.rendered_shape === 'ellipse' && !row.rendered_vector_fill))) ?? null, 20000);
}
async function menuRow(title: string, accept: (row: any) => boolean) {
  return h.waitFor(async () => {
    const row = (await menu()).rows?.find((row: any) => row.title === title);
    return row && accept(row) ? row : null;
  }, 20000);
}
async function capture(name: string) {
  await h.mouseMove(900, 650);
  await h.sleep(120);
  const icons = (await h.query('tabs.type_icon')).filter(shown);
  const hosts = (await h.query('sidebar.host.icon')).filter(shown);
  await writeFile(join(out, `${name}.json`), JSON.stringify({icons, hosts, tabs: await tabs(), menu: await menu()}, null, 2));
  assert((await h.screenshot(join(out, `${name}.png`))).ok);
  report.captures.push(name);
}
try {
  const ready = await h.waitFor(async () => {try {return JSON.parse(await readFile(join(peerOut, 'ready.json'), 'utf8'));} catch {return null;}}, 15000);
  await writeFile(join(data, 'config.toml'), '[updates]\nauto_check=false\n[ui]\ntheme="dark"\nfont_family="Menlo"\n[ssh]\nauto_reconnect=false\n');
  await writeFile(join(data, 'known_hosts'), ready.known_host);
  let hosts = '[registry]\nschema_version=2\nrevision=1\nnext_connection_id=3\nnext_group_id=1\n';
  for (const [i, kind] of [primary, 'uos'].entries()) hosts += `[[hosts]]\nconnection_id=${i + 1}\nrevision=1\nname="${kind}"\nprotocol="ssh"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${kind}"\nauth_mode="password"\nauth={password="fixture-only"}\nauto_shell_integration=false\ncommand_info=false\n`;
  await writeFile(join(data, 'hosts.toml'), hosts, {mode: 0o600});
  log = await open(join(out, 'app.log'), 'w');
  app = spawn(join(prefix, 'bin/zerowork'), [], {env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'}, stdio: ['ignore', log.fd, log.fd]});
  ended = new Promise(resolve => app!.once('close', resolve));
  await h.waitForServerReady();
  await h.resizeWindow(1440, 900);
  for (const kind of [primary, 'uos']) {
    const row = await h.waitFor(async () => (await h.query('sidebar.host')).find((node: any) => shown(node) && flat(node).some(child => child.test_id === 'sidebar.host.name' && child.text === kind)) ?? null);
    await h.mouseMove(row.rect.x + 55, row.rect.y + row.rect.h / 2);
    const connect = await h.waitFor(async () => (await h.query('sidebar.host.connect')).find((node: any) => shown(node) && node.rect.y >= row.rect.y && node.rect.y < row.rect.y + row.rect.h) ?? null);
    await h.clickAt(connect.rect.x + connect.rect.w / 2, connect.rect.y + connect.rect.h / 2);
    await h.waitFor(async () => {try {await readFile(join(peerOut, `probed-${kind}`)); return true;} catch {return null;}}, 15000);
    await h.waitFor(async () => (await tabs()).find((row: any) => row.title === kind && row.icon === iconIds[kind] && row.state === 'normal') ?? null, 15000);
    await h.sleep(400);
    await writeFile(join(peerOut, `output-${kind}`), `MENU_ROW_${kind}\r\n`);
    await menuRow(kind, row => row.original_colours && row.has_icon && row.icon_tint === 0xffffffff && row.icon_backdrop === (kind === primary ? expectedBackdrop : 0));
  }
  await capture('01-original');
  assert.equal((await tabState(primary, 'normal')).backdrop, expectedBackdrop);
  report.checks.push(`${primary} and UOS preserve original artwork in actual Tab and native menu, with the expected separate backplate`);
  await writeFile(join(peerOut, `output-${primary}`), 'BACKGROUND_ACTIVITY\r\n');
  await menuRow(primary, row => row.bouncing && row.original_colours);
  const positions: number[] = [];
  for (let i = 0; i < 18; i++) {
    const icon = (await h.query('tabs.type_icon')).filter(shown)[0];
    positions.push(icon.translate_y ?? 0);
    await h.sleep(75);
  }
  assert(Math.max(...positions) - Math.min(...positions) > 1, 'background icon visibly moves');
  report.motion = positions;
  await capture('02-background-activity');
  report.checks.push('Background terminal output drives icon bounce while preserving original colour; native list receives the same activity state');
  await writeFile(join(peerOut, `drop-${primary}`), 'drop');
  const failed = await tabState(primary, 'failed');
  assert.equal(failed.backdrop, expectedBackdrop);
  assert(!failed.original && ((failed.tint >>> 24) & 255) > ((failed.tint >>> 16) & 255) + 30);
  await capture('03-disconnected-red');
  report.failed = failed;
  report.checks.push('Real transport loss turns the Tab and shared menu projection red while saved host artwork retains source colours');
  await h.clickAt((await visible('tabs.tab.1')).rect.x + 50, (await visible('tabs.tab.1')).rect.y + 15);
  await rm(join(peerOut, `drop-${primary}`));
  await writeFile(join(peerOut, `hold-shell-${primary}`), 'hold');
  await h.clickTestId('remote.notice.reconnect');
  await h.waitFor(async () => {try {await readFile(join(peerOut, `held-shell-${primary}`)); return true;} catch {return null;}}, 15000);
  const connecting = await tabState(primary, 'connecting');
  assert(!connecting.original);
  assert.equal(connecting.backdrop, expectedBackdrop);
  report.connecting = connecting;
  await capture('04-reconnecting-gray');
  report.checks.push('A real pending SSH shell request leaves the reconnecting Tab gray');
  await rm(join(peerOut, `hold-shell-${primary}`));
  await h.waitFor(async () => !(await h.query('remote.notice')).some(shown) || null, 20000);
  assert((await tabState(primary, 'normal')).original);
  await capture('05-reconnected-original');
  report.checks.push('Successful reconnection restores the original OS logo');
  await writeFile(join(peerOut, `exit-${primary}`), 'exit');
  await h.waitFor(async () => (await h.query('remote.notice.title')).find((node: any) => shown(node) && node.text?.includes('已退出')) ?? null, 20000);
  assert((await tabState(primary, 'normal')).original);
  await capture('06-normal-exit-original');
  report.checks.push('Normal remote exit keeps the original logo rather than applying a connection warning colour');
  report.status = 'passed';
} catch (error) {
  report.status = 'failed'; report.error = String(error); process.exitCode = 1;
  if (app && app.exitCode === null) await capture('failure').catch(() => {});
} finally {
  await rm(join(peerOut, `hold-shell-${primary}`), {force: true});
  if (app?.exitCode === null && app.signalCode === null) app.kill('SIGTERM');
  if (ended) await ended;
  if (app?.pid) await cleanupOwnedBridgeDirectories(app.pid);
  if (peer.exitCode === null && peer.signalCode === null) peer.kill('SIGTERM');
  await peerEnded;
  await log?.close(); await peerLog.close();
  await rm(base, {recursive: true, force: true});
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
}
console.log(`${report.status}: ${out}`);
