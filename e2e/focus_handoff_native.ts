/** Focus ownership through production AI, tabs and group UI, with real Local PTYs. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, writeFile, rm} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

const binary = resolve(process.argv[2] ?? '/tmp/zw-focus-fix/bin/zerowork');
const out = resolve(process.argv[3] ?? '/tmp/zw-focus-handoff');
const h = await import(pathToFileURL(resolve(binary, '../../share/zenit/harness/client.ts')).href);
await mkdir(out, {recursive: true});
const isolated = await mkdtemp('/private/tmp/zw-focus-');
const rpc = join(isolated, 'rpc'), data = join(isolated, 'data'), shell = join(isolated, 'shell');
await Promise.all([mkdir(rpc), mkdir(data), mkdir(shell)]);
await writeFile(join(shell, '.zshrc'), "bindkey -e\nPS1='focus-test%# '\n");
await writeFile(join(data, 'config.toml'), '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n');
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(binary, [], {env: {...process.env, ZEROWORK_DATA_DIR: data, ZDOTDIR: shell,
    ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: '1',
    ZENIT_E2E_ISOLATE_POINTER: '1', ZENIT_E2E_ISOLATE_KEYBOARD: '1'}, stdio: ['ignore', log.fd, log.fd]});
const ended = new Promise(r => app.once('close', r));
const report: any = {status: 'running', checks: [], focus: [], limitations: ['Physical keyboard/IME and macOS app switching are not injected by this Harness.']};
const shown = (n: any) => n && !n.hidden && n.visible !== false && n.rect?.w > 0 && n.rect?.h > 0;
const flat = (n: any): any[] => [n, ...(n.children ?? []).flatMap(flat)];
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
async function clickNode(n: any) { assert((await h.clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok); }
async function click(id: string) { await clickNode(await visible(id)); }
async function focus(stage: string, expected?: number | string) {
    const actual = await h.focused();
    report.focus.push({stage, actual});
    if (typeof expected === 'number') assert.equal(actual.id, expected, stage);
    if (typeof expected === 'string') assert.equal(actual.test_id, expected, stage);
    return actual.id;
}
async function receipt(name: string) {
    const file = join(isolated, name);
    await h.type_(`printf '%s' $$ > '${file}'`);
    await h.key('return');
    return h.waitFor(async () => { try { const value = await readFile(file, 'utf8'); return /^\d+$/.test(value) ? value : null; } catch { return null; } }, 10000);
}
async function group(name: string) {
    await receipt('ready-' + name);
    await h.sleep(150);
    await h.type_('@');
    await visible('terminal.commands');
    await h.type_('grp Focus');
    await h.key('right');
    await h.key('return');
    await visible('groups.workspace');
}
async function capture(name: string) {
    assert((await h.screenshot(join(out, name + '.png'))).ok);
    await writeFile(join(out, name + '.focus.json'), JSON.stringify(await h.focused(), null, 2));
}
try {
    await h.waitForServerReady();
    assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
    await h.resizeWindow(1200, 800);
    await click('workspace.empty.local');
    await visible('terminal.surface');
    const firstFocus = await focus('new local', 'terminal.input');
    const firstPid = await receipt('first-ready');
    const firstTab = (await h.query('tabs.strip')).flatMap(flat).find((n: any) => /^tabs\.tab\.\d+$/.test(n.test_id ?? '') && shown(n)).test_id;
    for (let i = 0; i < 3; i++) {
        await click('toolbar.ai');
        // Do not click ai.prompt or add a readiness sleep before the first text.
        await h.type_('a');
        assert.equal((await h.inputState('ai.prompt')).buffer, 'a');
        await focus('assistant first letter ' + i, 'ai.prompt');
        await h.key('a', {cmd: true}); await h.key('backspace');
        await click(i % 2 === 0 ? 'ai.collapse' : 'toolbar.ai');
        await focus('assistant collapse ' + i, firstFocus);
        assert.equal(await receipt('after-ai-' + i), firstPid);
    }
    report.checks.push('Repeated AI opening accepts its first letter without a prompt click; collapse and toolbar toggle restore the same live PTY.');
    await click('toolbar.new_session'); await click('session.menu.local');
    await visible('terminal.surface');
    const secondFocus = await focus('second local', 'terminal.input');
    const secondPid = await receipt('second-ready');
    assert.notEqual(firstPid, secondPid);
    const secondTab = (await h.query('tabs.strip')).flatMap(flat).find((n: any) => /^tabs\.tab\.\d+$/.test(n.test_id ?? '') && n.test_id !== firstTab && shown(n)).test_id;
    for (let i = 0; i < 3; i++) {
        await click(firstTab); await focus('first tab ' + i, firstFocus);
        assert.equal(await receipt('first-switch-' + i), firstPid);
        await click(secondTab); await focus('second tab ' + i, secondFocus);
        assert.equal(await receipt('second-switch-' + i), secondPid);
    }
    report.checks.push('Tab switches route immediate input to each original PTY.');
    await group('second');
    await click(firstTab); await group('first');
    await h.waitFor(async () => (await h.query('groups.pane.header')).filter(shown).length === 2 || null);
    const panes = flat(await visible('groups.workspace')).filter((n: any) => /^groups\.pane\.\d+$/.test(n.test_id ?? ''));
    for (const pane of panes) {
        const input = flat(pane).find((n: any) => n.test_id === 'terminal.input');
        const title = flat(pane).find((n: any) => n.test_id === 'groups.pane.title');
        await clickNode(title);
        await focus('group title ' + pane.test_id, input.id);
        assert([firstPid, secondPid].includes(await receipt('header-' + pane.test_id)));
    }
    report.checks.push('Selecting a group member title gives that member real keyboard focus.');
    const groupFocus = await focus('before group resize', 'terminal.input');
    const separator = flat(await visible('groups.workspace')).find((n: any) => /^groups\.separator\./.test(n.test_id ?? '') && shown(n));
    assert(separator);
    const x = separator.rect.x + separator.rect.w / 2, y = separator.rect.y + separator.rect.h / 2;
    await h.mouseDown(x, y); await h.mouseMove(x + 20, y); await h.mouseUp(x + 20, y);
    await focus('after group resize', groupFocus);
    await receipt('after-group-resize');
    report.checks.push('Resizing a group preserves the selected terminal and accepts subsequent input.');
    await capture('group-focus');
    await click(firstTab); await focus('group to standalone', firstFocus);
    await click('groups.tab');
    await focus('standalone to group', 'terminal.input');
    await capture('restored-group');
    // End only the two fixture-owned shells before exercising normal Quit.
    // This keeps shutdown independent of active-group close decisions.
    for (const tab of [firstTab, secondTab]) {
        await click(tab); await focus('fixture shell exit ' + tab, 'terminal.input');
        await h.type_('exit'); await h.key('return');
        await visible('local.ended.close'); await click('local.ended.close');
    }
    await h.request('POST', '/zerowork/windows', {action: 'quit'});
    await h.waitFor(async () => {
        if (app.exitCode !== null || app.signalCode !== null) return true;
        for (const id of ['groups.close.accept', 'local.close.accept', 'session.close.accept'])
            if ((await h.query(id)).some(shown)) await click(id);
        return null;
    }, 20000);
    await Promise.race([ended, h.sleep(15000)]);
    assert.equal(app.exitCode, 0, 'normal application quit');
    report.status = 'passed';
} catch (error) {
    report.status = 'failed'; report.error = String(error); report.stack = (error as Error).stack;
    await capture('failure').catch(() => {}); process.exitCode = 1;
} finally {
    if (app.exitCode === null && app.signalCode === null) {
        app.kill('SIGTERM'); await Promise.race([ended, h.sleep(3000)]);
        if (app.exitCode === null && app.signalCode === null) { app.kill('SIGKILL'); await ended; }
    }
    await log.close(); await rm(isolated, {recursive: true, force: true});
    await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
    console.log(report.status + ': ' + join(out, 'report.json'));
}
