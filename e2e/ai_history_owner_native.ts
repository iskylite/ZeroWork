// Real standalone rail and deletion confirmation. No real account or Keychain.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const executable = join(prefix, 'bin/zerowork');
const dir = await realpath(await mkdtemp(join(tmpdir(), 'zw-ai-history-owner-')));
const data = join(dir, 'data'), rpc = join(dir, 'rpc');
const checks: string[] = [];
let processHandle: ReturnType<typeof spawn> | undefined, ended: Promise<unknown> | undefined;
let phase = 'init', stderr = '', requests = 0;
const provider = createServer(async (req, res) => {
  try {
    assert.equal(req.headers.authorization, undefined);
    for await (const ignored of req) void ignored;
    if (req.method === 'GET') {
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ data: [{ id: 'fixture', context_length: 32768 }] }));
      return;
    }
    requests++;
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end('data: ' + JSON.stringify({ choices: [{ index: 0, delta: { content: 'History fixture response' } }] }) + '\n\ndata: [DONE]\n\n');
  } catch {
    res.writeHead(400).end();
  }
});
try {
  for (const p of [data, rpc, join(data, 'credentials')]) await mkdir(p, { mode: 0o700 });
  await writeFile(join(data, 'credentials', '.local-storage'), '1', { mode: 0o600 });
  const port = await new Promise<number>((ok, fail) => {
    provider.once('error', fail);
    provider.listen(0, '127.0.0.1', () => ok((provider.address() as { port: number }).port));
  });
  await writeFile(join(data, 'config.toml'), [
    '[meta]', 'config_revision=1', '[ai]', 'default_provider="fixture"', 'permission_mode="confirm"',
    '[[ai.providers]]', 'id="fixture"', 'kind="openai_compat"', 'enabled=true',
    `endpoint="http://127.0.0.1:${port}/v1/chat/completions"`,
    '[[ai.providers.models]]', 'name="fixture"', 'context_window=32768', 'default=true', '',
  ].join('\n'));
  process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
  const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
  const env = { ...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1',
    ZENIT_E2E_ISOLATE_POINTER: '1', ZW_TEST_CREDENTIAL_RESPONSE: 'cancel', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: '', ZDOTDIR: dir };
  for (const k of ['ZEROWORK_AI_MOCK', 'ZEROWORK_AI_ENDPOINT', 'ZEROWORK_AI_MODEL', 'ZEROWORK_AI_PROVIDER']) delete env[k];
  const hash = createHash('sha256');
  for await (const bytes of createReadStream(executable)) hash.update(bytes);
  const sha256 = hash.digest('hex');
  if (process.env.ZW_AI_TEST_SHA256) assert.equal(sha256, process.env.ZW_AI_TEST_SHA256);
  processHandle = spawn(executable, [], { env, stdio: ['ignore', 'ignore', 'pipe'] });
  processHandle.stderr?.on('data', chunk => { stderr = (stderr + String(chunk)).slice(-3000); });
  ended = new Promise(resolve => processHandle!.once('close', resolve));
  const live = (n: any) => n && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0.5 && n.rect?.w > 0 && n.rect?.h > 0;
  const inspect = async (id: string) => (await h.query(id)).find(live);
  const see = (id: string) => h.waitFor(() => inspect(id), 12000);
  const gone = (id: string) => h.waitFor(async () => !(await inspect(id)) || null, 8000);
  const click = async (id: string) => {
    phase = 'click ' + id;
    const n = await see(id);
    assert((await h.clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok);
  };
  const journal = () => readFile(join(data, 'ai-sessions-active.jsonl'), 'utf8').catch(() => '');
  const events = async (kind: string) => (await journal()).split('\n').filter(Boolean).flatMap(s => {
    try { const e = JSON.parse(s).event; return e?.kind === kind ? [e] : []; } catch { return []; }
  });
  await h.waitForServerReady(18000);
  assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), processHandle.pid);
  await h.resizeWindow(1280, 800);
  await click('toolbar.new_session');
  await click('session.menu.ai');
  await see('ai.workspace.shell');
  const flatten = (nodes: any[]): any[] => nodes.flatMap(n => [n, ...flatten(n.children ?? [])]);
  const tabs = () => h.query('tabs.strip').then(flatten);
  const standaloneTab = (await tabs()).find(n => /^tabs\.tab\.\d+$/.test(n.test_id ?? '')).test_id;
  await click('ai.prompt');
  assert((await h.type_('History fixture original')).ok);
  await click('ai.send');
  await see('ai.turn.complete');
  await gone('ai.stop');
  await h.waitFor(async () => (await events('checkpoint')).length || null, 12000);
  const before = requests;

  await click('ai.workspace.session.pin.0');
  await h.waitFor(async () => (await events('history_pin')).find(e => e.history_pinned === true), 8000);
  await click('ai.workspace.session.pin.0');
  await h.waitFor(async () => (await events('history_pin')).find(e => e.history_pinned === false), 8000);
  await click('ai.workspace.session.pin.0');
  await h.waitFor(async () => (await events('history_pin')).filter(e => e.history_pinned === true).length === 2 || null, 8000);
  checks.push('Real standalone row pin/unpin/pin writes three durable updates without a model turn');

  await click('ai.workspace.new');
  await click('ai.session.close.accept');
  await gone('ai.session.close.confirmation');
  await h.waitFor(async () => (await events('unbind')).length || null, 10000);
  await click('ai.workspace.session.0');
  await see('ai.history');
  await see('ai.history.restore');
  assert((await see('ai.history.body')).text.includes('History fixture original'));
  assert.equal((await events('bind')).length, 0, 'preview must not rebind the original');
  await click('ai.history.restore');
  await gone('ai.history');
  const rebound = await h.waitFor(async () => (await events('bind'))[0], 10000);
  assert.equal(JSON.stringify(rebound.conversation), JSON.stringify((await events('history_pin'))[0].conversation));
  assert.equal(requests, before, 'restoring must not submit history or its draft');
  await click('ai.workspace.new');
  await click('ai.session.close.accept');
  await gone('ai.session.close.confirmation');
  await h.waitFor(async () => (await events('unbind')).length >= 2 || null, 10000);

  // Opt-in extra cross-surface run: real local terminal, never a remote shell.
  let lastModelCount = before;
  if (process.env.ZW_AI_TEST_CROSS === 'true') {
    const copyVisible = async (excluded = '') => h.waitFor(async () => {
      const candidates = await Promise.all(Array.from({ length: 7 }, (_, i) => {
        const id = 'ai.session.copy_use.' + (i + 1);
        return id === excluded ? null : inspect(id);
      }));
      return candidates.find(Boolean);
    }, 10000);
    await click('toolbar.new_session');
    await click('session.menu.local');
    await see('terminal.surface');
    phase = 'open attached AI with keyboard';
    await h.sleep(350);
    if (!(await inspect('ai.prompt'))) assert((await h.key('j', { cmd: true })).ok);
    await see('ai.prompt');
    const sample = await Promise.all(['ai.panel','ai.sessions','ai.prompt','ai.workspace.shell','ai.strip','ai.empty.history'].map(async id => [id, (await h.query(id)).map((n: any) => ({ shown: Boolean(live(n)), rect: n.rect, opacity: n.effective_opacity }))]));
    phase = 'terminal controls ' + JSON.stringify(sample);
    await see('ai.sessions');
    await click('ai.sessions');
    phase = 'attached global history menu layout';
    await see('ai.sessions.menu');
    phase = 'standalone to terminal history action';
    const original = await copyVisible();
    await gone(original.test_id.replace('copy_use', 'restore'));
    await click(original.test_id);
    await see('ai.session.close.confirmation');
    await click('ai.session.close.accept');
    const firstCopy = await h.waitFor(async () => (await events('fork_bound'))[0], 10000);
    assert.notDeepEqual(firstCopy.conversation, firstCopy.parent);
    assert.equal(requests, lastModelCount);
    checks.push('Standalone history cannot transfer original identity into a local-terminal assistant; explicit confirmation only creates a fresh copy');

    // Record actual text from the attached terminal and inspect it in the
    // independent conversation through the app's global history controls.
    await click('ai.prompt');
    assert((await h.type_('History fixture terminal')).ok);
    await click('ai.send');
    await see('ai.turn.complete');
    await gone('ai.stop');
    await h.waitFor(async () => (await events('checkpoint')).some(e => JSON.stringify(e.conversation) === JSON.stringify(firstCopy.conversation)) || null, 10000);
    lastModelCount = requests;
    await click(standaloneTab);
    await see('ai.workspace.shell');
    await click('ai.workspace.history');
    await see('ai.sessions.menu');
    phase = 'terminal to standalone history action';
    const terminalAction = await copyVisible(original.test_id);
    await gone(terminalAction.test_id.replace('copy_use', 'restore'));
    await click(terminalAction.test_id);
    await see('ai.session.close.confirmation');
    await click('ai.session.close.accept');
    const secondCopy = await h.waitFor(async () => (await events('fork_bound'))[1], 10000);
    assert.deepEqual(secondCopy.parent, firstCopy.conversation);
    assert.notDeepEqual(secondCopy.conversation, secondCopy.parent);
    assert.equal(secondCopy.workspace_source, undefined);
    assert.equal(requests, lastModelCount);
    checks.push('Terminal to standalone also uses disclosed explicit text-only copy, not original restore or workspace/SSH authority');
  }

  await click('ai.workspace.session.delete.0');
  await see('ai.session.close.confirmation');
  await click('ai.session.close.cancel');
  await gone('ai.session.close.confirmation');
  assert.equal((await events('remove')).length, 0);

  await click('ai.workspace.session.delete.0');
  await click('ai.session.close.accept');
  await gone('ai.session.close.confirmation');
  const removed = await h.waitFor(async () => (await events('remove'))[0], 10000);
  assert.equal(JSON.stringify(removed.conversation), JSON.stringify((await events('history_pin'))[0].conversation));
  if (process.env.ZW_AI_TEST_CROSS !== 'true') await gone('ai.workspace.session.delete.0');
  checks.push('Preview is read-only; original identity is restored only on the proven same live environment. Delete can be canceled, and confirmation removes only the exact pinned history record.');
  assert.equal(requests, lastModelCount);
  assert((await h.request('POST', '/zerowork/windows', { action: 'quit' })).ok);
  const deadline = Date.now() + 10000;
  while (processHandle.exitCode === null && processHandle.signalCode === null && Date.now() < deadline) {
    for (const id of ['local.close.accept', 'session.close.accept']) if (await inspect(id).catch(() => null)) await click(id);
    await Promise.race([ended, h.sleep(100)]);
  }
  assert.equal(processHandle.exitCode, 0);
  console.log(JSON.stringify({ status: 'passed', checks, sha256 }));
} catch (error) {
  console.error(JSON.stringify({ status: 'failed', phase, checks, error: String(error), stderr }));
  process.exitCode = 1;
} finally {
  if (processHandle && processHandle.exitCode === null && processHandle.signalCode === null) { processHandle.kill(); await ended; }
  provider.closeAllConnections();
  if (provider.listening) await new Promise<void>(done => provider.close(() => done()));
  await rm(dir, { recursive: true, force: true, maxRetries: 8, retryDelay: 150 });
}
