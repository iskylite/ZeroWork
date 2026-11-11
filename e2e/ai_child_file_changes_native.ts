/** Actual child file changes through a disposable Local session and loopback Provider.
 * zig build -Dtest-mode=true --prefix /tmp/zw-child-changes-build -j2
 * ZW_AI_TEST_PREFIX=/tmp/zw-child-changes-build node e2e/ai_child_file_changes_native.ts
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, open, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { createServer, type ServerResponse } from 'node:http';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const out = resolve(process.argv[2] ?? '/tmp/zw-child-file-changes');
const iso = await realpath(await mkdtemp('/tmp/zw-child-file-changes-'));
const [data, rpc, zdot] = ['data', 'rpc', 'zdot'].map(name => join(iso, name));
for (const dir of [out, data, rpc, zdot]) await mkdir(dir, { recursive: true });
await writeFile(join(zdot, '.zshrc'), "bindkey -e\nPS1='child-file-changes%# '\n");

const writeTool = 'host.local_write_text';
const queryTool = 'host.local_get_changes';
const taskTool = 'host.agent_tasks';
const wire = (name: string) => name.replaceAll('_', '_u').replaceAll('.', '__');
const frame = (delta: object, finish_reason: string) =>
  'data: ' + JSON.stringify({ choices: [{ index: 0, delta, finish_reason }] }) + '\n\n';
const done = 'data: [DONE]\n\n';
const finish = (res: ServerResponse, content: string) => res.end(frame({ content }, 'stop') + done);
type Call = [id: string, name: string, args: object];
function emit(res: ServerResponse, ...calls: Call[]) {
  return res.end(frame({ tool_calls: calls.map(([id, name, args], index) => ({
    index, id, type: 'function', function: { name: wire(name), arguments: JSON.stringify(args) },
  })) }, 'tool_calls') + done);
}

const result = (content: string) => {
  const envelope = JSON.parse(content);
  const block = envelope.content?.find((item: any) => item.type === 'structured');
  return { status: envelope.status, body: block ? JSON.parse(block.text) : envelope };
};
type Result = ReturnType<typeof result>;
function succeeded(value: Result) {
  assert.equal(value.status, 'succeeded', JSON.stringify(value));
  return value.body;
}
function refused(value: Result, error: string) {
  assert.equal(value.status, 'rejected', JSON.stringify(value));
  assert.equal(value.body.error_code, error);
}
function writeArgs(role: string) {
  return { path: join(iso, role + '.txt'), mode: 'create', text: role + '\n', request_key: role };
}
function checkWrite(value: Result, role: string) {
  const written = succeeded(value);
  assert.equal(written.verified, true);
  assert.equal(written.target, writeArgs(role).path);
  assert.match(written.operation_ref, /^[0-9a-f]{32}$/);
  return written;
}

let failure: unknown;
let parentWrite: any;
let siblingWrite: any;
let ownWrite: any;
const checks: string[] = [];
const server = createServer(async (req, res) => {
  if (req.method !== 'POST') return res.end('{"data":[{"id":"file-changes"}]}');
  try {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    const request = JSON.parse(raw);
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    if (!request.tools?.length) return finish(res, 'Child file changes');
    const tools = new Set(request.tools.map((tool: any) => tool.function.name));
    const results = new Map<string, Result>(request.messages.filter((msg: any) => msg.role === 'tool')
      .map((msg: any) => [msg.tool_call_id, result(msg.content)]));
    const get = (id: string) => results.get(id)!;
    if (tools.has(wire(taskTool))) {
      if (!results.has('parent-write')) return emit(res, ['parent-write', writeTool, writeArgs('parent')]);
      parentWrite = checkWrite(get('parent-write'), 'parent');
      if (!results.has('context')) return emit(res, ['context', 'host.get_current_context', {}]);
      const context = succeeded(get('context'));
      const launch = (role: string): Call => ['launch-' + role, taskTool, {
        action: 'create', request_key: role, name: role, text: 'FILE_CHANGE_CHILD_' + role,
        context_mode: 'independent', reusable: false, session_refs: [context.binding_ref], local_files: 'write',
      }];
      if (!results.has('launch-sibling')) return emit(res, launch('sibling'));
      assert.equal(succeeded(get('launch-sibling')).task.local_files, 'write');
      const waits = [...results].filter(([id]) => id.startsWith('events-'));
      const wait = (): Call => ['events-' + waits.length, taskTool, {
        action: 'wait_events', after_sequence: waits.length ? succeeded(waits.at(-1)![1]).watermark : 0, wait_ms: 5000,
      }];
      const reported = (marker: string) => waits.some(([, entry]) => JSON.stringify(succeeded(entry)).includes(marker));
      if (!reported('SIBLING_FILE_CHANGE_DONE')) return emit(res, wait());
      if (!results.has('launch-own')) return emit(res, launch('own'));
      assert.equal(succeeded(get('launch-own')).task.local_files, 'write');
      if (!reported('OWN_FILE_CHANGE_DONE')) return emit(res, wait());
      if (!results.has('parent-query')) return emit(res, ['parent-query', queryTool, {}]);
      assert.deepEqual(new Set(succeeded(get('parent-query')).operations.map((op: any) => op.operation_ref)),
        new Set([parentWrite.operation_ref, siblingWrite.operation_ref, ownWrite.operation_ref]));
      checks.push('Parent dispatch aggregates its own and both delegated children’s changes.');
      return finish(res, 'PARENT_FILE_CHANGES_DONE');
    }

    const role = request.messages.some((msg: any) => msg.role === 'user' && msg.content === 'FILE_CHANGE_CHILD_sibling')
      ? 'sibling' : 'own';
    assert(request.messages.some((msg: any) => msg.role === 'user' && msg.content === 'FILE_CHANGE_CHILD_' + role));
    assert(tools.has(wire(writeTool)) && tools.has(wire(queryTool)));
    if (!results.has('child-write')) return emit(res, ['child-write', writeTool, writeArgs(role)]);
    const written = checkWrite(get('child-write'), role);
    if (role === 'sibling') {
      siblingWrite = written;
      return finish(res, 'SIBLING_FILE_CHANGE_DONE');
    }
    ownWrite = written;
    if (!results.has('own-list')) return emit(res,
      ['own-list', queryTool, {}],
      ['own-verify', queryTool, { operation_ref: written.operation_ref, verify: true }],
      ['parent-op', queryTool, { operation_ref: parentWrite.operation_ref, verify: true }],
      ['sibling-op', queryTool, { operation_ref: siblingWrite.operation_ref }],
      ['parent-task', queryTool, { task_ref: parentWrite.task_ref }],
      ['sibling-task', queryTool, { task_ref: siblingWrite.task_ref }],
    );
    assert.deepEqual(succeeded(get('own-list')).operations.map((op: any) => op.operation_ref), [written.operation_ref]);
    const verified = succeeded(get('own-verify'));
    assert.equal(verified.operation_ref, written.operation_ref);
    assert.equal(verified.observation.matches_submitted_candidate, true);
    for (const id of ['parent-op', 'sibling-op']) refused(get(id), 'LocalFileOperationNotFound');
    for (const id of ['parent-task', 'sibling-task']) refused(get(id), 'LocalFileTaskNotAuthorized');
    checks.push('Child dispatch lists and verifies its own change and refuses parent and sibling references.');
    return finish(res, 'OWN_FILE_CHANGE_DONE');
  } catch (error) {
    failure = error;
    if (!res.headersSent) res.writeHead(500);
    res.end();
  }
});

await new Promise<void>(ready => server.listen(0, '127.0.0.1', ready));
const address = server.address();
assert(address && typeof address !== 'string');
await writeFile(join(data, 'config.toml'), `[meta]
config_revision=1
[ai]
default_provider="file-changes"
permission_mode="confirm"
[[ai.providers]]
id="file-changes"
kind="openai_compat"
endpoint="http://127.0.0.1:${address.port}/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="file-changes"
context_window=200000
default=true
`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(join(prefix, 'bin', 'zerowork'), [], { env: {
  ...process.env, ZEROWORK_DATA_DIR: data, ZDOTDIR: zdot, ZEROWORK_AUTOCONNECT: '0',
  ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: '',
}, stdio: ['ignore', log.fd, log.fd] });
const ended = new Promise<void>(resolve => app.once('close', () => resolve()));
const alive = () => app.exitCode === null && app.signalCode === null;
const shown = (node: any) => !node.hidden && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect?.w > 0 && node.rect?.h > 0;
const text = (node: any): string => Array.isArray(node) ? node.map(text).join(' ') :
  [node?.text ?? '', text(node?.children ?? [])].join(' ');
const visible = (id: string) => h.waitFor(async () => {
  if (failure) throw failure;
  assert(alive(), 'Fixture application exited');
  return (await h.query(id)).find(shown) ?? null;
}, 15000);
const click = async (id: string) => {
  await visible(id);
  assert((await h.clickTestId(id)).ok, id);
};

try {
  await h.waitForServerReady(60000);
  assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
  await h.resizeWindow(1200, 900);
  await click('workspace.empty.local');
  await visible('terminal.surface');
  await click('toolbar.ai');
  await click('ai.composer.permission');
  await click('ai.permission.auto');
  await click('ai.prompt');
  await h.type_('ROOT_FILE_CHANGES');
  await click('ai.send');
  await h.waitFor(async () => {
    if (failure) return true;
    return text(await h.query('ai.panel')).includes('PARENT_FILE_CHANGES_DONE') &&
      !(await h.query('ai.stop')).some(shown) || null;
  }, 30000);
  if (failure) throw failure;
  assert.equal(checks.length, 2);
  for (const role of ['parent', 'sibling', 'own']) {
    const expected = writeArgs(role);
    assert.equal(await readFile(expected.path, 'utf8'), expected.text);
  }
  await h.request('POST', '/zerowork/windows', { action: 'quit' });
  await h.waitFor(async () => {
    for (const id of ['groups.close.accept', 'local.close.accept', 'session.close.accept']) {
      if (!alive()) return true;
      const nodes = await Promise.race([h.query(id).catch(() => []), ended]);
      if (!Array.isArray(nodes)) break;
      if (nodes.some(shown)) await Promise.race([h.clickTestId(id).catch(() => {}), ended]);
    }
    return !alive() || null;
  }, 15000);
  assert.equal(app.exitCode, 0);
  console.log(JSON.stringify({ checks }));
} finally {
  if (alive()) app.kill('SIGTERM');
  await ended;
  server.closeAllConnections();
  await new Promise<void>(resolve => server.close(() => resolve()));
  await log.close();
  await rm(iso, { recursive: true, force: true });
}
