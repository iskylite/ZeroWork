/** Real local/SSH windows: fractional wheel movement, overscan, and boundaries. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, realpath, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';

const prefix = resolve(process.argv[2] ?? '/tmp/zw-pixel-scroll-build');
const out = resolve(process.argv[3] ?? '/tmp/zw-pixel-scroll-verification');
await mkdir(out, {recursive: true});
const isolated = await realpath(await mkdtemp('/tmp/zw-pixel-scroll-'));
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc');
await mkdir(data); await mkdir(rpc);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const peerSource = (await readFile('e2e/ssh_aux_download_loopback.py', 'utf8'))
  .replace('                channel.sendall(banner)', '                channel.sendall(b"".join(("SSH-ROW-%04d\\r\\n" % i).encode() for i in range(600)) + banner)');
const peerLog = await open(join(out, 'peer.log'), 'w');
const peer = spawn('python3', ['-c', `import sys\nsys.path.insert(0,${JSON.stringify(resolve('e2e'))})\n` + peerSource, '--out', join(isolated, 'peer')], {stdio: ['ignore', peerLog.fd, peerLog.fd]});
const peerEnd = new Promise(r => peer.once('close', r));
let app: ReturnType<typeof spawn> | undefined, appEnd: Promise<unknown> | undefined;
const appLog = await open(join(out, 'app.log'), 'w');
const report: any = {status: 'running', isolated, checks: [], captures: []};
const flatten = (n: any): any[] => [n, ...(n.children ?? []).flatMap(flatten)];
const shown = (n: any) => n?.rect?.w > 0 && n.rect.h > 0 && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0;
const content = (n: any): string => (n.text ?? '') + (n.children ?? []).map(content).join('');
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
async function scrollCheck(id: string, marker: string, label: string) {
  const root = await visible(id), r = root.rect;
  const position = async () => flatten(await visible(id)).find(n => n.text?.includes(marker) && shown(n))?.rect.y;
  const before = await h.waitFor(position, 15000);
  await capture(label + '-before');
  let displacement = 0;
  const samples = [];
  for (const pixels of [0.5, 0.25, 3, 7, -2.25]) {
    await h.scrollAt(r.x + r.w * .6, r.y + r.h * .5, 0, pixels);
    displacement += pixels;
    await h.waitFor(async () => {
      const y = await position();
      return y !== undefined && Math.abs(y - before - displacement) < .01 || null;
    }, 5000);
    samples.push({pixels, displacement, actual: (await position()) - before});
  }
  report.checks.push({label, samples});
  await capture(label + '-fractional');
  // More than one row must remain continuous, with content at both edges.
  await h.scrollAt(r.x + r.w * .6, r.y + r.h * .5, 0, 200.5);
  await h.sleep(150); await capture(label + '-scrolled');
  await h.scrollAt(r.x + r.w * .6, r.y + r.h * .5, 0, -100000);
  await h.waitFor(async () => content(await visible(id)).includes(label === 'local' ? 'LOCAL-ROW-0599' : 'SSH-ROW-0599') || null, 10000);
  await capture(label + '-bottom');
}
try {
  const ready = await h.waitFor(async () => {
    try { return JSON.parse(await readFile(join(isolated, 'peer/ready.json'), 'utf8')); } catch { return null; }
  }, 15000);
  await writeFile(join(data, 'config.toml'), '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n');
  await writeFile(join(data, 'hosts.toml'), `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Pixel Scroll SSH"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
  app = spawn(join(prefix, 'bin/zerowork'), [], {env: {...process.env, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0'}, stdio: ['ignore', appLog.fd, appLog.fd]});
  appEnd = new Promise(r => app!.once('close', r));
  await h.waitForServerReady(60000); await h.resizeWindow(1100, 760);
  await click('workspace.empty.local'); await visible('terminal.surface'); await h.sleep(800);
  await click('terminal.surface'); await h.type_("printf 'LOCAL-ROW-%04d\\n' {0..599}"); await h.key('return');
  await scrollCheck('terminal.surface', 'LOCAL-ROW-0580', 'local');
  const host = (await h.query('sidebar.host')).find((n: any) => shown(n) && content(n).includes('Pixel Scroll SSH'));
  assert(host); assert((await h.clickAt(host.rect.x + 70, host.rect.y + host.rect.h / 2)).ok);
  await h.waitFor(async () => {
    const modal = (await h.query('plugin.challenge.modal')).find(shown);
    if (modal) {
      if (flatten(modal).some(n => n.test_id === 'plugin.challenge.choice.0' && shown(n))) {
        assert(content(modal).includes(ready.fingerprint)); await click('plugin.challenge.choice.0');
      } else if (flatten(modal).some(n => n.test_id === 'plugin.challenge.secret' && shown(n))) {
        await click('plugin.challenge.secret'); await h.type_(ready.password); await click('plugin.challenge.submit');
      }
    }
    return (await h.query('status.connection.identity')).some((n: any) => shown(n) && content(n).includes('已连接')) || null;
  }, 30000);
  await scrollCheck('terminal.input', 'SSH-ROW-0580', 'ssh');
  report.status = 'passed';
} catch (error) {
  report.status = 'failed'; report.error = String(error); process.exitCode = 1;
  if (app) await capture('failure').catch(() => {});
} finally {
  if (app) { app.kill('SIGTERM'); await appEnd; }
  peer.kill('SIGTERM'); await peerEnd;
  await appLog.close(); await peerLog.close();
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report));
}
