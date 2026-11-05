/** @log followed by repeated clear through an isolated real Local PTY. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, realpath, readFile, writeFile, open, rm} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';

const binary = resolve(process.argv[2]), outputPath = resolve(process.argv[3]);
const h = await import(pathToFileURL(resolve(binary, '../../share/zenit/harness/client.ts')).href);
await mkdir(outputPath, {recursive: false});
const out = await realpath(outputPath);
const isolated = await realpath(await mkdtemp(join(tmpdir(), 'zw-builtin-clear-')));
const rpc = join(isolated, 'rpc'), data = join(isolated, 'data'), shell = join(isolated, 'shell');
await Promise.all([mkdir(rpc), mkdir(data), mkdir(shell)]);
await writeFile(join(shell, '.zshrc'), "bindkey -e\nPS1='clear-test%# '\n");
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(binary, [], {env: {...process.env, ZDOTDIR: shell, ZEROWORK_DATA_DIR: data,
    ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_FILE_RPC_DIR: rpc,
    ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'}, stdio: ['ignore', log.fd, log.fd]});
const ended = new Promise(r => app.once('close', r));
const report: any = {status: 'running', checks: []};
const shown = (n: any) => n.hidden !== true && n.visible !== false && n.rect?.w > 0 && n.rect?.h > 0;
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
const text = (n: any): string => (n.text ?? '') + (n.children ?? []).map(text).join('');
const records = async () => (await h.query('terminal.command.record')).filter(shown).map(text);
async function click(id: string) {
    const n = await visible(id);
    assert((await h.clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok);
}
async function press(key: string) { assert((await h.key(key)).ok); }
async function type(value: string) { assert((await h.type_(value)).ok); }
async function capture(name: string) {
    assert((await h.screenshot(join(out, name + '.png'))).ok);
    await writeFile(join(out, name + '.json'), JSON.stringify(await h.query('terminal.surface'), null, 2));
}
try {
    await h.waitForServerReady();
    assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
    await h.resizeWindow(1100, 760);
    await click('workspace.empty.local');
    report.stage = 'local terminal';
    await visible('terminal.surface');
    await h.sleep(1500);
    await type('@');
    report.stage = 'command palette';
    await visible('terminal.commands');
    await type('log');
    await press('right');
    await h.waitFor(async () => !(await h.query('terminal.commands')).some(shown) || null);
    await press('return');
    report.stage = 'log history';
    await visible('terminal.history.card');
    await h.waitFor(async () => (await records()).some((s: string) => s.includes('@log')) || null);
    await capture('log-history');
    await press('escape');
    await h.sleep(250);
    // Zsh can clear/redraw while returning from replay. Create a live card
    // as well, so the clear assertion always starts with visible app output.
    await type('@');
    await visible('terminal.commands');
    await type('help');
    await press('right');
    await h.waitFor(async () => !(await h.query('terminal.commands')).some(shown) || null);
    await press('return');
    await h.waitFor(async () => (await records()).some((s: string) => s.includes('@help')) || null);
    await capture('before-clear');
    for (let i = 1; i <= 3; i++) {
        await type('clear');
        await press('return');
        await h.waitFor(async () => !(await records()).some((s: string) => /@(log|help)/.test(s)) || null);
        await h.sleep(250);
        await capture('after-clear-' + i);
    }
    report.checks.push('Actual @log history opens; Escape returns to Local; a visible @help card is removed by three real clear commands.');
    const marker = join(isolated, 'shell-continues');
    await type(`printf done > '${marker}'`);
    await press('return');
    await h.waitFor(async () => { try { return await readFile(marker, 'utf8') === 'done' || null; } catch { return null; } });
    assert(!(await records()).some((s: string) => /@(log|help)/.test(s)));
    report.checks.push('Subsequent shell output does not restore the old card.');
    await capture('after-shell-output');
    await type('exit');
    await press('return');
    await visible('local.ended.close');
    report.status = 'passed';
} catch (error) {
    report.status = 'failed';
    report.error = String(error);
    await capture('failure').catch((e: unknown) => { report.captureError = String(e); });
    report.records = await records().catch(() => []);
    process.exitCode = 1;
} finally {
    if (app.exitCode === null && app.signalCode === null) {
        app.kill('SIGTERM');
        await Promise.race([ended, h.sleep(2500)]);
        if (app.exitCode === null && app.signalCode === null) { app.kill('SIGKILL'); await ended; }
    }
    await log.close();
    await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
    await rm(isolated, {recursive: true, force: true});
    console.log(JSON.stringify(report));
}
