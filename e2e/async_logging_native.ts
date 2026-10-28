/** Real UI cleanup must wait for the asynchronous logger's release receipt. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, realpath, writeFile, open, readdir, rm, stat} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {tmpdir} from 'node:os';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const binary = resolve(process.argv[2]), out = resolve(process.argv[3]);
await mkdir(out, {recursive: false});
const base = await realpath(await mkdtemp(join(tmpdir(), 'zw-async-log-ui-')));
const data = join(base, 'data'), rpc = join(base, 'rpc');
await mkdir(data); await mkdir(rpc);
await writeFile(join(data, 'hosts.toml'), '');
await writeFile(join(data, 'config.toml'), '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\n');
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(binary, [], {env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_ISOLATE_POINTER: '1', ZENIT_E2E_BACKGROUND: '1'}, stdio: ['ignore', log.fd, log.fd]});
const ended = new Promise(r => app.once('close', r));
const shown = (n: any) => n && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
const click = async (id: string) => { const n = await visible(id); assert((await h.clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok); };
const report: any = {passed: false, scope: 'isolated actual Metal UI, owned data and diagnostic files; no SSH or external service'};
try {
    await h.waitForServerReady(60000); await h.resizeWindow(1280, 800);
    await h.waitFor(async () => { try { return (await readdir(join(data, 'logs'))).some(n => n.endsWith('.log')) || null; } catch { return null; } }, 5000);
    await click('toolbar.settings'); await click('settings.nav.data');
    const viewport = await visible('settings.viewport');
    const scrollDown = async () => { await h.scrollAt(viewport.rect.x + viewport.rect.w / 2, viewport.rect.y + viewport.rect.h / 2, 0, -1600); await h.sleep(150); };
    await scrollDown();
    if (!(await h.query('settings.data.clear_all')).some(shown)) await click('settings.data.actions.header');
    await scrollDown();
    await click('settings.data.clear_all'); await visible('data.cleanup.modal');
    await h.screenshot(join(out, 'cleanup-confirmation.png'));
    const start = Date.now(); await click('data.cleanup.confirm');
    await Promise.race([ended, h.sleep(10000)]);
    assert.equal(app.exitCode, 0, 'App did not complete owned-data cleanup and exit');
    report.closeMs = Date.now() - start;
    assert(report.closeMs < 5000, 'normal log release delayed cleanup');
    await h.sleep(250);
    let removed = false;
    try { await stat(data); } catch (error: any) { if (error.code === 'ENOENT') removed = true; else throw error; }
    if (!removed) assert.equal((await readdir(data)).length, 0);
    report.passed = true; report.dataRemoved = true; report.lateLogRecreation = false;
} catch (error) {
    report.error = String(error); report.stack = (error as Error).stack;
    await h.screenshot(join(out, 'failure.png')).catch(() => {}); process.exitCode = 1;
} finally {
    if (app.exitCode === null && app.signalCode === null) { app.kill('SIGTERM'); await Promise.race([ended, h.sleep(2000)]); if (app.exitCode === null && app.signalCode === null) { app.kill('SIGKILL'); await ended; } }
    await log.close(); await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
    await rm(base, {recursive: true, force: true});
}
console.log(JSON.stringify(report));
