/** Native managed-file acceptance using a loopback Provider and disposable data.
 * zig build -Dtest-mode=true -j2
 * node e2e/ai_local_file_write_native.ts /tmp/zw-managed-file-evidence
 * ZW_TEST_PYTHON=/path/to/python-with-paramiko node e2e/ai_local_file_write_native.ts /tmp/zw-managed-file-ssh-evidence --ssh
 * The --sftp and --kvm cases verify that a saved workspace stays inactive for
 * independent non-terminal sessions. KVM opens its offline view without device input.
 * Add --group to --sftp to exercise real SFTP/Local membership transitions.
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { createServer, type ServerResponse } from 'node:http';
import { mkdir, mkdtemp, open, readFile, realpath, rename, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const out = resolve(process.argv[2] ?? '/tmp/zw-managed-file-evidence');
const ssh = process.argv.includes('--ssh');
const sftp = process.argv.includes('--sftp');
const kvm = process.argv.includes('--kvm');
const group = process.argv.includes('--group');
assert([ssh, sftp, kvm].filter(Boolean).length <= 1, 'Choose one transport');
assert(!group || sftp, 'The mixed group uses the loopback SFTP peer');
const unsupported = sftp || kvm;
const attached = ssh || unsupported;
const protocol = ssh ? 'ssh' : 'sftp';
const root = await realpath(await mkdtemp('/tmp/zw-managed-file-app-'));
const [data, rpc, zdot, workspace, cwd, remote] = ['data', 'rpc', 'zdot', 'Project', 'cwd', 'ssh-peer'].map(name => join(root, name));
for (const dir of [out, data, rpc, zdot, workspace, cwd, remote]) await mkdir(dir, { recursive: true });

const initial = 'port=8080\n';
const edited = 'port=9090\n';
const outsideText = 'created with an explicit absolute path\n';
const target = join(workspace, 'config.txt');
const cwdTwin = join(cwd, 'config.txt');
const remoteTwin = join(remote, 'config.txt');
const alias = join(cwd, 'project-config.txt');
const staleName = 'relative-denied.txt';
const absolute = join(cwd, 'approved-directory', 'nested', 'absolute.txt');
const rejected = join(cwd, 'rejected.txt');
const auto = join(cwd, 'auto.txt');
const attachedTarget = join(workspace, 'remote-context-proof.txt');
const attachedText = 'host workspace from a remote connection context\n';
const external = 'modified by the fixture after the app stopped\n';
await writeFile(target, initial);
await writeFile(cwdTwin, 'unrelated Local cwd file\n');
await writeFile(remoteTwin, 'unrelated SSH file\n');
await symlink(target, alias);
await writeFile(join(zdot, '.zshrc'), `bindkey -e\ncd -- '${cwd}'\nPS1='managed-file-fixture%# '\n`);

const conversation = randomBytes(16).toString('hex');
const agent = randomBytes(16).toString('hex');
const identity = await stat(workspace);
const journalPath = join(data, 'ai-sessions.jsonl');
const lifecyclePath = join(data, 'ai', 'lifecycle.json');
const baseline = [
  { schema: 1, event: { kind: 'create', conversation, agent, owner: group ? { group: 1 } : { session: 1 }, revision: 2 } },
  { schema: 4, event: {
    kind: 'workspace_update', conversation, agent, revision: 2,
    workspace: { revision: 2, availability: 'ready', directory: workspace, resolved_directory: workspace, directory_identity: { device: identity.dev, inode: identity.ino } },
    workspace_change: { before_revision: 1, reason: 'set' },
  } },
  { schema: 1, event: { kind: 'checkpoint', conversation, agent, revision: 2, turn: 1 },
    messages: [{ role: 'user', content: 'Fixture checkpoint' }, { role: 'assistant', content: 'Ready' }] },
];
await writeFile(journalPath, baseline.map(row => JSON.stringify(row)).join('\n') + '\n');

const wire = (name: string) => ['run_command', 'read_remote_file'].includes(name) ? name : name.replaceAll('_', '_u').replaceAll('.', '__');
const projectCheckPrompt = '在当前项目目录运行本地验证，并按审批修改配置';
const supportedAttachedPrompt = 'MANAGED_WRITE_ATTACHED';
const unsupportedPrompt = 'MANAGED_WORKSPACE_UNSUPPORTED';
const groupPrompts = {
  filesOnly: 'GROUP_WITHOUT_TERMINAL',
  mixed: 'GROUP_WITH_LOCAL_TERMINAL',
  pending: 'GROUP_WRITE_AWAITING_MEMBERSHIP',
  removed: 'GROUP_TERMINAL_REMOVED',
  restored: 'GROUP_TERMINAL_RESTORED',
};
const allPrompts = [projectCheckPrompt, 'MANAGED_WRITE_AUTO', 'MANAGED_WRITE_REOPEN', supportedAttachedPrompt, unsupportedPrompt, ...Object.values(groupPrompts)];
const hostFileTools = [
  'host.local_list_files', 'host.local_search_text', 'host.local_read_text',
  'host.local_write_text', 'host.local_edit_text', 'host.local_get_changes',
];
const terminalFileTools = ['file.read_text', 'file.write_text', 'file.edit_text'];
const projectCheckCommand = `(cd -- '${workspace}' && printf '%s\\n' "$PWD" && cat config.txt)`;
const frame = (delta: object, finish_reason?: string) => 'data: ' + JSON.stringify({ choices: [{ index: 0, delta, finish_reason }] }) + '\n\n';
const done = 'data: [DONE]\n\n';
type Call = [string, string, object];
function emit(res: ServerResponse, ...items: Call[]) {
  return res.end(frame({ tool_calls: items.map(([id, name, args], index) => ({
    index, id, type: 'function', function: { name: wire(name), arguments: JSON.stringify(args) },
  })) }, 'tool_calls') + done);
}

function parseResult(content: string) {
  const envelope = JSON.parse(content);
  const targetResult = envelope.targets ? envelope.targets[0] : envelope;
  if (envelope.targets) assert.equal(envelope.targets.length, 1);
  for (const block of targetResult.content ?? []) {
    if (block.type === 'structured') return { envelope: targetResult, body: JSON.parse(block.text) };
    if (block.type === 'text') {
      try {
        return { envelope: targetResult, body: JSON.parse(block.text) };
      } catch {}
    }
  }
  return { envelope: targetResult, body: targetResult };
}

type Result = ReturnType<typeof parseResult>;
function succeeded(result: Result) {
  assert.equal(result.envelope.status, 'succeeded', JSON.stringify(result));
  return result.body;
}
function refused(result: Result, reason?: string) {
  if (reason) assert(JSON.stringify(result).includes(reason), JSON.stringify(result));
  assert.notEqual(result.envelope.status, 'succeeded', JSON.stringify(result));
  assert.equal(result.body.committed ?? false, false);
  assert.equal(result.body.side_effect_started ?? result.envelope.side_effect_started ?? result.envelope.receipt?.side_effect_started ?? false, false);
}
async function unchanged(path: string, expected?: string) {
  if (expected === undefined) await assert.rejects(stat(path), { code: 'ENOENT' });
  else assert.equal(await readFile(path, 'utf8'), expected);
}

const requests: any[] = [];
const observed: Record<string, Result> = {};
const report: any = { status: 'running', transport: group ? 'mixed loopback SFTP and Local group' : ssh ? 'loopback SSH' : sftp ? 'loopback SFTP' : kvm ? 'offline loopback KVM' : 'Local', checks: [], approvals: [], out };
let fixtureFailure: unknown = null;
let firstVersion: string | null = null;
let verifiedOperation: string | null = null;
let committedInode: number | null = null;
let terminalIds: number[] = [];
let durableReference: string | null = null;
let staleReference: string | null = null;
let groupMembershipLost = false;
const pendingGroupWriteKey = 'group-write-awaiting-membership';
const sftpReadPath = '/fixture/README.md';

async function replyLocal(res: ServerResponse, messages: any[], results: Map<string, Result>, ids: number[]) {
  const lastTask = messages.findLast(message => message.role === 'user' && [projectCheckPrompt, 'MANAGED_WRITE_AUTO', 'MANAGED_WRITE_REOPEN'].includes(message.content))?.content;
  if (lastTask === 'MANAGED_WRITE_REOPEN') {
    if (!results.has('reopen-history')) return emit(res,
      ['reopen-history', 'host.local_get_changes', { operation_ref: verifiedOperation, verify: true }],
      ['reopen-reference', 'host.local_read_text', { file_ref: durableReference }],
      ['reopen-stale-reference', 'host.local_read_text', { file_ref: staleReference }]);
    const history = succeeded(results.get('reopen-history')!);
    assert.equal(history.operation_ref, verifiedOperation);
    assert.equal(history.target, target);
    assert.equal(history.verified, true, 'A later external edit must not erase the verified historical commit');
    assert.equal(history.observation.matches_submitted_candidate, false);
    assert.notEqual(history.observation.current_version, history.submitted_after_version);
    const reread = succeeded(results.get('reopen-reference')!);
    assert.equal(reread.path, target);
    assert.equal(reread.text, external);
    refused(results.get('reopen-stale-reference')!, 'SourceChanged');
    return res.end(frame({ content: 'MANAGED_WRITE_REOPEN_DONE' }, 'stop') + done);
  }
  if (lastTask === 'MANAGED_WRITE_AUTO') {
    if (!results.has('auto-stale')) return emit(res,
      ['auto-stale', 'host.local_write_text', { path: target, mode: 'replace', text: 'must never replace\n', expected_version: firstVersion, request_key: 'auto-stale' }],
      ['auto-create', 'host.local_write_text', { path: auto, mode: 'create', text: 'written in auto mode\n', request_key: 'auto-create' }]);
    refused(results.get('auto-stale')!, 'SourceChanged');
    assert.equal(succeeded(results.get('auto-create')!).verified, true);
    if (!results.has('persist-ref')) return emit(res,
      ['persist-ref', 'host.local_read_text', { path: target }],
      ['stale-ref', 'host.local_read_text', { path: auto }]);
    durableReference = succeeded(results.get('persist-ref')!).file_ref;
    staleReference = succeeded(results.get('stale-ref')!).file_ref;
    assert.equal(typeof durableReference, 'string');
    assert.equal(typeof staleReference, 'string');
    return res.end(frame({ content: 'MANAGED_WRITE_AUTO_DONE' }, 'stop') + done);
  }

  assert.equal(lastTask, projectCheckPrompt);
  const execution = results.get('project-execution');
  if (!execution) return emit(res, ['project-execution', 'run_command', { session_ids: ids, command: projectCheckCommand }]);
  const batch = succeeded(execution);
  assert.equal(batch.session_id, ids[0]);
  assert.equal(batch.transport, 'local');
  assert.equal(batch.cwd, cwd);
  assert.equal(batch.exit, 0);
  assert.equal(batch.stdout, workspace + '\n' + initial);
  if (!results.has('host-read')) return emit(res,
    ['host-read', 'host.local_read_text', { path: 'config.txt' }],
    ['local-read', 'file.read_text', { path: 'config.txt', session_ids: ids }],
    ['local-alias-read', 'file.read_text', { path: alias, session_ids: ids }]);
  const hostRead = succeeded(results.get('host-read')!);
  assert.equal(hostRead.path, target);
  assert.equal(hostRead.text, initial);
  assert.match(hostRead.version, /^zw1:[0-9a-f]{64}$/);
  for (const read of ['local-read', 'local-alias-read']) {
    const value = succeeded(results.get(read)!);
    assert.equal(value.path, target);
    assert.equal(value.version, hostRead.version);
    assert.equal(value.text, initial);
  }
  firstVersion = hostRead.version;
  const editArgs = { path: 'config.txt', edits: [{ old_text: initial.trimEnd(), new_text: edited.trimEnd() }], expected_version: firstVersion, request_key: 'shared-edit' };
  if (!results.has('local-edit')) return emit(res, ['local-edit', 'file.edit_text', { ...editArgs, session_ids: ids }]);
  const localEdit = succeeded(results.get('local-edit')!);
  assert.equal(localEdit.verified, true);
  assert.equal(localEdit.committed, true);
  assert.equal(localEdit.target, target);
  assert.equal(typeof localEdit.operation_ref, 'string');
  verifiedOperation = localEdit.operation_ref;
  if (!results.has('host-replay')) {
    committedInode = (await stat(target)).ino;
    return emit(res,
      ['host-replay', 'host.local_edit_text', editArgs],
      ['conflicting-replay', 'host.local_edit_text', { ...editArgs, edits: [{ old_text: initial.trimEnd(), new_text: 'port=1111' }] }]);
  }
  const replay = succeeded(results.get('host-replay')!);
  assert.equal(replay.operation_ref, verifiedOperation);
  assert.equal(replay.verified, true);
  assert.equal((await stat(target)).ino, committedInode, 'Replay must not replace the file a second time');
  refused(results.get('conflicting-replay')!, 'IdempotencyConflict');
  if (!results.has('rejected')) return emit(res,
    ['rejected', 'host.local_write_text', { path: rejected, mode: 'create', text: 'rejected by the human\n', request_key: 'human-rejected' }]);
  refused(results.get('rejected')!);
  if (!results.has('stale-relative')) return emit(res,
    ['stale-relative', 'host.local_write_text', { path: staleName, mode: 'create', text: 'must not be created\n', request_key: 'stale-relative' }],
    ['fixed-absolute', 'host.local_write_text', { path: absolute, mode: 'create', text: outsideText, create_parents: true, request_key: 'fixed-absolute' }]);
  refused(results.get('stale-relative')!, 'WorkspaceChanged');
  const created = succeeded(results.get('fixed-absolute')!);
  assert.equal(created.target, absolute);
  assert.equal(created.verified, true);
  assert.deepEqual(created.created_parents, [join(cwd, 'approved-directory'), join(cwd, 'approved-directory', 'nested')]);
  const notice = messages.filter(message => message.role === 'user' && String(message.content).includes('"kind":"local_workspace_changed"')).at(-1);
  assert.equal(JSON.parse(notice.content).local_workspace.state, 'none');
  if (!results.has('verify-history')) return emit(res,
    ['verify-history', 'host.local_get_changes', { operation_ref: verifiedOperation, verify: true }]);
  const verified = succeeded(results.get('verify-history')!);
  assert.equal(verified.coverage, 'managed_local_file_tools');
  assert.equal(verified.operation_ref, verifiedOperation);
  assert.equal(verified.target, target);
  assert.equal(verified.verified, true);
  assert.equal(verified.observation.matches_submitted_candidate, true);
  return res.end(frame({ content: 'MANAGED_WRITE_CONFIRM_DONE' }, 'stop') + done);
}

function replyAttached(res: ServerResponse, results: Map<string, Result>, ids: number[]) {
  if (!results.has('attached-host-read')) return emit(res,
    ['attached-host-read', 'host.local_read_text', { path: 'config.txt' }],
    ['ssh-terminal-read', 'file.read_text', { path: remoteTwin, session_ids: ids }]);
  const localRead = succeeded(results.get('attached-host-read')!);
  assert.equal(localRead.path, target);
  assert.equal(localRead.text, initial);
  assert.match(localRead.version, /^zw1:[0-9a-f]{64}$/);
  const sshRead = succeeded(results.get('ssh-terminal-read')!);
  assert.equal(sshRead.text, 'unrelated SSH file\n');
  assert.match(sshRead.version, /^[0-9a-f]{64}$/);
  if (!results.has('attached-host-write')) return emit(res,
    ['attached-host-write', 'host.local_write_text', { path: 'remote-context-proof.txt', mode: 'create', text: attachedText, request_key: 'attached-host-write' }]);
  const written = succeeded(results.get('attached-host-write')!);
  assert.equal(written.verified, true);
  assert.equal(written.target, attachedTarget);
  return res.end(frame({ content: 'MANAGED_WRITE_ATTACHED_DONE' }, 'stop') + done);
}

function replyUnsupported(res: ServerResponse, results: Map<string, Result>, prompt: string) {
  const context = prompt + '-context';
  const read = prompt + '-relative-read';
  const write = prompt + '-absolute-write';
  if (!results.has(context)) return emit(res,
    [context, 'host.get_current_context', {}],
    [read, 'host.local_read_text', { path: 'config.txt' }],
    [write, 'host.local_write_text', {
      path: attachedTarget, mode: 'create', text: attachedText, request_key: write,
    }]);
  const current = succeeded(results.get(context)!);
  if (group) assert.deepEqual(current.current_binding, { group: 1 });
  assert.equal(current.local_workspace ?? null, null, 'Host metadata must omit the stored workspace');
  refused(results.get(read)!, 'ToolNotInRequest');
  refused(results.get(write)!, 'ToolNotInRequest');
  return res.end(frame({ content: prompt + '_DONE' }, 'stop') + done);
}

function replyMixedGroup(res: ServerResponse, results: Map<string, Result>, prompt: string) {
  const context = prompt + '-context';
  const read = prompt + '-host-read';
  if (!results.has(context)) return emit(res,
    [context, 'host.get_current_context', {}],
    [read, 'host.local_read_text', { path: 'config.txt' }]);
  const current = succeeded(results.get(context)!);
  assert.deepEqual(current.current_binding, { group: 1 });
  assert.equal(current.local_workspace.directory, workspace);
  assert.equal(current.local_workspace.revision, 2);
  const localRead = succeeded(results.get(read)!);
  assert.equal(localRead.path, target);
  assert.equal(localRead.text, initial);
  return res.end(frame({ content: prompt + '_DONE' }, 'stop') + done);
}

function replyPendingGroupWrite(res: ServerResponse, results: Map<string, Result>, sftpTarget: number) {
  if (!results.has(pendingGroupWriteKey)) return emit(res,
    [pendingGroupWriteKey, 'host.local_write_text', {
      path: attachedTarget, mode: 'create', text: attachedText, request_key: pendingGroupWriteKey,
    }]);
  refused(results.get(pendingGroupWriteKey)!);
  assert(groupMembershipLost, 'The write must stay pending while the terminal is a member');
  if (!results.has('group-sftp-read-after-revocation')) return emit(res,
    ['group-sftp-read-after-revocation', 'read_remote_file', { path: sftpReadPath, session_ids: [sftpTarget] }]);
  const read = succeeded(results.get('group-sftp-read-after-revocation')!);
  assert.equal(read.transport, 'sftp');
  assert.equal(read.stdout, '# remote markdown\n');
  return res.end(frame({ content: groupPrompts.pending + '_DONE' }, 'stop') + done);
}

const server = createServer(async (req, res) => {
  if (req.method !== 'POST') return res.end('{"data":[{"id":"managed-file-fixture"}]}');
  try {
    let raw = '';
    for await (const part of req) raw += part;
    const body = JSON.parse(raw);
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    if (!body.tools?.length) return res.end(frame({ content: 'Managed file acceptance' }, 'stop') + done);
    requests.push(body);
    const definitions = new Map<string, any>(body.tools.map((tool: any) => [tool.function.name, tool.function]));
    const promptIndex = body.messages.findLastIndex((message: any) => message.role === 'user' && allPrompts.includes(message.content));
    assert(promptIndex >= 0, 'Expected a fixture prompt');
    const prompt = body.messages[promptIndex].content;
    const currentMessages = body.messages.slice(promptIndex + 1);
    const workspaceAvailable = group
      ? [groupPrompts.mixed, groupPrompts.restored].includes(prompt) || (prompt === groupPrompts.pending && !groupMembershipLost)
      : !unsupported;
    const system = body.messages.filter((message: any) => message.role === 'system').map((message: any) => message.content).join(' ');
    if (!workspaceAvailable) {
      for (const name of [...hostFileTools, ...terminalFileTools]) {
        assert(!definitions.has(wire(name)), `Unexpected tool ${name}`);
      }
      assert(!system.includes('local_workspace'), 'An unsupported connection must omit the workspace system snapshot');
      assert(!system.includes(workspace), 'The stored directory must stay outside the system prompt');
      assert(!currentMessages.some((message: any) => message.role === 'user' && String(message.content).includes(workspace)));
      if (!group) assert(!body.messages.some((message: any) => message.role === 'user' && String(message.content).includes('"kind":"local_workspace_changed"')));
    } else if (requests.length === 1 || group) {
      for (const name of [...hostFileTools, ...terminalFileTools]) {
        assert(definitions.has(wire(name)), `Missing tool ${name}`);
      }
      const ids = definitions.get(wire('file.read_text')).parameters.properties.session_ids.items.enum;
      assert(Array.isArray(ids) && ids.length === 1, 'The terminal must offer exactly one authorized target');
      for (const name of ['file.write_text', 'file.edit_text']) {
        const required = definitions.get(wire(name)).parameters.required;
        assert.equal(required.includes('request_key'), !ssh, `Unexpected request_key contract for ${name}`);
      }
      terminalIds = ids;
    }
    if (prompt === projectCheckPrompt && !currentMessages.some((message: any) => message.role === 'tool')) {
      assert(definitions.has(wire('run_command')), 'The Local batch route must be available');
      assert(system.includes('explicitly use the workspace directory for that execution'));
      assert(system.includes(workspace));
    }
    if (group && workspaceAvailable) assert(system.includes(workspace), 'Eligible group requests must carry the saved directory');
    const results = new Map<string, Result>(currentMessages.filter((message: any) => message.role === 'tool')
      .map((message: any) => [message.tool_call_id, parseResult(message.content)]));
    for (const [id, result] of results) observed[id] = result;
    if (prompt === groupPrompts.pending) {
      const ids = definitions.get(wire('read_remote_file'))?.parameters.properties.session_ids.items.enum;
      assert(Array.isArray(ids) && ids.length === 1, 'The SFTP service must remain available');
      return replyPendingGroupWrite(res, results, ids[0]);
    }
    if (!workspaceAvailable) return replyUnsupported(res, results, prompt);
    if (group) return replyMixedGroup(res, results, prompt);
    if (ssh) return replyAttached(res, results, terminalIds);
    return await replyLocal(res, body.messages, results, terminalIds);
  } catch (error) {
    fixtureFailure = error;
    if (!res.headersSent) res.writeHead(500);
    res.end();
  }
});

await new Promise<void>(ready => server.listen(0, '127.0.0.1', ready));
const address = server.address();
assert(address && typeof address !== 'string');
await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ssh]\nauto_shell_integration=false\n[ai]\ndefault_provider="managed-file"\npermission_mode="confirm"\nexecution_mode="isolated_exec"\nstep_display="expanded"\n[[ai.providers]]\nid="managed-file"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${address.port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="managed-file-fixture"\ncontext_window=200000\ndefault=true\n`);

process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const log = await open(join(out, 'app.log'), 'w');
const binary = join(prefix, 'bin', 'zerowork');
report.binary_sha256 = createHash('sha256').update(await readFile(binary)).digest('hex');
let peer: ReturnType<typeof spawn> | undefined;
let peerLog: Awaited<ReturnType<typeof open>> | undefined;
const peerOutput = join(root, 'peer-output');
let peerFingerprint: string | undefined;
let app: ReturnType<typeof spawn> | undefined;
let ended: Promise<void> | undefined;

const alive = () => app?.exitCode === null && app.signalCode === null;
const shown = (n: any) => n && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const flatten = (nodes: any): any[] => Array.isArray(nodes) ? nodes.flatMap(flatten) : nodes ? [nodes, ...(nodes.children ?? []).flatMap(flatten)] : [];
const text = (nodes: any) => flatten(nodes).map(node => node.text ?? '').join(' ');
const visible = (id: string) => h.waitFor(async () => {
  if (fixtureFailure) throw fixtureFailure;
  return (await h.query(id)).find(shown) ?? null;
}, 15000);
const click = async (id: string) => {
  report.last_action = id;
  await visible(id);
  assert((await h.clickTestId(id)).ok, id);
};
const approval = async (path: string) => h.waitFor(async () => {
  if (fixtureFailure) throw fixtureFailure;
  return (await h.query('ai.interaction.target')).find((node: any) => shown(node) && node.text === path) ?? null;
}, 20000);
const submit = async (prompt: string) => {
  await click('ai.prompt');
  await h.type_(prompt);
  await click('ai.send');
};
const completed = async (marker: string) => h.waitFor(async () => {
  if (fixtureFailure) throw fixtureFailure;
  return text(await h.query('ai.panel')).includes(marker) && !(await h.query('ai.stop')).some(shown) || null;
}, 20000);
const capture = async (name: string) => {
  assert((await h.screenshot(join(out, name + '.png'))).ok);
  await writeFile(join(out, name + '.json'), JSON.stringify(await h.query('ai.panel'), null, 2));
};
async function approve(path: string, label: string, pendingBytes?: string) {
  await approval(path);
  await unchanged(path, pendingBytes);
  await capture(label);
  report.approvals.push({ path, decision: 'approve' });
  await click('ai.interaction.approve');
}

async function verifyChangeCard(path: string, expectedSummary: string) {
  const findCard = async () => {
    const panel = flatten(await h.query('ai.panel'));
    const card = panel.find(node => node.test_id?.startsWith('ai.tool.result.') &&
      flatten(node).some(child => child.test_id === 'ai.step.header' && shown(child) && text(child).includes(expectedSummary)));
    return card ?? null;
  };
  const card = await h.waitFor(findCard, 12000);
  const header = flatten(card).find(node => node.test_id === 'ai.step.header' && shown(node));
  assert(header);
  assert((await h.clickAt(header.rect.x + header.rect.w / 2, header.rect.y + header.rect.h / 2)).ok);
  return h.waitFor(async () => {
    const details = flatten(await findCard()).filter(shown);
    return details.some(node => node.test_id === 'ai.workspace.change.path' && node.text === path) ? details : null;
  }, 10000);
}

async function launchApp() {
  app = spawn(binary, [], { env: {
    ...process.env, ZEROWORK_DATA_DIR: data, ZDOTDIR: zdot, ZEROWORK_AUTOCONNECT: '0',
    ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: '',
  }, stdio: ['ignore', log.fd, log.fd] });
  ended = new Promise(resolve => app!.once('close', () => resolve()));
  await h.waitForServerReady(60000);
  assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
  await h.resizeWindow(1440, 1000);
}
async function quitApp() {
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
  assert(!alive(), 'Application did not quit through its normal window lifecycle');
  assert.equal(app!.exitCode, 0);
}
async function ensureGroupPanel() {
  if (!(await h.query('ai.prompt')).some(shown)) await click('toolbar.ai');
  await visible('ai.prompt');
}

async function restoreConversation() {
  if (group) await ensureGroupPanel();
  else await click(unsupported ? 'toolbar.ai' : 'ai.strip');
  await click('ai.sessions');
  await click('ai.session.restore.1');
  await visible('ai.prompt');
}
async function assertWorkspaceUI(available: boolean, evidence: string) {
  if (available) assert.equal((await visible('ai.workspace.name')).text, 'Project');
  else await h.waitFor(async () => !(await h.query('ai.workspace.name')).some(shown) || null, 15000);
  await clickNode(await visible('ai.composer.attachment'));
  await visible('ai.attachment.image');
  assert.equal((await h.query('ai.attachment.workspace')).some(shown), available);
  await capture(evidence);
  await h.key('escape');
  await h.waitFor(async () => !(await h.query('ai.attachment.image')).some(shown) || null, 15000);
}

async function assertSavedWorkspace() {
  const updates = (await readFile(journalPath, 'utf8')).trim().split('\n')
    .map(row => JSON.parse(row).event).filter(event => event?.kind === 'workspace_update');
  assert.deepEqual(updates, [baseline[1].event], 'Membership changes must preserve the saved preference');
}

async function clickNode(node: any) {
  assert(shown(node));
  assert((await h.clickAt(node.rect.x + node.rect.w / 2, node.rect.y + node.rect.h / 2)).ok);
}

async function collapseGroupPanel() {
  const control = (await h.query('ai.collapse')).find(shown);
  if (!control) return;
  await clickNode(control);
  await h.waitFor(async () => !(await h.query('ai.prompt')).some(shown) || null, 15000);
}

async function navigateSftpLocalPane() {
  const pane = await visible('files.local');
  await clickNode(flatten(pane).find(node => node.test_id === 'files.path.edit' && shown(node)));
  const input = flatten(await visible('files.local')).find(node => node.test_id === 'files.path' && shown(node));
  await clickNode(input);
  await h.key('a', { cmd: true });
  await h.type_(cwd);
  await h.key('return');
  await h.waitFor(async () => text(await h.query('files.local')).includes('project-config.txt') || null, 15000);
}

async function tabFor(title: string) {
  return h.waitFor(async () => flatten(await h.query('tabs.strip')).find(node =>
    shown(node) && /^tabs\.tab\.\d+$/.test(node.test_id ?? '') && text(node).includes(title)) ?? null, 15000);
}

async function paneFor(title: string) {
  return h.waitFor(async () => flatten(await h.query('groups.workspace')).find(node =>
    shown(node) && /^groups\.pane\.\d+$/.test(node.test_id ?? '') && text(node).includes(title)) ?? null, 15000);
}

async function joinGroup(title: string, existing: boolean) {
  await clickNode(await tabFor(title));
  await h.waitFor(async () => !(await h.query('groups.workspace')).some(shown) || null, 15000);
  const tab = await tabFor(title);
  const x = tab.rect.x + tab.rect.w / 2;
  const y = tab.rect.y + tab.rect.h / 2;
  assert((await h.request('POST', '/mouse_down', { x, y, button: 'right' })).ok);
  assert((await h.request('POST', '/mouse_up', { x, y, button: 'right' })).ok);
  await click('context.menu.join_session_group');
  await visible('groups.join.dialog');
  if (existing) await click('groups.join.existing');
  else {
    await click('groups.join.name');
    await h.type_('Workspace scope fixture');
    await click('groups.join.accept');
  }
  await visible('groups.workspace');
  await h.waitFor(async () => !(await h.query('groups.join.dialog')).some(shown) || null, 10000);
  await paneFor(title);
}

async function selectSftpPane() {
  const pane = await paneFor('Managed file loopback fixture');
  await clickNode(flatten(pane).find(node => node.test_id === 'groups.pane.title' && shown(node)));
  await h.sleep(280);
}

async function checkGroupStage(prompt: string, available: boolean) {
  await selectSftpPane();
  await ensureGroupPanel();
  await assertWorkspaceUI(available, prompt.toLowerCase());
  await submit(prompt);
  await completed(prompt + '_DONE');
}

try {
  if (kvm) {
    const payload = { endpoint: { host: '127.0.0.1', https_port: 1 }, username: 'fixture', display: { scale: 'fit', read_only_requested: true } };
    await writeFile(join(data, 'hosts.toml'), `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="bmc_ikvm"\nname="Managed file KVM fixture"\npayload=${JSON.stringify(JSON.stringify(payload))}\n`);
  } else if (attached) {
    peerLog = await open(join(out, protocol + '-peer.log'), 'w');
    const peerArgs = ssh ? ['e2e/terminal_files_ssh_peer.py', '--out', peerOutput, '--root', remote]
      : ['e2e/sftp_v3_peer.py', '--out', peerOutput];
    peer = spawn(process.env.ZW_TEST_PYTHON ?? 'python3', peerArgs, { stdio: ['ignore', peerLog.fd, peerLog.fd] });
    const ready = await h.waitFor(async () => {
      if (peer!.exitCode !== null) throw new Error('Owned peer exited before initialization');
      try { return JSON.parse(await readFile(join(peerOutput, 'ready.json'), 'utf8')); } catch { return null; }
    }, 15000);
    if (ssh) await writeFile(join(data, 'known_hosts'), ready.known_host);
    else peerFingerprint = ready.fingerprint;
    await writeFile(join(data, 'hosts.toml'), `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="${protocol}"\nauth_mode="password"\nname="Managed file loopback fixture"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\noptions={strict_host_key=true}\n`);
  }

  await launchApp();
  if (ssh) {
    await click('sidebar.host');
    await click('sidebar.host.connect');
    await visible('terminal.surface');
    await h.sleep(1500);
  } else if (sftp) {
    await click('sidebar.host');
    await click('sidebar.host.connect');
    await h.waitFor(async () => {
      if ((await h.query('files.workspace')).some(shown)) return true;
      const plugin = (await h.query('plugin.challenge.title')).find(shown);
      if (plugin) {
        assert(text(await visible('plugin.challenge.material')).includes(peerFingerprint!));
        await click('plugin.challenge.choice.0');
      }
      const modal = (await h.query('auth.challenge.modal')).find(shown);
      const trust = modal && flatten(modal).find(node => node.test_id === 'auth.challenge.trust_once');
      if (trust?.focusable) {
        assert(text(modal).includes(peerFingerprint!));
        await click('auth.challenge.trust_once');
      }
      return null;
    }, 20000);
    await navigateSftpLocalPane();
  } else if (kvm) {
    const row = await visible('sidebar.host');
    assert((await h.clickAt(row.rect.x + 65, row.rect.y + row.rect.h / 2)).ok);
    await h.key('return');
    await visible('bmc.content');
    assert(!(await h.query('terminal.surface')).some(shown));
  } else {
    await click('workspace.empty.local');
    await visible('terminal.surface');
  }
  if (group) await joinGroup('Managed file loopback fixture', false);
  await restoreConversation();
  assert.equal(requests.length, 0);

  if (group) {
    await checkGroupStage(groupPrompts.filesOnly, false);
    await collapseGroupPanel();
    await click('toolbar.new_session');
    await click('session.menu.local');
    await visible('terminal.surface');
    await joinGroup('Local Terminal', true);
    await checkGroupStage(groupPrompts.mixed, true);

    await submit(groupPrompts.pending);
    await approval(attachedTarget);
    await unchanged(attachedTarget);
    await capture('group-write-pending-approval');
    await collapseGroupPanel();
    const localPane = await paneFor('Local Terminal');
    await click('groups.menu.' + localPane.test_id.split('.').at(-1));
    const menu = await visible('groups.member_menu');
    groupMembershipLost = true;
    await clickNode(flatten(menu).find(node => node.text === '移出组，保留会话' && shown(node)));
    await h.waitFor(async () => !(await h.query(localPane.test_id)).some(shown) || null, 15000);
    await tabFor('Local Terminal');
    await ensureGroupPanel();
    await completed(groupPrompts.pending + '_DONE');
    assert(!(await h.query('ai.interaction.approve')).some(shown));
    await unchanged(attachedTarget);
    const peerAudit = JSON.parse(await readFile(join(peerOutput, 'state.json'), 'utf8'));
    assert(peerAudit.calls.some((call: any) => call.op === 'READ' && call.path === sftpReadPath));
    assert(!peerAudit.calls.some((call: any) => ['WRITE', 'REMOVE', 'RENAME', 'TRUNCATE'].includes(call.op)));
    report.peer_audit = peerAudit;
    report.checks.push('Removing the last Local member revokes a pending absolute host write before dispatch. A new read in the same task still returns bytes from the same real SFTP peer.');
    await checkGroupStage(groupPrompts.removed, false);
    await collapseGroupPanel();
    await joinGroup('Local Terminal', true);
    await checkGroupStage(groupPrompts.restored, true);
    await assertSavedWorkspace();
    await unchanged(target, initial);
    await unchanged(attachedTarget);
    report.checks.push('A real SFTP-only group stays ineligible even with a saved directory and an unrelated open Local terminal. While its SFTP pane is selected, adding the Local member enables the same group directory; removing and rejoining that terminal disables and restores it without rewriting the preference.');
  } else if (unsupported) {
    await assertWorkspaceUI(false, 'unsupported-attachment-menu');
    await submit(unsupportedPrompt);
    await completed(unsupportedPrompt + '_DONE');
    assert(!(await h.query('ai.interaction.approve')).some(shown));
    await unchanged(target, initial);
    await unchanged(attachedTarget);
    await assertSavedWorkspace();
    if (sftp) {
      const audit = JSON.parse(await readFile(join(peerOutput, 'state.json'), 'utf8'));
      assert(audit.calls.some((call: any) => call.op === 'LIST'), 'File workspace must perform a real remote directory listing');
      assert(!audit.calls.some((call: any) => ['WRITE', 'REMOVE', 'RENAME', 'TRUNCATE'].includes(call.op)));
      assert.equal(audit.files['/fixture/remote-context-proof.txt'], undefined);
      report.peer_audit = audit;
    } else {
      assert(!(await h.query('terminal.surface')).some(shown));
    }
    report.checks.push('A saved directory in an independent non-terminal session is hidden in the header, attachment menu and Provider snapshot. The catalog omits the file tools, unsolicited calls cannot dispatch, and the saved directory stays on disk.');
  } else if (ssh) {
    assert.equal((await visible('ai.workspace.name')).text, 'Project');
    await submit(supportedAttachedPrompt);
    await approve(attachedTarget, 'attached-host-write-approval');
    await completed(supportedAttachedPrompt + '_DONE');
    await unchanged(attachedTarget, attachedText);
    await unchanged(remoteTwin, 'unrelated SSH file\n');
    await unchanged(join(remote, 'remote-context-proof.txt'));
    const audit = JSON.parse(await readFile(join(peerOutput, 'audit.json'), 'utf8'));
    assert.equal(audit.exec_reads, 1);
    assert.equal(audit.exec_writes, 0);
    assert.equal(audit.sftp_requests, 0);
    assert.equal(audit.shell_input_bytes, 0);
    assert.deepEqual(audit.errors, []);
    report.peer_audit = audit;
    report.checks.push('With only a real SSH tab open, host read/write use the local workspace and terminal reads use the authorized SSH service. The peer sees only the SSH read.');
  } else {
    assert.equal((await visible('ai.workspace.name')).text, 'Project');
    await submit(projectCheckPrompt);
    await visible('ai.interaction.approve');
    assert(text(await h.query('ai.interaction.command')).includes(projectCheckCommand));
    await click('ai.interaction.approve');
    await approval(target);
    const summary = text(await h.query('ai.interaction.command'));
    assert.match(summary, /[−-]1\s+port=8080/);
    assert.match(summary, /\+1\s+port=9090/);
    await approve(target, 'local-edit-approval', initial);

    await approval(rejected);
    await unchanged(target, edited);
    await unchanged(rejected);
    report.approvals.push({ path: rejected, decision: 'reject' });
    await click('ai.interaction.reject');

    const stalePath = join(workspace, staleName);
    await approval(stalePath);
    await unchanged(stalePath);
    await click('ai.workspace');
    await click('ai.workspace.remove');
    await approval(absolute);
    await unchanged(stalePath);
    await unchanged(join(cwd, staleName));
    await unchanged(join(cwd, 'approved-directory'));
    const parentPreview = (await visible('ai.interaction.command')).text.split('\n');
    assert(parentPreview.includes(join(cwd, 'approved-directory')));
    assert(parentPreview.includes(join(cwd, 'approved-directory', 'nested')));
    await approve(absolute, 'absolute-after-workspace-removal');
    await completed('MANAGED_WRITE_CONFIRM_DONE');
    await unchanged(absolute, outsideText);
    await unchanged(cwdTwin, 'unrelated Local cwd file\n');
    await unchanged(rejected);
    await click('ai.maximize');
    await click('ai.turn.process.toggle');
    const verifiedCard = await verifyChangeCard(absolute, 'absolute.txt · +1 −0');
    assert(verifiedCard.some(node => node.test_id === 'ai.workspace.change.add' && text(node).includes(outsideText.trimEnd())));
    await h.sleep(240);
    await capture('verified-file-diff');
    const rejectedCard = await verifyChangeCard(rejected, 'rejected.txt · 未写入');
    assert(rejectedCard.some(node => node.test_id === 'ai.workspace.change.reason' && node.text === '审批已拒绝'));
    assert(!rejectedCard.some(node => ['ai.workspace.change.add', 'ai.workspace.change.remove'].includes(node.test_id)));
    await h.sleep(240);
    await capture('rejected-file-diff');

    await click('ai.composer.permission');
    await click('ai.permission.auto');
    await submit('MANAGED_WRITE_AUTO');
    await h.waitFor(async () => {
      assert(!(await h.query('ai.interaction.approve')).some(shown), 'Auto must not request a confirm dialog');
      if (fixtureFailure) throw fixtureFailure;
      return text(await h.query('ai.panel')).includes('MANAGED_WRITE_AUTO_DONE') && !(await h.query('ai.stop')).some(shown) || null;
    }, 20000);
    await unchanged(target, edited);
    await unchanged(auto, 'written in auto mode\n');

    const facts = JSON.parse(await readFile(lifecyclePath, 'utf8')).records;
    for (const key of ['shared-edit', 'human-rejected', 'stale-relative', 'fixed-absolute', 'auto-stale', 'auto-create']) {
      const matches = facts.filter((row: any) => row.request_key === key);
      assert.equal(matches.length, 1, `Expected one durable record for ${key}`);
      const committed = ['shared-edit', 'fixed-absolute', 'auto-create'].includes(key);
      assert.equal(matches[0].dispatch_started, committed, key);
      assert.equal(matches[0].local_file_result.committed, committed, key);
    }
    report.checks.push(
      'Approved Local batch validation ran in the explicit workspace directory and read its relative file, which differs from the Local terminal cwd file.',
      'Host read and Local terminal read return one content version through relative paths and a symlink.',
      'The native approval shows the resolved path and proposed edit before mutation. One Local commit is replayed through the host entry, and changed parameters collide.',
      'Human rejection and workspace removal revoke pending writes with no dispatch. The absolute create in the same batch remains independent and creates the approved directory chain.',
      'Native file cards show a verified diff and a rejected write, and the change query resolves the original operation.',
      'Auto mode commits a permitted create and rejects a stale replacement without prompting.',
    );

    await quitApp();
    report.first_app_exit = app!.exitCode;
    await writeFile(target, external);
    const replacement = join(cwd, 'replacement.tmp');
    await writeFile(replacement, 'replacement inode\n');
    await rename(replacement, auto);
    const beforeReopen = requests.length;
    await launchApp();
    await click('workspace.empty.local');
    await visible('terminal.surface');
    await restoreConversation();
    assert.equal(requests.length, beforeReopen, 'Restoring the conversation must not call the Provider');
    await submit('MANAGED_WRITE_REOPEN');
    await completed('MANAGED_WRITE_REOPEN_DONE');
    await unchanged(target, external);
    await unchanged(auto, 'replacement inode\n');
    const reopenedFacts = JSON.parse(await readFile(lifecyclePath, 'utf8')).records;
    assert.deepEqual(reopenedFacts, facts, 'Read-only verification must not rewrite the journal or replay any effects');
    report.checks.push('After normal Quit and process restart, the original operation verifies read-only, a stable reference resolves within the restored conversation, and a replaced inode rejects the old reference.');
  }
  const lifecycle = await readFile(lifecyclePath).catch(error => {
    if (unsupported && error.code === 'ENOENT') return null;
    throw error;
  });
  if (lifecycle) {
    if (unsupported) {
      const records = JSON.parse(lifecycle.toString()).records;
      assert(!records.some((row: any) => row.request_key?.endsWith('-absolute-write')));
      if (group) {
        const pendingWrite = records.find((row: any) => row.request_key === pendingGroupWriteKey);
        assert(pendingWrite, 'The original prepared write must retain a receipt');
        assert.equal(pendingWrite.dispatch_started, false);
        assert.equal(pendingWrite.local_file_result.committed, false);
      }
    }
    await writeFile(join(out, 'lifecycle.json'), lifecycle);
  }
  report.status = 'passed';
} catch (error) {
  report.status = 'failed';
  report.error = String(error);
  report.fixture_error = fixtureFailure ? String(fixtureFailure) : undefined;
  if (alive()) await capture('failure').catch(() => {});
} finally {
  try { await quitApp(); } catch (error) { report.quit_error = String(error); }
  if (alive()) {
    app!.kill('SIGTERM');
    await Promise.race([ended, h.sleep(3000)]);
    if (alive()) app!.kill('SIGKILL');
    await ended;
  }
  report.app_exit = app?.exitCode ?? null;
  if (report.app_exit !== 0) report.status = 'failed';
  if (peer && peer.exitCode === null && peer.signalCode === null) {
    const peerClosed = new Promise<void>(resolve => peer!.once('close', () => resolve()));
    peer.kill('SIGTERM');
    await Promise.race([peerClosed, h.sleep(3000)]);
    if (peer.exitCode === null && peer.signalCode === null) peer.kill('SIGKILL');
    await peerClosed;
  }
  await peerLog?.close();
  server.closeAllConnections();
  await new Promise<void>(closed => server.close(() => closed()));
  await log.close();
  await writeFile(join(out, 'requests.json'), JSON.stringify(requests, null, 2));
  report.results = observed;
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  await rm(root, { recursive: true, force: true });
  console.log(JSON.stringify({ status: report.status, transport: report.transport, error: report.error, app_exit: report.app_exit, out }));
  if (report.status !== 'passed') process.exitCode = 1;
}
