/** Run the real Web connection wizard and tab against isolated HTTP and SSH peers. */
import assert from 'node:assert/strict';
import {execFileSync, spawn, type ChildProcess} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, realpath, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

const prefix = resolve(process.argv[2] ?? 'zig-out');
const output = resolve(process.argv[3]);
const macOSVersion = execFileSync('/usr/bin/sw_vers', ['-productVersion'], {encoding: 'utf8'}).trim();
let macOSSDKVersion: string | null = null;
try {
    macOSSDKVersion = execFileSync('/usr/bin/xcrun', ['--show-sdk-version'], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore']}).trim();
} catch {}
const h = await import(pathToFileURL(join(prefix, 'share/zenit/harness/client.ts')).href);
const run = await realpath(await mkdtemp(join(tmpdir(), 'zw-native-web-')));
const data = join(run, 'data');
const rpc = join(run, 'rpc');
await Promise.all([mkdir(data), mkdir(rpc), mkdir(output)]);
await writeFile(join(output, 'environment.json'), JSON.stringify({macOSVersion, macOSSDKVersion}, null, 2) + '\n');
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const appLog = await open(join(output, 'app.log'), 'w');
const peerLog = await open(join(output, 'peer.log'), 'w');
const peer = spawn(process.env.ZW_WEB_TEST_PYTHON ?? 'python3', ['-B', resolve('e2e/web_workspace_peer.py'), run], {
    stdio: ['ignore', peerLog.fd, peerLog.fd],
});
const peerExit = new Promise(done => peer.once('close', done));
let app: ChildProcess | undefined;
let appExit: Promise<unknown> | undefined;
let stage = 'start fixtures';

const visible = (node: any) => node && node.visible !== false && !node.hidden && (node.effective_opacity ?? 1) > 0 && node.rect?.w > 0 && node.rect?.h > 0;
const flatten = (node: any): any[] => [node, ...(node.children ?? []).flatMap(flatten)];
const content = (node: any) => flatten(node).map(item => item.text ?? '').join(' ');
const find = (id: string, match = (_node: any) => true) =>
    h.waitFor(async () => (await h.query(id)).find((node: any) => visible(node) && match(node)) ?? null, 12000);
async function click(id: string, match?: (node: any) => boolean) {
    await find(id, match);
    await h.sleep(180);
    const {x, y, w, h: height} = (await find(id, match)).rect;
    const center = {x: x + w / 2, y: y + height / 2};
    await h.mouseMove(center.x, center.y);
    assert((await h.clickAt(center.x, center.y)).ok);

}
async function fill(id: string, value: string) {
    await click(id);
    await h.key('a', {cmd: true});
    await h.type_(value);
}
async function json(path: string) {
    return JSON.parse(await readFile(path, 'utf8'));
}
async function traffic(): Promise<any[]> {
    const contents = await readFile(join(run, 'traffic.jsonl'), 'utf8').catch(error => {
        if (error.code === 'ENOENT') return '';
        throw error;
    });
    return contents.trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
}
async function received(path: string) {
    return h.waitFor(async () => (await traffic()).find(entry => entry.path === path) ?? null, 18000);
}
async function capture(name: string) {
    await h.sleep(180);
    assert((await h.screenshot(join(output, name + '.png'))).ok);
    if (app?.pid && process.env.ZW_WEB_WINDOW_NUMBER) {
        const number = execFileSync(process.env.ZW_WEB_WINDOW_NUMBER, [String(app.pid)], {encoding: 'utf8'}).trim();
        assert(/^\d+$/.test(number), 'find fixture AppKit window number');
        execFileSync('/usr/sbin/screencapture', ['-x', '-o', '-l', number, join(output, name + '-composited.png')]);
    }
}

async function openWebWizard(name: string) {
    await click('toolbar.new_session');
    await click('session.menu.new_profile');
    await find('wizard.protocol');
    if (!(await h.query('web.editor.name')).some(visible)) {
        await click('wizard.protocol');
        await click('wizard.protocol.web');
    }
    await fill('web.editor.name', name);
}

try {
    const ready = await h.waitFor(() => json(join(run, 'ready.json')).catch(() => null), 10000);
    await writeFile(join(data, 'known_hosts'), ready.known_hosts);
    await writeFile(join(data, 'config.toml'), '[meta]\nconfig_revision=1\n[ui]\ntheme="reference-light"\n');
    const hops = ready.ports.map((port: number, index: number) =>
        `[[hosts]]\nconnection_id=${index + 1}\nrevision=1\nprotocol="ssh"\nname="Owned hop ${index + 1}"\nhost="127.0.0.1"\nport=${port}\nuser="socks-fixture"\nauth_mode="password"\nauth={password="local-controlled-only"}\n`);
    await writeFile(join(data, 'hosts.toml'), '[registry]\nschema_version=2\nrevision=1\nnext_connection_id=3\nnext_group_id=1\n' + hops.join(''));
    app = spawn(join(prefix, 'bin/zerowork'), [], {
        env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'},
        stdio: ['ignore', appLog.fd, appLog.fd],
    });
    appExit = new Promise(done => app!.once('close', done));
    await h.waitForServerReady(30000);
    assert.equal(Number((await json(join(rpc, 'owner.json'))).pid), app.pid);
    await h.resizeWindow(1280, 800);

    stage = 'open web in the shared connection wizard';
    await openWebWizard('Owned direct web');
    await click('web.editor.mode.preset');
    await fill('web.editor.url', ready.direct);
    await capture('wizard-web');
    stage = 'save and load the direct preset';
    await click('web.editor.open');
    await find('web.document');
    assert.equal((await received('/direct')).host, new URL(ready.direct).host);
    stage = 'save the active page as a bookmark';
    await h.waitFor(async () => !(await h.query('web.state')).some(visible) || null, 12000);
    await click('web.address.bookmark');
    await h.waitFor(async () => {
        const config = await readFile(join(data, 'hosts.toml'), 'utf8');
        const saved = config.split('[[hosts]]').find(asset => asset.includes('"Owned direct web"'));
        const payload = saved?.match(/^payload\s*=\s*(".*")$/m)?.[1];
        return payload && JSON.parse(JSON.parse(payload)).bookmarks.length === 1 ? true : null;
    }, 12000);
    await capture('direct-web');
    stage = 'edit the existing bookmark without navigating';
    await click('web.address.bookmark');
    await fill('web.bookmark.edit.name', 'Fixture bookmark');
    await click('web.bookmark.edit.save');
    await h.waitFor(async () => (await readFile(join(data, 'hosts.toml'), 'utf8')).includes('Fixture bookmark') || null, 12000);
    assert.equal((await traffic()).filter(event => event.path === '/direct').length, 1);

    stage = 'website dialogs retain user choices and distinguish empty input from cancel';
    await openWebWizard('Web interaction fixture');
    await click('web.editor.mode.manual');
    await click('web.editor.temporary');
    stage = 'same-document address changes during loading reach the address bar';
    await fill('web.address', new URL('/history-loading', ready.direct).href);
    await h.key('return');
    await received('/history-loading-image');
    await received('/history-rewritten');
    const historyAddress = new URL('/history-address', ready.direct).href;
    await find('web.address', node => content(node).includes(historyAddress));
    assert(!(await traffic()).some(event => event.path === '/history-address'));

    stage = 'website dialogs retain user choices and distinguish empty input from cancel';
    await fill('web.address', new URL('/interaction-fixture', ready.direct).href);
    await h.key('return');
    const prompt = async (title: string, message: string) => {
        await find('plugin.challenge.modal', node => content(node).includes(title) && content(node).includes(message));
        await find('plugin.challenge.source', node => content(node).includes(new URL(ready.direct).origin));
    };
    await prompt('网页提示', 'fixture visible alert');
    await capture('website-alert');
    await click('plugin.challenge.choice.0');
    await prompt('网页确认', 'fixture accept confirmation');
    await click('plugin.challenge.choice.0');
    await prompt('网页确认', 'fixture cancel confirmation');
    await click('plugin.challenge.cancel');
    await prompt('网页输入', 'fixture empty prompt');
    assert.equal((await h.inputState('plugin.challenge.answer.0')).buffer, 'default text');
    await capture('website-prompt');
    await click('plugin.challenge.answer.0');
    await h.key('a', {cmd: true});
    await h.key('backspace');
    await click('plugin.challenge.submit');
    await prompt('网页输入', 'fixture cancel prompt');
    await click('plugin.challenge.cancel');
    const result = await h.waitFor(async () => (await traffic()).find(event => event.path?.startsWith('/interaction-result?')) ?? null, 12000);
    const values = new URL(result.path, ready.direct).searchParams;
    assert.equal(values.get('accepted'), 'true');
    assert.equal(values.get('rejected'), 'false');
    assert.equal(values.get('empty'), '""');
    assert.equal(values.get('cancelled'), 'null');

    stage = 'website HTTP authentication uses a window-owned one-time challenge';
    await fill('web.address', new URL('/auth-fixture', ready.direct).href);
    await h.key('return');
    await prompt('网站登录', 'Web fixture');
    await fill('plugin.challenge.answer.0', 'web-fixture');
    await fill('plugin.challenge.answer.1', 'local-auth-only');
    await capture('website-authentication');
    await click('plugin.challenge.submit');
    await h.waitFor(async () => (await traffic()).some(event => event.authentication === true) || null, 12000);
    await h.waitFor(async () => !(await h.query('plugin.challenge.modal')).some(visible) || null, 12000);
    assert(!(await readFile(join(data, 'hosts.toml'), 'utf8')).includes('local-auth-only'));

    stage = 'configure two hops with the shared SSH asset picker';
    await openWebWizard('Owned routed web');
    await click('web.editor.mode.manual');
    await click('wizard.access.jump');
    for (const hop of [1, 2]) {
        await click(hop === 1 ? 'wizard.route.hop.0' : 'wizard.route.insert.1');
        await find('wizard.route.search');
        if (hop === 1) await capture('wizard-shared-picker');
        await click('wizard.route.option', node => content(node).includes('Owned hop ' + hop));
    }
    await click('wizard.access.direct');
    await h.waitFor(async () => !(await h.query('wizard.route.chain')).some(visible) || null, 12000);
    await click('wizard.access.jump');
    await find('wizard.route.hop.1', node => content(node).includes('Owned hop 2'));
    await capture('wizard-ssh-route');

    await h.resizeWindow(860, 620);
    const compact = await find('wizard.route.chain');
    assert(compact.rect.w > 0 && compact.rect.h > 0 && compact.rect.h < 620);
    await h.scrollAt(compact.rect.x + compact.rect.w / 2, compact.rect.y + compact.rect.h / 2, 0, -240);
    await capture('wizard-ssh-route-compact');
    await h.resizeWindow(1280, 800);
    await click('web.editor.open');
    await h.waitFor(async () => !(await h.query('web.editor')).some(visible) || null, 12000);
    stage = 'submit a target to the saved SSH route';
    await find('web.address');
    assert(!(await traffic()).some(event => event.ssh_connection), 'manual route starts on navigation');
    await fill('web.address', ready.routed);
    await h.key('return');
    stage = 'navigate a manually entered IP through two SSH hops';
    assert.equal((await received('/routed')).host, new URL(ready.routed).host);
    const routed = await traffic();
    assert(routed.some(event => event.hop === 'entry' && event.allowed && event.destination[1] === ready.ports[1]));
    assert(routed.some(event => event.hop === 'exit' && event.allowed && event.destination.join(':') === ready.target.join(':')));
    await h.resizeWindow(1024, 680);
    await capture('ssh-web');
    assert.equal((await traffic()).filter(event => event.path === '/routed').length, 1);

    stage = 'reload the GET before reconnecting the interrupted SSH route';
    await click('web.reload');
    await h.waitFor(async () => (await traffic()).filter(event => event.path === '/routed').length === 2 || null, 12000);
    await h.waitFor(async () => !(await h.query('web.state')).some(visible) || null, 12000);
    await writeFile(join(run, 'drop'), '');
    await find('web.reconnect');
    await capture('ssh-disconnected');
    await click('web.reconnect');
    await h.waitFor(async () => (await traffic()).filter(event => event.path === '/routed').length === 3 || null, 18000);
    await h.waitFor(async () => !(await h.query('web.reconnect')).some(visible) || null, 12000);
    await capture('ssh-reconnected');

    stage = 'quit and release the session';
    await h.request('POST', '/zerowork/windows', {action: 'quit'});
    await Promise.race([appExit, h.sleep(12000)]);
    assert.equal(app.exitCode, 0, 'application should close the native surface and SSH route');
    console.log(`PASS macOS ${macOSVersion}, SDK ${macOSSDKVersion ?? 'unavailable'}: shared wizard, saved bookmark, JS dialogs and empty/cancelled prompts, HTTP authentication, direct WebKit, two-hop SOCKS5, GET reload/reconnect and normal Quit`);
} catch (error) {
    if (app?.exitCode === null) await capture('failure').catch(() => {});
    throw new Error(stage, {cause: error});
} finally {
    if (app?.exitCode === null && app.signalCode === null) {
        app.kill('SIGTERM');
        await Promise.race([appExit, h.sleep(3000)]);
        if (app.exitCode === null && app.signalCode === null) app.kill('SIGKILL');
    }
    if (appExit) await appExit;
    if (peer.exitCode === null && peer.signalCode === null) peer.kill('SIGTERM');
    await peerExit;
    await Promise.all([appLog.close(), peerLog.close()]);
    await rm(run, {recursive: true, force: true});
}
