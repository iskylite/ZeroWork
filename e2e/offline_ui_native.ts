/** Real Metal UI responsiveness through an owned SSH traffic blackhole. */
import assert from 'node:assert/strict';
import net from 'node:net';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, realpath, open, readFile, writeFile, readdir, rm} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {tmpdir} from 'node:os';
import * as h from '../zig-out/share/zenit/harness/client.ts';

const binary = resolve(process.argv[2]), out = resolve(process.argv[3]);
await mkdir(out, {recursive: false});
const base = await realpath(await mkdtemp(join(tmpdir(), 'zw-offline-ui-')));
const data = join(base, 'data'), rpc = join(base, 'rpc');
await mkdir(data); await mkdir(rpc);
const peerLog = await open(join(out, 'peer.log'), 'w');
const peerDir = join(out, 'peer');
const peer = spawn('python3', ['e2e/ssh_tab_connections_peer.py', '--out', peerDir], {stdio: ['ignore', peerLog.fd, peerLog.fd]});
const peerEnded = new Promise(r => peer.once('close', r));
let offline = false;
const sockets = new Set<net.Socket>();
const proxy = net.createServer(client => {
    sockets.add(client); client.on('close', () => sockets.delete(client)); client.on('error', () => {});
    if (offline) { client.on('data', () => {}); return; }
    const upstream = net.connect({host: '127.0.0.1', port: peerPort});
    sockets.add(upstream); upstream.on('close', () => sockets.delete(upstream)); upstream.on('error', () => client.destroy());
    client.on('data', bytes => { if (!offline) upstream.write(bytes); });
    upstream.on('data', bytes => { if (!offline) client.write(bytes); });
    client.on('end', () => upstream.end()); upstream.on('end', () => client.end());
});
let peerPort = 0;
let app: ReturnType<typeof spawn> | undefined;
let appLog: Awaited<ReturnType<typeof open>> | undefined;
let ended: Promise<unknown> | undefined;
const report: any = {passed: false, scope: 'owned loopback SSH blackhole; actual Metal window and production frame hooks; no physical network configuration changes', checks: []};
const shown = (n: any) => n && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const content = (n: any): string => !shown(n) ? '' : (n.text ?? '') + (n.children ?? []).map(content).join('');
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 12000);
const click = async (id: string, count = 1) => { const n = await visible(id); assert((await h.clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2, count)).ok); };
try {
    const ready = await h.waitFor(async () => { try { return JSON.parse(await readFile(join(peerDir, 'ready.json'), 'utf8')); } catch { return null; } }, 15000);
    peerPort = ready.port;
    await new Promise<void>(r => proxy.listen(0, '127.0.0.1', r));
    const port = (proxy.address() as net.AddressInfo).port;
    await writeFile(join(data, 'known_hosts'), ready.known_host.replace(`]:${peerPort} `, `]:${port} `));
    await writeFile(join(data, 'config.toml'), '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ssh]\nkeepalive_sec=2\nconnect_timeout_sec=1\nreconnect_max=1\nreconnect_backoff=[1,1,1,1,1]\nauto_reconnect=true\n');
    await writeFile(join(data, 'hosts.toml'), `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Offline regression peer"\nhost="127.0.0.1"\nport=${port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
    process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
    appLog = await open(join(out, 'app.log'), 'w');
    app = spawn(binary, [], {env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'}, stdio: ['ignore', appLog.fd, appLog.fd]});
    ended = new Promise(r => app!.once('close', r));
    await h.waitForServerReady(60000); await h.resizeWindow(1280, 800);
    await click('sidebar.host', 2);
    await h.waitFor(async () => content(await visible('workspace.pane')).includes('sshrecords') || null, 20000);
    await h.screenshot(join(out, 'connected.png'));
    offline = true;
    const responseMs: number[] = [];
    // Drop both directions without FIN/RST, including subsequent handshakes.
    // Poll actual UI state across keepalive expiry and the failed reconnect.
    const start = Date.now();
    let failed = false;
    while (Date.now() - start < 15000) {
        const t0 = Date.now();
        const pane = await h.query('workspace.pane');
        responseMs.push(Date.now() - t0);
        const text = pane.map(content).join('');
        if (text.includes('重新连接失败') || text.includes('连接已断开') || text.includes('连接失败')) failed = true;
        await h.resizeWindow(responseMs.length % 2 ? 1280 : 1281, 800);
        await h.sleep(100);
    }
    assert(failed, 'UI never published a disconnected/failed reconnect state');
    assert(Math.max(...responseMs) < 1000, `UI stalled: ${Math.max(...responseMs)} ms`);
    assert(content(await visible('workspace.pane')).includes('sshrecords'), 'last terminal output was lost');
    report.checks.push('Keepalive detects a silent traffic blackhole; failed reconnect retains terminal output and continues handling UI requests');
    await h.screenshot(join(out, 'disconnected.png'));
    await click('toolbar.settings'); await visible('settings.nav.ssh'); await click('settings.nav.ssh');
    await h.screenshot(join(out, 'settings-while-offline.png'));
    report.checks.push('Settings opens and switches pages while SSH remains offline');
    const names = await readdir(join(data, 'logs'));
    let diskLog = '';
    for (const name of names) if (name.endsWith('.log') || name.endsWith('.log.1')) diskLog += await readFile(join(data, 'logs', name), 'utf8');
    await writeFile(join(out, 'diagnostic.log'), diskLog);
    const frameErrors = (diskLog.match(/frame consume failed:/g) ?? []).length;
    assert(frameErrors <= 10, `repeated frame errors flooded the log: ${frameErrors}`);
    report.passed = true;
    report.uiRequests = responseMs.length;
    report.maxUiResponseMs = Math.max(...responseMs);
    report.frameErrors = frameErrors;
    report.diagnosticBytes = Buffer.byteLength(diskLog);
} catch (error) {
    report.error = String(error); report.stack = (error as Error).stack;
    if (app) await h.screenshot(join(out, 'failure.png')).catch(() => {});
    process.exitCode = 1;
} finally {
    if (app && app.exitCode === null && app.signalCode === null) {
        app.kill('SIGTERM'); await Promise.race([ended, h.sleep(3000)]);
        if (app.exitCode === null && app.signalCode === null) { app.kill('SIGKILL'); await ended; }
    }
    for (const socket of sockets) socket.destroy();
    if (proxy.listening) await new Promise<void>(r => proxy.close(() => r()));
    peer.kill('SIGTERM'); await Promise.race([peerEnded, h.sleep(4000)]);
    if (peer.exitCode === null && peer.signalCode === null) { peer.kill('SIGKILL'); await peerEnded; }
    await appLog?.close(); await peerLog.close();
    await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
    await rm(base, {recursive: true, force: true});
}
console.log(JSON.stringify(report));
