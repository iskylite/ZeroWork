/** Turn usage shows provider totals, request counts and missing-usage states. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, writeFile, open, realpath, readFile, rm} from 'node:fs/promises';
import {join, resolve} from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const out = resolve(process.argv[2] ?? '/tmp/zw-turn-usage-results');
await mkdir(out, {recursive: true});
const isolated = await realpath(await mkdtemp('/tmp/zw-turn-usage-'));
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
    const text = 'data: ' + JSON.stringify({choices: [{index: 0, delta: {content: '用量检查完成。'}}]}) + '\n\n';
    const usage = replies === 1 ? 'data: ' + JSON.stringify({choices: [], usage: {prompt_tokens: 2400, completion_tokens: 160}}) + '\n\n' : '';
    res.end(text + usage + 'data: [DONE]\n\n');
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
const text = (n: any): string => n.text ?? (n.children ?? []).map(text).join('');
const report: any = {status: 'running', checks: []};
try {
    await h.waitForServerReady(60000);
    assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
    await h.resizeWindow(1440, 900);
    await click('workspace.empty.local'); await visible('terminal.surface'); await click('toolbar.ai');
    await click('ai.prompt'); await h.type_('请检查用量'); await click('ai.send');
    await visible('ai.turn.complete');
    assert.equal(text(await visible('ai.turn.tokens')), '本回合用量 2.6K');
    assert((await h.screenshot(join(out, 'turn-usage.png'))).ok);
    await click('ai.turn.tokens');
    const details = await visible('ai.turn.usage.details');
    assert(text(details).includes('输入 2400 Token'));
    assert(text(details).includes('输出 160 Token'));
    assert(text(details).includes('请求次数 1'));
    assert(details.rect.w > 0 && details.rect.h > 60);
    await h.sleep(300);
    assert((await h.screenshot(join(out, 'turn-usage-details.png'))).ok);
    await h.key('escape');
    await h.waitFor(async () => !(await h.query('ai.turn.usage.details')).some(shown) || null, 5000);
    await h.resizeWindow(860, 480);
    await click('ai.turn.tokens');
    const compact = await visible('ai.turn.usage.details');
    assert(compact.rect.x >= 0 && compact.rect.y >= 0);
    assert(compact.rect.x + compact.rect.w <= 860);
    await h.sleep(300);
    assert((await h.screenshot(join(out, 'turn-usage-compact.png'))).ok);
    await h.key('escape');
    report.checks.push('Provider input/output totals, one-request count, click, Escape and compact-window popup');
    await click('ai.prompt'); await h.type_('服务商不返回用量'); await click('ai.send');
    await h.waitFor(async () => (await h.query('ai.turn.complete')).filter(shown).length === 2 || null, 15000);
    const usages = (await h.query('ai.turn.tokens')).filter(shown);
    assert.equal(text(usages.at(-1)), '本回合用量未返回');
    report.checks.push('Missing provider usage stays unknown');
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
