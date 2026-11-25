/**
 * Verify the production browser child-window path end to end.
 *
 * A local HTTP origin serves parent.html with real window.open buttons and a
 * child page that reads window.opener/document.cookie, posts a message back to
 * the opener and writes document.title. The real Web plugin is opened through
 * the connection wizard; the address-bar badge must track the native
 * ZWWebPopupWindow count, hide again when the child closes, and allow the next
 * child to open.
 *
 * node e2e/web_popup_native.ts --binary /tmp/zw-popup/bin/zerowork --out /tmp/zw-popup-out
 */
import assert from 'node:assert/strict';
import {spawn, type ChildProcess} from 'node:child_process';
import {createServer, type IncomingMessage, type ServerResponse} from 'node:http';
import type {AddressInfo} from 'node:net';
import {mkdir, mkdtemp, open, readFile, realpath, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

const root = resolve(dirname(new URL(import.meta.url).pathname), '..');
const argv = process.argv.slice(2);
if (argv.includes('--help')) {
    console.log('node e2e/web_popup_native.ts --binary /path/to/zerowork --out /path/to/output');
    process.exit(0);
}
const options: Record<string, string> = {};
for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    if (!['--binary', '--out'].includes(name) || !argv[index + 1]) throw new Error('Invalid option ' + name);
    options[name] = argv[index + 1];
}
const binary = resolve(options['--binary'] ?? join(root, 'zig-out/bin/zerowork'));
const prefix = resolve(dirname(binary), '..');

const harness = await import(pathToFileURL(join(prefix, 'share/zenit/harness/client.ts')).href);
const h = harness as typeof import('../vendor/zenit/e2e/client.ts');
const run = await realpath(await mkdtemp(join(tmpdir(), 'zw-popup-e2e-')));
const data = join(run, 'data');
const rpc = join(run, 'rpc');
const output = resolve(options['--out'] ?? join(run, 'evidence'));
await Promise.all([mkdir(data), mkdir(rpc), mkdir(output, {recursive: true})]);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const appLog = await open(join(output, 'app.log'), 'w');
const fixtureLog = await open(join(output, 'fixture.log'), 'w');
let app: ChildProcess | undefined;
let appExit: Promise<unknown> | undefined;
let server: ReturnType<typeof createServer> | undefined;
let stage = 'start fixture';

type Traffic = {path: string; cookie: string};
const traffic: Traffic[] = [];
const parentHTML = `<!doctype html><meta charset="utf-8"><title>Popup Parent</title>
<style>html,body{margin:0;background:#20242c;color:#fff;font:16px -apple-system}button{position:fixed;left:0;width:320px;height:96px;font-size:20px}</style>
<button id="open" style="top:0" onclick="document.cookie='popup_fixture=shared; path=/'; openChild('/child.html', 'popup_child')">打开子窗口</button>
<button id="two" style="top:104px" onclick="document.cookie='popup_fixture=shared; path=/'; openChild('/child.html?second=1', 'popup_child_two_a'); openChild('/child.html?second=1', 'popup_child_two_b')">打开两个子窗口</button>
<script>
let children = [];
function openChild(url, name) {
    const child = window.open(url, name, 'width=560,height=460');
    if (!child) { fetch('/event?blocked=' + encodeURIComponent(name)); return; }
    children.push(child);
}
window.addEventListener('message', event => {
    const value = event.data || {};
    if (value.kind !== 'popup-child') return;
    fetch('/event?opener=' + (value.opener ? '1' : '0') + '&cookie=' + encodeURIComponent(value.cookie) + '&title=' + encodeURIComponent(value.title));
});
const auto = new URLSearchParams(location.search).get('auto');
if (auto) setTimeout(() => { const button = document.getElementById(auto); if (button) button.click(); }, 350);
</script>`;
const childHTML = `<!doctype html><meta charset="utf-8"><title>Child pending</title>
<style>html,body{margin:0;background:#101418;color:#fff;font:14px -apple-system}</style>
<div id="info">child</div>
<script>
const second = location.search.includes('second=1');
const info = {kind: 'popup-child', opener: !!window.opener, cookie: document.cookie, title: ''};
document.title = info.opener ? (second ? 'Second Child OK' : 'Child Opener OK') : 'Child Opener Missing';
info.title = document.title;
document.getElementById('info').textContent = document.title + ' cookie=' + info.cookie;
if (window.opener) window.opener.postMessage(info, '*');
</script>`;

const closeHTML = `<!doctype html><meta charset="utf-8"><title>Close child</title>
<script>
const names = (new URLSearchParams(location.search).get('names') || '').split(',').filter(Boolean);
fetch('/close-page?names=' + encodeURIComponent(names.join(',')));
setTimeout(() => {
    for (const name of names) {
        const child = window.open('', name);
        if (child && !child.closed) child.close();
    }
}, 150);
</script>`;

function serve(request: IncomingMessage, response: ServerResponse) {
    const url = new URL(request.url ?? '/', 'http://127.0.0.1');
    traffic.push({path: url.pathname + url.search, cookie: request.headers.cookie ?? ''});
    void fixtureLog.write(JSON.stringify(traffic[traffic.length - 1]) + '\n');
    if (url.pathname === '/parent.html' || url.pathname === '/') {
        response.writeHead(200, {'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store'});
        response.end(parentHTML);
    } else if (url.pathname === '/child.html') {
        response.writeHead(200, {'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store'});
        response.end(childHTML);
    } else if (url.pathname === '/close.html') {
        response.writeHead(200, {'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store'});
        response.end(closeHTML);
    } else {
        response.writeHead(204, {'Cache-Control': 'no-store'});
        response.end();
    }
}

const visible = (node: any) => node && node.visible !== false && !node.hidden && (node.effective_opacity ?? 1) > 0 && node.rect?.w > 0 && node.rect?.h > 0;
const flatten = (node: any): any[] => [node, ...(node.children ?? []).flatMap(flatten)];
const content = (node: any) => flatten(node).map((item: any) => item.text ?? '').join(' ');
const find = (id: string, match = (_node: any) => true) =>
    h.waitFor(async () => ((await h.query(id)) as any[]).find(node => visible(node) && match(node)) ?? null, 12000);
async function click(id: string, match?: (node: any) => boolean) {
    await find(id, match);
    await h.sleep(120);
    assert((await h.clickTestId(id)).ok);
}
async function fill(id: string, value: string) {
    await click(id);
    await h.key('a', {cmd: true});
    await h.type_(value);
}
let origin = '';
// The Zenit harness dispatches pointer events through the Zenit node tree and
// cannot reach a native WKWebView child. The fixture loads a page that performs
// a real DOM click on its own button; the click handler then calls the same
// production window.open path.
async function navigateAuto(id: 'open' | 'two') {
    const seen = traffic.filter(entry => entry.path.startsWith('/parent.html?auto=' + id)).length;
    await click('web.address');
    await h.key('a', {cmd: true});
    await h.type_(origin + '/parent.html?auto=' + id);
    await h.key('return');
    await eventStarting('/parent.html?auto=' + id, seen);
}
async function closeNamed(names: string) {
    const seen = traffic.filter(entry => entry.path.startsWith('/close-page')).length;
    await click('web.address');
    await h.key('a', {cmd: true});
    await h.type_(origin + '/close.html?names=' + encodeURIComponent(names));
    await h.key('return');
    await eventStarting('/close-page', seen);
    await h.waitFor(async () => (await badgeText()) === null || null, 15000);
}
async function eventStarting(prefix: string, from = 0) {
    return h.waitFor(async () => {
        const matches = traffic.filter(entry => entry.path.startsWith(prefix));
        return matches.length > from ? matches[from] : null;
    }, 12000);
}
async function capture(name: string) {
    await h.sleep(160);
    assert((await h.screenshot(join(output, name + '.png'))).ok);
    const snapshot: Record<string, unknown> = {};
    for (const id of ['web.popups', 'web.popups.popup', 'web.toolbar', 'web.document', 'web.address']) snapshot[id] = await h.query(id);
    await writeFile(join(output, name + '.json'), JSON.stringify(snapshot, null, 2) + '\n');
}
async function badgeText(): Promise<string | null> {
    const nodes = (await h.query('web.popups')) as any[];
    const shown = nodes.filter(visible);
    if (!shown.length) return null;
    const text = flatten(shown[0]).map((node: any) => node.text).filter(Boolean).join(' ');
    return text || null;
}

try {
    stage = 'start fixture and app';
    server = createServer(serve);
    await new Promise<void>(done => server!.listen(0, '127.0.0.1', done));
    const port = (server.address() as AddressInfo).port;
    origin = 'http://127.0.0.1:' + port;
    await writeFile(join(output, 'environment.json'), JSON.stringify({origin, binary}, null, 2) + '\n');
    await writeFile(join(data, 'known_hosts'), '');
    await writeFile(join(data, 'config.toml'), '[meta]\nconfig_revision=1\n[ui]\ntheme="reference-light"\n');
    await writeFile(join(data, 'hosts.toml'), '[registry]\nschema_version=2\nrevision=1\nnext_connection_id=1\nnext_group_id=1\n');
    const credentials = join(data, 'credentials');
    await mkdir(credentials, {mode: 0o700});
    await writeFile(join(credentials, '.local-storage'), '1', {mode: 0o600});
    app = spawn(binary, [], {
        env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZW_TEST_CREDENTIAL_RESPONSE: 'cancel'},
        stdio: ['ignore', appLog.fd, appLog.fd],
    });
    appExit = new Promise(done => app!.once('close', done));
    await h.waitForServerReady(30000);
    await h.resizeWindow(1280, 800);

    stage = 'open the browser connection';
    await click('toolbar.new_session');
    await click('session.menu.new_web');
    await find('web.editor.name');
    await fill('web.editor.name', 'Popup fixture');
    await click('web.editor.mode.preset');
    await fill('web.editor.url', origin + '/parent.html');
    await click('web.editor.next');
    await find('wizard.access.direct');
    await click('web.editor.next');
    await find('web.editor.review');
    await click('web.editor.open');
    await find('web.document');
    await h.waitFor(async () => !((await h.query('web.state')) as any[]).some(visible) || null, 15000);
    assert.equal((await eventStarting('/parent.html')).path, '/parent.html');
    await capture('01-parent');

    stage = 'open the first native child from the page button';
    await navigateAuto('open');
    await h.waitFor(async () => (await badgeText()) === '子窗口 1' || null, 15000);
    const message = await eventStarting('/event?opener=');
    assert.equal(message.path, '/event?opener=1&cookie=' + encodeURIComponent('popup_fixture=shared') + '&title=Child%20Opener%20OK');
    assert.equal((await badgeText()), '子窗口 1');
    await capture('02-one-popup');

    stage = 'the badge opens the real popup list';
    await click('web.popups');
    const row = await find('web.popups.item.1');
    assert(content(row).includes('Child Opener OK'), 'popup row carries the live document.title');
    await capture('03-popup-list');
    await h.key('escape');

    stage = 'closing the child restores the address bar';
    await closeNamed('popup_child');
    assert.equal((await badgeText()), null);
    await capture('04-after-close');

    stage = 'a second page trigger opens the next child';
    await navigateAuto('open');
    await h.waitFor(async () => (await badgeText()) === '子窗口 1' || null, 15000);
    const secondMessage = await h.waitFor(async () => traffic.filter(entry => entry.path.startsWith('/event?opener=')).length >= 2 ? traffic.filter(entry => entry.path.startsWith('/event?opener='))[1] : null, 15000);
    assert.equal(secondMessage.path, message.path);
    assert.equal((await badgeText()), '子窗口 1');
    await capture('05-second-popup');
    await closeNamed('popup_child');

    stage = 'two live children count as two';
    await navigateAuto('two');
    await h.waitFor(async () => (await badgeText()) === '子窗口 2' || null, 15000);
    assert.equal((await badgeText()), '子窗口 2');
    await capture('06-two-popups');
    await closeNamed('popup_child_two_a,popup_child_two_b');

    stage = 'quit releases every native child window';
    await navigateAuto('two');
    await h.waitFor(async () => (await badgeText()) === '子窗口 2' || null, 15000);
    await h.request('POST', '/zerowork/windows', {action: 'quit'});
    await Promise.race([appExit, h.sleep(15000)]);
    assert.equal(app.exitCode, 0, 'application quits cleanly with child windows closed');
    assert(!(await readFile(join(output, 'app.log'), 'utf8')).includes('ZW_TEST_CREDENTIAL_REQUEST'),
        'the direct fixture must not even ask the mocked Keychain to authorize');
    console.log('PASS: window.open creates a native child, opener/cookie postMessage works, badge 1 -> hidden -> 1 -> 2, titles propagate, quit exits 0');
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
    if (server) await new Promise<void>(done => server!.close(() => done()));
    await Promise.all([appLog.close(), fixtureLog.close()]);
    await rm(run, {recursive: true, force: true});
}
