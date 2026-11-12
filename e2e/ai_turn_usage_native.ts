/** Verify native turn details and the history sent across actual provider requests. */
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
const frame = (delta: object) => 'data: ' + JSON.stringify({choices: [{index: 0, delta}]}) + '\n\n';
const usage = (input: number, output: number) => 'data: ' + JSON.stringify({choices: [], usage: {prompt_tokens: input, completion_tokens: output}}) + '\n\n';
const done = 'data: [DONE]\n\n';
let replies = 0;
let finishThinking: (() => void) | undefined;
const reasoning = '核对上下文后继续处理。';
const longQuestions = Array.from({length: 4}, (_, i) => `history-turn-${i + 1} ` + `entry-${i + 1} `.repeat(1700).trimEnd());
const longAnswers = longQuestions.map((_, i) => `history-answer-${i + 1}`);
const contextTool = 'host__get_ucurrent_ucontext';
const readIds = ['history-context-read-1', 'history-context-read-2', 'history-context-read-3'];
const retainedResults = new Map<string, string>();
let longRequests = 0;
let longCompleted = 0;
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
        res.end(frame({content: '中文回合闲置检查'}) + done);
        return;
    }
    assert(body.tools?.length > 0, 'Exercise a real captured tool catalog');
    const users = body.messages.filter((message: any) => message.role === 'user');
    const longTurn = longQuestions.indexOf(users.at(-1)?.content);
    if (users.at(-1)?.content?.startsWith('history-turn-')) assert.notEqual(longTurn, -1, 'Provider must receive the entire long question');
    if (longTurn !== -1) {
        longRequests += 1;
        assert.equal(longTurn, longCompleted);
        assert.deepEqual(users.slice(-longTurn - 1).map((message: any) => message.content), longQuestions.slice(0, longTurn + 1));
        for (const answer of longAnswers.slice(0, longTurn)) {
            assert(body.messages.some((m: any) => m.role === 'assistant' && m.content === answer));
        }
        let priorResult = -1;
        const present = readIds.filter(id => body.messages.some((m: any) => m.role === 'tool' && m.tool_call_id === id));
        assert.deepEqual(present, readIds.slice(0, longRequests - 1));
        for (const id of present) {
            const call = body.messages.findIndex((m: any) => m.role === 'assistant' && m.tool_calls?.some((c: any) => c.id === id && c.function.name === contextTool && c.function.arguments === '{}'));
            const result = body.messages.findIndex((m: any) => m.role === 'tool' && m.tool_call_id === id);
            assert(call > priorResult && result === call + 1, `matching tool result must follow ${id}`);
            const content = body.messages[result].content;
            if (retainedResults.has(id)) assert.equal(content, retainedResults.get(id));
            else {
                const result = JSON.parse(content);
                assert.equal(result.status, 'succeeded');
                const context = JSON.parse(result.content.find((block: any) => block.type === 'structured').text);
                assert.equal(context.initial_kind, 'session');
                assert.equal(context.grants.read_state, true);
                retainedResults.set(id, content);
            }
            priorResult = result;
        }
        if (longTurn === 0 && present.length < readIds.length) {
            assert(body.tools.some((tool: any) => tool.function.name === contextTool));
            res.end(frame({tool_calls: [{index: 0, id: readIds[present.length], type: 'function', function: {name: contextTool, arguments: '{}'}}]}) + usage(20000, 32) + done);
        } else {
            assert.deepEqual(present, readIds);
            longCompleted += 1;
            res.end(frame({content: longAnswers[longTurn]}) + usage(22000 + longTurn * 2000, 15) + done);
        }
        return;
    }
    replies += 1;
    if (replies === 1) {
        // Invalid arguments produce a tool result without launching a command.
        res.write(frame({reasoning_content: reasoning}));
        finishThinking = () => res.end(frame({tool_calls: [{index: 0, id: 'usage-fixture-call', type: 'function', function: {name: 'run_command', arguments: '{}'}}]}) + usage(1000, 60) + done);
        return;
    }
    assert(body.messages.some((m: any) => m.role === 'user' && m.content === '请检查用量'));
    assert(body.messages.some((m: any) => m.role === 'tool' && m.tool_call_id === 'usage-fixture-call'));
    if (replies === 3) assert(body.messages.some((m: any) => m.role === 'assistant' && m.content === '用量检查完成。'));
    res.end(frame({content: '用量检查完成。'}) + (replies === 2 ? usage(1400, 100) : '') + done);
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
    await visible('ai.step_group.header');
    assert(!(await h.query('ai.thinking')).some(shown), 'Thinking details start collapsed');
    await click('ai.step_group.header');
    assert(text(await visible('ai.thinking')).includes(reasoning));
    await click('ai.step_group.header');
    await h.waitFor(async () => !(await h.query('ai.thinking')).some(shown) || null, 5000);
    assert(finishThinking);
    finishThinking();
    report.checks.push('Streamed thinking appears on demand and collapses again while the provider is still streaming');
    await visible('ai.turn.complete');
    assert.equal(text(await visible('ai.turn.tokens')), '用量明细');
    assert((await h.screenshot(join(out, 'turn-usage.png'))).ok);
    await click('ai.turn.tokens');
    const details = await visible('ai.turn.usage.details');
    assert.equal(text(await visible('ai.turn.usage.total')), '本回合累计用量2.6K Token');
    assert.equal(text(await visible('ai.turn.usage.input')), '累计输入2,400');
    assert.equal(text(await visible('ai.turn.usage.output')), '累计输出160');
    assert.equal(text(await visible('ai.turn.usage.requests')), '模型请求2 次');
    assert(text(details).includes('共享的上下文会在每次请求中重复计入。'));
    assert(details.rect.w > 0 && details.rect.h > 60);
    await h.sleep(300);
    assert((await h.screenshot(join(out, 'turn-usage-details.png'))).ok);
    await h.key('escape');
    await h.waitFor(async () => !(await h.query('ai.turn.usage.details')).some(shown) || null, 5000);
    await click('ai.composer.usage');
    const context = await visible('ai.usage.menu');
    assert(text(context).includes('基准输入（实测）'));
    assert.equal(text(await visible('ai.usage.part.value')), '1.4K');
    assert(!text(await visible('ai.usage.summary')).includes('2.6K'));
    await h.key('escape');
    await h.waitFor(async () => !(await h.query('ai.usage.menu')).some(shown) || null, 5000);
    await h.resizeWindow(860, 480);
    await click('ai.turn.tokens');
    const compact = await visible('ai.turn.usage.details');
    assert(compact.rect.x >= 0 && compact.rect.y >= 0);
    assert(compact.rect.x + compact.rect.w <= 860);
    await h.sleep(300);
    assert((await h.screenshot(join(out, 'turn-usage-compact.png'))).ok);
    await h.key('escape');
    report.checks.push('Two requests report 2.6K cumulative usage while the current context uses only the 1.4K latest input as its baseline');
    await click('ai.prompt'); await h.type_('服务商不返回用量'); await click('ai.send');
    await h.waitFor(async () => (await h.query('ai.turn.complete')).filter(shown).length === 2 || null, 15000);
    const usages = (await h.query('ai.turn.tokens')).filter(shown);
    assert.equal(text(usages.at(-1)), '用量明细');
    const {x, y, w, h: height} = usages.at(-1).rect;
    assert((await h.clickAt(x + w / 2, y + height / 2)).ok);
    const missing = await visible('ai.turn.usage.details');
    assert(text(missing).includes('服务商未返回完整用量。'));
    assert.equal(text(await visible('ai.turn.usage.requests')), '模型请求1 次');
    assert(!(await h.query('ai.turn.usage.input')).some(shown));
    assert(!(await h.query('ai.turn.usage.output')).some(shown));
    await h.sleep(300);
    assert((await h.screenshot(join(out, 'turn-usage-unreported.png'))).ok);
    report.checks.push('The next turn receives the previous answer and tool result; missing provider usage stays unknown');
    await h.key('escape');
    await h.resizeWindow(1440, 900);
    for (const [index, question] of longQuestions.entries()) {
        await click('ai.prompt');
        await h.type_(question);
        await click('ai.send');
        await h.waitFor(async () => longCompleted === index + 1 && !(await h.query('ai.stop')).some(shown) || null, 20000);
    }
    assert.equal(longRequests, 7);
    assert.equal(retainedResults.size, 3);
    report.checks.push('Four long turns replay every previous question and answer verbatim and preserve three real session context reads with their matching results');
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
