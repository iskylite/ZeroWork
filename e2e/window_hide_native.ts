/** Retained native window, live Local PTY, Dock reopen and normal Quit. */
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, writeFile, rm, copyFile, realpath} from 'node:fs/promises';
import {join, resolve, dirname} from 'node:path';
import {tmpdir} from 'node:os';
import * as h from '../zig-out/share/zenit/harness/client.ts';

const binary = resolve(process.argv[2] ?? 'zig-out/bin/zerowork');
const out = resolve(process.argv[3] ?? '/tmp/zerowork-window-hide');
await mkdir(out, {recursive: true});
const isolated = await realpath(await mkdtemp(join(tmpdir(), 'zw-window-hide-')));
const rpc = join(isolated, 'rpc'), data = join(isolated, 'data');
const bundle = join(isolated, 'WindowHideCheck.app'), executable = join(bundle, 'Contents/MacOS');
await Promise.all([mkdir(rpc), mkdir(data), mkdir(executable, {recursive: true})]);
await copyFile(binary, join(executable, 'ZeroWork'));
for (const helper of ['zw_ipc.so', 'zw_execution.so', 'zw_execution_guard'])
    await copyFile(join(dirname(binary), helper), join(executable, helper));
const bundleId = 'com.zerowork.window-hide-check.' + Date.now();
await writeFile(join(bundle, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>ZeroWork</string><key>CFBundleIdentifier</key><string>${bundleId}</string><key>CFBundleName</key><string>WindowHideCheck</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
const signingIdentity = execFileSync('python3', ['scripts/macos_signing.py', 'identity'], {encoding: 'utf8'}).trim();
execFileSync('/usr/bin/codesign', ['--force', '--deep', '--sign', signingIdentity, bundle]);
const windowList = join(out, 'window-list');
execFileSync('/usr/bin/swiftc', [resolve('e2e/native_window_list.swift'), '-o', windowList]);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(out, 'app.log'), 'w');
const env = {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0',
    ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_ISOLATE_POINTER: '1'};
delete env.ZENIT_E2E_BACKGROUND;
const app = spawn(join(executable, 'ZeroWork'), [], {env, stdio: ['ignore', log.fd, log.fd]});
const ended = new Promise(r => app.once('close', r));
const report: any = {status: 'running', checks: [], pid: app.pid};
const shown = (n: any) => !n.hidden && n.visible !== false && n.rect?.w > 0 && n.rect?.h > 0;
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
const state = () => h.request('POST', '/zerowork/windows', {action: 'snapshot'});
const nativeWindows = () => JSON.parse(execFileSync(windowList, [String(app.pid)], {encoding: 'utf8'}));
const onScreen = (id: number) => nativeWindows().some((w: any) => w.kCGWindowNumber === id && w.kCGWindowIsOnscreen);
const beat = join(isolated, 'heartbeat'), receipt = join(isolated, 'shell.pid');
let shellPid: number | undefined;
function alive(pid: number) { try { process.kill(pid, 0); return true; } catch { return false; } }
async function heartbeat() { try { return Number(await readFile(beat, 'utf8')); } catch { return 0; } }
async function click(id: string) { await visible(id); assert((await h.clickTestId(id)).ok); }
async function capture(name: string) {
    assert((await h.screenshot(join(out, name + '.png'))).ok);
    await writeFile(join(out, name + '.state.json'), JSON.stringify(await state(), null, 2));
}
try {
    await h.waitForServerReady(60000);
    assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
    await h.resizeWindow(1100, 760);
    await click('workspace.empty.local');
    await visible('terminal.surface');
    await h.type_(`printf '%s' $$ > '${receipt}'; i=0; while true; do i=$((i+1)); printf '%s' $i > '${beat}'; sleep 0.2; done`);
    await h.key('enter');
    await h.waitFor(async () => (await heartbeat()) >= 2 || null);
    shellPid = Number(await readFile(receipt, 'utf8'));
    const before = await state(), original = before.windows[0];
    const session = before.sessions.find((s: any) => s.plugin === 'local');
    assert(session && alive(shellPid!));
    await h.waitFor(() => onScreen(original.native_window) || null);
    await capture('before-hide');
    for (let round = 1; round <= 2; round++) {
        assert((await h.request('POST', '/zerowork/windows', {action: 'close', window: original.window})).ok);
        await h.waitFor(() => !onScreen(original.native_window) || null);
        assert.equal(app.exitCode, null);
        const start = await heartbeat();
        await h.waitFor(async () => (await heartbeat()) > start + 3 || null);
        const hidden = await state();
        assert.equal(hidden.native_count, 1);
        assert.deepEqual(hidden.windows.map((w: any) => [w.window, w.native_window, w.closing]), [[original.window, original.native_window, false]]);
        assert.equal(hidden.sessions.find((s: any) => s.session === session.session).lifecycle, 'attached');
        assert(!(await h.query('local.close.confirmation')).some(shown));
        assert(alive(shellPid!));
        await writeFile(join(out, `hidden-${round}.json`), JSON.stringify({state: hidden, native: nativeWindows(), heartbeat: await heartbeat()}, null, 2));
        // LaunchServices sends the same reopen Apple event as clicking the Dock icon.
        execFileSync('/usr/bin/open', [bundle]);
        await h.waitFor(() => onScreen(original.native_window) || null, 15000);
        assert.equal(app.exitCode, null);
        assert.equal((await state()).native_count, 1);
        await capture('restored-' + round);
        report.checks.push(`Round ${round}: window hides, original shell keeps working, Dock reopen restores the same native window and session.`);
    }
    // Quit while hidden must still release the original process and native owner.
    await click('terminal.input');
    await h.key('c', {ctrl: true});
    await h.sleep(300);
    const stopped = await heartbeat();
    await h.sleep(500);
    assert.equal(await heartbeat(), stopped);
    await h.request('POST', '/zerowork/windows', {action: 'close', window: original.window});
    await h.waitFor(() => !onScreen(original.native_window) || null);
    await h.request('POST', '/zerowork/windows', {action: 'quit'});
    await Promise.race([ended, h.sleep(15000)]);
    assert.equal(app.exitCode, 0, 'Quit while hidden exits normally');
    assert.equal(app.signalCode, null);
    assert(!alive(shellPid!));
    report.checks.push('Quit while hidden closes the retained Local shell and exits normally with code zero.');
    report.status = 'passed';
} catch (error) {
    report.status = 'failed'; report.error = String(error); report.stack = (error as Error).stack;
    await capture('failure').catch(() => {});
    process.exitCode = 1;
} finally {
    if (app.exitCode === null && app.signalCode === null) {
        app.kill('SIGTERM'); await Promise.race([ended, h.sleep(2000)]);
        if (app.exitCode === null && app.signalCode === null) { app.kill('SIGKILL'); await ended; }
    }
    if (shellPid && alive(shellPid)) process.kill(shellPid, 'SIGHUP');
    await log.close();
    report.exit = {code: app.exitCode, signal: app.signalCode};
    await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
    await rm(isolated, {recursive: true, force: true});
    console.log(JSON.stringify(report));
}
