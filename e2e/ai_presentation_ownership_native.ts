/** Exercise real window hit testing and retained AI surfaces without model credentials. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, open, realpath, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { once } from 'node:events';
import { createServer, type ServerResponse } from 'node:http';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const root = await realpath(await mkdtemp('/tmp/zw-ai-presentation-'));
const data = join(root, 'data'), rpc = join(root, 'rpc');
await mkdir(data);
await mkdir(rpc);
await mkdir(join(data, 'credentials'), { mode: 0o700 });
await writeFile(join(data, 'credentials', '.local-storage'), '1', { mode: 0o600 });
const dockPreference = process.argv.includes('--dock-preference');
const wideHostRail = process.argv.includes('--wide-host-rail');
const theme = process.argv.includes('--light') ? 'reference-light' : 'dark';
const unsent = 'retain this unsent draft';
let sent: ServerResponse | undefined;
const providerErrors: string[] = [];
const server = createServer(async (req, res) => {
  try {
    assert.equal(req.headers.authorization, undefined, 'fixture must not receive credentials');
    if (req.method !== 'POST') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{"data":[{"id":"local-test"}]}');
      return;
    }
    let raw = '';
    for await (const chunk of req) raw += chunk;
    const lastUser = JSON.parse(raw).messages.findLast((item: any) => item.role === 'user')?.content;
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const frame = (value: string) => 'data: ' + JSON.stringify({ choices: [{ index: 0, delta: { content: value } }] }) + '\n\n';
    if (!sent && lastUser === unsent) {
      sent = res;
      res.write(frame('DOCK_STREAMING'));
      return; // Deliberately held open to hit-test and click the stop button.
    }
    res.end(frame('Fixture title') + 'data: [DONE]\n\n');
  } catch (error) {
    providerErrors.push(String(error));
    res.end();
  }
});
server.listen(0, '127.0.0.1');
await once(server, 'listening');
const port = (server.address() as { port: number }).port;
await writeFile(join(data, 'config.toml'), `[meta]
config_revision=1
[ui]
theme="${theme}"
ai_dock_preferred=${dockPreference}
${wideHostRail ? 'sidebar_width=480\n' : ''}[ai]
default_provider="local"
[[ai.providers]]
id="local"
kind="openai_compat"
endpoint="http://127.0.0.1:${port}/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="local-test"
context_window=32768
default=true
`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(root, 'app.log'), 'w');
const app = spawn(join(prefix, 'bin/zerowork'), [], {
  env: { ...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZW_TEST_CREDENTIAL_RESPONSE: 'cancel', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: '', ZDOTDIR: root },
  stdio: ['ignore', log.fd, log.fd],
});
const exited = once(app, 'close');
const shown = (n: any) => n && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0.01 && n.rect?.w > 0 && n.rect?.h > 0;
const nodes = async (id: string) => (await h.query(id)).filter(shown);
const visible = async (id: string) => h.waitFor(async () => (await nodes(id))[0] ?? null, 5000);
const hidden = async (id: string) => h.waitFor(async () => (await nodes(id)).length === 0 ? true : null, 5000);
const draft = async (text: string) => h.waitFor(async () => (await h.inputState('ai.prompt')).buffer === text ? true : null, 5000);
const click = async (id: string) => { await visible(id); assert((await h.clickTestId(id)).ok, id); };
const hover = async (id: string) => { const { rect: r } = await visible(id); assert((await h.mouseMove(r.x + r.w / 2, r.y + r.h / 2)).ok); };
const same = async (id: string, rect: any) => {
  const visible = await nodes(id);
  assert.equal(visible.length, 1, id);
  for (const axis of ['x','y','w','h']) assert(Math.abs(visible[0].rect[axis] - rect[axis]) < 1, id + '.' + axis);
};
try {
  await h.waitForServerReady(30000);
  await h.resizeWindow(1440, 900);
  await click('workspace.empty.local');
  await visible('terminal.surface');
  await hidden('toolbar.ai');
  await hidden('tabs.color_marker');
  await hidden('tabs.active_underline');
  await visible('tabs.connection.state');
  const tools = (await visible('toolbar.group.global')).children.map((n: any) => n.test_id);
  assert.deepEqual(tools, ['toolbar.window_pin','toolbar.history','toolbar.notifications','status.connection.theme','toolbar.settings']);
  const mascot = (await visible('workspace.mascot.body')).rect;
  const entrance = (await visible('ai.strip')).rect;
  await hover('ai.strip');
  if (!dockPreference) await visible('ai.prompt');
  for (let i = 0; i < 8; i++) {
    await h.sleep(90);
    await same('ai.strip', entrance);
    await same('workspace.mascot.body', mascot);
    if (!dockPreference) assert.equal((await nodes('ai.prompt')).length, 1, 'hover preview blinked');
    assert.equal((await nodes('workspace.ai_dock')).length, 0, 'hover must not reflow terminal');
  }
  if (!dockPreference) {
    await hover('ai.prompt');
    await h.sleep(320);
    assert.equal((await nodes('ai.prompt')).length, 1, 'crossing into preview should keep it open');
  }
  await h.mouseMove(5, 300);
  await hidden('ai.prompt');
  assert((await h.key('j', {cmd:true})).ok);
  await click('ai.prompt');
  await h.type_(unsent);
  if (!dockPreference) await click('ai.dock_right');
  await visible('workspace.ai_dock');
  await draft(unsent);
  const composerFitsDock = async (action = 'ai.send') => {
    let geometry: Record<string, any> = {};
    try {
      return await h.waitFor(async () => {
        const ids = ['workspace.content.row', 'workspace.pane', 'workspace.ai_dock.slot', 'ai.panel', 'ai.composer.surface', 'ai.prompt', action, 'ai.header', 'ai.strip', 'ai.sessions', 'ai.session.new', 'ai.dock_right', 'ai.collapse'];
        const found = await Promise.all(ids.map(nodes));
        geometry = Object.fromEntries(ids.map((id, i) => [id, found[i][0]?.rect]));
        if (found.some(row => row.length !== 1)) return null;
        const [row, pane, slot, panel, composer, input, button, header, strip, ...headerButtons] = found.map(entry => entry[0].rect);
        const encloses = (outer: any, inner: any) => inner.x >= outer.x - 0.75 && inner.y >= outer.y - 0.75 && inner.x + inner.w <= outer.x + outer.w + 0.75 && inner.y + inner.h <= outer.y + outer.h + 0.75;
        const [ownerPill] = await nodes('ai.owner');
        const [ownerText] = await nodes('ai.owner.label');
        if (ownerText && (!ownerPill || !encloses(ownerPill.rect, ownerText.rect))) return null;
        return pane.w >= Math.min(260, row.w * 0.4) - 1 && strip.y + strip.h <= panel.y && encloses(row, pane) && encloses(row, slot) && encloses(slot, panel) && encloses(panel, header) && headerButtons.every(control => encloses(header, control)) && encloses(panel, composer) && encloses(composer, input) && encloses(composer, button) ? slot.w : null;
      }, 5000);
    } catch (e) {
      throw new Error('Docked composer outside slot: ' + JSON.stringify(geometry), { cause: e });
    }
  };
  const preferred = await composerFitsDock();
  await same('ai.strip', entrance);
  assert((await h.clickAt(340, 540)).ok);
  await visible('ai.prompt');
  await h.resizeWindow(860, 480);
  assert(await composerFitsDock() < preferred);
  await draft(unsent);
  await click('ai.collapse');
  await hidden('ai.prompt');
  assert((await h.key('j', {cmd:true})).ok);
  await composerFitsDock();
  await draft(unsent);
  if (process.env.ZW_AI_DOCK_CAPTURE) {
    await h.mouseMove(5, 300);
    assert((await h.screenshot(resolve(process.env.ZW_AI_DOCK_CAPTURE))).ok, 'could not capture narrow dock');
    const [composer, input, action] = await Promise.all(['ai.composer.surface', 'ai.prompt', 'ai.send'].map(visible));
    const right = (node: any) => node.rect.x + node.rect.w;
    console.log(`${theme} narrow dock: send inset ${Number((right(composer) - right(action)).toFixed(2))}pt, input inset ${Number((right(composer) - right(input)).toFixed(2))}pt`);
  }
  await click('ai.send');
  await h.waitFor(async () => sent ?? null, 8000);
  await composerFitsDock('ai.stop');
  await click('ai.stop');
  await visible('ai.send');
  assert.deepEqual(providerErrors, []);
  await click('ai.prompt');
  await h.type_(unsent);
  await h.resizeWindow(1440, 900);
  assert(Math.abs(await composerFitsDock() - preferred) < 0.75, 'a narrow window must not overwrite the saved dock width');
  await click('ai.dock_right');
  await hidden('workspace.ai_dock');
  await visible('ai.prompt');
  await draft(unsent);
  await click('toolbar.new_session');
  await click('session.menu.ai');
  await visible('ai.workspace.shell');
  await draft('');
  for (const id of ['toolbar.ai','ai.strip','workspace.mascot.body','workspace.ai_dock','ai.dock_right']) await hidden(id);
  assert((await h.key('j', {cmd:true})).ok); // focus, never close an embedded conversation
  await visible('ai.prompt');
  await h.resizeWindow(860, 480);
  await visible('ai.prompt');
  await hidden('ai.strip');
  await hidden('workspace.mascot.body');
  assert((await h.key('1', {cmd:true})).ok);
  await visible('workspace.mascot.body');
  await visible('ai.strip');
  assert((await h.key('j', {cmd:true})).ok);
  await visible('ai.prompt');
  await visible('ai.sessions');
  console.log('Native AI presentation: fixed trigger clear of dock, non-reflow hover, retained width, clickable narrow collapse/Send/Stop, dock/undock, outside click and standalone entry OK');
} finally {
  app.kill('SIGTERM');
  await exited.catch(() => {});
  server.closeAllConnections();
  await new Promise<void>(done => server.close(() => done()));
  await log.close();
  await rm(root, { recursive: true, force: true });
}
