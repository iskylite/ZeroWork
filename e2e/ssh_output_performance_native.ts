/** Native SSH output/idle resource probe against an isolated loopback PTY.
 * Run before/after with the same binary mode, geometry and machine workload.
 * CPU windows issue no Harness RPC. One fully occupied CPU core is 100%.
 * Timings are evidence, not hardware-independent pass/fail thresholds. */
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {mkdir, mkdtemp, realpath, open, readFile, writeFile, rm} from 'node:fs/promises';
import {resolve, join} from 'node:path';
import {createHash} from 'node:crypto';
import * as h from '../vendor/zenit/e2e/client.ts';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';

const [binaryArg, outArg] = process.argv.slice(2);
assert(binaryArg && outArg, 'binary output-directory; ZW_TEST_PYTHON must provide paramiko');
const binary = resolve(binaryArg), out = resolve(outArg);
const python = process.env.ZW_TEST_PYTHON ?? 'python3';
const focusScreen = process.env.ZEROWORK_PERF_FOCUS === 'screen';
const screenRepeats = Number(process.env.ZEROWORK_PERF_SCREEN_REPEATS ?? 1);
const threadProbe = process.env.ZEROWORK_PERF_THREAD_PROBE;
assert(Number.isInteger(screenRepeats) && screenRepeats >= 1 && screenRepeats <= 5, 'screen repeats must be 1..5');
const iso = await realpath(await mkdtemp('/private/tmp/zw-ssh-output-'));
await Promise.all([mkdir(out, {recursive: true}), mkdir(join(iso, 'data')), mkdir(join(iso, 'rpc'))]);
process.env.ZENIT_E2E_FILE_RPC_DIR = join(iso, 'rpc');
const peerLog = await open(join(out, 'peer.log'), 'w');
const peer = spawn(python, ['e2e/ssh_nested_shell_peer.py', '--out', join(iso, 'peer')], {stdio: ['ignore', peerLog.fd, peerLog.fd]});
let peerError: Error | null = null;
peer.once('error', error => { peerError = error; });
const peerEnded = new Promise(r => peer.once('close', r));
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
const flat = (n: any): any[] => Array.isArray(n) ? n.flatMap(flat) : n ? [n, ...(n.children ?? []).flatMap(flat)] : [];
const shown = (n: any) => n && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const text = (n: any): string => n?.hidden || n?.visible === false ? '' : (n?.text ?? '') + (n?.children ?? []).map(text).join('');
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 20000);
async function click(id: string) { await visible(id); assert((await h.clickTestId(id)).ok, id); }
async function tail() { return text({children: await h.query('terminal.input')}); }
async function authenticate(password: string) {
    const modal = (await h.query('plugin.challenge.modal')).find(shown);
    if (!modal) return;
    const nodes = flat(modal);
    if (nodes.some(n => n.test_id === 'plugin.challenge.choice.1' && shown(n))) await click('plugin.challenge.choice.1');
    else if (nodes.some(n => n.test_id === 'plugin.challenge.secret' && shown(n))) {
        await click('plugin.challenge.secret'); await h.type_(password); await click('plugin.challenge.submit');
    }
}
function resource(pid: number) {
    const parts = execFileSync('/bin/ps', ['-p', String(pid), '-o', 'time=,rss='], {encoding: 'utf8'}).trim().split(/\s+/);
    const threads: {id: number; cpu_ns: number}[] = threadProbe ? JSON.parse(execFileSync(threadProbe, [String(pid)], {encoding: 'utf8'})).threads : [];
    return {cpu_seconds: parts[0].split(':').map(Number).reduce((a, b) => a * 60 + b, 0), rss_kib: Number(parts[1]), threads, time_ms: performance.now()};
}
function compilers() {
    return execFileSync('/bin/ps', ['-axo', 'pid=,%cpu=,comm='], {encoding: 'utf8'})
        .split('\n').filter(line => /\/(zig|clang|clang\+\+)$/.test(line.trim()));
}
let app: ReturnType<typeof spawn> | undefined, appEnded: Promise<unknown> | undefined, appLog: Awaited<ReturnType<typeof open>> | undefined;
const report: any = {
    binary, sha256: createHash('sha256').update(await readFile(binary)).digest('hex'), cases: [],
    geometry: {width: 1200, height: 800, theme: 'dark', wallpaper: false}, focus: focusScreen ? 'screen' : 'matrix', screen_repeats: screenRepeats,
    limits: ['Optimized native Metal App, private data, real loopback SSH and isolated PTY shell; not a remote WAN benchmark.',
        'CPU is the App process only; shell, peer and compilation are separate. CPU windows have no Harness RPC or stack sampling.',
        'One-second CPU intervals have ps timer quantization; RSS is an endpoint, not a peak or leak verdict.',
        'Synthetic Harness input/background window does not establish physical input latency.'],
};
async function checkpoint() { await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2) + '\n'); }
async function measure(label: string, durationMs: number, command?: string, marker?: string) {
    if (command) { await click('terminal.input'); await h.type_(command); }
    await h.resetTiming();
    const frameBefore = await h.stats();
    if (command) await h.key('enter');
    const compilersBefore = compilers();
    const before = resource(app!.pid!);
    const samples = [before];
    const start = performance.now();
    for (let deadline = 1000; deadline <= durationMs; deadline += 1000) {
        await sleep(Math.max(0, start + deadline - performance.now()));
        samples.push(resource(app!.pid!));
    }
    const after = samples.at(-1)!;
    const compilersAfter = compilers();
    const frameAfter = await h.stats();
    if (marker) await h.waitFor(async () => (await tail()).includes(marker) || null, 45000, 100);
    const intervals = samples.slice(1).map((s, i) => 100000 * (s.cpu_seconds - samples[i].cpu_seconds) / (s.time_ms - samples[i].time_ms));
    const originalThreads = new Map(before.threads.map(t => [t.id, t.cpu_ns]));
    const threadCpu = after.threads.filter(t => originalThreads.has(t.id))
        .map(t => ({id: t.id, cpu_percent: (t.cpu_ns - originalThreads.get(t.id)!) / (after.time_ms - before.time_ms) / 10000}))
        .sort((a, b) => b.cpu_percent - a.cpu_percent);
    const row = {label, seconds: (after.time_ms - before.time_ms) / 1000,
        cpu_percent: 100000 * (after.cpu_seconds - before.cpu_seconds) / (after.time_ms - before.time_ms),
        cpu_one_second_max_percent: Math.max(...intervals), cpu_one_second_intervals: intervals,
        rss_kib: after.rss_kib, frames: frameAfter.frame_count - frameBefore.frame_count, timing: frameAfter,
        compilers_before: compilersBefore, compilers_after: compilersAfter,
        persistent_threads_cpu: threadCpu.slice(0, 5),
        terminal: await h.request('POST', '/zerowork/terminal', {action: 'metrics'}),
        profile: await h.request('POST', '/zerowork/terminal', {action: 'profile'})};
    report.cases.push(row); await checkpoint();
    console.log(`${label}: CPU ${row.cpu_percent.toFixed(2)}%, 1s max ${row.cpu_one_second_max_percent.toFixed(2)}%, frames ${row.frames}, RSS ${(row.rss_kib / 1024).toFixed(1)} MiB`);
    if (threadCpu.length) console.log(`  busiest persistent thread ${threadCpu[0].id}: ${threadCpu[0].cpu_percent.toFixed(2)}% (not an inferred thread name)`);
}
try {
    const ready = await h.waitFor(async () => {
        if (peerError) throw peerError;
        if (peer.exitCode !== null) throw new Error('SSH peer exited');
        try { return JSON.parse(await readFile(join(iso, 'peer/ready.json'), 'utf8')); } catch { return null; }
    }, 15000);
    await writeFile(join(iso, 'data/config.toml'), '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[ssh]\nauto_reconnect=false\nauto_shell_integration=true\n[updates]\nauto_check=false\n' + (process.env.ZEROWORK_PERF_INTEGRATION === '1' ? '[ai]\ndefault_provider="fixture"\n[[ai.providers]]\nid="fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:9/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="fixture"\ncontext_window=200000\ndefault=true\n' : ''));
    await writeFile(join(iso, 'data/hosts.toml'), `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="SSH output fixture"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
    appLog = await open(join(out, 'app.log'), 'w');
    app = spawn(binary, [], {env: {...process.env, OPENAI_API_KEY: '', ANTHROPIC_API_KEY: '', ZEROWORK_DATA_DIR: join(iso, 'data'), ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'}, stdio: ['ignore', appLog.fd, appLog.fd]});
    appEnded = new Promise(r => app!.once('close', r)); report.pid = app.pid;
    await h.waitForServerReady(60000); await h.resizeWindow(1200, 800); await sleep(2000);
    if (!focusScreen) await measure('empty-idle', 30000);
    const host = await visible('sidebar.host'); await h.mouseMove(host.rect.x + host.rect.w - 18, host.rect.y + host.rect.h / 2); await click('sidebar.host.connect');
    await h.waitFor(async () => {
        await authenticate(ready.password);
        return (await tail()).includes('fixture>') || null;
    }, 45000);
    await sleep(2000); if (!focusScreen) await measure('ssh-idle', 30000);
    await measure('ssh-lines-8MiB', 9000,
        `/usr/bin/perl -e '$|=1;my $s=("R"x127)."\\n";for(1..256){print $s x256;select undef,undef,undef,0.03125}print "AUDIT_","LINES_DONE\\n"'`, 'AUDIT_LINES_DONE');
    for (let i = 1; i <= screenRepeats; i++) await measure(`ssh-screen-refresh-${i}`, 9000,
        `/usr/bin/perl -e '$|=1;for my $i(1..960){printf "\\033[HSSH screen %06d\\033[K\\n",$i;for my $r(1..15){printf "task %02d value %06d\\033[K\\n",$r,$i+$r}select undef,undef,undef,0.008333}print "\\nAUDIT_","SCREEN_${i}_DONE\\n"'`, `AUDIT_SCREEN_${i}_DONE`);
    if (!focusScreen) await measure('ssh-after-output-idle', 30000);
    await click('toolbar.settings'); if (!focusScreen) await measure('settings-over-ssh-idle', 30000);
    assert((await h.screenshot(join(out, 'settings.png'))).ok);
    if (process.env.ZEROWORK_PERF_INTEGRATION === '1') {
        const windows = () => h.request('POST', '/zerowork/windows', {action: 'snapshot'});
        const select = (window: number) => h.request('POST', '/zerowork/windows', {action: 'select', window});
        const metrics = () => h.request('POST', '/zerowork/terminal', {action: 'metrics'});
        const first = (await windows()).windows[0].window;
        const openTree = (await windows()).windows[0].tree_nodes;
        await click('settings.close'); await sleep(250);
        const closedTree = (await windows()).windows[0].tree_nodes;
        assert(closedTree < openTree, 'closed settings leaves the traversed tree');
        await click('toolbar.settings'); await visible('settings.panel'); await click('settings.close');
        await click('ai.strip'); await click('ai.prompt'); await h.type_('PERFORMANCE_LOCAL_DRAFT');
        await click('ai.collapse'); await click('ai.strip'); await visible('ai.prompt');
        assert.equal((await h.inputState('ai.prompt')).buffer, 'PERFORMANCE_LOCAL_DRAFT', 'AI draft survives retained detach/reopen');
        await h.key('a', {cmd: true}); await h.key('backspace'); await click('ai.collapse');
        await click('terminal.input'); await h.key('f', {cmd: true}); await click('terminal.search.query'); await h.type_('AUDIT_SCREEN');
        const searched = await h.waitFor(async () => {const m = await metrics(); return m.search_matches > 0 && !m.search_task_pending ? m : null;}, 30000, 100);
        assert(searched.search_background_scans > 0, 'real Ctrl+F uses background search');
        assert.equal(searched.search_synchronous_scans, 0, 'SSH Ctrl+F has no synchronous full-history fallback');
        await click('terminal.search.close');
        await click('terminal.input'); await h.key('f', {cmd: true}); await visible('terminal.search.query'); await h.key('escape');
        const drained = await h.waitFor(async () => {const m = await h.request('POST', '/zerowork/terminal', {action: 'memory'}); return m.search_executor.running === 0 && m.search_executor.queued === 0 ? m : null;}, 15000, 100);
        assert(drained.search_executor.workers <= 2, 'shared CPU execution stays bounded');
        const row = await visible('sidebar.host');
        const point = {x: row.rect.x + 10, y: row.rect.y + row.rect.h / 2, button: 'right'};
        await h.request('POST', '/mouse_down', point); await h.request('POST', '/mouse_up', point);
        await click('context.menu.new_window');
        const sibling = await h.waitFor(async () => (await windows()).windows.find((w: any) => w.window !== first) ?? null, 20000);
        await select(sibling.window);
        await h.waitFor(async () => {await authenticate(ready.password); return (await tail()).includes('fixture>') || null;}, 45000);
        await select(first); await click('terminal.input');
        await h.type_(`/usr/bin/perl -e '$|=1;for my $i(1..960){printf "\\033[HWindow %06d\\033[K\\n",$i;select undef,undef,undef,0.008333}print "AUDIT_","WINDOW_DONE\\n"'`);
        await h.key('enter'); const windowBefore = await windows(); await sleep(9000); const windowAfter = await windows();
        await h.waitFor(async () => (await tail()).includes('AUDIT_WINDOW_DONE') || null, 15000, 100);
        const delta = (id: number) => windowAfter.windows.find((w: any) => w.window === id).frame_count - windowBefore.windows.find((w: any) => w.window === id).frame_count;
        const activeFrames = delta(first), siblingFrames = delta(sibling.window);
        assert(activeFrames > 100, 'active SSH window presents output');
        assert(siblingFrames < Math.max(20, activeFrames / 10), 'unrelated window avoids output-rate redraw');
        report.integration = {settings_open_tree_nodes: openTree, settings_closed_tree_nodes: closedTree, search: searched, search_after_cancel: drained, active_frames: activeFrames, sibling_frames: siblingFrames};
        await select(sibling.window);
        const beforeClose = (await windows()).sessions.filter((s: any) => s.window === sibling.window).map((s: any) => [s.session,s.generation,s.lifecycle,s.close_operation]);
        assert(beforeClose.length > 0, 'sibling owns its SSH session');
        assert((await h.request('POST', '/zerowork/windows', {action: 'close', window: sibling.window})).ok);
        // AppNavHost.nativeCloseRequest(.window) intentionally hides the window.
        // Its session must survive; application Quit below drains both windows.
        const retained = await windows();
        assert(retained.windows.some((w: any) => w.window === sibling.window), 'ordinary window close retains the window host');
        assert.deepEqual(retained.sessions.filter((s: any) => s.window === sibling.window).map((s: any) => [s.session,s.generation,s.lifecycle,s.close_operation]), beforeClose, 'ordinary close preserves the SSH session');
        report.integration.close_retains_sibling_session = true;
        await select(first);
    }
    if (process.env.ZEROWORK_PERF_SAMPLE === '1') {
        // A separate workload after all CPU windows: sampling itself must not
        // contaminate the before/after process-time measurements above.
        await click('settings.close'); await click('terminal.input');
        await h.type_(`/usr/bin/perl -e '$|=1;for my $i(1..960){printf "\\033[HProfile %06d\\033[K\\n",$i;for my $r(1..15){printf "task %02d value %06d\\033[K\\n",$r,$i+$r}select undef,undef,undef,0.008333}print "\\nAUDIT_","PROFILE_DONE\\n"'`);
        await h.key('enter'); await sleep(1000);
        const path = join(out, 'screen-refresh.sample.txt');
        execFileSync('/usr/bin/sample', [String(app.pid), '3', '1', '-file', path], {timeout: 15000, stdio: 'ignore'});
        await h.waitFor(async () => (await tail()).includes('AUDIT_PROFILE_DONE') || null, 30000, 100);
        report.separate_stack_sample = 'screen-refresh.sample.txt';
    }
    // Exercise the real close/worker drain path after measurement, including
    // the VT mutex lifetime. Forced termination below is failure cleanup only.
    const quit = await h.request('POST', '/zerowork/windows', {action: 'quit'});
    assert(quit.ok, 'normal application Quit accepted');
    const quitStarted = performance.now();
    let rpcUnavailable = false;
    while (app.exitCode === null && app.signalCode === null && performance.now() - quitStarted < 20000) {
        if (!rpcUnavailable) {
            try {
                for (const id of ['groups.close.accept', 'local.close.accept', 'session.close.accept']) {
                    if ((await h.query(id)).some(shown)) await h.clickTestId(id);
                }
            } catch { rpcUnavailable = true; }
        }
        await Promise.race([appEnded, sleep(100)]);
    }
    report.normal_quit = {exit_code: app.exitCode, signal: app.signalCode};
    assert.equal(app.exitCode, 0, 'normal Quit drains workers and exits zero');
    assert.equal(app.signalCode, null, 'normal Quit needs no signal');
    report.status = 'passed';
} catch (error) {
    report.status = 'failed'; report.error = String(error); process.exitCode = 1;
    if (app?.exitCode === null) await h.screenshot(join(out, 'failure.png')).catch(() => {});
} finally {
    if (app && app.exitCode === null && app.signalCode === null) {
        app.kill('SIGTERM');
        await Promise.race([appEnded, sleep(3000)]);
        if (app.exitCode === null && app.signalCode === null) { app.kill('SIGKILL'); await appEnded; }
    }
    if (app?.pid) await cleanupOwnedBridgeDirectories(app.pid);
    await appLog?.close();
    if (peer.exitCode === null && peer.signalCode === null) peer.kill('SIGTERM');
    await peerEnded; await peerLog.close();
    const peerReport = await readFile(join(iso, 'peer/report.json'), 'utf8').catch(() => null);
    if (peerReport) {
        report.peer = JSON.parse(peerReport);
        if (report.peer.errors?.length) { report.status = 'failed'; report.error = 'SSH peer errors'; process.exitCode = 1; }
    }
    await checkpoint(); await rm(iso, {recursive: true, force: true});
}
