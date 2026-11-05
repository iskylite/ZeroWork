/** Native startup checks with disposable data; a FIFO models slow image IO. */
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, rm, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';

const binary = resolve(process.argv[2] ?? 'zig-out/bin/zerowork');
const out = resolve(process.argv[3] ?? '/tmp/zerowork-startup-check');
await mkdir(out, {recursive:true});
const pixel = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFUlEQVR4nGP8//8/AzbAhFV00EoAAFbUAw037MyjAAAAAElFTkSuQmCC', 'base64');
const shown = (n:any) => n.visible !== false && n.rect?.w > 0 && n.rect?.h > 0;
const reports:any[] = [];

for (const scenario of ['ready', 'missing', 'disabled', 'slow', 'timeout']) {
    const iso = await mkdtemp('/private/tmp/zw-startup-');
    const data = join(iso, 'data'), rpc = join(iso, 'rpc');
    await mkdir(data); await mkdir(rpc);
    let path = join(iso, 'image.png'), source = 'file';
    if (scenario === 'ready') {
        path = join(iso, 'images'); source = 'directory'; await mkdir(path);
        await writeFile(join(path, '1.png'), 'corrupt first image');
        await writeFile(join(path, '2.png'), pixel);
        await writeFile(join(path, '3.png'), 'deferred corrupt image');
    } else if (scenario === 'slow' || scenario === 'timeout') {
        execFileSync('mkfifo', [path]);
    }
    const config = `[ui]\ntheme="${scenario === 'timeout' ? 'light' : 'dark'}"\n[ui.materials.background]\nenabled=${scenario !== 'disabled'}\nsource="${source}"\npath=${JSON.stringify(path)}\ntransparency=60\n[updates]\nauto_check=false\n`;
    await writeFile(join(data, 'config.toml'), config);
    process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
    const log = await open(join(out, `${scenario}.log`), 'w');
    const app = spawn(binary, [], {env:{...process.env, ZEROWORK_DATA_DIR:data, ZEROWORK_AUTOCONNECT:'0', ZENIT_E2E_FILE_RPC_DIR:rpc, ZENIT_E2E_BACKGROUND:'1', ZENIT_E2E_ISOLATE_POINTER:'1', ZENIT_E2E_ISOLATE_KEYBOARD:'1'}, stdio:['ignore', log.fd, log.fd]});
    const ended = new Promise<void>(done => app.once('close', () => done()));
    // Keep the writer open until the test releases it, bounded even on failure.
    const writer = scenario === 'slow' || scenario === 'timeout' ? spawn('python3', ['-c',
        'import os,sys,time,pathlib\np,release=sys.argv[1:]\nf=os.open(p,os.O_WRONLY)\nend=time.monotonic()+10\nwhile not pathlib.Path(release).exists() and time.monotonic()<end:time.sleep(.01)\nos.write(f,bytes.fromhex("'+pixel.toString('hex')+'"))\nos.close(f)', path, join(iso, 'release')], {stdio:'ignore'}) : null;
    const writerEnded = writer ? new Promise<void>(done => writer.once('close', () => done())) : null;
    try {
        await h.waitForServerReady(30000);
        if (writer) {
            const overlay = await h.waitFor(async () => (await h.query('startup.overlay')).find(shown) ?? null, 5000);
            const began = Date.now();
            const identity = (await h.query('startup.identity')).find(shown)!;
            const logo = (await h.query('startup.logo')).find(shown)!;
            assert(Math.abs(overlay.rect.w - 1440) <= 1 && Math.abs(overlay.rect.h - 900) <= 1, JSON.stringify(overlay.rect));
            assert(Math.abs(logo.rect.w - 80) <= 1 && Math.abs(logo.rect.h - 80) <= 1);
            assert(Math.abs(identity.rect.x + identity.rect.w / 2 - 720) <= 1);
            assert(Math.abs(identity.rect.y + identity.rect.h / 2 - 450) <= 1);
            assert((await h.screenshot(join(out, `${scenario}-loading.png`))).ok);
            await writeFile(join(out, `${scenario}-geometry.json`), JSON.stringify({overlay, identity, logo}, null, 2));
            if (scenario === 'slow') {
                await h.resizeWindow(860, 480);
                const compact = (await h.query('startup.overlay')).find(shown)!;
                const centered = (await h.query('startup.identity')).find(shown)!;
                assert.equal(compact.rect.w, 860); assert.equal(compact.rect.h, 480);
                assert(Math.abs(centered.rect.x + centered.rect.w / 2 - 430) <= 1);
                assert(Math.abs(centered.rect.y + centered.rect.h / 2 - 240) <= 1);
                assert((await h.screenshot(join(out, 'slow-loading-860.png'))).ok);
                await h.resizeWindow(1440, 900);
            }
            if (scenario === 'timeout') {
                await h.waitFor(async () => !(await h.query('startup.overlay')).some(shown) || null, 3000);
                assert(Date.now() - began < 2800, 'slow IO kept the workspace covered');
                assert((await h.screenshot(join(out, 'timeout-fallback.png'))).ok);
            }
            await writeFile(join(iso, 'release'), 'ready');
            if (scenario === 'slow') {
                await h.waitFor(async () => (await h.query('startup.overlay')).find(n => shown(n) && n.opacity! > 0 && n.opacity! < .99) ?? null, 3000);
                assert((await h.screenshot(join(out, 'slow-fading.png'))).ok);
            }
        }
        await h.waitFor(async () => !(await h.query('startup.overlay')).some(shown) || null, 5000);
        assert((await h.query('workspace.shell')).some(shown));
        assert((await h.screenshot(join(out, `${scenario}-workspace.png`))).ok);
        if (scenario === 'ready' || scenario === 'slow') {
            const brightness = Number(execFileSync('python3', ['-c', 'from PIL import Image\nimport sys\nim=Image.open(sys.argv[1]).convert("RGB")\nprint(sum(im.getpixel((im.width-100,im.height//2)))/3)', join(out, `${scenario}-workspace.png`)], {encoding:'utf8'}));
            assert(brightness > 60, 'workspace was revealed before the white background painted');
        }
        if (scenario === 'disabled') assert.equal((await h.query('startup.overlay')).length, 0);
        // A completed splash must remain hidden after late resource completion.
        if (writer) {await writerEnded; await h.sleep(250); assert(!(await h.query('startup.overlay')).some(shown));}
        if (scenario === 'ready') {
            assert((await h.clickTestId('toolbar.settings')).ok);
            assert((await h.clickTestId('settings.nav.appearance')).ok);
            await h.waitFor(async () => (await h.query('settings.background.state')).some(n => n.text?.includes('2.png')) || null, 5000);
        }
        assert.equal(await readFile(join(data, 'config.toml'), 'utf8'), config);
        assert((await h.request('POST', '/quit')).ok);
        await ended;
        assert.equal(app.exitCode, 0, 'native app did not shut down cleanly');
        reports.push({scenario, status:'passed'});
    } finally {
        await writeFile(join(iso, 'release'), 'ready');
        if (app.exitCode === null && app.signalCode === null) app.kill('SIGTERM');
        await ended;
        if (writer && writer.exitCode === null && writer.signalCode === null) writer.kill('SIGTERM');
        if (writerEnded) await writerEnded;
        await log.close();
        await cleanupOwnedBridgeDirectories(app.pid!);
        await rm(iso, {recursive:true, force:true});
    }
}
await writeFile(join(out, 'native-report.json'), JSON.stringify(reports, null, 2));
console.log(JSON.stringify(reports));
