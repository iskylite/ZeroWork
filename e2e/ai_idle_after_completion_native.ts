/** Completed AI turns must retain their nodes and return to an idle scene. */
import assert from 'node:assert/strict';
import {execFileSync, spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, writeFile, open, realpath, readFile, rm} from 'node:fs/promises';
import {join, resolve} from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const out = resolve(process.argv[2] ?? '/tmp/zw-ai-idle-results');
await mkdir(out, {recursive: true});
const isolated = await realpath(await mkdtemp('/tmp/zw-ai-idle-'));
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc');
await mkdir(data); await mkdir(rpc);
const frame = (content: string) => 'data: ' + JSON.stringify({choices: [{index: 0, delta: {content}}]}) + '\n\ndata: [DONE]\n\n';
let replies = 0;
const server = createServer(async (req, res) => {
    if (req.method !== 'POST') {
        res.end(JSON.stringify({data: [{id: 'idle-fixture'}]}));
        return;
    }
    let raw = '';
    for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw);
    res.writeHead(200, {'content-type': 'text/event-stream'});
    if (body.messages[0]?.content?.startsWith('将用户的问题概括')) {
        res.end(frame('中文回合闲置检查'));
        return;
    }
    assert(body.tools?.length > 0, 'Exercise a real captured tool catalog');
    replies += 1;
    res.end(frame(`第 ${replies} 轮已完成，中文与 emoji 正常。🙂`));
});
await new Promise<void>(done => server.listen(0, '127.0.0.1', done));
const port = (server.address() as any).port;
await writeFile(join(data, 'config.toml'), `[meta]
config_revision=1
[ui]
theme="dark"
font_family="Menlo"
font_size=14
[ai]
default_provider="idle-fixture"
[[ai.providers]]
id="idle-fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:${port}/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="idle-fixture"
context_window=200000
default=true
`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(out, 'app.log'), 'w');
const environment = {...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: ''};
for (const name of ['ZEROWORK_AI_MOCK', 'ZEROWORK_AI_ENDPOINT', 'ZEROWORK_AI_MODEL', 'ZEROWORK_AI_PROVIDER']) delete environment[name];
const app = spawn(join(prefix, 'bin/zerowork'), [], {env: environment, stdio: ['ignore', log.fd, log.fd]});
const exited = new Promise(done => app.once('exit', (code, signal) => done({code, signal})));
const shown = (n: any) => n && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
const click = async (id: string) => { await visible(id); assert((await h.clickTestId(id)).ok, id); };
const pause = (ms: number) => new Promise(done => setTimeout(done, ms));
const cpuMs = () => {
    const time = execFileSync('/bin/ps', ['-p', String(app.pid), '-o', 'time='], {encoding: 'utf8'}).trim();
    const parts = time.split(':').map(Number);
    return parts.reduce((total, part) => total * 60 + part, 0) * 1000;
};
const report: any = {status: 'running', checks: [], samples: []};
try {
    await h.waitForServerReady(60000);
    assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
    await h.resizeWindow(1440, 900);
    await click('workspace.empty.local'); await visible('terminal.surface'); await click('toolbar.ai');
    for (let turn = 1; turn <= 2; turn++) {
        await click('ai.prompt'); await h.type_(`第 ${turn} 轮：请用中文回答 🙂`); await click('ai.send');
        await h.waitFor(async () => (await h.query('ai.turn.complete')).filter(shown).length === turn || null, 15000);
        // Initial model discovery and title publication may finish after the
        // answer and legitimately rebuild once. Let those workers settle first.
        await pause(5000);
        let previous = '', stable = 0;
        const settleDeadline = performance.now() + 15000;
        while (stable < 5) {
            assert(performance.now() < settleDeadline, 'Transcript never settles after completion');
            await pause(250);
            const current = JSON.stringify((await h.query('ai.message.user.row')).filter(shown).map((n: any) => n.id));
            stable = current === previous ? stable + 1 : 0;
            previous = current;
        }
        const ids = (await h.query('ai.message.user.row')).filter(shown).map((n: any) => n.id);
        assert.equal(ids.length, turn);
        const before = await h.stats();
        const start = performance.now(), cpu = cpuMs();
        // No harness traffic here: RPC/frame waits would conceal an idle loop.
        await pause(3000);
        const cpuDeltaMs = cpuMs() - cpu, elapsedMs = performance.now() - start;
        const after = await h.stats();
        const cpuPercent = 100 * cpuDeltaMs / elapsedMs;
        report.samples.push({turn, nodeIds: ids, cpuDeltaMs, elapsedMs, cpuPercent, frameDelta: after.frame_count - before.frame_count});
        const feedback = (await h.query('ai.feedback.text')).filter(shown).map((n: any) => n.text ?? '').join('');
        assert(!feedback.includes('InvalidUtf8'), feedback);
        assert.deepEqual((await h.query('ai.message.user.row')).filter(shown).map((n: any) => n.id), ids, 'Completed transcript must not be rebuilt while idle');
        assert(cpuPercent < 40, `Idle process consumed ${cpuPercent.toFixed(1)}% CPU`);
        report.checks.push(`Turn ${turn}: joined tool-catalog cleanup leaves stable message nodes, no InvalidUtf8, and idle CPU below 40%`);
    }
    assert.equal(replies, 2);
    assert((await h.screenshot(join(out, 'completed-idle.png'))).ok);
    report.status = 'passed';
} catch (error) {
    report.status = 'failed'; report.error = String(error); process.exitCode = 1;
    await h.screenshot(join(out, 'failure.png')).catch(() => {});
} finally {
    // Only terminate the isolated fixture created above; live SSH is untouched.
    if (app.exitCode === null && app.signalCode === null) app.kill('SIGTERM');
    await exited;
    server.closeAllConnections(); await new Promise<void>(done => server.close(() => done()));
    await log.close();
    await rm(isolated, {recursive: true, force: true});
    await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
}
console.log(JSON.stringify(report, null, 2));
