/** Native startup and credential cancellation with an isolated system-reply fixture. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, readFile, writeFile, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const output = resolve(process.argv[2] ?? '/tmp/zw-startup-lazy-credentials');
await mkdir(output, { recursive: true });
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const shown = (node: any) => node && node.visible !== false && !node.hidden &&
    node.rect?.w > 0 && node.rect?.h > 0 && (node.effective_opacity ?? 1) > 0;
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 10000);
async function click(id: string) {
    await visible(id);
    assert((await h.clickTestId(id)).ok, id);
}
const report: any = { cases: [] };
const reference = 'zw1_' + 'a'.repeat(64);

async function scenario(kind: 'ssh' | 'ai', response: 'cancel' | 'success' | 'local' | 'migrate' = 'cancel') {
    const isolated = await realpath(await mkdtemp(join(tmpdir(), 'zw-startup-secret-')));
    const data = join(isolated, 'data');
    const rpc = join(isolated, 'rpc');
    await Promise.all([data, rpc].map(path => mkdir(path, { recursive: true })));
    if (response === 'local') {
        const credentials = join(data, 'credentials');
        await mkdir(credentials, { mode: 0o700 });
        await writeFile(join(credentials, '.local-storage'), '1', { mode: 0o600 });
        await writeFile(join(credentials, reference), 'fixture-only-secret', { mode: 0o600 });
    }
    let contacts = 0;
    let authenticatedPosts = 0;
    const server = createServer((request, response) => {
        if (request.method === 'POST' && request.headers.authorization === 'Bearer fixture-only-secret') {
            authenticatedPosts++;
            response.writeHead(200, { 'content-type': 'text/event-stream' });
            response.end('data: {"choices":[{"index":0,"delta":{"content":"SAVED_KEY_OK"}}]}\n\ndata: [DONE]\n\n');
        } else {
            response.writeHead(401).end();
        }
    });
    server.on('connection', () => contacts++);
    await new Promise<void>(done => server.listen(0, '127.0.0.1', done));
    const port = (server.address() as { port: number }).port;
    await writeFile(join(data, 'config.toml'), `[meta]
config_revision=1
[ai]
default_provider="fixture"
[[ai.providers]]
id="fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:${port}/v1/chat/completions"
api_key_ref="${reference}"
enabled=true
[[ai.providers.models]]
name="fixture"
context_window=200000
default=true
`);
    await writeFile(join(data, 'hosts.toml'), `[registry]
schema_version=2
revision=1
next_connection_id=2
next_group_id=1
[[hosts]]
connection_id=1
revision=1
protocol="ssh"
name="Credential fixture SSH"
host="127.0.0.1"
port=${port}
user="fixture"
auth={ password_ref = "${reference}" }
`);
    process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
    const start = performance.now();
    const app = spawn(join(prefix,'bin/zerowork'), [], { env: {
        ...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0',
        ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1',
        ZW_TEST_CREDENTIAL_RESPONSE: response === 'local' ? 'cancel' : response === 'migrate' ? 'success' : response,
    }, stdio: ['ignore','ignore','pipe'] });
    const ended = new Promise(done => app.once('close', done));
    let logs = '';
    let shownAt: number|null = null;
    app.stderr!.on('data', bytes => {
        logs += String(bytes);
        if (shownAt === null && logs.includes('Native window created')) shownAt = performance.now() - start;
    });
    const calls = () => (logs.match(/ZW_TEST_CREDENTIAL_REQUEST/g) ?? []).length;
    try {
        await h.waitForServerReady(15000);
        await visible('workspace.shell');
        const readyMs = Math.round(performance.now()-start);
        await h.resizeWindow(1440, 900);
        await new Promise(done => setTimeout(done,1050));
        assert.equal(calls(), 0, 'startup and idle model discovery do not ask for credentials');
        if (response !== 'local') assert.equal(contacts, 0);
        if (response === 'migrate') {
            await click('toolbar.settings');
            await click('settings.nav.data');
            if (!(await h.query('settings.data.credential_local')).some(shown)) await click('settings.data.location.header');
            await h.screenshot(join(output, 'credential-storage-keychain.png'));
            await click('settings.data.credential_local');
            const elapsed = performance.now();
            assert((await h.resizeWindow(1370, 830)).ok);
            assert(performance.now() - elapsed < 750);
            await h.waitFor(async () => await readFile(join(data, 'credentials', '.local-storage'), 'utf8').catch(() => null), 5000);
            assert.equal(await readFile(join(data, 'credentials', reference), 'utf8'), 'fixture-only-secret');
            assert.equal(calls(), 1);
            await h.screenshot(join(output, 'credential-storage-local.png'));
            await click('settings.close');
        }
        if (kind === 'ssh') {
            if (!(await h.query('sidebar.host')).some(shown)) await click('sidebar.restore');
            await click('sidebar.host');
            await click('sidebar.host.connect');
        } else {
            await click('workspace.empty.local');
            await visible('terminal.surface');
            await click('toolbar.ai');
            await click('ai.prompt');
            await h.type_('test saved API key');
            await click('ai.send');
        }
        if (response !== 'local') await h.waitFor(() => calls() >= 1 || null, 5000);
        const during = performance.now();
        assert((await h.resizeWindow(1350, 820)).ok);
        const responseMs = Math.round(performance.now() - during);
        assert(responseMs < 750, `UI response took ${responseMs} ms during a 900 ms authorization wait`);
        if (response === 'cancel') {
            await h.waitFor(async () => {
                const parts = await Promise.all(['ai.panel', 'terminal.surface', 'workspace.status'].map(id => h.query(id).catch(() => [])));
                return JSON.stringify(parts).includes('已取消系统身份验证') || null;
            }, 10000);
            assert.equal(calls(), 1, 'cancellation must not re-prompt');
            assert.equal(contacts, 0, 'cancelled authorization must not contact the host or provider');
        } else {
            await h.waitFor(async () => JSON.stringify(await h.query('ai.response')).includes('SAVED_KEY_OK') || null, 10000);
            assert(authenticatedPosts >= 1);
            if (response === 'local') assert.equal(calls(), 0, 'local storage never queries Keychain');
            if (response === 'migrate') assert.equal(calls(), 1, 'only the conversion queries Keychain');
        }
        assert((await h.resizeWindow(1280, 800)).ok);
        report.cases.push({ kind, response, nativeWindowMs: Math.round(shownAt ?? 0), workspaceReadyMs: readyMs, uiResizeDuringAuthorizationMs: responseMs, authorizationRequests: calls(), outboundConnections: contacts, authenticatedPosts });
        await h.request('POST', '/zerowork/windows', { action: 'quit' });
    } catch (error) {
        await h.screenshot(join(output, kind+'-'+response+'-failure.png')).catch(() => {});
        throw error;
    } finally {
        if (app.exitCode === null && app.signalCode === null) app.kill('SIGTERM');
        await ended;
        await new Promise<void>(done => server.close(() => done()));
        await writeFile(join(output, kind+'-'+response+'.log'), logs);
        await rm(isolated, { recursive: true, force: true });
    }
}
try {
    for (const kind of ['ssh', 'ai'] as const) await scenario(kind);
    await scenario('ai', 'success');
    await scenario('ai', 'local');
    await scenario('ai', 'migrate');
    report.ok = true;
} catch (error) {
    report.error = String(error);
    process.exitCode = 1;
} finally {
    await writeFile(join(output,'report.json'), JSON.stringify(report,null,2));
    console.log(JSON.stringify(report));
}
