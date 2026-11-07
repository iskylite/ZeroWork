/** Per-session assistant presentation with real Local tabs and a loopback model.
 * ZW_AI_TEST_PREFIX=<test build> node e2e/ai_tab_presentation_native.ts <out>
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir, mkdtemp, open, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? '/tmp/zw-tab-ime-fix');
const out = resolve(process.argv[2] ?? '/tmp/zw-ai-tab-presentation');
await mkdir(out, {recursive: true});
const iso = await mkdtemp('/private/tmp/zw-ai-tabs-');
const data = join(iso, 'data'), rpc = join(iso, 'rpc'), zdot = join(iso, 'zdot');
for (const dir of [data, rpc, zdot]) await mkdir(dir);
await writeFile(join(zdot, '.zshrc'), "bindkey -e\nPS1='ai-tabs%# '\n");
let held: any = null;
let modelRequests = 0;
const frame = (content: string) => 'data: ' + JSON.stringify({choices: [{index: 0, delta: {content}}]}) + '\n\n';
const server = createServer(async (req, res) => {
    if (req.method !== 'POST') {res.end('{"data":[{"id":"tabs-fixture"}]}'); return;}
    let raw = ''; for await (const bytes of req) raw += bytes;
    const body = JSON.parse(raw);
    res.writeHead(200, {'content-type': 'text/event-stream'});
    if (!body.tools?.length) {res.end(frame('本地会话测试') + 'data: [DONE]\n\n'); return;}
    modelRequests++;
    held = res;
    res.write(frame('FIRST_SESSION_RUNNING'));
});
await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
await writeFile(join(data, 'config.toml'), `[meta]
config_revision=1
[ui]
theme="dark"
[ai]
default_provider="tabs-fixture"
[[ai.providers]]
id="tabs-fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:${(server.address() as any).port}/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="tabs-fixture"
context_window=200000
default=true
`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(join(prefix, 'bin/zerowork'), [], {env: {...process.env,
    ZEROWORK_DATA_DIR: data, ZDOTDIR: zdot, ZEROWORK_AUTOCONNECT: '0',
    ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1',
    OPENAI_API_KEY: '', ANTHROPIC_API_KEY: ''}, stdio: ['ignore', log.fd, log.fd]});
const ended = new Promise(r => app.once('close', r));
const alive = () => app.exitCode === null && app.signalCode === null;
const shown = (n: any) => n && n.hidden !== true && n.visible !== false &&
    (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
const absent = (id: string) => h.waitFor(async () => !(await h.query(id)).some(shown) || null, 10000);
const click = async (id: string) => {await visible(id); assert((await h.clickTestId(id)).ok, id);};
const input = async (value: string) => {await click('ai.prompt'); await h.key('a', {cmd: true}); await h.type_(value);};
const draft = (value: string) => h.waitFor(async () => (await h.inputState('ai.prompt')).buffer === value || null, 10000);
const report: any = {status: 'running', isolation: iso, checks: []};
const capture = async (name: string) => {await h.mouseMove(1, 1); assert((await h.screenshot(join(out, name + '.png'))).ok);};
try {
    await h.waitForServerReady(60000); await h.resizeWindow(1200, 900);
    await click('workspace.empty.local'); await visible('terminal.surface'); await click('toolbar.ai');
    await input('FIRST_TASK'); await click('ai.send'); await h.waitFor(() => held || null, 15000);
    await input('FIRST_SESSION_DRAFT');
    await click('toolbar.new_session'); await click('session.menu.local'); await visible('terminal.surface');
    await absent('ai.panel'); await capture('second-initially-collapsed');
    await click('tabs.tab.1'); await visible('ai.panel'); await draft('FIRST_SESSION_DRAFT');
    await visible('ai.stop');
    await click('tabs.tab.2'); await absent('ai.panel');
    report.checks.push('new tab starts collapsed; returning to first session restores its open panel, draft and running task');
    await click('toolbar.ai'); await input('SECOND_SESSION_DRAFT');
    await click('tabs.tab.1'); await draft('FIRST_SESSION_DRAFT'); await click('ai.collapse'); await absent('ai.panel');
    await click('tabs.tab.2'); await visible('ai.panel'); await draft('SECOND_SESSION_DRAFT');
    await absent('ai.stop'); await capture('second-open-first-collapsed');
    await h.key('1', {cmd: true}); await absent('ai.panel');
    await h.key('2', {cmd: true}); await visible('ai.panel'); await draft('SECOND_SESSION_DRAFT');
    report.checks.push('collapse is session-local; mouse and keyboard switching restore independent visibility without moving task or draft');
    await h.resizeWindow(860, 480); await click('ai.collapse'); await absent('ai.panel');
    await h.key('1', {cmd: true}); await absent('ai.panel'); await click('toolbar.ai');
    await visible('ai.panel'); await draft('FIRST_SESSION_DRAFT'); await visible('ai.stop');
    await capture('first-open-compact');
    assert.equal(modelRequests, 1, 'switching/reopening never sends or cancels the original task');
    report.checks.push('compact window preserves both collapsed states; explicit reopening restores original conversation and worker');
    report.status = 'passed';
} catch (error) {
    report.status = 'failed'; report.error = String(error); process.exitCode = 1;
    await capture('failure').catch(() => {});
} finally {
    held?.destroy();
    if (alive()) {
        await h.request('POST', '/zerowork/windows', {action: 'quit'}).catch(() => {});
        await Promise.race([ended, h.sleep(15000)]);
    }
    if (alive()) {report.forced = true; app.kill('SIGTERM'); await ended;}
    if (report.forced || app.exitCode !== 0) {report.status = 'failed'; process.exitCode = 1;}
    report.exit_code = app.exitCode;
    server.closeAllConnections(); await new Promise<void>(r => server.close(() => r()));
    await log.close(); await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify({status: report.status, error: report.error, out}));
}
