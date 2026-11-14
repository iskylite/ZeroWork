/** Journal growth, restart/compaction and historical copy/restore regression.
 * All writes, terminals and model responses belong to a private data directory.
 * An optional ZW_AI_JOURNAL_FIXTURE is copied, never edited in place.
 */
import assert from 'node:assert/strict';
import {execFileSync, spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, readFile, writeFile, copyFile, open, realpath, stat} from 'node:fs/promises';
import {join, resolve} from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? '/tmp/zw-ai-journal-build');
const out = resolve(process.argv[2] ?? '/tmp/zw-ai-journal-results');
await mkdir(out, {recursive: true});
const isolated = await realpath(await mkdtemp('/tmp/zw-ai-journal-'));
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc');
await mkdir(data); await mkdir(rpc);
const journal = join(data, 'ai-sessions.jsonl');
const fixture = process.env.ZW_AI_JOURNAL_FIXTURE;
if (fixture) await copyFile(fixture, journal);
const delay = (ms: number) => new Promise(done => setTimeout(done, ms));
const event = (content: string) => 'data: ' + JSON.stringify({choices: [{index: 0, delta: {content}}]}) + '\n\n';
let requests = 0;
const server = createServer(async (req, res) => {
    if (req.method !== 'POST') { res.end(JSON.stringify({data: [{id: 'journal-fixture'}]})); return; }
    let raw = ''; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw);
    res.writeHead(200, {'content-type': 'text/event-stream'});
    if (!body.tools?.length) { res.end(event('会话存储验证') + 'data: [DONE]\n\n'); return; }
    requests++;
    for (let i = 0; i < 80; i++) {
        res.write(event(i === 0 ? '诊断验证答复：' : '中文输出 🙂 '));
        await delay(40);
    }
    res.end('data: [DONE]\n\n');
});
await new Promise<void>(done => server.listen(0, '127.0.0.1', done));
await writeFile(join(data, 'config.toml'), `[meta]
config_revision=1
[ui]
theme="dark"
[ai]
default_provider="journal-fixture"
permission_mode="confirm"
[[ai.providers]]
id="journal-fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:${(server.address() as any).port}/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="journal-fixture"
context_window=1000000
default=true
`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const log = await open(join(out, 'app.log'), 'w');
let app: ReturnType<typeof spawn>, ended: Promise<any>;
const alive = () => app && app.exitCode === null && app.signalCode === null;
const shown = (n: any) => n && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const flat = (n: any): any[] => Array.isArray(n) ? n.flatMap(flat) : n ? [n, ...(n.children ?? []).flatMap(flat)] : [];
const text = (n: any) => flat(n).map(n => n.text ?? '').join(' ');
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 30000);
const click = async (id: string) => { await visible(id); assert((await h.clickTestId(id)).ok, id); };
const report: any = {status: 'running', isolated, checks: []};
async function launch() {
    app = spawn(join(prefix, 'bin/zerowork'), [], {env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'}, stdio: ['ignore', log.fd, log.fd]});
    ended = new Promise(done => app.once('exit', (code, signal) => done({code, signal})));
    await h.waitForServerReady(60000);
    assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
    await h.resizeWindow(1440, 1000);
    await click('workspace.empty.local'); await visible('terminal.surface'); await click('toolbar.ai');
}
async function quit() {
    assert((await h.request('POST', '/zerowork/windows', {action: 'quit'})).ok);
    const deadline = performance.now() + 20000;
    while (alive() && performance.now() < deadline) {
        for (const id of ['local.close.accept', 'session.close.accept', 'groups.close.accept']) {
            if (!alive()) break;
            try { if ((await h.query(id)).some(shown)) await h.clickTestId(id); } catch {}
        }
        await Promise.race([ended, delay(100)]);
    }
    assert(!alive(), 'Normal Quit must complete');
    assert.deepEqual(await ended, {code: 0, signal: null});
}
async function confirm() {
    await delay(200);
    if ((await h.query('ai.session.close.accept')).some(shown)) await click('ai.session.close.accept');
}
const rows = async () => text((await h.query('ai.message.user.text')).filter(shown));
const cpuMs = () => execFileSync('/bin/ps', ['-p', String(app.pid), '-o', 'time='], {encoding: 'utf8'}).trim().split(':').map(Number).reduce((a, b) => a * 60 + b, 0) * 1000;
try {
    if (!fixture) {
        await launch();
        await click('ai.prompt'); await h.type_('JOURNAL_ORIGINAL 保留完整聊天 🙂'); await click('ai.send');
        await h.waitFor(async () => (await h.query('ai.turn.complete')).some(shown) || null, 20000);
        await delay(1000);
        const events = (await readFile(journal, 'utf8')).trim().split('\n').map(JSON.parse);
        const saves = events.filter(e => e.event?.kind === 'presentation').length;
        assert(saves <= 6, `80 stream chunks produced ${saves} full snapshots`);
        report.streaming_snapshots = saves;
        await quit();
        const original = await readFile(journal, 'utf8');
        const latest = original.trim().split('\n').map(JSON.parse).find(e => e.event?.kind === 'presentation' && !e.event.presentation_patch);
        assert(latest);
        // Valid obsolete snapshots with large trailing JSON whitespace model
        // the 128 MiB archive without changing any rendered chat content.
        const padded = JSON.stringify({...latest, event: {...latest.event, presentation: latest.event.presentation + ' '.repeat(256 * 1024)}}) + '\n';
        const count = Math.floor((128 * 1024 * 1024 - 64 * 1024 - Buffer.byteLength(original)) / Buffer.byteLength(padded));
        // Put obsolete full snapshots before the real base and its patches.
        const split = original.indexOf('\n') + 1;
        const file = await open(journal, 'w');
        try {
            await file.write(original.slice(0, split));
            for (let i = 0; i < count; i++) await file.write(padded);
            await file.write(original.slice(split));
        } finally {
            await file.close();
        }
        report.checks.push('80 streamed deltas produce at most six complete display snapshots');
    }
    const before = await readFile(journal, 'utf8');
    const sourceLines = before.trim().split('\n');
    const lastPresentation = new Map<string, {base: string, patch?: string}>();
    const expected = sourceLines.filter(line => {
        const row = JSON.parse(line);
        if (row.event?.kind === 'presentation') {
            const id = row.event.conversation;
            if (row.event.presentation_patch) {
                const saved = lastPresentation.get(id);
                assert(saved, 'Presentation patch needs a base');
                saved.patch = line;
            } else {
                lastPresentation.set(id, {base: line});
            }
            return false;
        }
        return true;
    });
    await launch();
    const after = await readFile(journal, 'utf8');
    report.bytes_before = Buffer.byteLength(before); report.bytes_after = Buffer.byteLength(after);
    assert(report.bytes_after < report.bytes_before / 4, 'Restart must reclaim superseded snapshots');
    const actual = after.trim().split('\n');
    for (const {base, patch} of lastPresentation.values()) {
        expected.push(base);
        if (patch) expected.push(patch);
    }
    for (const line of expected) assert(actual.includes(line), 'Every non-display event and the latest chat snapshot with its base must survive byte-for-byte');
    assert.equal(requests, fixture ? 0 : 1, 'Reopening must not replay model or tools');
    await click('ai.sessions');
    const buttons = flat(await h.query('ai.sessions.menu')).filter(n => shown(n) && /^ai\.session\.jump\.\d+$/.test(n.test_id ?? ''));
    assert(buttons.length > 0, 'Historical sessions must remain listed');
    const id = buttons[0].test_id.split('.').at(-1);
    await click(`ai.session.jump.${id}`);
    const historicalText = text(await visible('ai.history.body'));
    assert(historicalText.length > 0);
    assert((await h.screenshot(join(out, '00-history-view.png'))).ok);
    await click('ai.history.close');
    const eventCount = async (kind: string) => (await readFile(journal, 'utf8')).trim().split('\n').map(JSON.parse).filter(row => row.event?.kind === kind).length;
    const forks = await eventCount('fork_bound'), bindings = await eventCount('bind');
    await click('ai.sessions'); await click(`ai.session.copy_use.${id}`); await confirm();
    await h.waitFor(async () => (await eventCount('fork_bound')) === forks + 1 || null, 10000);
    await h.waitFor(async () => (await rows()).length > 0 || null, 20000);
    const originalText = await rows();
    for (const node of (await h.query('ai.message.user.text')).filter(shown)) assert(historicalText.includes(text(node)));
    assert((await h.screenshot(join(out, '01-history-copy.png'))).ok);
    await click('ai.session.new'); await confirm();
    await click('ai.sessions'); await click(`ai.session.restore.${id}`); await confirm();
    await h.waitFor(async () => (await eventCount('bind')) === bindings + 1 || null, 10000);
    await h.waitFor(async () => (await rows()) === originalText || null, 20000);
    assert.equal(requests, fixture ? 0 : 1, 'Viewing, copying and restoring history never resends a request');
    assert(!text(await h.query('ai.panel')).includes('JournalLimit'));
    report.checks.push('Restart compacts a nearly full journal and preserves all non-display events and final snapshots byte-for-byte');
    report.checks.push('Historical view, copy-and-use and restore preserve user messages without model/tool replay');
    const ids = (await h.query('ai.message.user.row')).filter(shown).map((n: any) => n.id);
    await delay(1500);
    const cpu = cpuMs(), start = performance.now();
    await delay(3000);
    report.idle_cpu_percent = 100 * (cpuMs() - cpu) / (performance.now() - start);
    assert(report.idle_cpu_percent < 40, `Idle CPU ${report.idle_cpu_percent}%`);
    assert.deepEqual((await h.query('ai.message.user.row')).filter(shown).map((n: any) => n.id), ids);
    assert((await h.screenshot(join(out, '02-history-restored.png'))).ok);
    await quit();
    report.checks.push('Restored transcript nodes remain stable while idle and normal application Quit succeeds');
    report.status = 'passed';
} catch (error) {
    report.status = 'failed'; report.error = String(error); process.exitCode = 1;
    if (alive()) {
        await h.screenshot(join(out, 'failure.png')).catch(() => {});
        await writeFile(join(out, 'failure-tree.json'), JSON.stringify(await h.tree().catch(() => null), null, 2));
    }
} finally {
    if (alive()) { app.kill('SIGTERM'); await ended; }
    server.closeAllConnections(); await new Promise<void>(done => server.close(() => done())); await log.close();
    report.requests = requests; report.final_bytes = await stat(journal).then(s => s.size).catch(() => null);
    await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
}
console.log(JSON.stringify(report, null, 2));
