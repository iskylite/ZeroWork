/** Context uses a measured input baseline and invalidates it on mutations. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, writeFile, open, realpath, readFile, rm} from 'node:fs/promises';
import {join, resolve} from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const out = resolve(process.argv[2] ?? '/tmp/zw-context-usage-results');
await mkdir(out, {recursive: true});
const isolated = await realpath(await mkdtemp('/tmp/zw-context-usage-'));
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc');
await mkdir(data); await mkdir(rpc);
const frame = (content: string) => 'data: ' + JSON.stringify({choices: [{index: 0, delta: {content}}]}) + '\n\ndata: [DONE]\n\n';
let replies = 0, summaries = 0, missingUsage = false;
const server = createServer(async (req, res) => {
    if (req.method !== 'POST') {
        res.end(JSON.stringify({data: [{id: 'idle-fixture'}, {id: 'other-fixture'}]}));
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
    if (body.messages[0]?.content?.startsWith('Create concise conversation memory')) {
        summaries += 1;
        res.end(frame('目标：检查上下文统计。'));
        return;
    }
    assert(body.tools?.length > 0, 'Exercise a real captured tool catalog');
    replies += 1;
    const text = 'data: ' + JSON.stringify({choices: [{index: 0, delta: {content: '用量检查完成。' + 'observed '.repeat(40)}}]}) + '\n\n';
    const usage = !missingUsage ? 'data: ' + JSON.stringify({choices: [], usage: {prompt_tokens: replies * 24000, completion_tokens: 160}}) + '\n\n' : '';
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
[[ai.providers.models]]
name="other-fixture"
context_window=200000
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
    const send = async (value: string) => { const turn = replies + 1; await click('ai.prompt'); await h.type_(value); await click('ai.send'); await h.waitFor(async () => (await h.query('ai.turn.complete')).filter(shown).length === turn || null, 15000); };
    const usageMenu = async () => { await click('ai.composer.usage'); return visible('ai.usage.menu'); };
    const summary = async () => text(await visible('ai.usage.summary'));
    const noBaseline = async () => { const menu = await usageMenu(); assert(!text(menu).includes('基准输入（实测）'), text(menu)); assert(text(menu).includes('终端上下文')); await h.key('escape'); };
    await send('第一轮：检查上下文实测值');
    let menu = await usageMenu();
    assert(text(menu).includes('基准输入（实测）'));
    assert(text(menu).includes('新增内容（估算）'));
    let values = (await h.query('ai.usage.part.value')).filter(shown).map(text);
    assert.equal(values[0], '24.0K');
    assert(values[1].startsWith('~'));
    const beforeDraft = await summary();
    await h.sleep(300); assert((await h.screenshot(join(out, 'measured-context.png'))).ok);
    await h.key('escape'); await click('ai.prompt'); await h.type_('x'.repeat(4000));
    menu = await usageMenu(); values = (await h.query('ai.usage.part.value')).filter(shown).map(text);
    assert.equal(values[0], '24.0K'); assert.notEqual(await summary(), beforeDraft);
    report.checks.push('24000 measured input retained; only answer and draft estimated, fixed costs not added twice');
    await h.key('escape'); await click('ai.prompt'); await h.key('a', {cmd: true}); await h.key('backspace');
    const viewport = await visible('ai.conversation.viewport'); await h.scrollAt(viewport.rect.x + viewport.rect.w / 2, viewport.rect.y + viewport.rect.h / 2, 0, 100000);
    await click('ai.message.edit'); await click('ai.message.edit.input'); await h.key('a', {cmd: true}); await h.type_('第一轮已编辑'); await click('ai.message.edit.save');
    await noBaseline(); report.checks.push('Editing user history invalidates the measured baseline');
    await send('第二轮：重新获取实测基准');
    menu = await usageMenu(); assert(text(menu).includes('基准输入（实测）'));
    values = (await h.query('ai.usage.part.value')).filter(shown).map(text); assert.equal(values[0], '48.0K'); await h.key('escape');
    const selectModel = async (name: string) => {
        await click('ai.composer.model');
        const option = await h.waitFor(async () => (await h.query('ai.model.option')).filter(shown).find((n: any) => text(n).includes(name)) ?? null, 5000);
        assert((await h.clickAt(option.rect.x + option.rect.w / 2, option.rect.y + option.rect.h / 2)).ok);
    };
    await selectModel('other-fixture'); await noBaseline();
    await selectModel('idle-fixture'); await noBaseline();
    report.checks.push('Switching models invalidates permanently; switching back does not revive an old baseline');
    await send('第三轮：准备压缩上下文');
    menu = await usageMenu(); assert(text(menu).includes('基准输入（实测）'));
    await click('ai.usage.compaction.start');
    await h.waitFor(async () => summaries > 0 && !(await h.query('ai.usage.compaction.cancel')).some(shown) || null, 20000);
    await h.key('escape'); await noBaseline();
    report.checks.push('Successful compaction replaces history and discards the old measured baseline');
    missingUsage = true; await send('第四轮：服务商缺少用量'); await noBaseline();
    report.checks.push('Missing provider usage falls back to an explicit estimate');
    await h.resizeWindow(860, 480); await usageMenu(); await h.sleep(300);
    assert((await h.screenshot(join(out, 'estimated-context-compact.png'))).ok);
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
