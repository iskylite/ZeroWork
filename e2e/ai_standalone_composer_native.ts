/** Click the standalone composer's real rendered controls. This uses an isolated
 * fixture profile, a background native window and an isolated loopback provider. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createServer } from 'node:http';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const folder = await realpath(await mkdtemp(join(tmpdir(), 'zw-standalone-composer-')));
const data = join(folder, 'data'), rpc = join(folder, 'rpc');
const checks: string[] = [];
const geometry: { menu: string; width: number; x: number; gap: number; composerWidth: number }[] = [];
let lastGeometry: { menu: string; popup: unknown; composer: unknown } | undefined;
let child: ReturnType<typeof spawn> | undefined;
let ended: Promise<unknown> | undefined;
let log = '', step = 'start', turns = 0, expected: 'batch' | 'terminal' | 'none' | undefined;
let providerProblem = '', lastTool = '', counter = 0, chatRequests = 0;
const receipts: string[] = [];
const wire = (name: string) => name === 'run_command' ? name : name.replaceAll('_', '_u').replaceAll('.', '__');
const frame = (delta: object) => 'data: ' + JSON.stringify({ choices: [{ index: 0, delta }] }) + '\n\ndata: [DONE]\n\n';
const payload = (e: any) => {
  const receipt = e.targets ? (assert.equal(e.targets.length, 1), e.targets[0]) : e;
  assert.equal(receipt.status, 'succeeded', JSON.stringify(receipt));
  for (const block of receipt.content ?? []) {
    try { return JSON.parse(block.text); } catch {}
  }
  return receipt;
};
const fixture = createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/v1/models') {
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ data: ['fixture-first', 'fixture-second'].map((id, i) => ({ id, reasoning: false, vision: false, context_length: i ? 65536 : 32768 })) }));
  } else {
    try {
      assert.equal(req.headers.authorization, undefined);
      let bytes = ''; for await (const chunk of req) bytes += chunk;
      const body = JSON.parse(bytes);
      assert.equal(req.method, 'POST'); chatRequests++;
      assert(expected, 'UI controls must not submit a user/model turn');
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      if (!body.tools?.length && expected !== 'none') { res.end(frame({ content: 'Composer verification' })); return; } // title request
      const label = expected.toUpperCase(), prompt = 'Composer test ' + label;
      const index = body.messages.findLastIndex((m:any) => m.role === 'user' && m.content === prompt);
      if (index < 0 && !body.tools?.length) { res.end(frame({ content: 'Composer verification' })); return; }
      assert(index >= 0, 'wrong conversation/prompt: ' + JSON.stringify(body.messages.filter((m:any) => m.role === 'user').map((m:any) => m.content)).slice(-500));
      assert.equal(body.model, 'fixture-second'); turns++;
      const defs = (body.tools ?? []).map((t: any) => t.function.name);
      const results = new Map<string, any>(body.messages.slice(index + 1).filter((m:any) => m.role === 'tool').map((m:any) => [m.tool_call_id, JSON.parse(m.content)]));
      function call(id: string, name: string, args: object) {
        assert(defs.includes(wire(name)), 'Missing authorized tool ' + name);
        lastTool = name;
        res.end(frame({ tool_calls: [{ index: 0, id, type: 'function', function: { name: wire(name), arguments: JSON.stringify(args) } }] }));
      }
      const done = () => { receipts.push(expected!); res.end(frame({ content: 'Composer verified ' + label })); };
      if (expected === 'none') {
        assert(!defs.includes('run_command') && !defs.includes(wire('host.run_in_terminal')), 'zero grants must not authorize batch or PTY');
        return done();
      }
      const listId = expected + '-list', runId = expected + '-run';
      if (!results.has(listId)) return call(listId, 'host.list_sessions', { limit: 8 });
      const sessions = payload(results.get(listId)).sessions; assert.equal(sessions.length, 1);
      const target = sessions[0], marker = 'ZW_NATIVE_' + label;
      const command = "printf '%s\\n' " + marker;
      if (!results.has(runId)) {
        if (expected === 'batch') return call(runId, 'run_command', { session_ids: [target.session_id], command });
        return call(runId, 'host.run_in_terminal', { session_ref: target.session_ref, command, request_key: runId });
      }
      const actual = payload(results.get(runId));
      if (expected === 'batch') { assert.equal(actual.exit, 0); assert(actual.stdout.includes(marker)); return done(); }
      assert(actual.execution_ref);
      const waits = [...results.keys()].filter(id => id.startsWith('wait-'));
      const previous = waits.length ? payload(results.get(waits.at(-1)!)) : null;
      if (!previous || previous.state !== 'interval_recorded') {
        assert(waits.length < 4, 'PTY did not settle: ' + JSON.stringify(previous));
        return call('wait-' + (++counter), 'host.wait_execution', { execution_ref: actual.execution_ref, after_revision: (previous ?? actual).source_revision, wait_ms: 12000, max_bytes: 8192 });
      }
      assert.equal(previous.snapshot.process.exit_code, 0); assert(previous.output.includes(marker)); return done();
    } catch (e) {
      providerProblem = String(e);
      if (!res.headersSent) res.writeHead(400);
      res.end(frame({ content: 'Fixture failed' }));
    }
  }
});
try {
  // Take an immutable copy before launch. Other builds can replace zig-out
  // with a release executable, which deliberately ignores fixture scoping.
  const binary = join(folder, 'zerowork');
  await copyFile(resolve(process.env.ZW_AI_TEST_BINARY ?? join(prefix, 'bin/zerowork')), binary);
  assert((await readFile(binary)).includes('MENU_BAR_BADGE'), 'Use a -Dtest-mode=true executable; never open production data');
  for (const name of ['zw_ipc.so', 'zw_execution.so', 'zw_secret_consume.so', 'zw_execution_guard']) {
    await symlink(join(prefix, 'bin', name), join(folder, name));
  }
  await symlink(resolve(import.meta.dirname, '../assets'), join(folder, 'assets'), 'dir');
  for (const path of [data, rpc, join(data, 'credentials')]) await mkdir(path, { mode: 0o700 });
  await writeFile(join(data, 'credentials', '.local-storage'), '1', { mode: 0o600 });
  const port = await new Promise<number>((ok, fail) => {
    fixture.once('error', fail); fixture.listen(0, '127.0.0.1', () => ok((fixture.address() as { port: number }).port));
  });
  await writeFile(join(data, 'config.toml'), [
    '[meta]', 'config_revision=1', '[ui]', 'theme=' + JSON.stringify(process.env.ZW_COMPOSER_TEST_THEME ?? 'dark'),
    '[ai]', 'default_provider="fixture"', 'permission_mode="confirm"', 'execution_mode="auto"',
    '[[ai.providers]]', 'id="fixture"', 'kind="openai_compat"', 'enabled=true', 'endpoint="http://127.0.0.1:' + port + '/v1/chat/completions"',
    '[[ai.providers.models]]', 'name="fixture-first"', 'context_window=32768', 'default=true',
    '[[ai.providers.models]]', 'name="fixture-second"', 'context_window=65536', ''
  ].join('\n'));
  process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
  const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
  const env = { ...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1',
    ZENIT_E2E_ISOLATE_POINTER: '1', ZW_TEST_CREDENTIAL_RESPONSE: 'cancel', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: '', ZDOTDIR: folder };
  for (const key of ['ZEROWORK_AI_MOCK', 'ZEROWORK_AI_ENDPOINT', 'ZEROWORK_AI_MODEL', 'ZEROWORK_AI_PROVIDER']) delete env[key];
  child = spawn(binary, [], { env, stdio: ['ignore', 'ignore', 'pipe'] });
  child.stderr?.on('data', bytes => { log = (log + String(bytes)).slice(-3500); });
  ended = new Promise(resolve => child!.once('close', resolve));
  const show = (n: any) => !!n && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > .5 && n.rect?.w > 0 && n.rect?.h > 0;
  const flat = (n: any): any[] => Array.isArray(n) ? n.flatMap(flat) : n ? [n, ...(n.children ?? []).flatMap(flat)] : [];
  const text = (n: any) => flat(n).filter(show).map(n => n.text ?? '').join(' ');
  const shown = async (id: string, label = '') => (await h.query(id)).find(n => show(n) && text(n).includes(label)) ?? null;
  const see = async (id: string, label = '') => {
    step = 'visible ' + id + ' ' + label;
    return h.waitFor(() => shown(id, label), 10000);
  };
  const click = async (id: string, label = '') => {
    step = 'click ' + id + ' ' + label;
    const n = await see(id, label); assert((await h.clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok);
  };
  const key = async (k: string, mods = {}) => { assert((await h.key(k, mods)).ok); };
  const menuAligned = async (id: string) => {
    step = 'aligned composer popup ' + id;
    return h.waitFor(async () => {
      const popup = await shown(id), composer = await shown('ai.composer.surface');
      lastGeometry = { menu: id, popup: popup?.rect, composer: composer?.rect };
      if (!popup || !composer) return null;
      const p = popup.rect, c = composer.rect;
      const gap = c.y - p.y - p.h;
      if (Math.abs(p.x - c.x) > 0.6 || Math.abs(p.w - c.w) > 0.6 || Math.abs(gap - 6) > 0.6) return null;
      geometry.push({ menu: id, width: p.w, x: p.x, gap, composerWidth: c.w });
      return popup;
    }, 8000);
  };
  const sessionMenu = async () => {
    await click('ai.prompt'); await key('a', { cmd: true }); await key('backspace');
    assert((await h.type_('/session')).ok); await see('ai.command.session');
    await key('return'); await menuAligned('ai.targets.popup');
  };
  const replaceDraft = async (value: string) => {
    await click('ai.prompt'); await key('a', { cmd: true }); await key('backspace');
    assert((await h.type_(value)).ok);
  };
  await h.waitForServerReady(18000);
  assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), child.pid);
  await h.resizeWindow(1280, 800);
  await click('toolbar.new_session'); await click('session.menu.ai'); await see('ai.workspace.shell');
  // A brand-new independent conversation advertises actual saved model choices.
  await click('ai.composer.model'); await see('ai.model.menu');
  await click('ai.model.option', 'fixture-second');
  await see('ai.composer.model', 'fixture-second');
  checks.push('Model picker selects fixture-second from the active standalone conversation');
  await click('ai.composer.permission'); await click('ai.permission.auto');
  await see('ai.composer.permission', '自动执行');
  await click('ai.composer.permission'); await click('ai.permission.confirm');
  await see('ai.composer.permission', '确认后执行');
  await click('ai.composer.execution'); await click('ai.execution.interactive');
  await see('ai.composer.execution', '交互式');
  checks.push('Permission and interactive execution mode choices are independent');
  assert.equal((await h.query('ai.targets.add')).length, 0, 'association is not a permanent composer control');
  await sessionMenu();
  assert.equal(await shown('ai.targets.chip'), null, 'no implicit access on a new AI tab');
  await click('ai.targets.create_local');
  await see('ai.workspace.shell'); await see('ai.workspace.scope', '1 个关联目标');
  await sessionMenu(); await click('ai.targets.chip');
  await see('ai.workspace.scope', '未关联会话');
  await click('ai.prompt'); assert((await h.type_('@')).ok);
  await menuAligned('ai.targets.popup'); await see('ai.targets.candidate');
  await key('escape'); await see('ai.workspace.scope', '未关联会话');
  await h.resizeWindow(860, 480);
  await sessionMenu(); await key('escape');
  await replaceDraft('@Loc');
  await menuAligned('ai.targets.popup'); await see('ai.targets.candidate');
  await key('return');
  await see('ai.workspace.scope', '1 个关联目标');
  await h.resizeWindow(1280, 800);
  checks.push('/session manages the actual terminal grant without a chip; @ aligns, Escape cancels, Return grants one target');
  await click('ai.composer.execution'); await click('ai.execution.auto');
  await see('ai.composer.execution', '自行判断'); await see('ai.composer.permission', '确认后执行');
  await see('ai.composer.model', 'fixture-second');
  checks.push('Restoring automatic routing leaves model, association and permission unchanged');
  await click('ai.prompt'); await key('a', { cmd: true }); await key('backspace');
  await click('ai.prompt'); assert((await h.type_('/')).ok);
  for (const id of ['ai.skill_picker.command', 'ai.command.model', 'ai.command.permission', 'ai.command.execution', 'ai.command.session']) await see(id);
  await menuAligned('ai.skill_picker');
  await h.resizeWindow(860, 480);
  // Native resize can take focus away and dismiss a completion; it must not
  // lose the draft. Reopen through the same keyboard path in the new size.
  assert.equal((await h.inputState('ai.prompt')).buffer, '/');
  await replaceDraft('/');
  await menuAligned('ai.skill_picker');
  const compactComposer = (await see('ai.composer.surface')).rect;
  const compactSend = (await h.query('ai.send'))[0]?.rect;
  assert(compactSend && compactSend.x >= compactComposer.x && compactSend.x + compactSend.w <= compactComposer.x + compactComposer.w + 0.5, 'narrow composer keeps Send inside');
  await h.resizeWindow(1280, 800);
  await replaceDraft('/mod'); await see('ai.command.model'); await key('return');
  await see('ai.model.menu'); await key('escape');
  checks.push('/ and /mod offer real commands and Return opens the model picker without a turn');
  for (const [input, label] of [['/swarm', 'Swarm'], ['/auto', 'Auto']]) {
    await click('ai.prompt'); assert((await h.type_(input)).ok);
    await see('ai.command.' + input.slice(1)); await key('return'); await see('ai.composer.mode', label);
  }
  checks.push('Selecting /swarm and /auto changes the actual orchestration mode, independently from command execution');
  assert.equal(chatRequests, 0); assert.equal(turns, 0, 'local commands / target changes must never submit any model request');
  const execute = async (mode: 'batch' | 'terminal' | 'none') => {
    expected = mode;
    await click('ai.prompt'); await key('a', { cmd: true }); await key('backspace');
    assert((await h.type_('Composer test ' + mode.toUpperCase())).ok); await key('return');
    step = 'actual ' + mode + ' receipt';
    const timeout = Date.now() + 23000;
    while (!receipts.includes(mode) || await shown('ai.stop')) {
      assert(!providerProblem, providerProblem);
      assert(Date.now() < timeout, 'No terminal receipt: ' + lastTool + ' / ' + providerProblem);
      // Respect tool-specific policy even in automatic mode. Only approve the
      // fixture's known printf if the app presents that exact native approval.
      const accept = await shown('ai.host_approval.accept');
      if (accept && lastTool === 'host.run_in_terminal') {
        const summary = await shown('ai.host_approval.summary');
        assert(text(summary).includes('ZW_NATIVE_TERMINAL'));
        await click('ai.host_approval.accept');
      }
      await h.sleep(100);
    }
  };
  // Explicit auto permission for this local test profile only; both commands
  // are fixed harmless printf. Assert real tool receipts, not assistant text.
  await click('ai.composer.permission'); await click('ai.permission.auto');
  await execute('batch');
  checks.push('With an explicitly associated target, auto runs a real isolated batch, exit 0 and exact printf marker');
  await click('ai.composer.execution'); await click('ai.execution.interactive');
  await execute('terminal');
  checks.push('Interactive mode runs on the one associated real local PTY with a recorded interval and exit 0');
  await sessionMenu(); await click('ai.targets.chip');
  await click('ai.composer.execution'); await click('ai.execution.auto');
  await execute('none');
  checks.push('No attached targets in auto mode means no execution authority or implicit use of another tab');
  assert((await h.request('POST', '/zerowork/windows', { action: 'quit' })).ok);
  const until = Date.now() + 9000;
  while (child.exitCode === null && child.signalCode === null && Date.now() < until) {
    for (const id of ['local.close.accept', 'session.close.accept']) {
      if (await shown(id).catch(() => null)) await click(id);
    }
    await Promise.race([ended, h.sleep(120)]);
  }
  assert.equal(child.exitCode, 0, 'application quits normally');
  console.log(JSON.stringify({ status: 'passed', checks, geometry }));
} catch (error) {
  console.error(JSON.stringify({ status: 'failed', step, checks, geometry, lastGeometry, error: String(error), providerProblem, lastTool, app: log }));
  process.exitCode = 1;
} finally {
  if (child && child.exitCode === null && child.signalCode === null) { child.kill(); await ended; }
  fixture.closeAllConnections();
  if (fixture.listening) await new Promise<void>(done => fixture.close(() => done()));
  await rm(folder, { recursive: true, force: true, maxRetries: 8, retryDelay: 150 });
}
