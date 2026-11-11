/** Run against a -Dtest-mode=true build. Uses an isolated App and loopback Provider.
 * ZW_AI_TEST_PREFIX=/path/to/zig-out node e2e/ai_local_workspace_native.ts /tmp/zw-workspace-evidence
 * Pass --picker to also exercise the real AppKit directory chooser in the macOS GUI session.
 */
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { copyFile, mkdir, mkdtemp, open, readFile, realpath, rm, stat, writeFile } from 'node:fs/promises';
import { createServer, type ServerResponse } from 'node:http';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const picker = process.argv.includes('--picker');
const out = resolve(process.argv.slice(2).find(argument => argument !== '--picker') ?? '/tmp/zw-workspace-evidence');
const root = await realpath(await mkdtemp('/tmp/zw-workspace-app-'));
const [data, rpc, zdot, workspace] = ['data', 'rpc', 'zdot', 'ExampleProject'].map(name => join(root, name));
for (const dir of [out, data, rpc, zdot, workspace]) await mkdir(dir, { recursive: true });
const firstChoice = join(root, 'First Project');
if (picker) await mkdir(firstChoice);
const file = join(workspace, 'project.txt');
await writeFile(file, 'Start of fixture.\nWorkspace content from the isolated local directory.\nEnd of fixture.\n');
await writeFile(join(zdot, '.zshrc'), "bindkey -e\nPS1='workspace-fixture%# '\n");

const journalPath = join(data, 'ai-sessions.jsonl');
if (!picker) {
  const conversation = randomBytes(16).toString('hex');
  const agent = randomBytes(16).toString('hex');
  const dir = await stat(workspace);
  const baseline = [
    { schema: 1, event: { kind: 'create', conversation, agent, owner: { session: 1 }, revision: 2 } },
    { schema: 4, event: {
      kind: 'workspace_update', conversation, agent, revision: 2,
      workspace: { revision: 2, availability: 'ready', directory: workspace, resolved_directory: workspace, directory_identity: { device: dir.dev, inode: dir.ino } },
      workspace_change: { before_revision: 1, reason: 'set' },
    } },
    { schema: 1, event: { kind: 'checkpoint', conversation, agent, revision: 2, turn: 1 },
      messages: [{ role: 'user', content: 'Prior question' }, { role: 'assistant', content: 'Prior answer' }] },
  ];
  await writeFile(journalPath, baseline.map(row => JSON.stringify(row)).join('\n') + '\n');
}
const removalRevision = picker ? 4 : 3;

const readTool = 'host__local_uread_utext';
const contextTool = 'host__get_ucurrent_ucontext';
const listTool = 'host__local_ulist_ufiles';
const searchTool = 'host__local_usearch_utext';
const frame = (delta: object) => 'data: ' + JSON.stringify({ choices: [{ index: 0, delta }] }) + '\n\n';
const done = 'data: [DONE]\n\n';
const calls = (...items: [string, string, object][]) => frame({ tool_calls: items.map(([id, name, args], index) => ({
  index, id, type: 'function', function: { name, arguments: JSON.stringify(args) },
})) });
const requests: any[] = [];
let providerCalls = 0;
let held: ServerResponse | null = null;
let serverFailure: unknown = null;
const server = createServer(async (req, res) => {
  if (req.method !== 'POST') return res.end('{"data":[{"id":"workspace-fixture"}]}');
  providerCalls++;
  try {
    let raw = '';
    for await (const part of req) raw += part;
    const body = JSON.parse(raw);
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    if (!body.tools?.length) return res.end(frame({ content: 'Workspace fixture title' }) + done);
    requests.push(body);
    const system = body.messages.find((m: any) => m.role === 'system')?.content;
    const tool = (id: string) => JSON.parse(body.messages.find((m: any) => m.tool_call_id === id).content);
    const notice = body.messages.filter((m: any) => m.role === 'user' && String(m.content).includes('"kind":"local_workspace_changed"')).at(-1);
    switch (requests.length) {
      case 1:
        assert(system.includes(workspace));
        assert(body.tools.some((t: any) => t.function.name === readTool));
        assert(body.tools.some((t: any) => t.function.name === listTool));
        assert(body.tools.some((t: any) => t.function.name === searchTool));
        return res.end(calls(['context', contextTool, {}], ['first-read', readTool, { path: 'project.txt' }],
          ['list-workspace', listTool, {}], ['search-workspace', searchTool, { pattern: 'isolated local directory', context_lines: 1 }]) + done);
      case 2:
        assert.equal(tool('context').status, 'succeeded');
        assert(JSON.stringify(tool('context')).includes(workspace));
        assert.equal(tool('first-read').status, 'succeeded');
        assert(JSON.stringify(tool('first-read')).includes('Workspace content from the isolated local directory'));
        assert.equal(tool('list-workspace').status, 'succeeded');
        assert(JSON.stringify(tool('list-workspace')).includes('project.txt'));
        assert.equal(tool('search-workspace').status, 'succeeded');
        const found = JSON.stringify(tool('search-workspace'));
        assert(found.includes('isolated local directory') && found.includes('Start of fixture.') && found.includes('End of fixture.'));
        assert(system.includes(workspace));
        held = res;
        res.write(frame({ content: 'WORKSPACE_STREAM_HELD' }));
        return;
      case 3: {
        assert(!system.includes(workspace));
        const event = JSON.parse(notice.content);
        assert.equal(event.local_workspace.state, 'none');
        assert.equal(event.local_workspace.revision, removalRevision);
        const stale = tool('stale-relative');
        assert(JSON.stringify(stale).includes('WorkspaceChanged'));
        assert.equal(stale.side_effect_started ?? stale.receipt?.side_effect_started, false);
        assert.equal(tool('fixed-absolute').status, 'succeeded');
        assert(JSON.stringify(tool('fixed-absolute')).includes(file));
        return res.end(frame({ content: 'WORKSPACE_ROUND_COMPLETE' }) + done);
      }
      default:
        throw new Error('unexpected Provider request');
    }
  } catch (error) {
    serverFailure = error;
    if (!res.headersSent) res.writeHead(500);
    res.end();
  }
});
await new Promise<void>(ready => server.listen(0, '127.0.0.1', ready));
const address = server.address();
assert(address && typeof address !== 'string');
await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ai]\ndefault_provider="workspace-fixture"\n[[ai.providers]]\nid="workspace-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${address.port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="workspace-fixture"\ncontext_window=200000\ndefault=true\n`);
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const log = await open(join(out, 'app.log'), 'w');
let executable = join(prefix, 'bin', 'zerowork');
if (picker) {
  const mac = join(root, 'Workspace Picker Verification.app', 'Contents', 'MacOS');
  await mkdir(mac, { recursive: true });
  await writeFile(join(mac, '..', 'Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>local.zerowork.workspacepicker.${process.pid}</string><key>CFBundleName</key><string>Workspace Picker Verification</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
  for (const name of ['zerowork', 'zw_ipc.so', 'zw_execution.so', 'zw_execution_guard', 'zw_secret_consume.so']) {
    await copyFile(join(prefix, 'bin', name), join(mac, name));
  }
  executable = join(mac, 'zerowork');
}
function launch(rpcDirectory: string) {
  process.env.ZENIT_E2E_FILE_RPC_DIR = rpcDirectory;
  return spawn(executable, [], { env: {
    ...process.env, ZEROWORK_DATA_DIR: data, ZDOTDIR: zdot, ZEROWORK_AUTOCONNECT: '0',
    ZENIT_E2E_BACKGROUND: picker ? '0' : '1', ...(picker ? { ZENIT_E2E_REAL_ACTIVATION: '1' } : {}),
    ZENIT_E2E_ISOLATE_POINTER: '1', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: '',
  }, stdio: ['ignore', log.fd, log.fd] });
}
let app = launch(rpc);
let ended = new Promise(resolve => app.once('close', resolve));
const alive = () => app.exitCode === null && app.signalCode === null;
const shown = (n: any) => n && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const flatten = (nodes: any): any[] => Array.isArray(nodes) ? nodes.flatMap(flatten) : nodes ? [nodes, ...(nodes.children ?? []).flatMap(flatten)] : [];
const text = (nodes: any) => flatten(nodes).map(n => n.text ?? '').join(' ');
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
const click = async (id: string) => { report.last_action = id; await visible(id); assert((await h.clickTestId(id)).ok, id); };
const report: any = { root, out, picker, status: 'running', checks: [] };
const os = (body: string) => execFileSync('osascript', ['-e', `tell application "System Events"\n tell (first process whose unix id is ${app.pid})\n ${body}\n end tell\nend tell`], { encoding: 'utf8', timeout: 10000 }).trim();
const windowProbe = join(root, 'native-window-list');
const dialogTitle = '选择本地工作区';
const dialogNames = ['Open Folder', dialogTitle];
function nativeDialog() {
  const rows = JSON.parse(execFileSync(windowProbe, [String(app.pid)], { encoding: 'utf8' }));
  return rows.find((row: any) => row.kCGWindowIsOnscreen && dialogNames.includes(row.kCGWindowName));
}
async function pick(action: string, options: { directory?: string, confirmCurrent?: boolean, capture?: string } = {}) {
  report.last_action = action;
  await visible(action);
  const clicked = h.clickTestId(action);
  clicked.catch(() => {});
  const dialog = await h.waitFor(() => nativeDialog() ?? null, 15000);
  assert.equal(dialog.kCGWindowName, dialogTitle);
  report.dialog_title = dialog.kCGWindowName;
  const target = `window ${JSON.stringify(dialog.kCGWindowName)}`;
  await h.waitFor(() => os(`exists ${target}`) === 'true' || null, 5000);
  if (options.directory) {
    report.last_action = `${action} activate dialog`;
    os('set frontmost to true');
    await h.waitFor(() => os('get frontmost') === 'true' || null, 5000);
    report.last_action = `${action} open Go to Folder`;
    os('keystroke "g" using {command down, shift down}');
    await h.waitFor(() => Number(os(`count sheets of ${target}`)) > 0 || null, 5000);
    report.last_action = `${action} navigate to directory`;
    os(`set value of text field 1 of sheet 1 of ${target} to ${JSON.stringify(options.directory)}\n key code 36`);
    await h.waitFor(() => Number(os(`count sheets of ${target}`)) === 0 || null, 5000);
  }
  if (options.capture) {
    await h.sleep(180);
    execFileSync('/usr/sbin/screencapture', ['-x', '-l', String(dialog.kCGWindowNumber), join(out, `${options.capture}.png`)]);
  }
  if (options.directory || options.confirmCurrent) {
    report.last_action = `${action} click Open`;
    os(`click button "选择" of splitter group 1 of ${target}`);
  } else {
    report.last_action = `${action} click Cancel`;
    os(`tell splitter group 1 of ${target}\n if exists button "Cancel" then\n click button "Cancel"\n else\n click button "取消"\n end if\n end tell`);
  }
  report.last_action = `${action} await close`;
  assert((await clicked).ok);
  await h.waitFor(() => !nativeDialog() || null, 5000);
}
async function reopenConversation(restore = true) {
  await h.waitForServerReady(60000);
  await h.resizeWindow(1100, 760);
  await click('workspace.empty.local');
  await visible('terminal.surface');
  await click('ai.strip');
  if (restore) {
    await click('ai.sessions');
    await click('ai.session.restore.1');
  }
}
async function quit() {
  if (!alive()) return;
  await h.request('POST', '/zerowork/windows', { action: 'quit' });
  const until = performance.now() + 15000;
  while (alive() && performance.now() < until) {
    for (const id of ['groups.close.accept', 'local.close.accept', 'session.close.accept']) {
      if (!alive()) break;
      if (flatten(await h.query(id).catch(() => [])).some(shown)) await h.clickTestId(id).catch(() => {});
    }
    await Promise.race([ended, h.sleep(80)]);
  }
}
async function workspaceUpdates() {
  try {
    return (await readFile(journalPath, 'utf8')).trim().split('\n').filter(Boolean)
      .map(line => JSON.parse(line).event).filter(event => event.kind === 'workspace_update');
  } catch (error: any) {
    if (error.code !== 'ENOENT') throw error;
    return [];
  }
}
async function verifyPicker() {
  const draft = 'Keep the draft while choosing a folder';
  assert(!(await h.query('ai.workspace')).some(shown));
  await click('ai.prompt');
  await h.type_(draft);
  await click('ai.composer.attachment');
  await pick('ai.attachment.workspace');
  assert(!(await h.query('ai.workspace')).some(shown));
  assert.equal((await h.inputState('ai.prompt')).buffer, draft);
  assert.deepEqual(await workspaceUpdates(), []);
  assert.equal(providerCalls, 0);

  await click('ai.composer.attachment');
  await pick('ai.attachment.workspace', { directory: firstChoice });
  await h.waitFor(async () => (await visible('ai.workspace.name')).text === 'First Project' || null, 5000);
  assert.equal((await h.inputState('ai.prompt')).buffer, draft);
  await click('ai.workspace');
  assert.equal((await visible('ai.workspace.path')).text, firstChoice);
  await pick('ai.workspace.change');
  assert.equal((await visible('ai.workspace.name')).text, 'First Project');
  assert.equal((await h.inputState('ai.prompt')).buffer, draft);
  await click('ai.workspace');
  await pick('ai.workspace.change', { confirmCurrent: true, capture: 'picker-reopen-current' });
  assert.equal((await visible('ai.workspace.name')).text, 'First Project');
  await click('ai.workspace');
  await pick('ai.workspace.change', { directory: workspace, capture: 'picker-change' });
  await h.waitFor(async () => (await visible('ai.workspace.name')).text === 'ExampleProject' || null, 5000);
  assert.equal((await h.inputState('ai.prompt')).buffer, draft);
  await click('ai.workspace');
  assert.equal((await visible('ai.workspace.path')).text, workspace);
  await click('ai.workspace');
  assert.equal(providerCalls, 0);
  const updates = await workspaceUpdates();
  assert.deepEqual(updates.map(event => [event.workspace.revision, event.workspace.directory]), [[2, firstChoice], [3, workspace]]);
  report.checks.push('The real AppKit chooser opens with the expected title from the attachment menu of a new conversation. Cancel preserves the draft and starts no Provider request. Choosing A and changing to B persist exactly two workspace revisions.');
  report.checks.push('Changing directories opens AppKit in the selected A directory. Cancelling the change preserves A and its draft.');

  await quit();
  assert.equal(app.exitCode, 0);
  report.first_app_exit = app.exitCode;
  const restartRpc = join(root, 'rpc-restart');
  await mkdir(restartRpc);
  app = launch(restartRpc);
  ended = new Promise(resolve => app.once('close', resolve));
  await reopenConversation();
  assert.equal((await visible('ai.workspace.name')).text, 'ExampleProject');
  assert.equal((await h.inputState('ai.prompt')).buffer, draft);
  assert.equal(providerCalls, 0);
  report.checks.push('A normal Quit and a new app process restore B and the original unsent draft without a Provider request.');
}
try {
  if (picker) execFileSync('swiftc', ['e2e/native_window_list.swift', '-o', windowProbe]);
  await reopenConversation(!picker);
  if (picker) await verifyPicker();
  assert.equal((await visible('ai.workspace.name')).text, 'ExampleProject');
  assert.equal(requests.length, 0);
  await click('ai.prompt');
  if (picker) await h.key('a', { cmd: true });
  await h.type_('Read project.txt');
  await click('ai.send');
  const streamed = await h.waitFor(() => { if (serverFailure) throw serverFailure; return held; }, 20000);
  await click('ai.workspace');
  await click('ai.workspace.remove');
  assert.equal((await visible('ai.workspace.name')).text, '已移除');
  assert((await h.screenshot(join(out, 'pending-removal.png'))).ok);
  streamed.end(calls(['stale-relative', readTool, { path: 'project.txt' }], ['fixed-absolute', readTool, { path: file }]) + done);
  await h.waitFor(async () => {
    if (serverFailure) throw serverFailure;
    return text(await h.query('ai.panel')).includes('WORKSPACE_ROUND_COMPLETE') || null;
  }, 20000);
  await h.waitFor(async () => !(await h.query('ai.workspace')).some(shown) || null, 15000);
  const rows = String(await readFile(journalPath, 'utf8')).trim().split('\n').map(row => JSON.parse(row));
  assert(rows.some(row => row.event?.kind === 'workspace_ack' && row.event.workspace_ack_revision === removalRevision));
  assert.equal(requests.length, 3);
  report.checks.push('Restore did not call the Provider; relative read, list, and search used the saved workspace, then a streamed old relative plan was rejected while a fixed absolute read still succeeded. The new notice was acknowledged and the removal pill cleared.');
  report.status = 'passed';
} catch (error) {
  report.status = 'failed';
  report.error = String(error);
  try {
    if (picker && alive() && nativeDialog()) os('set frontmost to true\n key code 53');
  } catch {}
  await h.screenshot(join(out, 'failure.png')).catch(() => {});
  await h.query('ai.panel').then(tree => writeFile(join(out, 'failure-tree.json'), JSON.stringify(tree, null, 2))).catch(() => {});
} finally {
  try {
    if (picker && alive() && nativeDialog()) os('set frontmost to true\n key code 53');
    await quit();
  } catch (error) { report.quit_error = String(error); }
  if (alive()) { app.kill('SIGTERM'); await ended; }
  report.app_exit = app.exitCode;
  if (app.exitCode !== 0) report.status = 'failed';
  server.closeAllConnections();
  await new Promise<void>(closed => server.close(() => closed()));
  await log.close();
  await writeFile(join(out, 'requests.json'), JSON.stringify(requests, null, 2));
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  await rm(root, { recursive: true, force: true });
  console.log(JSON.stringify(report));
  if (report.status !== 'passed') process.exitCode = 1;
}
