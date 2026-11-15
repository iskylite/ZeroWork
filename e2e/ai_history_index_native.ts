/** Real-journal startup, background restart, and isolated conversation reads. */
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream, constants } from 'node:fs';
import { appendFile, copyFile, mkdir, mkdtemp, readFile, readdir, realpath, rm, stat, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const archive = process.env.ZW_AI_JOURNAL_FIXTURE;
assert(archive, 'Set ZW_AI_JOURNAL_FIXTURE to the legacy journal');
const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const output = resolve(process.argv[2] ?? '/tmp/zw-history-index-proof');
await mkdir(output, { recursive: true });
const isolated = await realpath(await mkdtemp(join(tmpdir(), 'zw-history-index-')));
const data = join(isolated, 'data');
const legacy = join(data, 'ai-sessions.jsonl');
const index = join(data, 'ai-sessions-legacy-index-v2.jsonl');
await mkdir(data);
await copyFile(archive, legacy, constants.COPYFILE_FICLONE);
const digest = async (path: string) => {
    const hash = createHash('sha256');
    for await (const bytes of createReadStream(path)) hash.update(bytes);
    return hash.digest('hex');
};
const sourceSize = (await stat(legacy)).size;
const sourceHash = await digest(legacy);
const report: Record<string, any> = { sourceBytes: sourceSize, runs: {} };
let requests = 0;
let requestAt: number | null = null;
const server = createServer(async (req, res) => {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    if (req.method === 'POST' && raw.includes('INDEX_CONCURRENT_NEW_CHAT')) {
        requests++;
        requestAt ??= performance.now();
    }
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end('data: {"choices":[{"index":0,"delta":{"content":"INDEX_NEW_CHAT_ANSWER"}}]}\n\ndata: [DONE]\n\n');
});
await new Promise<void>(done => server.listen(0, '127.0.0.1', done));
await writeFile(join(data, 'config.toml'), `[meta]
config_revision=1
[ai]
default_provider="fixture"
[[ai.providers]]
id="fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:${(server.address() as { port: number }).port}/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="fixture"
context_window=200000
default=true
`);

const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const shown = (n: any) => n && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const query = async (id: string) => {
    const result = await h.query(id).catch(() => []);
    return Array.isArray(result) ? result : [];
};
const visible = (id: string) => h.waitFor(async () => (await query(id)).find(shown) ?? null, 30000);
const click = async (id: string) => { await visible(id); assert((await h.clickTestId(id)).ok, id); };
const diagnostic = async () => {
    const path = join(data, 'logs');
    const files = await readdir(path).catch(() => []);
    return (await Promise.all(files.filter(name => /^app-.*[.]log$/.test(name)).map(name => readFile(join(path, name), 'utf8')))).join('\n');
};
const committed = async () => {
    const bytes = await readFile(index, 'utf8').catch(() => '');
    return bytes.slice(0, bytes.lastIndexOf('\n') + 1).trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
};
const peakFootprint = (pid: number) => {
    const summary = execFileSync('/usr/bin/vmmap', ['-summary', String(pid)], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    return summary.match(/Physical footprint \(peak\):\s*([^\r\n]+)/)?.[1]?.trim() ?? null;
};
let current: Awaited<ReturnType<typeof launch>> | undefined;
async function launch(name: string) {
    const rpc = join(isolated, name);
    await mkdir(rpc);
    process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
    const diagnosticStart = (await diagnostic()).length;
    const child = spawn(join(prefix, 'bin/zerowork'), [], { env: {
        ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0',
        ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1',
    }, stdio: ['ignore', 'ignore', 'pipe'] });
    const ended = new Promise<{ code: number | null, signal: string | null }>(done => child.on('close', (code, signal) => done({ code, signal })));
    let stderr = '';
    child.stderr.on('data', chunk => stderr += chunk);
    const run = { child, ended, alive: () => child.exitCode === null && child.signalCode === null, log: async () => (await diagnostic()).slice(diagnosticStart), stderr: () => stderr };
    current = run;
    await h.waitForServerReady(15000);
    assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), child.pid);
    await visible('workspace.shell');
    const ms = await h.waitFor(async () => (await run.log()).match(/startup interactive ms total=(\d+)/) ?? null, 10000);
    report.runs[name] = { interactiveMs: Number(ms[1]) };
    return run;
}
async function quit(run: NonNullable<typeof current>) {
    assert((await h.request('POST', '/zerowork/windows', { action: 'quit' })).ok);
    const deadline = performance.now() + 15000;
    while (run.alive() && performance.now() < deadline) {
        for (const id of ['local.close.accept', 'session.close.accept', 'groups.close.accept']) {
            if (run.alive() && (await query(id)).some(shown)) await h.clickTestId(id).catch(() => {});
        }
        await Promise.race([run.ended, h.sleep(60)]);
    }
    assert(!run.alive());
    assert.deepEqual(await run.ended, { code: 0, signal: null });
}
async function openAi() {
    await h.resizeWindow(1440, 960);
    await click('workspace.empty.local');
    await visible('terminal.surface');
    await click('toolbar.ai');
    await visible('ai.empty.configured');
    assert(!(await query('ai.empty.unconfigured')).some(shown));
}
try {
    const idle = await launch('idle');
    await h.sleep(1200);
    assert(!/AI history (index|preview|restore)/.test(await idle.log()));
    assert(!(await readdir(data)).some(name => /^ai-sessions-(legacy-index|active)/.test(name)));
    report.runs.idle.historyBytes = 0;
    report.runs.idle.peakFootprint = peakFootprint(idle.child.pid!);
    await quit(idle);

    const interrupted = await launch('interrupted');
    await openAi();
    assert.equal((await committed()).length, 0, 'Opening the composer leaves the old journal alone');
    await click('ai.prompt');
    await h.type_('INDEX_CONCURRENT_NEW_CHAT');
    const migrationAt = performance.now();
    await click('ai.sessions');
    await click('ai.sessions.close');
    await click('ai.send');
    await h.waitFor(async () => JSON.stringify(await h.query('ai.response')).includes('INDEX_NEW_CHAT_ANSWER') || null, 10000);
    assert(requestAt !== null);
    assert(!(await interrupted.log()).includes('AI history index ms'), 'Provider response arrived during migration');
    const progress = await h.waitFor(async () => (await committed()).at(-1)?.end ?? null, 8000);
    assert(progress > 0 && progress < sourceSize, 'Interrupt after a durable migration checkpoint');
    interrupted.child.kill('SIGKILL');
    assert.equal((await interrupted.ended).signal, 'SIGKILL');
    const beforeRestart = (await committed()).at(-1).end;
    // Reproduce an interruption during a sidecar append as well as the
    // actual process interruption between durable commits.
    await appendFile(index, '{"inode":');
    report.runs.interrupted.firstProviderRequestMs = Math.round(requestAt - migrationAt);
    report.runs.interrupted.committedSourceBytes = beforeRestart;

    const resumed = await launch('resumed');
    await openAi();
    assert.equal((await committed()).at(-1).end, beforeRestart);
    await click('ai.sessions');
    const measures = await h.waitFor(async () => (await resumed.log()).match(/AI history index ms total=(\d+) bytes_read=(\d+) resumed_bytes=(\d+) records=(\d+)/) ?? null, 60000);
    const [, elapsed, read, offset, conversations] = measures.map(Number);
    const checkpoints = await committed();
    assert.equal(offset, beforeRestart);
    const active = join(data, 'ai-sessions-active.jsonl');
    const activeSize = (await stat(active)).size;
    assert.equal(read, sourceSize - beforeRestart + activeSize);
    const newHistory = await readFile(active, 'utf8');
    assert(newHistory.includes('INDEX_CONCURRENT_NEW_CHAT') && newHistory.includes('INDEX_NEW_CHAT_ANSWER'));
    report.newConversationSurvivedRestart = true;
    assert.equal(checkpoints.at(-1).end, sourceSize);
    for (const [i, batch] of checkpoints.entries()) assert.equal(batch.from, checkpoints[i - 1]?.end ?? 0);
    Object.assign(report.runs.resumed, { indexMs: elapsed, indexBytes: read, legacyBytesRead: read - activeSize, resumeOffset: offset, conversations, peakFootprint: peakFootprint(resumed.child.pid!) });

    // Welcome is row 1. The catalog publishes legacy rows ahead of the
    // previous process's independent active row.
    await click('ai.session.jump.2');
    await h.waitFor(async () => (await query('ai.history.body')).some(shown) &&
        !JSON.stringify(await h.query('ai.history.body')).includes('正在加载此会话') || null, 30000);
    const preview = await h.waitFor(async () => (await resumed.log()).match(/AI history preview ms total=(\d+) bytes_read=(\d+) rows=(\d+)/) ?? null, 30000);
    const first = checkpoints.flatMap(batch => batch.rows.flatMap((row: any) => row.items)).find((item: any, _: number, all: any[]) =>
        item.origin && !item.child && !all.some(other => JSON.stringify(other.conversation) === JSON.stringify(item.conversation) && other.removed));
    assert(first);
    const spans = checkpoints.flatMap(batch => batch.rows).filter((row: any) => row.items.some((item: any) =>
        JSON.stringify(first.conversation) === JSON.stringify(item.conversation)));
    assert(+preview[2] > 0);
    assert(+preview[2] <= spans.reduce((n: number, row: any) => n + row.end - row.start, 0));
    assert(+preview[3] <= spans.length);
    const selected = new Map<string, any>();
    const pending = new Map<string, any>();
    for (const row of spans) {
        const item = row.items.find((item: any) => JSON.stringify(first.conversation) === JSON.stringify(item.conversation));
        for (const flag of ['snapshot', 'transcript', 'draft', 'workspace']) {
            if (!item.projection?.[flag]) continue;
            if (flag === 'snapshot') selected.delete('transcript');
            selected.set(flag, row);
        }
        for (const receipt of item.receipts ?? []) {
            const id = JSON.stringify(receipt.id);
            if (['consumed', 'cancelled', 'failed'].includes(receipt.delivery)) pending.delete(id);
            else if (receipt.has_body) pending.set(id, row);
        }
    }
    if (selected.size) {
        const ranges = new Set([...selected.values(), ...pending.values()]);
        assert.equal(+preview[3], ranges.size);
        assert.equal(+preview[2], [...ranges].reduce((bytes, row) => bytes + row.end - row.start, 0));
    }
    assert(+preview[2] < sourceSize);
    report.preview = { ms: +preview[1], bytes: +preview[2], rows: +preview[3], peakFootprint: peakFootprint(resumed.child.pid!) };
    assert((await h.screenshot(join(output, 'selected-history.png'))).ok);
    await click('ai.history.restore');
    const restored = await h.waitFor(async () =>
        (await query('ai.message.user.text')).some(shown) ? 'loaded' :
        (await query('ai.session.close.accept')).some(shown) ? 'confirm' : null, 12000);
    if (restored === 'confirm') await click('ai.session.close.accept');
    await visible('ai.message.user.text');
    const restore = await h.waitFor(async () => (await resumed.log()).match(/AI history restore selected ms total=(\d+) bytes_read=(\d+)/) ?? null, 10000);
    report.selectedRestore = { ms: +restore[1], bytes: +restore[2] };
    await quit(resumed);
    assert.equal(await digest(legacy), sourceHash);
    assert.equal(await digest(archive), sourceHash);
    report.oldJournalSha256Unchanged = true;
    report.ok = true;
} catch (err) {
    report.error = err instanceof Error ? err.stack : String(err);
    process.exitCode = 1;
    if (current?.alive()) await h.screenshot(join(output, 'failure.png')).catch(() => {});
} finally {
    if (current?.alive()) {
        current.child.kill('SIGTERM');
        await current.ended;
    }
    if (current) await writeFile(join(output, 'last-run.log'), await current.log());
    server.closeAllConnections();
    await new Promise<void>(done => server.close(() => done()));
    await writeFile(join(output, 'report.json'), JSON.stringify(report, null, 2));
    await rm(isolated, { recursive: true, force: true });
    console.log(JSON.stringify(report));
}
