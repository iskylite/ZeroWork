/** Durable context baseline across real process restarts and model changes. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, writeFile, readFile, open, realpath, rm} from 'node:fs/promises';
import {join, resolve} from 'node:path';
const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const out = resolve(process.argv[2] ?? '/tmp/zw-context-restart-results');
await mkdir(out, {recursive: true});
const isolated = await realpath(await mkdtemp('/tmp/zw-context-restart-'));
const data = join(isolated, 'data'); await mkdir(data);
let replies = 0, phase = 0, app: any = null;
const frame = (content: string) => 'data: ' + JSON.stringify({choices: [{index: 0, delta: {content}}]}) + '\n\n';
const server = createServer(async (req, res) => {
    if (req.method !== 'POST') { res.end(JSON.stringify({data: [{id: 'restart-fixture'}, {id: 'other-fixture'}]})); return; }
    let raw = ''; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw);
    res.writeHead(200, {'content-type': 'text/event-stream'});
    if (body.messages[0]?.content?.startsWith('将用户的问题概括')) { res.end(frame('上下文基准恢复') + 'data: [DONE]\n\n'); return; }
    replies++;
    res.end(frame('已完成上下文基准检查。') + 'data: ' + JSON.stringify({choices: [], usage: {prompt_tokens: 24000, completion_tokens: 160}}) + '\n\ndata: [DONE]\n\n');
});
await new Promise<void>(done => server.listen(0, '127.0.0.1', done));
const port = (server.address() as any).port;
async function config(other = false) {
    await writeFile(join(data, 'config.toml'), `[meta]
config_revision=1
[ui]
theme="dark"
font_family="Menlo"
font_size=14
[ai]
default_provider="restart-fixture"
[[ai.providers]]
id="restart-fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:${port}/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="restart-fixture"
context_window=200000
default=${!other}
[[ai.providers.models]]
name="other-fixture"
context_window=200000
default=${other}
`);
}
const log = await open(join(out, 'app.log'), 'w');
const shown = (n: any) => n && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const text = (n: any): string => n.text ?? (n.children ?? []).map(text).join('');
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
const click = async (id: string) => { await visible(id); assert((await h.clickTestId(id)).ok, id); };
async function launch() {
    const rpc = join(isolated, 'rpc-' + ++phase); await mkdir(rpc);
    process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
    const env = {...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZDOTDIR: isolated, OPENAI_API_KEY: '', ANTHROPIC_API_KEY: ''};
    for (const name of ['ZEROWORK_AI_MOCK', 'ZEROWORK_AI_ENDPOINT', 'ZEROWORK_AI_MODEL', 'ZEROWORK_AI_PROVIDER']) delete env[name];
    app = spawn(join(prefix, 'bin/zerowork'), [], {env, stdio: ['ignore', log.fd, log.fd]});
    await h.waitForServerReady(30000);
    assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
    await h.resizeWindow(1280, 900);
    await click('workspace.empty.local'); await visible('terminal.surface'); await click('toolbar.ai');
}
async function stop() {
    if (app && app.exitCode === null && app.signalCode === null) {
        const exited = new Promise(done => app.once('close', done)); app.kill('SIGTERM'); await exited;
    }
    app = null;
}
async function restore() {
    await click('ai.sessions'); await click('ai.session.restore.1');
    await h.sleep(150);
    if ((await h.query('ai.session.close.accept')).some(shown)) await click('ai.session.close.accept');
    await h.waitFor(async () => (await h.query('ai.message.user.text')).filter(shown).some((n: any) => text(n).includes('重启恢复基准')) || null, 15000);
}
async function menu() { await click('ai.composer.usage'); return visible('ai.usage.menu'); }
async function lastPresentation() {
    const lines = (await readFile(join(data, 'ai-sessions.jsonl'), 'utf8')).trim().split('\n').map(line => JSON.parse(line));
    const events = lines.map(row => row.event).filter(event => event?.kind === 'presentation');
    const source = events.find(event => event.presentation.includes('重启恢复基准'));
    // Subsequent records may contain only a compact presentation patch.
    return source && events.findLast(event => JSON.stringify(event.conversation) === JSON.stringify(source.conversation));
}
const report: any = {status: 'running', checks: []};
try {
    await config(); await launch();
    await click('ai.prompt'); await h.type_('重启恢复基准'); await click('ai.send'); await visible('ai.turn.complete');
    await h.waitFor(async () => (await lastPresentation())?.context_usage?.baseline?.sample?.input_tokens === 24000 || null, 10000);
    await stop();
    await launch(); await restore();
    assert(text(await menu()).includes('上次请求输入（实测）'));
    assert(text(await visible('ai.usage.measured')).endsWith('24.0K'));
    assert.equal(replies, 1, 'Restoring a counter must not query the model');
    await h.sleep(300); assert((await h.screenshot(join(out, 'restored-measured-context.png'))).ok);
    report.checks.push('A fresh process restores the 24000-token measured baseline without a model request');
    await stop();
    await config(true); await launch(); await restore();
    assert(!text(await menu()).includes('上次请求输入（实测）'));
    await h.waitFor(async () => (await lastPresentation())?.context_usage === null || null, 10000);
    report.checks.push('A different configured model rejects the saved baseline and durably clears it');
    await stop();
    await config(); await launch(); await restore();
    assert(!text(await menu()).includes('上次请求输入（实测）'));
    assert.equal(replies, 1);
    report.checks.push('Another restart with the original model does not revive the invalidated baseline');
    report.status = 'passed';
} catch (error) {
    report.status = 'failed'; report.error = String(error); process.exitCode = 1;
    await h.screenshot(join(out, 'failure.png')).catch(() => {});
    await writeFile(join(out, 'failure-tree.json'), JSON.stringify(await h.tree().catch(() => null), null, 2));
} finally {
    await stop(); server.closeAllConnections(); await new Promise<void>(done => server.close(() => done()));
    await log.close(); report.modelRequests = replies;
    await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
    await rm(isolated, {recursive: true, force: true});
}
console.log(JSON.stringify(report, null, 2));
