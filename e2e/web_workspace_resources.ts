/** Exercise real WKWebView, two SSH hops and the owned SOCKS5 cleanup in one app process.
 * zig build -Dtest-mode=true --prefix /path/to/build
 * xcrun clang -O2 e2e/web_resource_process_probe.c -o /path/to/process-probe
 * ZW_WEB_TEST_PYTHON=/path/to/paramiko/python node e2e/web_workspace_resources.ts /path/to/build /path/to/process-probe /path/to/report
 */
import assert from 'node:assert/strict';
import {execFileSync, spawn, type ChildProcess} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, realpath, rm, writeFile} from 'node:fs/promises';
import {connect} from 'node:net';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

const prefix = resolve(process.argv[2]);
const processProbe = resolve(process.argv[3]);
const output = resolve(process.argv[4]);
const cycles = Number(process.env.ZW_WEB_RESOURCE_CYCLES ?? 20);
assert(Number.isInteger(cycles) && cycles > 0 && cycles <= 20);
const h = await import(pathToFileURL(join(prefix, 'share/zenit/harness/client.ts')).href);
const run = await realpath(await mkdtemp(join(tmpdir(), 'zw-web-resource-run-')));
const data = join(run, 'data');
const rpc = join(run, 'rpc');
await Promise.all([mkdir(data), mkdir(rpc), mkdir(output, {recursive: true})]);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;

const appLog = await open(join(output, 'app.log'), 'w');
const peerLog = await open(join(output, 'peer.log'), 'w');
const peer = spawn(process.env.ZW_WEB_TEST_PYTHON ?? 'python3', ['-B', resolve('e2e/web_workspace_peer.py'), run], {
    stdio: ['ignore', peerLog.fd, peerLog.fd],
});
const peerExit = new Promise(done => peer.once('close', done));
let app: ChildProcess | undefined;
let appExit: Promise<unknown> | undefined;
let stage = 'start isolated peers';
const results: Record<string, unknown>[] = [];
let diagnostic: unknown;

type Cleanup = {reservations: number; retained: number; pending_owners: number};
type Native = {owners: number; pending: number; completed: number};
type Proxy = {
    phase: string; cleanup: string; port: number; workers: number[];
    counts: {handshakes: number; pending: number; opening: number; active: number};
};
type Web = {
    session: number; generation: number; path: string; page: string;
    surface: boolean; mounted: boolean; proxy: Proxy | null; path_error: string | null;
};
type ResourceSnapshot = {ok: boolean; cleanup: Cleanup; native: Native; sessions: Web[]};
type Session = {session: number; lifecycle: string; close_cleanup_released: boolean; tab: number};
type Ready = {ports: number[]; known_hosts: string; routed: string; direct: string};

const visible = (node: any) => node && node.visible !== false && !node.hidden &&
    (node.effective_opacity ?? 1) > 0 && node.rect?.w > 0 && node.rect?.h > 0;
const content = (node: any): string => [node.text ?? '', ...(node.children ?? []).map(content)].join(' ');
const flatten = (node: any): any[] => [node, ...(node.children ?? []).flatMap(flatten)];
const find = (id: string, matches = (_: any) => true) =>
    h.waitFor(async () => (await h.query(id)).find((node: any) => visible(node) && matches(node)) ?? null, 12000);
async function click(id: string, matches?: (node: any) => boolean) {
    const {x, y, w, h: height} = (await find(id, matches)).rect;
    await h.mouseMove(x + w / 2, y + height / 2);
    assert((await h.clickAt(x + w / 2, y + height / 2)).ok);
}
async function openWeb(name = 'Resource web fixture') {
    const row = () => find('sidebar.host', node => content(node).includes(name));
    const {x, y, h: height} = (await row()).rect;
    await h.mouseMove(x + 48, y + height / 2);
    const button = await h.waitFor(async () => flatten(await row())
        .find(node => node.test_id === 'sidebar.host.connect' && visible(node)) ?? null, 12000);
    assert((await h.clickAt(button.rect.x + button.rect.w / 2, button.rect.y + button.rect.h / 2)).ok);
}
async function resources(): Promise<ResourceSnapshot> {
    const state = await h.request('GET', '/zerowork/web-resources');
    assert.equal(state.ok, true);
    diagnostic = state;
    return state;
}
async function setCleanupHold(hold: boolean) {
    const result = await h.request('POST', '/zerowork/web-resources',
        {action: hold ? 'hold_cleanup' : 'release_cleanup'});
    assert.equal(result.ok, true);
}
async function session(id: number): Promise<Session | undefined> {
    const state = await h.request('GET', '/zerowork/windows');
    return state.sessions.find((item: Session) => item.session === id);
}
type ProcessResources = {sockets: number; families: {unix: number; inet: number; other: number}; liveWorkers: number[]};
function processResources(workerIds: number[] = []): ProcessResources {
    return JSON.parse(execFileSync(processProbe, [String(app!.pid), ...workerIds.map(String)], {encoding: 'utf8'}));
}
function tcpDescriptors(): string[] {
    try {
        return execFileSync('/usr/sbin/lsof', ['-nP', '-a', '-p', String(app!.pid), '-iTCP', '-Fn'],
            {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']})
            .split('\n').filter(line => line.startsWith('n')).map(line => line.slice(1)).sort();
    } catch (error: any) {
        // lsof exits 1 when there are no matching descriptors.
        if (error.status === 1 && !error.stdout && !error.stderr) return [];
        throw error;
    }
}
function portClosed(port: number): Promise<boolean> {
    return new Promise((resolvePromise, reject) => {
        const client = connect(port, '127.0.0.1');
        client.once('connect', () => { client.destroy(); resolvePromise(false); });
        client.once('error', (error: NodeJS.ErrnoException) => {
            if (error.code === 'ECONNREFUSED') resolvePromise(true);
            else reject(error);
        });
        client.setTimeout(1000, () => { client.destroy(); reject(new Error('old proxy port did not answer')); });
    });
}
async function requestCount(path: string): Promise<number> {
    const log = await readFile(join(run, 'traffic.jsonl'), 'utf8').catch(error => {
        if (error.code === 'ENOENT') return '';
        throw error;
    });
    return log.trim().split('\n').filter(Boolean).filter(line => JSON.parse(line).path === path).length;
}

const idleCleanup = {reservations: 0, retained: 0, pending_owners: 0};
const sameCleanup = (state: Cleanup, expected: Cleanup) =>
    state.reservations === expected.reservations && state.retained === expected.retained &&
    state.pending_owners === expected.pending_owners;

async function waitActive(completedBefore: number, wantedRequests: number) {
    // Each page generation must receive explicit answers. Resource accounting
    // must cover real pending handlers, rather than auto-cancelled dialogs.
    for (const [title, message] of [['网页提示', 'fixture alert'], ['网页确认', 'fixture confirm'], ['网页输入', 'fixture prompt']]) {
        await find('plugin.challenge.modal', node => content(node).includes(title) && content(node).includes(message));
        if (title === '网页输入') {
            await click('plugin.challenge.answer.0');
            await h.type_('resource response');
            await click('plugin.challenge.submit');
        } else {
            await click('plugin.challenge.choice.0');
        }
    }
    const live = await h.waitFor(async () => {
        const state = await resources();
        const web = state.sessions[0];
        if (state.sessions.length !== 1 || !web?.surface || web.path !== 'ready' ||
            web.page !== 'displayed' || !web.proxy || web.proxy.phase !== 'ready' ||
            web.proxy.counts.active < 1 || !web.proxy.workers.every(Boolean) ||
            state.native.completed < completedBefore + 4 ||
            await requestCount('/resource-stream') < wantedRequests) return null;
        assert.deepEqual(state.cleanup, {...idleCleanup, reservations: 1});
        assert.equal(state.native.owners, 1);
        assert.equal(state.native.pending, 0);
        return {...web, proxy: web.proxy, completed: state.native.completed};
    }, 20000);
    assert.equal(await requestCount('/resource-probe'), wantedRequests, 'each generation loads the page once');
    assert.equal(await requestCount('/resource-stream'), wantedRequests, 'each generation starts one active flow');
    assert.equal(new Set(live.proxy.workers).size, 4);
    const os = processResources(live.proxy.workers);
    assert.deepEqual(os.liveWorkers, live.proxy.workers, 'OS can observe every proxy/SSH worker');
    assert(tcpDescriptors().some(name => name === `127.0.0.1:${live.proxy.port}`), 'OS can observe the live loopback listener');
    return {...live, socketFds: os.sockets};
}
type Active = Awaited<ReturnType<typeof waitActive>>;

type Baseline = {tcp: string[]; sockets: number; families: ProcessResources['families']};
async function confirmNoRoute(old: Active, baseline: Baseline) {
    await h.waitFor(async () => {
        const current = processResources(old.proxy.workers);
        const tcp = tcpDescriptors();
        const closed = await portClosed(old.proxy.port);
        diagnostic = {current, tcp, baseline, closed};
        return current.liveWorkers.length === 0 && current.sockets === baseline.sockets && closed &&
            JSON.stringify(current.families) === JSON.stringify(baseline.families) &&
            JSON.stringify(tcp) === JSON.stringify(baseline.tcp) ? tcp : null;
    }, 10000);
}

async function requestTabClose(owner: number) {
    const attached = await session(owner);
    assert(attached?.tab);
    await h.key('w', {cmd: true});
    await h.waitFor(async () => {
        if ((await h.query('session.close.accept')).some(visible)) {
            await click('session.close.accept');
        }
        const state = await session(owner);
        return state && ['closing', 'cleanup_unknown', 'closed'].includes(state.lifecycle) ? state : null;
    }, 15000);
}

async function closeTab(old: Active, baseline: Baseline) {
    await requestTabClose(old.session);
    await h.waitFor(async () => {
        const state = await resources();
        if (state.sessions.length !== 0 || state.native.owners !== 0 ||
            state.native.pending !== 0 || !sameCleanup(state.cleanup, idleCleanup)) return null;
        const ended = await session(old.session);
        return ended?.lifecycle === 'closed' && ended.close_cleanup_released ? state : null;
    }, 15000);
    await confirmNoRoute(old, baseline);
    return (await resources()).native.completed;
}

async function terminate(proc: ChildProcess | undefined, done: Promise<unknown> | undefined) {
    if (!proc || !done) return;
    if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill('SIGTERM');
        await Promise.race([done, h.sleep(3000)]);
        if (proc.exitCode === null && proc.signalCode === null) proc.kill('SIGKILL');
    }
    await done;
}

try {
    const ready: Ready = await h.waitFor(async () =>
        JSON.parse(await readFile(join(run, 'ready.json'), 'utf8').catch(() => 'null')), 10000);
    await writeFile(join(data, 'known_hosts'), ready.known_hosts);
    await writeFile(join(data, 'config.toml'), '[meta]\nconfig_revision=1\n[updates]\nauto_check=false\n');
    const ssh = ready.ports.map((port, index) =>
        `[[hosts]]\nconnection_id=${index + 1}\nrevision=1\nprotocol="ssh"\nname="Resource hop ${index + 1}"\nhost="127.0.0.1"\nport=${port}\nuser="socks-fixture"\nauth_mode="password"\nauth={password="local-controlled-only"}\n`);
    const payload = {url_mode: 'preset', start_url: new URL('/resource-probe', ready.routed).href,
        route: {mode: 'ssh', hop_asset_ids: [1, 2]}, bookmarks: []};
    const web = `[[hosts]]\nconnection_id=3\nrevision=1\nprotocol="web"\nname="Resource web fixture"\npayload_version=1\npayload=${JSON.stringify(JSON.stringify(payload))}\n`;
    const warmupPayload = {url_mode: 'preset', start_url: ready.direct, route: {mode: 'direct'}, bookmarks: []};
    const warmup = `[[hosts]]\nconnection_id=4\nrevision=1\nprotocol="web"\nname="Direct WebKit warmup"\npayload_version=1\npayload=${JSON.stringify(JSON.stringify(warmupPayload))}\n`;
    await writeFile(join(data, 'hosts.toml'),
        '[registry]\nschema_version=2\nrevision=1\nnext_connection_id=5\nnext_group_id=1\n' + ssh.join('') + web + warmup);
    app = spawn(join(prefix, 'bin/zerowork'), [], {
        env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0',
            ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'},
        stdio: ['ignore', appLog.fd, appLog.fd],
    });
    appExit = new Promise(done => app!.once('close', done));
    await h.waitForServerReady(30000);
    assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
    const baseline = await resources();
    assert.deepEqual(baseline.cleanup, idleCleanup);
    assert.deepEqual(baseline.native, {owners: 0, pending: 0, completed: 0});
    assert.deepEqual(baseline.sessions, []);
    const cold = processResources();
    stage = 'measure the persistent process socket initialized by direct WebKit';
    await openWeb('Direct WebKit warmup');
    const direct = await h.waitFor(async () => {
        const state = await resources();
        const web = state.sessions[0];
        return web?.page === 'displayed' && web.surface && !web.proxy ? web : null;
    }, 15000);
    await requestTabClose(direct.session);
    await h.waitFor(async () => {
        const state = await resources();
        return state.sessions.length === 0 && state.native.owners === 0 &&
            state.native.pending === 0 && sameCleanup(state.cleanup, idleCleanup) ? state : null;
    }, 15000);
    const {sockets, families} = processResources();
    const socketBaseline = {tcp: tcpDescriptors(), sockets, families};

    let completed = (await resources()).native.completed;
    let requests = 0;
    for (let index = 1; index <= cycles; index++) {
        stage = `open/close ${index}/${cycles}: open a saved web connection`;
        await openWeb();
        const active = await waitActive(completed, ++requests);
        assert.equal(active.generation, 1);
        assert(active.socketFds > socketBaseline.sockets, 'route acquires real socket descriptors');
        stage = `open/close ${index}/${cycles}: close a live routed page`;
        completed = await closeTab(active, socketBaseline);
        results.push({case: 'open-close', index, owner: active.session, closedPort: active.proxy.port,
            stoppedWorkers: active.proxy.workers, activeFlows: active.proxy.counts.active,
            completedHandlers: completed, closeReceipt: 'released', socketBaseline});
        console.log(`PASS open/close ${index}/${cycles}`);
    }

    stage = 'start the reconnect fixture';
    await openWeb();
    let active = await waitActive(completed, ++requests);
    for (let index = 1; index <= cycles; index++) {
        stage = `drop/reconnect ${index}/${cycles}: interrupt the first SSH hop`;
        const old = active;
        await writeFile(join(run, 'drop'), '');
        await find('web.reconnect');
        await h.waitFor(async () => {
            const state = await resources();
            const web = state.sessions[0];
            return state.sessions.length === 1 && web.path === 'disconnected' && !web.proxy && !web.mounted &&
                state.native.pending === 0 && sameCleanup(state.cleanup, idleCleanup) ? state : null;
        }, 15000);
        await confirmNoRoute(old, socketBaseline);
        stage = `drop/reconnect ${index}/${cycles}: open the next generation`;
        await click('web.reconnect');
        active = await waitActive(old.completed, ++requests);
        assert.equal(active.session, old.session);
        assert.equal(active.generation, old.generation + 1);
        assert(active.proxy.workers.every(id => !old.proxy.workers.includes(id)));
        results.push({case: 'drop-reconnect', index, owner: active.session, retiredGeneration: old.generation,
            replacementGeneration: active.generation, closedPort: old.proxy.port, stoppedWorkers: old.proxy.workers,
            activeFlows: old.proxy.counts.active, completedHandlers: active.completed, socketBaseline});
        console.log(`PASS drop/reconnect ${index}/${cycles}`);
    }

    stage = 'hold a real SSH transport cleanup across repeated retries';
    const old = active;
    await setCleanupHold(true);
    await requestTabClose(old.session);
    const unknown = await h.waitFor(async () => {
        const state = await resources();
        const previous = state.sessions.find(web => web.session === old.session);
        const host = await session(old.session);
        return previous?.proxy?.cleanup === 'unknown' && !previous.surface && state.native.owners === 0 &&
            state.native.pending === 0 && state.cleanup.reservations === 1 && state.cleanup.pending_owners === 1 &&
            host?.lifecycle === 'cleanup_unknown' && !host.close_cleanup_released ? state : null;
    }, 12000);
    assert(await portClosed(old.proxy.port), 'the proxy listener is already closed');
    assert(tcpDescriptors().some(name => name.endsWith(`:${ready.ports[0]}`)), 'SSH socket is actually retained');

    stage = 'reject a new route while the held transport owns the cleanup slot';
    await openWeb();
    const blocked = await h.waitFor(async () => {
        const state = await resources();
        const web = state.sessions.find(web => web.session !== old.session);
        return web?.path === 'disconnected' && web.path_error === '连接仍在关闭，请稍后重试。' &&
            !web.surface && !web.proxy ? web : null;
    }, 12000);
    assert.equal(await requestCount('/resource-probe'), requests);
    await h.sleep(2200);
    assert.equal((await session(old.session))?.lifecycle, 'cleanup_unknown', 'retry preserves the unknown host receipt');
    assert.equal((await resources()).cleanup.reservations, 1);

    stage = 'finish native cleanup, release the slot, and retry the blocked route';
    await setCleanupHold(false);
    await h.waitFor(async () => {
        const state = await resources();
        const ended = await session(old.session);
        return state.sessions.length === 1 && state.sessions[0].session === blocked.session &&
            sameCleanup(state.cleanup, idleCleanup) && ended?.lifecycle === 'closed' && ended.close_cleanup_released
            ? state : null;
    }, 12000);
    await confirmNoRoute(old, socketBaseline);
    await click('web.reconnect');
    active = await waitActive(old.completed, ++requests);
    assert.equal(active.session, blocked.session);
    await closeTab(active, socketBaseline);
    results.push({case: 'cleanup-budget', retainedOwner: old.session, heldCleanup: unknown.cleanup, refusedOwner: blocked.session,
        releasedReceipt: true, resumed: true, socketBaseline});
    console.log('PASS unknown cleanup retains a native socket and budget, then retries and releases both');

    stage = 'quit after the final route is released';
    await h.request('POST', '/zerowork/windows', {action: 'quit'});
    await Promise.race([appExit, h.sleep(12000)]);
    assert.equal(app.exitCode, 0);
    await writeFile(join(output, 'resources.json'), JSON.stringify({status: 'passed', cycles, cold, socketBaseline, results}, null, 2) + '\n');
} catch (error) {
    await writeFile(join(output, 'resources.json'),
        JSON.stringify({status: 'failed', stage, diagnostic, error: String(error), results}, null, 2) + '\n');
    throw new Error(stage, {cause: error});
} finally {
    await terminate(app, appExit);
    await terminate(peer, peerExit);
    await Promise.all([appLog.close(), peerLog.close()]);
    await rm(run, {recursive: true, force: true});
}
