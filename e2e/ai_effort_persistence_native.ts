/** Isolated native regression for reasoning defaults across sessions and restarts. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir, mkdtemp, open, readFile, realpath, rename, rm, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const out = resolve(process.argv[2] ?? '/tmp/zw-ai-effort-persistence');
await mkdir(out, {recursive: true});
const isolated = await realpath(await mkdtemp('/tmp/zw-ai-effort-persistence-'));
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc');
await mkdir(data); await mkdir(rpc); await writeFile(join(data, 'hosts.toml'), '');
const requests: any[] = [];
let held: any = null;
const frame = (delta: any) => 'data: ' + JSON.stringify({choices: [{index: 0, delta}]}) + '\n\n';
const server = createServer(async (req, res) => {
    if (req.method !== 'POST') {
        res.writeHead(200, {'content-type': 'application/json'});
        res.end(JSON.stringify({data: [{id: 'reasoner'}]}));
        return;
    }
    let raw = '';
    for await (const part of req) raw += part;
    const body = JSON.parse(raw);
    const title = body.messages[0]?.content?.startsWith('将用户的问题概括');
    if (!title) requests.push(body);
    res.writeHead(200, {'content-type': 'text/event-stream'});
    const latest = body.messages.filter((message: any) => message.role === 'user').at(-1)?.content;
    if (!title && typeof latest === 'string' && latest.includes('HOLD_EFFORT')) {
        held = res; res.flushHeaders(); return;
    }
    res.end(frame({content: '已收到。'}) + 'data: [DONE]\n\n');
});
await new Promise<void>(done => server.listen(0, '127.0.0.1', done));
const port = (server.address() as any).port;
const configPath = join(data, 'config.toml');
await writeFile(configPath, `[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ai]\ndefault_provider="fixture"\nfollow_up_mode="queue"\n` +
    `[[ai.providers]]\nid="fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n` +
    `[[ai.providers.models]]\nname="reasoner"\ncontext_window=64000\ndefault=true\nreasoning=true\nefforts=["low","medium","high"]\n` +
    `[[ai.providers.models]]\nname="limited-reasoner"\ncontext_window=64000\nreasoning=true\nefforts=["low","medium"]\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(out, 'app.log'), 'w');
const environment = {...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0'};
let app: any, ended: Promise<any>;
const shown = (n: any) => n && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const flat = (n: any): any[] => Array.isArray(n) ? n.flatMap(flat) : n ? [n, ...(n.children ?? []).flatMap(flat)] : [];
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
const click = async (id: string) => { await visible(id); const result = await h.clickTestId(id); assert(result.ok, `${id}: ${JSON.stringify(result)}`); };
const menu = async () => { if (!(await h.query('ai.model.menu')).some(shown)) { await click('ai.composer.model'); await h.sleep(180); } await visible('ai.model.menu'); };
const expectEffort = async (name: string) => { await menu(); await h.waitFor(async () => (await visible('ai.effort.value')).text === name || null, 10000); };
const choose = async (key: string | null, name: string) => { await menu(); await click('ai.effort.slider.track'); if (key) await h.key(key); await expectEffort(name); };
const newLocal = async () => { if ((await h.query('ai.panel')).some(shown)) await click('ai.collapse'); await click('toolbar.new_session'); await click('session.menu.local'); await visible('terminal.surface'); await click('toolbar.ai'); };
const newConversation = async () => {
    await click('ai.session.new'); await h.sleep(160);
    if ((await h.query('ai.session.close.accept')).some(shown)) await click('ai.session.close.accept');
    await h.waitFor(async () => !(await h.query('ai.session.close.accept')).some(shown) || null, 10000);
};
const launch = async () => {
    app = spawn(join(prefix, 'bin/zerowork'), [], {env: environment, stdio: ['ignore', log.fd, log.fd]});
    ended = new Promise(done => app.once('exit', (code: any, signal: any) => done({code, signal})));
    await h.waitForServerReady(60000); await h.resizeWindow(1440, 900);
    await h.waitFor(async () => !(await h.query('startup.overlay')).some(shown) || null, 15000);
};
const quit = async () => {
    let exited = false;
    const finished = ended.then(result => { exited = true; return result; });
    assert((await h.request('POST', '/zerowork/windows', {action: 'quit'})).ok);
    await h.waitFor(async () => {
        if (exited) return true;
        const nodes = await Promise.race([h.query('local.close.accept').catch(() => []), finished.then(() => [])]);
        if (!exited && nodes.some(shown)) assert((await h.clickTestId('local.close.accept')).ok);
        return exited || null;
    }, 15000);
    assert.deepEqual(await finished, {code: 0, signal: null});
};
const send = async (effort: string, model = 'reasoner') => {
    if ((await h.query('ai.model.menu')).some(shown)) await h.key('escape');
    const count = requests.length;
    await click('ai.prompt'); await h.type_('验证保存的推理强度'); await click('ai.send');
    await h.waitFor(() => requests.length > count || null, 15000);
    assert.equal(requests[count].reasoning_effort, effort);
    assert.equal(requests[count].model, model);
    await h.waitFor(async () => !(await h.query('ai.stop')).some(shown) || null, 15000);
};
const report: any = {status: 'running', checks: []};
try {
    await launch(); await click('workspace.empty.local'); await visible('terminal.surface'); await click('toolbar.ai');
    await expectEffort('低'); await h.key('escape');
    const first = flat(await h.query('tabs.strip')).find(n => /^tabs\.tab\.\d+$/.test(n.test_id ?? '')).test_id;
    await newLocal(); await expectEffort('低');
    const tabs = flat(await h.query('tabs.strip')).filter(n => /^tabs\.tab\.\d+$/.test(n.test_id ?? ''));
    const second = tabs.find(n => n.test_id !== first).test_id;
    await choose('end', '高');
    assert(/default_effort\s*=\s*"high"/.test(await readFile(configPath, 'utf8')));
    await h.key('escape'); await expectEffort('高');
    assert((await h.screenshot(join(out, 'selected-high.png'))).ok);
    await h.key('escape'); await click('ai.collapse'); await click(first); await click('toolbar.ai'); await expectEffort('高'); await send('high');
    report.checks.push('Selection is saved immediately; an existing unmodified session displays and sends high.');
    await choose(null, '中');
    assert(/default_effort\s*=\s*"medium"/.test(await readFile(configPath, 'utf8')));
    await h.key('escape'); await click('ai.collapse'); await click(second); await click('toolbar.ai'); await expectEffort('高');
    report.checks.push('An explicit choice in another existing session stays independent.');
    await h.key('escape'); await newConversation(); await expectEffort('中'); await send('medium');
    report.checks.push('A new conversation inherits the most recently saved default and sends it.');
    await quit(); await launch();
    if ((await h.query('workspace.empty.local')).some(shown)) { await click('workspace.empty.local'); await visible('terminal.surface'); await click('toolbar.ai'); }
    else await newLocal();
    await expectEffort('中'); await send('medium');
    report.checks.push('Restarting the app restores the saved effort and sends the same value.');
    await click('ai.prompt'); await h.type_('HOLD_EFFORT'); await click('ai.send');
    await h.waitFor(() => held || null, 15000);
    await click('ai.prompt'); await h.type_('QUEUED_EFFORT'); await click('ai.send'); await visible('ai.pending.card.0');
    await newLocal(); await expectEffort('中');
    let track = await visible('ai.effort.slider.track');
    assert((await h.clickAt(track.rect.x + track.rect.w - 1, track.rect.y + track.rect.h / 2)).ok);
    await expectEffort('高');
    held.end(frame({content: '原请求已完成。'}) + 'data: [DONE]\n\n'); held = null;
    const queued = await h.waitFor(() => requests.find(body => body.messages.some((message: any) => message.role === 'user' && typeof message.content === 'string' && message.content.includes('QUEUED_EFFORT'))) ?? null, 15000);
    assert.equal(queued.reasoning_effort, 'medium');
    report.checks.push('A queued request keeps its captured effort when another session changes the default.');
    await rename(configPath, configPath + '.backup'); await mkdir(configPath);
    track = await visible('ai.effort.slider.track');
    assert((await h.clickAt(track.rect.x + 1, track.rect.y + track.rect.h / 2)).ok);
    await h.waitFor(async () => flat(await visible('ai.model.menu')).some(n => n.text === '无法保存，请重试') || null, 10000);
    await expectEffort('高');
    await rm(configPath, {recursive: true}); await rename(configPath + '.backup', configPath);
    track = await visible('ai.effort.slider.track');
    assert((await h.clickAt(track.rect.x + 1, track.rect.y + track.rect.h / 2)).ok);
    await expectEffort('低');
    assert(/default_effort\s*=\s*"low"/.test(await readFile(configPath, 'utf8')));
    await h.waitFor(async () => flat(await visible('ai.model.menu')).some(n => n.text === '模型与推理强度') || null, 10000);
    report.checks.push('A failed save shows an error, retains the previous effort, and can be retried.');
    await choose('end', '高');
    await h.key('escape'); await newConversation(); await menu();
    const limited = await h.waitFor(async () => (await h.query('ai.model.option')).find(n => shown(n) && flat(n).some(node => node.text === 'limited-reasoner')) ?? null, 10000);
    assert((await h.clickAt(limited.rect.x + limited.rect.w / 2, limited.rect.y + limited.rect.h / 2)).ok);
    await expectEffort('中 · 已回落');
    assert((await h.screenshot(join(out, 'effort-fallback.png'))).ok);
    await send('medium', 'limited-reasoner');
    assert(/default_effort\s*=\s*"high"/.test(await readFile(configPath, 'utf8')));
    report.checks.push('A model with fewer supported levels displays the fallback and sends medium while the global default remains high.');
    await quit(); report.status = 'passed';
} catch (error) {
    report.status = 'failed'; report.error = String(error); process.exitCode = 1;
    await h.screenshot(join(out, 'failure.png')).catch(() => {});
} finally {
    if (held) held.end();
    if (app && app.exitCode === null && app.signalCode === null) { app.kill('SIGTERM'); await ended; }
    server.closeAllConnections(); await new Promise<void>(done => server.close(() => done()));
    await log.close(); await rm(isolated, {recursive: true, force: true});
    await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
}
console.log(JSON.stringify(report, null, 2));
