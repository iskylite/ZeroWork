/** Single-connection AI binding, restore and copy regression in the real app.
 * Uses one owned Local PTY, isolated data and a loopback model.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, open, readFile, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const out = resolve(process.argv[2] ?? '/tmp/zw-ai-single-connection');
const legacyMode = process.argv.includes('--legacy');
await mkdir(out, {recursive: true});
const isolated = await mkdtemp('/private/tmp/zw-ai-single-');
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc'), zdot = join(isolated, 'zdot');
for (const directory of [data, rpc, zdot]) await mkdir(directory);
await writeFile(join(zdot, '.zshrc'), "PS1='single-connection%# '\n");
const frame = (content: string) => 'data: ' + JSON.stringify({choices: [{index: 0, delta: {content}}]}) + '\n\ndata: [DONE]\n\n';
const requests: any[] = [];
const server = createServer(async (req, res) => {
    if (req.method !== 'POST') { res.end('{"data":[{"id":"single-fixture"}]}'); return; }
    let raw = '';
    for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw);
    res.writeHead(200, {'content-type': 'text/event-stream'});
    if (!body.tools?.length) { res.end(frame('单连接恢复检查')); return; }
    requests.push(body);
    const question = body.messages.findLast((message: any) => message.role === 'user').content;
    res.end(frame('ANSWER: ' + question));
});
await new Promise<void>(done => server.listen(0, '127.0.0.1', done));
await writeFile(join(data, 'config.toml'), `[meta]
config_revision=1
[ui]
theme="dark"
font_size=14
[ai]
default_provider="single-fixture"
[[ai.providers]]
id="single-fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:${(server.address() as any).port}/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="single-fixture"
context_window=200000
default=true
`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
if (legacyMode) {
    // Pre-presentation history, a previously saved empty presentation, and a
    // saved binding from a dead process, all with real canonical messages.
    const rows = [1, 2, 3].map(index => ({schema: 1, event: {
        kind: index === 3 ? 'migrate_bound' : 'migrate_closed',
        conversation: String(index).repeat(32), revision: 2, owner: {session: 1},
        initial_origin: {session: 1}, turn: 1,
        agent: index === 3 ? 'a'.repeat(32) : null,
        presentation: index === 2 ? JSON.stringify({schema: 1, messages: []}) : null,
    }, messages: [{role: 'user', content: `LEGACY_${index} 旧问题`}, {role: 'assistant', content: `LEGACY_ANSWER_${index} 旧答案`}]}));
    await writeFile(join(data, 'ai-sessions.jsonl'), rows.map(row => JSON.stringify(row)).join('\n') + '\n');
}
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(join(prefix, 'bin/zerowork'), [], {env: {...process.env, ZEROWORK_DATA_DIR: data, ZDOTDIR: zdot, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: ''}, stdio: ['ignore', log.fd, log.fd]});
const exited = new Promise(done => app.once('close', done));
const alive = () => app.exitCode === null && app.signalCode === null;
const shown = (node: any) => node && node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect?.w > 0 && node.rect?.h > 0;
const flat = (node: any): any[] => Array.isArray(node) ? node.flatMap(flat) : node ? [node, ...(node.children ?? []).flatMap(flat)] : [];
const text = (node: any) => flat(node).map(node => node.text ?? '').join(' ');
const visible = (id: string) => h.waitFor(async () => { assert(alive(), 'native app exited'); return (await h.query(id)).find(shown) ?? null; }, 15000);
const absent = (id: string) => h.waitFor(async () => !(await h.query(id)).some(shown) || null, 15000);
const report: any = {status: 'running', isolated, checks: []};
const click = async (id: string) => { report.last_action = id; await visible(id); assert((await h.clickTestId(id)).ok, id); };
async function confirm() {
    await h.sleep(180);
    if ((await h.query('ai.session.close.accept')).some(shown)) await click('ai.session.close.accept');
    await absent('ai.session.close.confirmation');
}
async function full(questions: string[]) {
    await h.waitFor(async () => (await h.query('ai.turn.complete')).filter(shown).length === questions.length || null, 15000);
    const users = (await h.query('ai.message.user.text')).filter(shown);
    assert.equal(users.length, questions.length, 'complete restored display history');
    for (const question of questions) assert(text(users).includes(question), question);
    const feedback = text((await h.query('ai.feedback.text')).filter(shown));
    assert(!/BindingConflict|BindingChanged|InvalidUtf8|ConversationNotFound/.test(feedback), feedback);
}
async function send(question: string, expected: string[]) {
    await click('ai.prompt'); await h.type_(question); await click('ai.send'); await full(expected);
    const users = requests.at(-1).messages.filter((message: any) => message.role === 'user').map((message: any) => message.content);
    for (const value of expected) assert(users.some((content: string) => content.includes(value)), 'model context: ' + value);
}
async function menu() { await click('ai.sessions'); await visible('ai.sessions.menu'); }
async function binding(id: number, bound: boolean) {
    const row = await visible('ai.session.row.' + id);
    assert(flat(row).some(node => node.test_id === (bound ? 'ai.session.bound' : 'ai.session.unbound')), 'binding for row ' + id);
}
async function journal() {
    const records = new Map<string, any>();
    for (const line of (await readFile(join(data, 'ai-sessions.jsonl'), 'utf8')).trim().split('\n')) {
        const row = JSON.parse(line), event = row.event;
        if (!event) continue;
        const record = records.get(event.conversation) ?? {id: event.conversation};
        if (['create', 'migrate_bound', 'fork_bound', 'bind', 'handoff'].includes(event.kind)) record.bound = true;
        if (['unbind', 'migrate_closed', 'fork'].includes(event.kind)) record.bound = false;
        if (event.kind === 'remove') record.removed = true;
        if (event.presentation) record.presentation = event.presentation;
        records.set(event.conversation, record);
    }
    return [...records.values()].filter(record => !record.removed);
}
async function boundCount(count: number) {
    assert.equal((await journal()).filter(record => record.bound).length, count, 'durable binding count with one connection');
}
try {
    await h.waitForServerReady(60000); await h.resizeWindow(1280, 960);
    assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
    await click('workspace.empty.local'); await visible('terminal.surface'); await click('toolbar.ai');
    if (legacyMode) {
        async function legacyHistory(index: number) {
            await h.waitFor(async () => text((await h.query('ai.message.user.text')).filter(shown)).includes('LEGACY_' + index) || null, 10000);
            assert(text((await h.query('ai.conversation')).filter(shown)).includes('LEGACY_ANSWER_' + index), 'legacy assistant answer');
            await boundCount(1);
        }
        await menu(); await binding(3, false); await click('ai.session.restore.1'); await confirm();
        await legacyHistory(1); await h.screenshot(join(out, '01-legacy-restored.png'));
        report.checks.push('History without a presentation restores visible questions and answers on one connection');
        await menu(); await click('ai.session.copy_use.2'); await confirm(); await legacyHistory(2);
        await h.screenshot(join(out, '02-legacy-copy.png'));
        report.checks.push('Copy-and-use repairs an empty saved presentation using the retained canonical history');
        await menu(); await click('ai.session.restore.3'); await confirm(); await legacyHistory(3);
        await click('ai.prompt'); await h.type_('LEGACY_FOLLOWUP'); await click('ai.send');
        await h.waitFor(async () => requests.length === 1 && text((await h.query('ai.response')).filter(shown)).includes('LEGACY_FOLLOWUP') || null, 15000);
        assert(requests[0].messages.some((message: any) => message.content.includes('LEGACY_3')));
        report.checks.push('A saved orphan binding is released on restart; restore and a follow-up keep the old context');
        report.status = 'passed';
    } else {
    await send('ORIGINAL 单连接原问题', ['ORIGINAL']);
    await menu(); await binding(1, true); await boundCount(1);
    // Copy the current conversation onto its own attached Agent.
    await click('ai.session.copy_use.1'); await confirm(); await full(['ORIGINAL']);
    await send('COPY_FOLLOWUP 副本继续', ['ORIGINAL', 'COPY_FOLLOWUP']);
    await menu(); await binding(1, false); await binding(2, true); await boundCount(1);
    await h.screenshot(join(out, '01-single-copy.png')); await click('ai.sessions.close');
    report.checks.push('Copy-and-use on the same single connection switches history and model context, releases the original binding and permits a follow-up');
    // A fresh welcome must leave the old conversation recoverable.
    await click('ai.session.new'); await confirm(); await menu();
    await binding(2, false); await boundCount(0); await visible('ai.session.restore.2');
    await click('ai.session.restore.1'); await confirm(); await full(['ORIGINAL']);
    await send('RESTORE_FOLLOWUP 原会话恢复后继续', ['ORIGINAL', 'RESTORE_FOLLOWUP']);
    await menu(); await binding(1, true); await binding(2, false); await boundCount(1);
    await h.screenshot(join(out, '02-single-restored.png')); await click('ai.sessions.close');
    report.checks.push('New unbinds the prior conversation; restoring the original restores its own history and context, without the copy follow-up');
    // Close the AI window, reopen its welcome, and restore the other history.
    await click('ai.close'); await visible('ai.close.confirmation'); await click('ai.close.confirmation.confirm');
    await absent('ai.panel'); await click('toolbar.ai'); await menu(); await boundCount(0);
    await click('ai.session.restore.2'); await confirm(); await full(['ORIGINAL', 'COPY_FOLLOWUP']);
    await send('REOPEN_FOLLOWUP 重新打开后继续', ['ORIGINAL', 'COPY_FOLLOWUP', 'REOPEN_FOLLOWUP']);
    report.checks.push('Closing and reopening the AI window releases its old binding; another history restores and continues on the same connection');
    // Plain copy from the read-only dialog must publish a real unbound copy.
    const beforeCopy = await journal();
    await menu(); await click('ai.session.jump.1'); await visible('ai.history');
    await click('ai.history.copy'); await absent('ai.history');
    await visible('ai.sessions.menu'); await boundCount(1);
    const afterCopy = await journal(); assert.equal(afterCopy.length, beforeCopy.length + 1);
    const fresh = afterCopy.at(-1); assert.equal(fresh.bound, false);
    assert(!beforeCopy.some(record => record.id === fresh.id));
    await h.screenshot(join(out, '03-copy-history.png'));
    const copiedRow = (await h.query('ai.sessions.menu')).flatMap(flat).filter((node: any) => /^ai.session.row.\d+$/.test(node.test_id ?? '')).at(-1);
    const copiedId = copiedRow.test_id.split('.').at(-1);
    await click('ai.session.restore.' + copiedId); await confirm(); await full(['ORIGINAL', 'RESTORE_FOLLOWUP']);
    await send('PLAIN_COPY_FOLLOWUP 普通副本继续', ['ORIGINAL', 'RESTORE_FOLLOWUP', 'PLAIN_COPY_FOLLOWUP']);
    report.checks.push('Copy without use publishes a distinct unbound history; using it later restores the copied context and permits a follow-up');
    report.status = 'passed';
    }
} catch (error) {
    report.status = 'failed'; report.error = String(error); process.exitCode = 1;
    await h.screenshot(join(out, 'failure.png')).catch(() => {});
    const state: any = {};
    for (const id of ['ai.sessions.menu', 'ai.conversation', 'ai.feedback.text', 'ai.close.confirmation']) state[id] = await h.query(id).catch(() => null);
    await writeFile(join(out, 'failure-tree.json'), JSON.stringify(state, null, 2));
} finally {
    try {
        if (alive()) await Promise.race([h.request('POST', '/zerowork/windows', {action: 'quit'}), exited]);
        const deadline = performance.now() + 15000;
        while (alive() && performance.now() < deadline) {
            for (const id of ['settings.close.discard', 'local.close.accept', 'session.close.accept']) {
                if (!alive()) break;
                const nodes = await h.query(id).catch(() => []);
                if (Array.isArray(nodes) && nodes.some(shown)) await h.clickTestId(id);
            }
            await Promise.race([exited, h.sleep(80)]);
        }
    } catch (error) { report.quit_error = String(error); }
    if (alive()) { report.forced = true; app.kill('SIGTERM'); }
    await exited; report.exit_code = app.exitCode;
    if (report.forced || app.exitCode !== 0) { report.status = 'failed'; process.exitCode = 1; }
    server.closeAllConnections(); await new Promise<void>(done => server.close(() => done())); await log.close();
    report.modelRequests = requests.length;
    await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report, null, 2));
}
