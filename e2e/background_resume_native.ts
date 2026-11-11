/** Persist committed directory progress through real timed rotation and restarts. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, realpath, rm, stat, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';

const binary = resolve(process.argv[2] ?? 'zig-out/bin/zerowork');
const out = resolve(process.argv[3] ?? '/tmp/zw-background-resume-native');
await mkdir(out, {recursive:true});
const isolated = await realpath(await mkdtemp('/private/tmp/zw-background-resume-'));
const data = join(isolated, 'data'), images = join(isolated, 'images');
await mkdir(data); await mkdir(images);
const white = 'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFUlEQVR4nGP8//8/AzbAhFV00EoAAFbUAw037MyjAAAAAElFTkSuQmCC';
const black = 'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAADElEQVR4nGNgGB4AAADIAAGtQHYiAAAAAElFTkSuQmCC';
for (const [name, bytes] of [['1.png', black], ['2.png', white], ['3.png', black]]) await writeFile(join(images, name), Buffer.from(bytes, 'base64'));
await writeFile(join(data, 'config.toml'), `[ui]\ntheme="dark"\n[ui.materials.background]\nenabled=true\nsource="directory"\npath=${JSON.stringify(images)}\norder="sequential"\ninterval_minutes=1\ntransparency=60\n[updates]\nauto_check=false\n`);
const statePath = join(data, 'background-rotation.json');
const readProgress = async () => JSON.parse(await readFile(statePath, 'utf8'));
const shown = (n:any) => n?.rect?.w > 0 && n.rect.h > 0 && n.visible !== false && n.hidden !== true;
const visible = (id:string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
async function click(id:string) {
    await visible(id);
    assert((await h.clickTestId(id)).ok, id);
    await h.sleep(100);
}
async function reveal(id:string) {
    for (let i=0; i<35; i++) {
        const n = await visible(id), v = (await visible('settings.viewport')).rect;
        if (n.rect.y >= v.y && n.rect.y+n.rect.h <= v.y+v.h) return;
        await h.scrollAt(v.x+v.w-5, v.y+v.h/2, 0, n.rect.y<v.y ? 150 : -150);
        await h.sleep(70);
    }
    throw Error('Cannot reveal '+id);
}
async function openSettings() {
    await click('toolbar.settings'); await click('settings.nav.appearance');
    await reveal('settings.materials.header'); await click('settings.materials.header');
    await reveal('settings.background.state');
}
async function expectImage(name:string) {
    await h.waitFor(async () => (await visible('settings.background.state')).text?.includes('目录轮播 · '+name) || null, 15000);
}
async function launch(round:number, run:()=>Promise<void>) {
    const rpc = join(isolated, 'rpc-'+round); await mkdir(rpc);
    process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
    const log = await open(join(out, 'app-'+round+'.log'), 'w');
    const app = spawn(binary, [], {env:{...process.env, ZEROWORK_DATA_DIR:data, ZEROWORK_AUTOCONNECT:'0', ZENIT_E2E_FILE_RPC_DIR:rpc, ZENIT_E2E_BACKGROUND:'1', ZENIT_E2E_ISOLATE_POINTER:'1', ZENIT_E2E_ISOLATE_KEYBOARD:'1'}, stdio:['ignore',log.fd,log.fd]});
    const ended = new Promise<void>(done => app.once('close', () => done()));
    try {
        await h.waitForServerReady(30000); await h.resizeWindow(1440,900);
        await h.waitFor(async () => !(await h.query('startup.overlay')).some(shown) || null, 5000);
        await run();
    } catch (error) {
        await h.screenshot(join(out,'failure-'+round+'.png')).catch(()=>{});
        await writeFile(join(out,'failure-'+round+'-tree.json'),JSON.stringify(await h.tree().catch(()=>null),null,2));
        throw error;
    }
    finally {
        if (app.exitCode===null && app.signalCode===null) app.kill('SIGTERM');
        await ended; await log.close();
    }
    assert.equal(app.signalCode, 'SIGTERM');
    const logs = await readFile(join(out, 'app-'+round+'.log'), 'utf8');
    assert(!/Cannot (save|clear) background progress|panic:|\[gpa\].*leaked/.test(logs), logs);
}
const report:any = {status:'running', checks:[]};
let randomProgress:any;
try {
    await launch(1, async () => {
        await openSettings(); await expectImage('1.png');
        const config = await readFile(join(data, 'config.toml'), 'utf8');
        const initialProgress = await stat(statePath, {bigint:true});
        assert((await h.resizeWindow(1240, 800)).ok);
        assert((await h.resizeWindow(1440, 900)).ok);
        await expectImage('1.png');
        const afterRedraw = await stat(statePath, {bigint:true});
        assert.equal(afterRedraw.ino, initialProgress.ino, 'redraw replaced unchanged background progress');
        assert.equal(afterRedraw.mtimeNs, initialProgress.mtimeNs, 'redraw wrote unchanged background progress');
        report.checks.push('native resize and redraw preserve the unchanged progress file');
        await click('settings.close');
        console.log('Waiting for the real one-minute switch');
        await h.sleep(31000); await h.health(); await h.sleep(31000);
        await openSettings(); await expectImage('2.png');
        const state = await readProgress();
        assert.equal(state.paths[state.index], join(images,'2.png'));
        assert.equal(await readFile(join(data,'config.toml'),'utf8'), config);
        assert.equal((await visible('settings.footer.state')).text ?? '', '');
        assert((await h.screenshot(join(out,'sequential-before-restart.png'))).ok);
        report.checks.push('real one-minute rotation persists current image without changing config or dirtying settings');
    });
    await launch(2, async () => {
        await openSettings(); await expectImage('2.png');
        await h.sleep(1500); await expectImage('2.png');
        assert((await h.screenshot(join(out,'sequential-after-restart.png'))).ok);
        report.checks.push('restart restores the displayed sequential image and starts a fresh interval');
        await reveal('settings.field.order'); await click('settings.field.order'); await click('settings.option.order.random');
        assert.equal((await visible('settings.footer.state')).text, '未保存');
        await click('settings.save');
        await h.waitFor(async () => ((await visible('settings.footer.state')).text ?? '') === '' || null, 15000);
        await expectImage('2.png');
        randomProgress = await readProgress();
        assert.equal(randomProgress.random, true);
        assert.equal(randomProgress.paths[randomProgress.index], join(images,'2.png'));
        report.checks.push('changing to random keeps the displayed image and saves the new queue');
    });
    await launch(3, async () => {
        await openSettings(); await expectImage('2.png');
        assert.deepEqual(await readProgress(), randomProgress);
        assert((await h.screenshot(join(out,'random-after-restart.png'))).ok);
        report.checks.push('random queue, cursor and displayed image all survive real process restart');
    });
    report.status='passed';
    console.log(JSON.stringify(report));
} catch (error) { report.status='failed'; report.error=String(error); console.error(error); process.exitCode=1; }
finally { await writeFile(join(out,'report.json'), JSON.stringify(report,null,2)); await rm(isolated,{recursive:true,force:true}); }
