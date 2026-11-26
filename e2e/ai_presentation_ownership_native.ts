/** Exercise real window hit testing and retained AI surfaces without model credentials. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, open, realpath, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { once } from 'node:events';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const root = await realpath(await mkdtemp('/tmp/zw-ai-presentation-'));
const data = join(root, 'data'), rpc = join(root, 'rpc');
await mkdir(data);
await mkdir(rpc);
const dockPreference = process.argv.includes('--dock-preference');
const theme = process.argv.includes('--light') ? 'reference-light' : 'dark';
await writeFile(join(data, 'config.toml'), `[meta]
config_revision=1
[ui]
theme="${theme}"
ai_dock_preferred=${dockPreference}
[ai]
default_provider="local"
[[ai.providers]]
id="local"
kind="openai_compat"
endpoint="http://127.0.0.1:1/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="local-test"
context_window=32768
default=true
`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(root, 'app.log'), 'w');
const app = spawn(join(prefix, 'bin/zerowork'), [], {
  env: { ...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1' },
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
  await h.type_('retain this unsent draft');
  if (!dockPreference) await click('ai.dock_right');
  await visible('workspace.ai_dock');
  await draft('retain this unsent draft');
  const composerFitsDock = async () => {
    let geometry: any;
    try {
      await h.waitFor(async () => {
        const [dock] = await nodes('workspace.ai_dock');
        const [input] = await nodes('ai.prompt');
        if (!dock || !input) return null;
        geometry = { dock: dock.rect, input: input.rect };
        return input.rect.x >= dock.rect.x - 1 && input.rect.x + input.rect.w <= dock.rect.x + dock.rect.w + 1 ? true : null;
      }, 2500);
    } catch (e) {
      throw new Error('Docked composer outside slot: ' + JSON.stringify(geometry), { cause: e });
    }
  };
  await composerFitsDock();
  await same('ai.strip', entrance);
  assert((await h.clickAt(340, 540)).ok);
  await visible('ai.prompt');
  await h.resizeWindow(860, 480);
  await composerFitsDock();
  await h.resizeWindow(1440, 900);
  await composerFitsDock();
  await click('ai.dock_right');
  await hidden('workspace.ai_dock');
  await visible('ai.prompt');
  await draft('retain this unsent draft');
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
  console.log('Native AI presentation: fixed trigger, non-reflow hover, dock/undock, outside click and standalone entry OK');
} finally {
  app.kill('SIGTERM');
  await exited.catch(() => {});
  await log.close();
  await rm(root, { recursive: true, force: true });
}
