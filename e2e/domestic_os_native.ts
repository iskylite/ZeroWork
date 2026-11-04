/** Actual SSH discovery and native colour artwork; all hosts are owned loopback fixtures.
 * node e2e/domestic_os_native.ts BUILD_PREFIX PYTHON [OUTPUT_DIRECTORY] [--international|--audit|--contrast|--graphical]
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, readdir, realpath, rm, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';

const prefix = resolve(process.argv[2] ?? 'zig-out');
const python = process.argv[3] ?? 'python3';
const out = resolve(process.argv[4] ?? '/tmp/zerowork-domestic-os-evidence');
await mkdir(out, {recursive: true});
const base = await realpath(await mkdtemp('/tmp/zw-domestic-os-'));
const h = await import(pathToFileURL(join(prefix, 'share/zenit/harness/client.ts')).href);
const international = process.argv[5] === '--international';
const audit = process.argv[5] === '--audit';
const contrast = process.argv[5] === '--contrast';
const graphical = process.argv[5] === '--graphical';
const kinds = graphical
  ? ['openkylin', 'ubuntukylin', 'loongnix']
  : contrast
  ? ['debian', 'alpine', 'freebsd', 'bclinux', 'netbsd', 'redflag', 'isoft', 'uos']
  : audit
  ? ['rhel', 'neokylin', 'bclinux', 'isoft', 'nfs', 'amazonlinux', 'alinux', 'euleros', 'tencentos']
  : international
  ? ['rhel', 'centos', 'almalinux', 'oraclelinux', 'sles', 'opensuse', 'amazonlinux', 'nixos', 'gentoo', 'kali', 'linuxmint', 'manjaro', 'openbsd', 'netbsd']
  : ['kylin', 'neokylin', 'openkylin', 'ubuntukylin', 'uos', 'deepin', 'openeuler', 'euleros', 'anolis', 'opencloudos', 'tencentos', 'alinux', 'loongnix', 'aosc', 'bclinux', 'kylinsec', 'nfs', 'linx', 'isoft', 'redflag'];
const releaseIds: Record<string, string> = {oraclelinux: 'ol', opensuse: 'opensuse-leap', amazonlinux: 'amzn'};
const batchSize = graphical ? 3 : contrast ? 8 : audit ? 5 : international ? 7 : 10;
const assetRegistry = await readFile('src/ui/host_os_assets.zig', 'utf8');
const iconIds = Object.fromEntries([...assetRegistry.matchAll(/pub const (\w+) = source\("[^"]+", (\d+)\);/g)].map(match => [match[1], Number(match[2])]));
const peerOut = join(base, 'peer');
const peerLog = await open(join(out, 'peer.log'), 'w');
const peer = spawn(python, ['e2e/domestic_os_peer.py', '--out', peerOut], {stdio: ['ignore', peerLog.fd, peerLog.fd]});
const peerEnded = new Promise(resolve => peer.once('close', resolve));
const shown = (node: any) => node?.visible !== false && node?.hidden !== true && node?.rect?.w > 0 && node?.rect?.h > 0;
const flat = (node: any): any[] => [node, ...(node.children ?? []).flatMap(flat)];
const report: any = {status: 'running', checks: [], captures: []};
try {
  const ready = await h.waitFor(async () => {
    try { return JSON.parse(await readFile(join(peerOut, 'ready.json'), 'utf8')); } catch { return null; }
  }, 15000);
  for (let batch = 0; batch < Math.ceil(kinds.length / batchSize); batch++) {
    const selected = kinds.slice(batch * batchSize, batch * batchSize + batchSize);
    const data = join(base, `data-${batch}`), rpc = join(base, `rpc-${batch}`);
    await Promise.all([mkdir(data), mkdir(rpc)]);
    process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
    const theme = process.env.ZEROWORK_OS_TEST_THEME ?? (batch ? 'sauber' : 'dark');
    await writeFile(join(data, 'config.toml'), `[updates]\nauto_check=false\n[ui]\ntheme="${theme}"\n`);
    await writeFile(join(data, 'known_hosts'), ready.known_host);
    let hosts = `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=11\nnext_group_id=1\n`;
    for (const [i, kind] of selected.entries()) {
      hosts += `[[hosts]]\nconnection_id=${i + 1}\nrevision=1\nname="${kind}"\nprotocol="ssh"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${kind}"\nauth_mode="password"\nauth={password="fixture-only"}\nauto_shell_integration=false\ncommand_info=false\n`;
    }
    await writeFile(join(data, 'hosts.toml'), hosts, {mode: 0o600});
    const log = await open(join(out, `app-${batch}.log`), 'w');
    const app = spawn(join(prefix, 'bin/zerowork'), [], {
      env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'},
      stdio: ['ignore', log.fd, log.fd],
    });
    const ended = new Promise(resolve => app.once('close', resolve));
    try {
      await h.waitForServerReady();
      await h.resizeWindow(1440, 900);
      for (const kind of selected) {
        const row = await h.waitFor(async () => (await h.query('sidebar.host')).find((node: any) => shown(node) && flat(node).some(child => child.test_id === 'sidebar.host.name' && child.text === kind)) ?? null);
        await h.mouseMove(row.rect.x + 55, row.rect.y + row.rect.h / 2);
        const connect = await h.waitFor(async () => (await h.query('sidebar.host.connect')).find((node: any) => shown(node) && node.rect.y >= row.rect.y && node.rect.y < row.rect.y + row.rect.h) ?? null);
        assert((await h.clickAt(connect.rect.x + connect.rect.w / 2, connect.rect.y + connect.rect.h / 2)).ok);
        await h.waitFor(async () => {
          try {
            const files = (await readdir(join(data, 'cache'))).filter(name => name.startsWith('os-'));
            const values = await Promise.all(files.map(name => readFile(join(data, 'cache', name), 'utf8')));
            return values.includes(kind) || null;
          } catch { return null; }
        }, 20000);
        const probe = await readFile(join(peerOut, `probed-${kind}`), 'utf8');
        assert(['freebsd', 'openbsd', 'netbsd'].includes(kind) ? probe.trim() === ({freebsd: 'FreeBSD', openbsd: 'OpenBSD', netbsd: 'NetBSD'}[kind]) : probe.includes(`ID="${releaseIds[kind] ?? kind}"`));
        const tab = await h.waitFor(async () => (await h.request('GET', '/zerowork/tab-icons')).find((item: any) => item.title === kind && item.original && item.state === 'normal') ?? null, 15000);
        assert.equal(tab.icon, iconIds[kind]);
        if (contrast || graphical) {
          await writeFile(join(peerOut, `output-${kind}`), `CONTRAST_${kind}\r\n`);
          await h.waitFor(async () => (await h.request('GET', '/zerowork/menu-bar')).rows?.find((item: any) => item.title === kind && item.has_icon && item.original_colours && item.icon_backdrop === (kind === 'isoft' ? 0xffffffff : 0)) ?? null, 15000);
        }
        await h.mouseMove(900, 700);
        await h.sleep(180);
        assert((await h.screenshot(join(out, `${kind}.png`))).ok);
        report.checks.push({os: kind, probe: 'actual loopback SSH exec', cached: kind, theme});
        report.captures.push(`${kind}.png`);
      }
      // Rebuilding the sidebar must reuse the discovered tags, not Linux.
      assert((await h.clickTestId('sidebar.collapse')).ok);
      await h.waitFor(async () => (await h.query('sidebar.restore')).some(shown) || null);
      assert((await h.clickTestId('sidebar.restore')).ok);
      await h.mouseMove(900, 700);
      await h.sleep(250);
      assert((await h.screenshot(join(out, `batch-${batch}-restored.png`))).ok);
      await writeFile(join(out, `batch-${batch}-nodes.json`), JSON.stringify({hosts: await h.query('sidebar.host'), tabs: await h.query('tabs.type_icon')}, null, 2));
    } catch (error) {
      await h.screenshot(join(out, `failure-${batch}.png`)).catch(() => {});
      await writeFile(join(out, `failure-${batch}.json`), JSON.stringify(await h.tree().catch(() => ({})), null, 2));
      throw error;
    } finally {
      if (app.exitCode === null && app.signalCode === null) app.kill('SIGTERM');
      await ended;
      await cleanupOwnedBridgeDirectories(app.pid!);
      await log.close();
    }
  }
  assert(!(await readdir(peerOut)).includes('unexpected-exec.txt'));
  report.status = 'passed';
} catch (error) {
  report.status = 'failed';
  report.error = String(error);
  process.exitCode = 1;
} finally {
  if (peer.exitCode === null && peer.signalCode === null) peer.kill('SIGTERM');
  await peerEnded;
  await peerLog.close();
  await rm(base, {recursive: true, force: true});
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
}
console.log(`${report.status}: ${out}`);
