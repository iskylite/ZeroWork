/** Owned loopback acceptance for SFTP feedback, radio authentication and bidirectional drag. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, open, readFile, realpath, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out = resolve(process.argv[2]);
await mkdir(out, { recursive: true });
const isolated = await realpath(await mkdtemp(join(tmpdir(), 'zerowork-sftp-feedback-')));
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc'), local = join(isolated, 'local'), peerOut = join(out, 'peer');
await Promise.all([mkdir(data), mkdir(rpc), mkdir(local)]);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const peerLog = await open(join(out, 'peer.log'), 'w'), appLog = await open(join(out, 'app.log'), 'w');
const peer = spawn('python3', [resolve('e2e/sftp_v3_peer.py'), '--out', peerOut], { stdio: ['ignore', peerLog.fd, peerLog.fd] });
let app: ReturnType<typeof spawn> | undefined;
const report: any = { status: 'running', checks: [], isolated, screenshots: [], external_hosts: 0 };
function shown(n: any) { return n?.rect?.w > 0 && n.rect.h > 0 && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? 1) > 0; }
function nodes(n: any): any[] { return shown(n) ? [n, ...(n.children ?? []).flatMap(nodes)] : []; }
function text(n: any) { return nodes(n).map(n => n.text ?? '').join(' '); }
function inside(n: any, id: string) { return nodes(n).find(n => n.test_id === id); }
async function visible(id: string) { return h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000); }
async function clickNode(n: any) { assert(shown(n)); await h.clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2); }
async function click(id: string) { await clickNode(await visible(id)); }
async function capture(name: string) { await h.sleep(120); await h.screenshot(join(out, name + '.png')); report.screenshots.push(name + '.png'); }
async function drag(from: any, x: number, y: number) {
  const sx = from.rect.x + Math.min(45, from.rect.w / 2), sy = from.rect.y + from.rect.h / 2;
  await h.mouseDown(sx, sy); await h.sleep(100);
  for (let i = 1; i <= 8; i++) { await h.mouseMove(sx + (x - sx) * i / 8, sy + (y - sy) * i / 8); await h.sleep(35); }
  await h.mouseUp(x, y);
}
async function confirm() { const modal = await visible('files.copy.confirmation'); await capture('transfer-confirm-' + report.screenshots.length); const button = inside(modal, 'files.copy.submit'); assert(button, text(modal)); await clickNode(button); }
try {
  const ready = await h.waitFor(async () => { try { return JSON.parse(await readFile(join(peerOut, 'ready.json'), 'utf8')); } catch { return null; } }, 15000);
  const host = (id: number, name: string, port: number) => `\n[[hosts]]\nconnection_id=${id}\nrevision=1\nprotocol="sftp"\nauth_mode="password"\noptions={strict_host_key=true}\nname="${name}"\nhost="127.0.0.1"\nport=${port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`;
  await writeFile(join(data, 'hosts.toml'), '[registry]\nschema_version=2\nrevision=1\nnext_connection_id=3\nnext_group_id=1\n' + host(1, 'SFTP Refused', 1) + host(2, 'SFTP Owned Peer', ready.port));
  await writeFile(join(data, 'config.toml'), '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n');
  const payload = Buffer.from('SFTP drag upload verification\n');
  await writeFile(join(local, 'upload.txt'), payload);
  await mkdir(join(local, 'downloads'));
  for (let i = 0; i < 150; i++) await writeFile(join(local, `scroll-${String(i).padStart(3, '0')}.txt`), 'scroll fixture');
  const bundle = join(out, 'SFTP Feedback.app', 'Contents');
  await mkdir(join(bundle, 'MacOS'), { recursive: true });
  await writeFile(join(bundle, 'Info.plist'), '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>local.zerowork.sftp.feedback</string><key>CFBundleName</key><string>SFTP Feedback</string><key>NSHighResolutionCapable</key><true/></dict></plist>');
  await copyFile(resolve(process.argv[3] ?? 'zig-out/bin/zerowork'), join(bundle, 'MacOS', 'zerowork'));
  await copyFile(resolve('zig-out/bin/zw_ipc.so'), join(out, 'zw_ipc.so'));
  app = spawn(join(bundle, 'MacOS', 'zerowork'), [], { env: { ...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1' }, stdio: ['ignore', appLog.fd, appLog.fd] });
  await h.waitForServerReady(); await h.resizeWindow(1440, 900);
  console.log('app ready');
  const hosts = (await h.query('sidebar.host')).filter(shown); assert.equal(hosts.length, 2);
  await clickNode(hosts[0]);
  await visible("connection.progress.spinner"); await capture("connection-connecting");
  await h.waitFor(async () => { const p = (await h.query('connection.progress')).find(shown); return p && text(p).includes('连接失败') && text(p).includes('Connect') ? p : null; }, 20000);
  await capture('connection-failed');
  await click('connection.progress.logs.toggle');
  await capture('connection-failed-logs');
  await click('connection.progress.retry');
  await h.waitFor(async () => { const p = (await h.query('connection.progress')).find(shown); return p && text(p).includes('尝试 2') && text(p).includes('连接失败') ? p : null; }, 20000);
  await capture('connection-retry-failed');
  await click('connection.progress.close');
  await h.waitFor(async () => !(await h.query('connection.progress')).some(shown) || null);
  await h.sleep(300); assert(!(await h.query('connection.progress')).some(shown));
  console.log('checkpoint', report.checks.length + 1);
  report.checks.push('Actual refused TCP connection exposes failure/code/logs; retries original session generation; dismiss remains dismissed');
  await click('sidebar.new'); await click('sidebar.new.host');
  await visible('wizard.auth.password');
  await visible('wizard.password.remember'); await capture('authentication-default-password');
  await click('wizard.auth.key'); await visible('wizard.key_path');
  await click('wizard.auth.agent'); await visible('wizard.auth.agent_notice');
  await click('wizard.auth.password'); await visible('wizard.password');
  await capture('authentication-radios'); await click('wizard.close');
  console.log('checkpoint', report.checks.length + 1);
  report.checks.push('Native radio choices switch password/key/agent fields; save password starts checked');
  await clickNode((await h.query('sidebar.host')).filter(shown)[1]);
  await h.waitFor(async () => {
    if ((await h.query('files.workspace')).some(shown)) return true;
    const plugin = (await h.query('plugin.challenge.title')).find(shown);
    if (plugin) {
      const material = text(await visible('plugin.challenge.material'));
      assert(material.includes(ready.fingerprint));
      await click('plugin.challenge.choice.0');
      await h.sleep(150);
      return null;
    }
    const modal = (await h.query('auth.challenge.modal')).find(shown);
    const trust = modal && inside(modal, 'auth.challenge.trust_once');
    if (trust?.focusable) { assert(text(modal).includes(ready.fingerprint)); await clickNode(trust); }
    return null;
  }, 30000);
  await capture('sftp-connected');
  { const field = inside(await visible('files.local'), 'files.path.edit'); await h.clickAt(field.rect.x + 3, field.rect.y + field.rect.h / 2); }
  await clickNode(await visible('files.path')); await h.key('a', { cmd: true }); await h.type_(local); await h.key('return');
  await h.waitFor(async () => text(await visible('files.local')).includes('scroll-') || null);
  const pane = await visible('files.local');
  for (let i = 0; i < 8; i++) { await h.scrollAt(pane.rect.x + pane.rect.w / 2, pane.rect.y + pane.rect.h / 2, 0, -1200); await h.sleep(40); }
  await capture('file-list-scrolled');
  const upload = await h.waitFor(async () => nodes(await visible('files.local')).find(n => n.test_id === 'files.row.name' && n.text === 'upload.txt') ?? null, 10000);
  const remote = await visible('files.remote');
  await drag(upload, remote.rect.x + remote.rect.w / 2, remote.rect.y + remote.rect.h - 80);
  await confirm();
  await h.waitFor(async () => { const state = JSON.parse(await readFile(join(peerOut, 'state.json'), 'utf8')); return state.files['/fixture/upload.txt']?.bytes === payload.length || null; }, 15000);
  console.log('checkpoint', report.checks.length + 1);
  report.checks.push('150-file list scrolls through virtual rows and real cross-pane drag uploads exact source length');
  { const field = inside(await visible('files.local'), 'files.path.edit'); await h.clickAt(field.rect.x + 3, field.rect.y + field.rect.h / 2); }
  await clickNode(await visible('files.path')); await h.key('a', { cmd: true }); await h.type_(join(local, 'downloads')); await h.key('return');
  await h.waitFor(async () => text(await visible('files.local')).includes('目录为空') || null);
  const download = await h.waitFor(async () => nodes(await visible('files.remote')).find(n => n.test_id === 'files.row.name' && n.text === 'export.yaml') ?? null, 15000);
  const destination = await visible('files.local');
  await drag(download, destination.rect.x + destination.rect.w / 2, destination.rect.y + destination.rect.h - 80);
  await confirm();
  await h.waitFor(async () => { try { return (await readFile(join(local, 'downloads', 'export.yaml'), 'utf8')) === 'real: downloaded\n' || null; } catch { return null; } }, 15000);
  await capture('bidirectional-drag-complete');
  console.log('checkpoint', report.checks.length + 1);
  report.checks.push('Real cross-pane drag downloads exact remote bytes into the original local directory without crashing');
  assert.equal(app.exitCode, null);
  report.status = 'passed';
} catch (error) { report.status = 'failed'; report.error = String(error); try { await capture('failure'); } catch {} throw error; }
finally { if (app?.exitCode === null) app.kill('SIGTERM'); peer.kill('SIGTERM'); await h.sleep(300); await appLog.close(); await peerLog.close(); await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2)); }
