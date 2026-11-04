/** Settings input shielding, registered BMC row, and real image/blur previews.
 * node e2e/settings_material_regressions_native.ts BINARY OUTPUT_DIR
 * Uses private configuration, a synthetic PNG, and background Harness input.
 */
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, realpath, rm, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {deflateSync} from 'node:zlib';
import * as h from '../vendor/zenit/e2e/client.ts';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';

const binary = resolve(process.argv[2]), out = resolve(process.argv[3]);
const iso = await realpath(await mkdtemp('/private/tmp/zw-settings-regressions-'));
const data = join(iso, 'data'), rpc = join(iso, 'rpc');
await Promise.all([mkdir(out, {recursive: true}), mkdir(data), mkdir(rpc)]);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
function crc32(bytes: Buffer) {
  let crc = 0xffffffff;
  for (const byte of bytes) { crc ^= byte; for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(kind: string, bytes: Buffer) {
  const type = Buffer.from(kind), size = Buffer.alloc(4), crc = Buffer.alloc(4);
  size.writeUInt32BE(bytes.length); crc.writeUInt32BE(crc32(Buffer.concat([type, bytes])));
  return Buffer.concat([size, type, bytes, crc]);
}
const width = 240, height = 160, raw = Buffer.alloc(height * (1 + width * 4));
for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
  const color = ((x / 20 | 0) + (y / 20 | 0)) % 2 ? [242, 192, 65] : [71, 129, 232];
  raw.set([...color, 255], y * (1 + width * 4) + 1 + x * 4);
}
const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 6;
const image = join(data, 'checker.png');
await writeFile(image, Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'), chunk('IHDR', header), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]));
await writeFile(join(out, 'fixture.png'), await readFile(image));
await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\n[ui.materials]\nblur_px=0\n[ui.materials.background]\nenabled=true\npath=${JSON.stringify(image)}\nfit="tile"\ntransparency=50\n`);
await writeFile(join(data, 'hosts.toml'), `[registry]
schema_version=2
revision=1
next_connection_id=3
next_group_id=2
[[groups]]
group_id=1
revision=1
name="Material fixture"
collapsed=false
ordered_connection_ids=[1,2]
[[hosts]]
connection_id=1
revision=1
asset_group_id=1
protocol="ssh"
name="Fixture Linux"
host="192.0.2.1"
user="demo"
[[hosts]]
connection_id=2
revision=1
asset_group_id=1
protocol="ssh"
name="Fixture Server"
host="192.0.2.2"
user="demo"
`);
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(binary, [], {env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'}, stdio: ['ignore', log.fd, log.fd]});
const ended = new Promise<number | null>(done => app.once('close', done));
const report: any = {status: 'running', binary, checks: [], captures: []};
const visible = (id: string) => h.waitFor(async () => {const nodes=await h.query(id);if(!Array.isArray(nodes))throw Error(id+': '+JSON.stringify(nodes));return nodes.find(n => n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect.w > 0 && n.rect.h > 0) ?? null;}, 15000);
async function click(id: string) {
  const n = await visible(id); assert((await h.clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok, id); await h.sleep(90);
}
async function reveal(id: string) {
  for (let i = 0; i < 30; i++) {
    const n = await visible(id), v = (await visible('settings.viewport')).rect;
    if (n.rect.y >= v.y && n.rect.y + n.rect.h <= v.y + v.h) return;
    await h.scrollAt(v.x + v.w - 5, v.y + v.h / 2, 0, n.rect.y < v.y ? 140 : -140); await h.sleep(60);
  }
  throw Error('Cannot reveal ' + id);
}
async function edit(id: string, value: string) {
  await reveal(id); await click(id); await h.key('a', {cmd: true}); await h.key('backspace'); await h.type_(value); await h.key('return'); await h.sleep(120);
  assert.equal(Number((await h.inputState(id)).buffer), Number(value));
}
async function capture(name: string, id: string) {
  await h.mouseMove(3, 3); await h.sleep(300);
  // The retained settings/preview tree can exceed a full-root query response.
  // Capturing geometry needs only the dedicated bounded screenPos route.
  const rect = await h.screenPos(id); assert(rect.w > 0 && rect.h > 0, id);
  const path = join(out, name + '.png'); assert((await h.screenshot(path)).ok);
  report.captures.push({name, path, rect}); await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
}
try {
  await h.waitForServerReady(); await h.resizeWindow(1440, 900);
  await click('workspace.empty.local'); await visible('terminal.surface'); await click('terminal.surface');
  const terminalFocus = await h.focused(); assert(terminalFocus.id !== undefined);
  await capture('workspace-t50-blur0', 'workspace.shell');
  report.canvas_pixels = JSON.parse(execFileSync('python3', [resolve('e2e/canvas_material_pixels.py'), join(out, 'workspace-t50-blur0.png'), JSON.stringify((await visible('ai.strip.lip')).rect)], {encoding: 'utf8'}));
  report.checks.push('All four cards and the AI entry actual pixels use one 50% canvas mix; no extra card opacity is applied.');
  await h.type_('@theme sauber'); await h.key('return'); await h.sleep(350);
  await capture('sauber-t50-blur0', 'workspace.shell');
  await click('toolbar.settings'); await click('settings.search');
  const card = (await visible('settings.panel')).rect;
  for (const [x, y] of [[card.x + 160, card.y + 14], [card.x + card.w - 12, card.y + card.h / 2], [card.x + card.w + 15, card.y + card.h / 2]]) {
    await h.clickAt(x, y); assert.notEqual((await h.focused()).id, terminalFocus.id, 'settings blank areas must not focus the terminal');
  }
  report.checks.push('Header, card blank space, and outer scrim keep pointer input above the terminal.');
  await click('settings.nav.plugins');
  await click('已内置'); await click('随应用提供'); await click('协议扩展');
  const names = await h.query('settings.plugin.bmc_ikvm.name'); assert.equal(names.length, 1);
  const future = await h.query('settings.plugins.future.body');
  const texts = (n: any): string[] => [...(n.text ? [n.text] : []), ...(n.children ?? []).flatMap(texts)];
  assert(!future.flatMap(texts).some(t => /BMC|iKVM/.test(t)));
  await capture('plugins', 'settings.panel');
  report.checks.push('BMC iKVM occurs once in registered plugins and is absent from protocol-extension placeholders.');
  await click('settings.nav.appearance'); await reveal('settings.materials.header'); await click('settings.materials.header');
  await h.waitFor(async () => (await visible('settings.background.state')).text?.includes('240 × 160') || null, 15000);
  for (const transparency of ['0', '50', '100']) {
    await edit('settings.field.transparency', transparency); await edit('settings.field.blur_px', '0'); await reveal('settings.background.preview');
    await capture('t' + transparency + '-blur0', 'settings.background.preview');
  }
  for (const blur of ['24', '96', '0']) {
    await edit('settings.field.blur_px', blur); await reveal('settings.background.preview'); await capture('t100-blur' + blur, 'settings.background.preview');
  }
  await edit('settings.field.blur_px', '24'); await reveal('settings.materials.preview.full'); await click('settings.materials.preview.full');
  await visible('settings.materials.preview.actions'); await capture('full-preview', 'workspace.shell');
  await click('settings.materials.preview.return'); await visible('settings.panel');
  report.checks.push('Real decoded image previews captured at transparency 0/50/100 and blur 0/24/96, including returning blur to zero and full-window preview.');
  await click('settings.save'); await h.waitFor(async () => (await visible('settings.footer.state')).text === '已保存' || null, 15000);
  const saved = await readFile(join(data, 'config.toml'), 'utf8'); assert.match(saved, /transparency = 100/); assert.match(saved, /blur_px = 24/);
  await click('settings.close');
  await capture('workspace-t100-blur24', 'workspace.shell'); await capture('saved-background', 'workspace.shell');
  await h.request('POST', '/quit', {}); const code = await ended; assert.equal(code, 0, 'normal app shutdown');
  report.status = 'passed';
} catch (error) {
  report.status = 'failed'; report.error = String(error); process.exitCode = 1; console.error(error);
  await h.screenshot(join(out, 'failure.png')).catch(() => {});
} finally {
  if (app.exitCode === null && app.signalCode === null) app.kill('SIGTERM');
  await ended; if (app.pid) await cleanupOwnedBridgeDirectories(app.pid); await log.close(); await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  await rm(iso, {recursive: true, force: true});
}
