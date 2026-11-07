/** Captured edge selection in real Local/SSH terminals, with a stationary pointer. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, realpath, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';

const prefix = resolve(process.argv[2] ?? '/tmp/zw-terminal-drag-build');
const out = resolve(process.argv[3] ?? '/tmp/zw-terminal-drag-verification');
await mkdir(out, {recursive: true});
const isolated = await realpath(await mkdtemp('/tmp/zw-terminal-drag-'));
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc');
await mkdir(data); await mkdir(rpc);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const peerSource = (await readFile('e2e/ssh_aux_download_loopback.py', 'utf8'))
  .replace('                channel.sendall(banner)', '                channel.sendall(b"".join(("SSH-ROW-%04d\\r\\n" % i).encode() for i in range(600)) + banner)');
const peerLog = await open(join(out, 'peer.log'), 'w');
const peer = spawn(process.env.ZW_TEST_PYTHON ?? 'python3', ['-c', `import sys\nsys.path.insert(0,${JSON.stringify(resolve('e2e'))})\n` + peerSource, '--out', join(isolated, 'peer')], {stdio: ['ignore', peerLog.fd, peerLog.fd]});
const peerEnd = new Promise(r => peer.once('close', r));
const appLog = await open(join(out, 'app.log'), 'w');
let app: ReturnType<typeof spawn> | undefined, appEnd: Promise<unknown> | undefined;
const report: any = {status: 'running', isolated, checks: [], captures: []};
const flat = (n: any): any[] => [n, ...(n.children ?? []).flatMap(flat)];
const shown = (n: any) => n?.rect?.w > 0 && n.rect.h > 0 && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0;
const text = (n: any): string => (n.text ?? '') + (n.children ?? []).map(text).join('');
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
async function click(id: string) {
  const n = await visible(id);
  assert((await h.clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok);
  await h.sleep(120);
}
async function capture(name: string) {
  const path = join(out, name + '.png');
  assert((await h.screenshot(path)).ok); report.captures.push(path);
}
async function dragCheck(label: string) {
  const surface = await visible('terminal.surface');
  const viewport = flat(surface).find(n => n.test_id === 'terminal.surface.viewport' && shown(n)).rect;
  const first = async () => {
    const root = await visible('terminal.surface');
    const rows = flat(root).filter(n => n.test_id?.startsWith('terminal.surface.row.') && shown(n) && n.rect.y + n.rect.h > viewport.y);
    rows.sort((a, b) => a.rect.y - b.rect.y);
    for (const row of rows) {
      const match = text(row).match(new RegExp(label.toUpperCase() + '-ROW-(\\d+)'));
      if (match) return Number(match[1]);
    }
    return null;
  };
  const x = viewport.x + viewport.w * .35, middle = viewport.y + viewport.h * .5;
  const before = await h.waitFor(first, 10000);
  assert((await h.mouseDown(x, middle)).ok);
  assert((await h.mouseMove(x, viewport.y - 18)).ok);
  await h.sleep(450);
  const up = await first(); assert(up !== null && up < before, `${label}: no upward scroll`);
  // Query and wait without moving the pointer: it must keep scrolling.
  await h.sleep(450);
  const stationary = await first(); assert(stationary !== null && stationary < up, `${label}: stationary drag stopped`);
  await capture(label + '-up-selection');
  assert((await h.mouseMove(x, middle)).ok);
  await h.sleep(100);
  const center = await first(); await h.sleep(200);
  assert.equal(await first(), center, `${label}: center did not stop scrolling`);
  assert((await h.mouseMove(x, viewport.y + viewport.h + 18)).ok);
  await h.sleep(450);
  const down = await first(); assert(down !== null && down > stationary!, `${label}: no downward scroll`);
  await capture(label + '-down-selection');
  assert((await h.mouseUp(x, viewport.y + viewport.h + 18)).ok);
  await h.sleep(100);
  const released = await first(); await h.sleep(200);
  assert.equal(await first(), released, `${label}: release did not stop scrolling`);
  report.checks.push({label, before, up, stationary, center, down, released});
}
try {
  const ready = await h.waitFor(async () => {
    try { return JSON.parse(await readFile(join(isolated, 'peer/ready.json'), 'utf8')); } catch { return null; }
  }, 15000);
  await writeFile(join(data, 'config.toml'), '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n');
  await writeFile(join(data, 'hosts.toml'), `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Drag Selection SSH"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
  app = spawn(join(prefix, 'bin/zerowork'), [], {env: {...process.env, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0'}, stdio: ['ignore', appLog.fd, appLog.fd]});
  appEnd = new Promise(r => app!.once('close', r));
  await h.waitForServerReady(60000); await h.resizeWindow(1100, 760);
  await click('workspace.empty.local'); await visible('terminal.surface'); await h.sleep(800);
  await click('terminal.surface'); await h.type_("printf 'LOCAL-ROW-%04d\\n' {0..599}"); await h.key('return');
  await h.waitFor(async () => text(await visible('terminal.surface')).includes('LOCAL-ROW-0599') || null, 15000);
  await dragCheck('local');
  const host = (await h.query('sidebar.host')).find((n: any) => shown(n) && text(n).includes('Drag Selection SSH'));
  assert(host);
  await h.mouseMove(host.rect.x + host.rect.w - 20, host.rect.y + host.rect.h / 2);
  await click('sidebar.host.connect');
  await h.waitFor(async () => {
    const modal = (await h.query('plugin.challenge.modal')).find(shown);
    if (modal) {
      if (flat(modal).some(n => n.test_id === 'plugin.challenge.choice.0' && shown(n))) {
        assert(text(modal).includes(ready.fingerprint)); await click('plugin.challenge.choice.0');
      } else if (flat(modal).some(n => n.test_id === 'plugin.challenge.secret' && shown(n))) {
        await click('plugin.challenge.secret'); await h.type_(ready.password); await click('plugin.challenge.submit');
      }
    }
    return text(await visible('terminal.surface')).includes('SSH-ROW-0599') || null;
  }, 30000);
  await dragCheck('ssh');
  report.status = 'passed';
} catch (error) {
  report.status = 'failed'; report.error = String(error); process.exitCode = 1;
  if (app) await capture('failure').catch(() => {});
} finally {
  if (app && app.exitCode === null && app.signalCode === null) {
    try {
      await h.request('POST', '/zerowork/windows', {action: 'quit'});
      for (let i = 0; i < 60 && app.exitCode === null && app.signalCode === null; i++) {
        for (const id of ['groups.close.accept', 'local.close.accept', 'session.close.accept']) {
          if ((await h.query(id)).some(shown)) await h.clickTestId(id);
        }
        await Promise.race([appEnd, h.sleep(100)]);
      }
    } catch {}
    // Closing the last window removes RPC before process cleanup finishes.
    await Promise.race([appEnd, h.sleep(10000)]);
    if (app.exitCode === null && app.signalCode === null) { report.forced_quit = true; app.kill('SIGTERM'); }
    await appEnd;
    report.app_exit = {code: app.exitCode, signal: app.signalCode};
    if (report.forced_quit || app.exitCode !== 0) { report.status = 'failed'; process.exitCode = 1; }
  }
  peer.kill('SIGTERM'); await peerEnd;
  await appLog.close(); await peerLog.close();
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report));
}
