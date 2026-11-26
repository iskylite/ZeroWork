/** Native startup and credential cancellation with an isolated system-reply fixture. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { constants, copyFile, mkdtemp, mkdir, readFile, readdir, stat, writeFile, realpath, rm } from 'node:fs/promises';
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
const otherReference = 'zw1_' + 'b'.repeat(64);
type Response = 'cancel' | 'success' | 'trusted' | 'local' | 'roundtrip' | 'reverse-cancel' | 'reverse-write-fail' | 'reverse-verify-fail';
async function exists(path: string) {
    try { await stat(path); return true; }
    catch (err: any) { if (err.code === 'ENOENT') return false; throw err; }
}
async function startupLog(data: string) {
    const directory = join(data, 'logs');
    const file = (await readdir(directory)).find(name => /^app-.*[.]log$/.test(name));
    return file ? await readFile(join(directory, file), 'utf8') : '';
}

async function scenario(kind: 'ssh' | 'ai', response: Response = 'cancel', archive?: string) {
    const isolated = await realpath(await mkdtemp(join(tmpdir(), 'zw-startup-secret-')));
    const data = join(isolated, 'data');
    const rpc = join(isolated, 'rpc');
    await Promise.all([data, rpc].map(path => mkdir(path, { recursive: true })));
    if (archive) await copyFile(archive, join(data, 'ai-sessions.jsonl'), constants.COPYFILE_FICLONE);
    const credentials = join(data, 'credentials');
    const marker = join(credentials, '.local-storage');
    const localEntry = join(credentials, reference);
    const startsLocal = response === 'local' || response.startsWith('reverse-');
    const promptsAtStartup = !startsLocal && response !== 'trusted';
    if (startsLocal) {
        await mkdir(credentials, { mode: 0o700 });
        await writeFile(marker, '1', { mode: 0o600 });
        await writeFile(localEntry, 'fixture-only-secret', { mode: 0o600 });
        if (response.startsWith('reverse-')) await writeFile(join(credentials, otherReference), 'other-fixture-secret', { mode: 0o600 });
    } else {
        // V0.8: local files are the default, so Keychain scenarios must record
        // the explicit backend choice first.
        await mkdir(credentials, { mode: 0o700 });
        await writeFile(join(credentials, '.keychain-storage'), '1', { mode: 0o600 });
    }
    let contacts = 0;
    let authenticatedPosts = 0;
    const server = createServer((request, response) => {
        const authenticated = request.headers.authorization === 'Bearer fixture-only-secret';
        if (request.method === 'GET' && authenticated) {
            response.writeHead(200, { 'content-type': 'application/json' });
            response.end(JSON.stringify({ object: 'list', data: [{ id: 'fixture' }] }));
        } else if (request.method === 'POST' && authenticated) {
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
        ZW_TEST_CREDENTIAL_RESPONSE: response === 'trusted' ? 'silent-success'
            : response === 'success' ? 'slow-success'
            : response === 'local' ? 'cancel' : response === 'roundtrip' ? 'success' : response.replace(/^reverse-/, ''),
    }, stdio: ['ignore','ignore','pipe'] });
    const ended = new Promise(done => app.once('close', done));
    let logs = '';
    let shownAt: number|null = null;
    let firstCredentialAt: number|null = null;
    app.stderr!.on('data', bytes => {
        logs += String(bytes);
        if (shownAt === null && logs.includes('Native window created')) shownAt = performance.now() - start;
        if (firstCredentialAt === null && logs.includes('ZW_TEST_CREDENTIAL_REQUEST')) firstCredentialAt = performance.now();
    });
    const calls = () => (logs.match(/ZW_TEST_CREDENTIAL_REQUEST/g) ?? []).length;
    try {
        await h.waitForServerReady(15000);
        await visible('workspace.shell');
        const readyMs = Math.round(performance.now()-start);
        if (promptsAtStartup) await h.waitFor(() => calls() === 1 || null, 5000);
        else assert.equal(calls(), 0);
        const resizeDuringStartup = performance.now();
        assert((await h.resizeWindow(1440, 900)).ok);
        const responseMs = Math.round(performance.now() - resizeDuringStartup);
        assert(responseMs < 750, `UI response took ${responseMs} ms during startup authorization`);
        assert.equal(contacts, 0);
        if (response === 'roundtrip') {
            await h.waitFor(async () => (await startupLog(data)).includes('startup credentials ms'), 5000);
        }
        let archiveResizeMs: number | null = null;
        if (archive) {
            assert(!/AI history (index|preview|restore)/.test(await startupLog(data)));
            await click('workspace.empty.local');
            await visible('terminal.surface');
            await click('ai.strip');
            await h.waitFor(async () => JSON.stringify(await h.query('ai.composer.model')).includes('fixture'), 5000);
            assert(!(await h.query('ai.empty.unconfigured')).some(shown));
            const resizeStart = performance.now();
            assert((await h.resizeWindow(1370, 830)).ok);
            archiveResizeMs = Math.round(performance.now() - resizeStart);
            assert(archiveResizeMs < 750);
            await h.screenshot(join(output, 'assistant-during-history.png'));
            await visible('ai.empty.configured');
            assert.equal(calls(), 1);
        }
        if (response === 'roundtrip' || response.startsWith('reverse-')) {
            const action = startsLocal ? 'settings.data.credential_keychain' : 'settings.data.credential_local';
            const status = async (value: string) => h.waitFor(async () =>
                JSON.stringify(await h.query('settings.operation.status')).includes(value), 6000);
            await click('toolbar.settings');
            await click('settings.nav.data');
            if (!(await h.query(action)).some(shown)) await click('settings.data.location.header');
            if (response === 'roundtrip') {
                await h.screenshot(join(output, 'credential-storage-keychain.png'));
                await click('settings.data.credential_local');
                await click('settings.confirmation.credential_switch');
                await status('已转为本地存储');
                assert.equal(await readFile(marker, 'utf8'), '1');
                assert.equal(await readFile(localEntry, 'utf8'), 'fixture-only-secret');
                assert.equal(calls(), 1);
                await visible('settings.data.credential_keychain');
                await h.screenshot(join(output, 'credential-storage-local.png'));
            }
            await click('settings.data.credential_keychain');
            const confirmation = await visible('settings.confirmation');
            assert(JSON.stringify(confirmation).includes('切换到 macOS 钥匙串？'));
            if (response === 'roundtrip') {
                await h.sleep(300); // Capture the native dialog after its opening transition.
                await h.screenshot(join(output, 'credential-storage-confirm-keychain.png'));
                await click('settings.confirmation.cancel');
                assert.equal(await readFile(marker, 'utf8'), '1');
                assert.equal(await readFile(localEntry, 'utf8'), 'fixture-only-secret');
                assert.equal(calls(), 1, 'cancelling the app confirmation does not open system authentication');
                await click('settings.data.credential_keychain');
            }
            await click('settings.confirmation.credential_switch');
            const resizeStart = performance.now();
            assert((await h.resizeWindow(1370, 830)).ok);
            assert(performance.now() - resizeStart < 750);
            if (response === 'roundtrip') {
                await status('已切换到 macOS 钥匙串');
                await visible('settings.data.credential_local');
                assert.equal(await exists(marker), false);
                assert.equal(await exists(localEntry), false);
                assert.equal(calls(), 2);
            } else {
                await status(response === 'reverse-cancel' ? '已取消转换，继续使用本地文件' : '凭据转换失败，继续使用本地文件');
                await visible('settings.data.credential_keychain');
                assert.equal(await readFile(marker, 'utf8'), '1');
                assert.equal(await readFile(localEntry, 'utf8'), 'fixture-only-secret');
                assert.equal(await readFile(join(credentials, otherReference), 'utf8'), 'other-fixture-secret');
            }
            await click('settings.close');
        }
        let explicitUseAt = 0;
        if (kind === 'ssh') {
            if (!(await h.query('sidebar.host')).some(shown)) await click('sidebar.restore');
            await click('sidebar.host');
            explicitUseAt = performance.now();
            await click('sidebar.host.connect');
        } else {
            if (!archive) {
                await click('workspace.empty.local');
                await visible('terminal.surface');
                await click('ai.strip');
            }
            await click('ai.prompt');
            await h.type_('test saved API key');
            explicitUseAt = performance.now();
            await click('ai.send');
        }
        if (response === 'success') {
            assert.equal(authenticatedPosts, 0, 'the first send waits for startup authorization');
            assert(!(await startupLog(data)).includes('startup credentials ms'), 'the first send was admitted while startup authorization was pending');
        }
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
            if (response === 'local' || response === 'trusted') assert.equal(calls(), 0);
            if (response === 'success') assert.equal(calls(), 1, 'first send shares the startup authorization');
            if (response === 'roundtrip') assert.equal(calls(), 2, 'the switched credential is usable through the vault');
            if (response.startsWith('reverse-')) assert.equal(calls(), response === 'reverse-cancel' ? 1 : 0);
        }
        assert((await h.resizeWindow(1280, 800)).ok);
        const timingLog = await h.waitFor(async () => {
            const contents = await startupLog(data);
            return contents.includes('startup interactive ms total=') && (startsLocal || contents.includes('startup credentials ms')) && contents;
        }, 6000);
        const stage = timingLog.match(/startup ms fonts=(\d+) paths_and_update=(\d+) scope=(\d+) data=(\d+) logging=(\d+)/);
        const interactive = timingLog.match(/startup interactive ms total=(\d+)/);
        const tick = timingLog.match(/startup first tick ms window_setup=(\d+) mount=(\d+) post_mount=(\d+) total=(\d+)/);
        assert(stage && tick && interactive);
        assert(!/AI history (preview|restore)/.test(timingLog));
        const stats = {
            fontsMs: +stage[1], pathsAndUpdateMs: +stage[2], credentialScopeMs: +stage[3],
            dataPreparationMs: +stage[4], loggingMs: +stage[5], windowSetupMs: +tick[1], mountMs: +tick[2],
            postMountMs: +tick[3], firstTickMs: +tick[4], interactiveMs: +interactive[1],
        };
        const unlock = timingLog.match(/startup credentials ms total=(\d+) result=(\w+)/);
        if (startsLocal) assert.equal(unlock, null);
        else {
            assert(unlock && timingLog.indexOf('startup interactive ms') < unlock.index!);
            assert.equal(unlock[2], response === 'cancel' ? 'CredentialAuthenticationCanceled' : 'ok');
        }
        if (promptsAtStartup) assert(firstCredentialAt !== null && firstCredentialAt < explicitUseAt);
        const firstCredentialRequestMs = firstCredentialAt !== null ? Math.round(firstCredentialAt - start) : null;
        report.cases.push({ kind, response, largeArchive: !!archive, stats, archiveResizeMs, firstCredentialRequestMs, nativeWindowMs: Math.round(shownAt ?? 0), workspaceReadyMs: readyMs, uiResizeDuringAuthorizationMs: responseMs, credentialUnlockMs: unlock ? +unlock[1] : null, authorizationRequests: calls(), outboundConnections: contacts, authenticatedPosts });
        await h.request('POST', '/zerowork/windows', { action: 'quit' });
    } catch (error) {
        await h.screenshot(join(output, kind+'-'+response+(archive ? '-history' : '')+'-failure.png')).catch(() => {});
        throw error;
    } finally {
        if (app.exitCode === null && app.signalCode === null) app.kill('SIGTERM');
        await ended;
        await new Promise<void>(done => server.close(() => done()));
        await writeFile(join(output, kind+'-'+response+(archive ? '-history' : '')+'.log'), logs);
        await rm(isolated, { recursive: true, force: true });
    }
}
try {
    for (const kind of ['ssh', 'ai'] as const) await scenario(kind);
    await scenario('ai', 'success');
    await scenario('ai', 'trusted');
    await scenario('ai', 'local');
    await scenario('ai', 'roundtrip');
    await scenario('ai', 'reverse-cancel');
    await scenario('ai', 'reverse-write-fail');
    await scenario('ai', 'reverse-verify-fail');
    if (process.env.ZW_STARTUP_HISTORY_FIXTURE) await scenario('ai', 'success', process.env.ZW_STARTUP_HISTORY_FIXTURE);
    report.ok = true;
} catch (error) {
    report.error = String(error);
    process.exitCode = 1;
} finally {
    await writeFile(join(output,'report.json'), JSON.stringify(report,null,2));
    console.log(JSON.stringify(report));
}
