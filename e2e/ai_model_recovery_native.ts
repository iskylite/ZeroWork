/** Real composer, settings and notification UI with an isolated loopback Provider. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, open, readFile, readdir, realpath, rename, rm, stat, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';

const binary = resolve(process.argv[2]), out = resolve(process.argv[3]);
const external = process.argv[4] === 'external';
const restart = process.argv[4] === 'restart';
await mkdir(out, {recursive: true});
const isolated = await realpath(await mkdtemp(join(tmpdir(), 'zw-model-recovery-')));
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc');
await mkdir(data); await mkdir(rpc);
await writeFile(join(data, 'hosts.toml'), '');
const requests: any[] = [];
let held: import('node:http').ServerResponse | null = null;
const reply = (res: import('node:http').ServerResponse, model: string) =>
    res.end('data: ' + JSON.stringify({choices: [{index: 0, delta: {content: '原生验证回复：' + model}}]}) + '\n\ndata: [DONE]\n\n');
const server = createServer(async (req, res) => {
    if (req.method !== 'POST') { res.writeHead(200, {'content-type': 'application/json'}); res.end('{"data":[]}'); return; }
    let body = '';
    for await (const chunk of req) body += chunk;
    const request = JSON.parse(body);
    if (!request.messages[0]?.content?.startsWith('将用户的问题概括')) requests.push(request);
    res.writeHead(200, {'content-type': 'text/event-stream'});
    if (external && request.messages.at(-1)?.content === '运行中修改配置') {
        held = res;
        res.flushHeaders();
        return;
    }
    reply(res, request.model);
});
await new Promise<void>(done => server.listen(0, '127.0.0.1', done));
const port = (server.address() as any).port;
const provider = (id: string, model: string, reasoning: string) =>
    `[[ai.providers]]\nid="${id}"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n` +
    `[[ai.providers.models]]\nname="${model}"\ncontext_window=64000\ndefault=true\nvision=true\nimage_token_reservation=8192\n${reasoning}\n`;
const config = join(data, 'config.toml');
const header = '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ai]\n';
await writeFile(config, header + 'default_provider="old-provider"\n' +
    provider('old-provider', 'old-model', 'reasoning=true\nefforts=["high"]') + provider('new-provider', 'new-model', ''));
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(out, 'app.log'), 'w');
let app: ReturnType<typeof spawn>;
let exited = true;
let ended: Promise<unknown>;
const launch = async () => {
    app = spawn(binary, [], {env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'}, stdio: ['ignore', log.fd, log.fd]});
    exited = false;
    ended = new Promise(done => app.once('exit', (code, signal) => { exited = true; done({code, signal}); }));
    await h.waitForServerReady(60000);
    assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
    await h.resizeWindow(1440, 900);
    await click('workspace.empty.local'); await visible('terminal.surface'); await click('toolbar.ai');
};
const quit = async () => {
    assert((await h.request('POST', '/zerowork/windows', {action: 'quit'})).ok);
    await h.waitFor(async () => {
        if (exited) return true;
        const nodes = await Promise.race([h.query('local.close.accept').catch(() => []), ended.then(() => [])]);
        if (!exited && nodes.some(shown)) assert((await h.clickTestId('local.close.accept')).ok);
        return exited || null;
    }, 15000);
    assert.deepEqual(await ended, {code: 0, signal: null});
};
const shown = (n: any) => n && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const text = (n: any): string => (n.text ?? '') + (n.children ?? []).map(text).join(' ');
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 12000);
const absent = (id: string) => h.waitFor(async () => !(await h.query(id)).some(shown) || null, 6000);
let step = 'startup';
const click = async (id: string) => { await visible(id); assert((await h.clickTestId(id)).ok, id); await h.sleep(160); };
const edit = async (id: string, value: string) => {
    await click(id); await h.key('a', {cmd: true}); await h.type_(value);
    assert.equal((await h.inputState(id)).buffer, value);
};
const screenshot = async (name: string) => assert((await h.screenshot(join(out, name + '.png'))).ok);
const choose = async (model: string) => {
    await click('ai.composer.model');
    const row = await h.waitFor(async () => (await h.query('ai.model.option')).find(n => shown(n) && text(n).includes(model)) ?? null, 6000);
    assert(!row.disabled, model);
    assert((await h.clickAt(row.rect.x + row.rect.w / 2, row.rect.y + row.rect.h / 2)).ok);
    await h.waitFor(async () => text(await visible('ai.composer.model')).includes(model) || null, 6000);
    if ((await h.query('ai.model.menu')).some(shown)) await h.key('escape');
};
const assertRetained = async (draft: string) => {
    assert.equal((await h.inputState('ai.prompt')).buffer, draft);
    assert(text(await visible('ai.panel')).includes('原生验证回复：old-model'));
    assert(text(await visible('ai.image.filename')).includes('AppIcon.png'));
};
const report: {checks: string[]; error?: string} = {checks: []};
const run = async () => {
    await launch();
    step = 'existing conversation';
    if (external) await choose('old-model');
    await click('ai.prompt'); await h.type_('原会话历史'); await click('ai.send');
    await h.waitFor(async () => text(await visible('ai.panel')).includes('原生验证回复：old-model') || null, 12000);
    await visible('ai.turn.complete');
    assert.equal(requests[0].model, 'old-model');
    assert.equal(requests[0].reasoning_effort, 'high');
    if (restart) {
        step = 'share original conversation';
        await click('ai.share');
        const shares = join(data, 'ai-shares');
        const [filename] = await readdir(shares);
        assert(filename?.endsWith('.md'));
        const file = join(shares, filename);
        assert((await readFile(file, 'utf8')).includes('原会话历史'));
        await click('ai.prompt'); await h.type_('重启前的草稿');
        await quit();
        const remaining = header + 'default_provider="new-provider"\n' + provider('new-provider', 'new-model', '');
        await writeFile(config, remaining);
        step = 'restore removed model after restart';
        await launch(); await click('ai.sessions'); await click('ai.session.restore.1');
        await h.waitFor(async () => text(await visible('ai.composer.model')).includes('未选择模型') || null, 6000);
        assert(text(await visible('ai.panel')).includes('原生验证回复：old-model'));
        assert.equal((await h.inputState('ai.prompt')).buffer, '重启前的草稿');
        await h.clickTestId('ai.send'); await h.sleep(220);
        assert.equal(requests.length, 1);
        await screenshot('restart-model-required');
        await quit();
        // Even if the old Provider returns, the invalidated conversation still needs a choice.
        await writeFile(config, remaining + provider('old-provider', 'old-model', 'reasoning=true\nefforts=["high"]'));
        step = 'restore explicit selection requirement';
        await launch(); await click('ai.sessions'); await click('ai.session.restore.1');
        await h.waitFor(async () => text(await visible('ai.composer.model')).includes('未选择模型') || null, 6000);
        await choose('new-model'); await click('ai.send');
        await h.waitFor(() => requests.some(request => request.model === 'new-model') || null, 12000);
        await h.waitFor(async () => text(await visible('ai.panel')).includes('原生验证回复：new-model') || null, 12000);
        await visible('ai.turn.complete');
        await click('ai.session.new');
        await click('ai.session.close.accept');
        await absent('ai.session.close.accept');
        step = 'delete original conversation and share';
        await click('ai.sessions'); await click('ai.session.delete.1');
        await click('ai.session.close.accept');
        await absent('ai.session.row.1');
        await assert.rejects(stat(file), {code: 'ENOENT'});
        await quit();
        report.checks.push('Restart preserves history, draft and removed-model gate, including after the old Provider returns. Explicit reselection sends on the replacement. Deleting the conversation removes its previously exported file.');
        return;
    }
    if (external) {
        // Start a second turn before removing its Provider from the file.
        await click('ai.prompt'); await h.type_('运行中修改配置'); await click('ai.send');
        await h.waitFor(() => held || null, 12000);
    }
    const draft = '换模后继续发送';
    await click('ai.prompt'); await h.type_(draft);
    const prompt = await visible('ai.prompt');
    const image = resolve('assets/macos/AppIcon.png');
    await h.dragAt(prompt.rect.x + 30, prompt.rect.y + 16, 0, image);
    await h.dragAt(prompt.rect.x + 30, prompt.rect.y + 16, 3, image);
    await assertRetained(draft);

    const replacement = external ? 'externally-added-model' : 'new-model';
    const externalConfig = header + 'default_provider="new-provider"\n' + provider('new-provider', replacement, '');
    step = external ? 'edit config.toml externally' : 'disable old provider';
    if (external) {
        // Simulate an editor's atomic save without changing config_revision.
        await writeFile(config + '.edit', externalConfig);
        await rename(config + '.edit', config);
        await h.waitFor(async () => text(await visible('ai.composer.model')).includes('模型不可用') || null, 6000);
        assert(requests.some(request => request.model === 'old-model' && request.messages.at(-1)?.content === '运行中修改配置'));
        assert(held && !held.destroyed && !held.writableEnded, 'editing the Provider interrupted the current turn');
        await absent('ai.composer.model.tooltip');
        reply(held, 'old-model');
        await h.waitFor(async () => (await h.query('ai.turn.complete')).filter(shown).length >= 2 || null, 12000);
        report.checks.push('External Provider removal did not interrupt the running turn; its response completed on the original model.');
    } else {
        await click('toolbar.settings'); await click('settings.nav.ai');
        if (!(await h.query('settings.ai.provider.0.delete_provider')).some(shown)) await click('settings.ai.provider.0.header');
        await click('settings.ai.provider.0.delete_provider');
        await click('settings.ai.delete.confirm'); await click('settings.save');
        await h.waitFor(async () => !(await readFile(config, 'utf8')).includes('old-provider') || null, 12000);
        await click('settings.close'); await absent('settings.close');
        if (!(await h.query('ai.prompt')).some(shown)) await click('toolbar.ai');
    }
    await h.waitFor(async () => text(await visible('ai.composer.model')).includes('未选择模型') || null, 6000);
    await visible('ai.send');
    const beforeBlockedSend = requests.length;
    await h.clickTestId('ai.send');
    await h.sleep(200);
    assert.equal(requests.length, beforeBlockedSend, 'unavailable model allowed a send');
    await assertRetained(draft);
    await h.waitFor(async () => text(await visible('notifications.toast.0')).includes('请在输入栏选择模型') || null, 6000);
    if (external) {
        assert.equal(await readFile(config, 'utf8'), externalConfig, 'reload wrote back to config.toml');
        report.checks.push('External replacement took effect without restarting, bumping the file revision or rewriting the file.');
    } else report.checks.push('Deleted the default Provider directly while the existing conversation was idle.');
    await screenshot('01-unavailable');

    step = 'dismiss and refresh';
    await click('notifications.dismiss.0'); await absent('notifications.toast.0');
    await click('ai.prompt'); await h.key('a', {cmd: true}); await h.key('backspace');
    assert.equal((await h.inputState('ai.prompt')).buffer, '');
    await h.type_(draft);
    for (let i = 0; i < 8; i++) {
        assert(!(await h.query('notifications.toast.0')).some(shown), 'same error reopened the dismissed toast');
        await h.sleep(125);
    }
    report.checks.push('Clicked ×; subsequent input refreshes did not reopen the same warning.');

    step = 'choose replacement';
    await choose(replacement);
    await assertRetained(draft);
    await screenshot('02-recovered');
    await click('ai.send');
    const followup = await h.waitFor(() => requests.find(request => request.model === replacement) ?? null, 12000);
    assert(!('reasoning_effort' in followup), 'stale reasoning effort leaked to replacement model');
    assert(followup.messages.some((m: any) => m.content === '原会话历史'));
    assert(followup.messages.some((m: any) => Array.isArray(m.content) && m.content.some((p: any) => p.type === 'text' && p.text.includes(draft)) && m.content.some((p: any) => p.type === 'image_url')));
    await h.waitFor(async () => text(await visible('ai.panel')).includes('原生验证回复：' + replacement) || null, 12000);
    report.checks.push('Switched models in the original conversation; the replacement received the preserved history, draft and image.');

    if (external) {
        step = 'preserve disk changes while saving an unrelated draft';
        await click('toolbar.settings'); await click('settings.nav.appearance');
        await click('settings.appearance.font.header');
        await edit('settings.field.font_size', '18');
        const updated = externalConfig.replace('name="externally-added-model"', 'name="externally-updated-model"');
        await writeFile(config, updated);
        await h.sleep(850);
        await click('settings.save');
        const saved = await h.waitFor(async () => {
            const bytes = await readFile(config, 'utf8');
            return /font_size\s*=\s*18/.test(bytes) ? bytes : null;
        }, 12000);
        assert(saved.includes('externally-updated-model'));
        assert(!saved.includes('externally-added-model'));
        report.checks.push('An already open settings draft saved its font size without reverting the external Provider update.');

        step = 'reject an overlapping Provider draft';
        await click('settings.nav.ai');
        if (!(await h.query('settings.ai.provider.0.endpoint')).some(shown)) await click('settings.ai.provider.0.header');
        await edit('settings.ai.provider.0.endpoint', `http://127.0.0.1:${port}/draft/v1/chat/completions`);
        const overlap = saved.replace('name = "externally-updated-model"', 'name = "externally-conflicting-model"');
        assert.notEqual(overlap, saved);
        await writeFile(config, overlap);
        await h.sleep(850);
        await click('settings.save');
        await h.waitFor(async () => text(await visible('settings.footer.state')).includes('Provider 配置冲突') || null, 6000);
        assert.equal(await readFile(config, 'utf8'), overlap);
        assert((await h.inputState('settings.ai.provider.0.endpoint')).buffer.includes('/draft/'));
        await screenshot('03-save-conflict');
        if ((await h.query('notifications.dismiss.0')).some(shown)) await click('notifications.dismiss.0');
        await click('settings.revert');
        await click('settings.close');
        report.checks.push('An overlapping Provider draft was rejected; the disk file and the unsaved draft were both preserved.');
    }

    step = 'quit';
    await quit();
};
try {
    await run();
} catch (error) {
    report.error = step + ': ' + String(error);
    process.exitCode = 1;
    await screenshot('failure').catch(() => {});
} finally {
    if (!exited) { app.kill('SIGTERM'); await ended; }
    server.closeAllConnections();
    await new Promise<void>(done => server.close(() => done()));
    await log.close();
    await rm(isolated, {recursive: true, force: true});
    await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
    console.log(report);
}
