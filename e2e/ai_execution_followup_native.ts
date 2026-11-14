/** Follow-up input while a real Local foreground command remains active. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, open, readFile, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const prefix = resolve(process.argv[2] ?? '/private/tmp/zw-async-followup-build');
const isolated = await mkdtemp('/private/tmp/zw-async-followup-');
const data = join(isolated, 'data');
const rpc = join(isolated, 'rpc');
const zdot = join(isolated, 'zdot');
const release = join(isolated, 'release');
for (const path of [data, rpc, zdot]) await mkdir(path);
await writeFile(join(zdot, '.zshrc'), "PS1='followup-test%# '\n");

const frame = (delta: any) => 'data: ' + JSON.stringify({ choices: [{ index: 0, delta }] }) + '\n\n';
const done = 'data: [DONE]\n\n';
const wireName = (name: string) => name.replaceAll('_', '_u').replaceAll('.', '__');
let failure: string | null = null;
let waitEmitted = false;
let executionRef = '';
let firstReply = false;
let secondReply = false;
let firstFollowupAt = 0;
let secondFollowupAt = 0;
let nextTurnAt = 0;
let passed = false;
let cleanupError: string | null = null;
let quitResult: unknown = null;
const delays: number[] = [];

function payload(envelope: any) {
  for (const block of envelope.content ?? []) {
    if (block.type === 'structured' || block.type === 'text') return JSON.parse(block.text);
  }
  throw new Error('missing structured host result');
}

const server = createServer(async (req, res) => {
  try {
    if (req.method !== 'POST') return res.end('{"data":[{"id":"followup-fixture"}]}');
    let raw = '';
    for await (const part of req) raw += part;
    const body = JSON.parse(raw);
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.flushHeaders();
    if (!body.tools?.length) return res.end(frame({ content: '长命令消息测试' }) + done);

    const messages = body.messages as any[];
    const results = new Map(messages.filter(message => message.role === 'tool').map(message => [message.tool_call_id, JSON.parse(message.content)]));
    const users = messages.filter(message => message.role === 'user').map(message => String(message.content));
    const hasUser = (marker: string) => users.some(content => content.includes(marker));
    const call = (id: string, name: string, args: object) => {
      const wire = wireName(name);
      assert(body.tools.some((tool: any) => tool.function.name === wire), `missing ${wire}`);
      res.end(frame({ tool_calls: [{ index: 0, id, type: 'function', function: { name: wire, arguments: JSON.stringify(args) } }] }) + done);
    };
    const result = (id: string) => {
      const envelope = results.get(id);
      if (!envelope) return null;
      assert.equal(envelope.status, 'succeeded', `${id}: ${JSON.stringify(envelope)}`);
      return payload(envelope);
    };

    if (hasUser('NEXT_TURN')) {
      const active = result('next-observation');
      if (!active) return call('next-observation', 'host.get_execution', { execution_ref: executionRef });
      assert.equal(active.execution_ref, executionRef);
      assert.equal(active.state, 'running');
      assert.equal(active.snapshot.process?.foreground_finished ?? false, false);
      delays.push(performance.now() - nextTurnAt);
      secondReply = true;
      return res.end(frame({ content: 'NEXT_TURN_OK' }) + done);
    }
    if (hasUser('FOLLOW_TWO')) {
      const wait = result('wait-long');
      assert(wait);
      assert.equal(wait.execution_ref, executionRef);
      assert.equal(wait.state, 'running');
      assert.equal(wait.wait_interrupted, 'new_input');
      assert.equal(wait.timed_out, false);
      delays.push(performance.now() - secondFollowupAt);
      firstReply = true;
      return res.end(frame({ content: 'STEERING_OK' }) + done);
    }
    if (hasUser('FOLLOW_ONE')) {
      const started = result('run-long');
      assert(started);
      assert.equal(started.state, 'running');
      assert.equal(started.wait_interrupted, 'new_input');
      assert.equal(started.timed_out, false);
      executionRef = started.execution_ref;
      delays.push(performance.now() - firstFollowupAt);
      waitEmitted = true;
      return call('wait-long', 'host.wait_execution', { execution_ref: executionRef, until: 'decision', wait_ms: 30000 });
    }
    const context = result('context');
    if (!context) return call('context', 'host.get_current_context', {});
    return call('run-long', 'host.run_in_terminal', { session_ref: context.binding_ref, command: `zmodload zsh/zselect && { while [[ ! -f '${release}' ]]; do zselect -t 5; done; true; }`, request_key: 'followup-long-command', wait_ms: 30000 });
  } catch (error) {
    failure = String(error);
    res.end();
  }
});
await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="sauber"\nfont_size=14\n[ai]\ndefault_provider="followup-fixture"\npermission_mode="auto"\nexecution_mode="attached_pty"\nfollow_up_mode="steer"\n[[ai.providers]]\nid="followup-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address() as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="followup-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const log = await open(join(isolated, 'app.log'), 'w');
const app = spawn(join(prefix, 'bin/zerowork'), [], { env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZEROWORK_DATA_DIR: data, ZDOTDIR: zdot, ZEROWORK_AUTOCONNECT: '0', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: '' }, stdio: ['ignore', log.fd, log.fd] });
const ended = new Promise<void>(resolve => app.once('close', () => resolve()));
const alive = () => app.exitCode === null && app.signalCode === null;
const shown = (node: any) => node && node.visible !== false && !node.hidden && (node.effective_opacity ?? 1) > 0 && node.rect?.w > 0 && node.rect?.h > 0;
const flat = (node: any): any[] => Array.isArray(node) ? node.flatMap(flat) : node ? [node, ...(node.children ?? []).flatMap(flat)] : [];
const text = (node: any) => flat(node).map(value => typeof value.text === 'string' ? value.text : '').join(' ');
const visible = (id: string) => h.waitFor(async () => { assert.equal(failure, null); return (await h.query(id)).find(shown) ?? null; }, 15000);
const click = async (id: string) => { await visible(id); assert((await h.clickTestId(id)).ok, id); };
const send = async (value: string) => { await click('ai.prompt'); await h.type_(value); await click('ai.send'); };
const executionRecord = async () => {
  try {
    const journal = JSON.parse(await readFile(join(data, 'ai/lifecycle.json'), 'utf8'));
    return journal.records.find((record: any) => record.original_call === 'run-long') ?? null;
  } catch { return null; }
};

try {
  await h.waitForServerReady(60000);
  await h.resizeWindow(1440, 1000);
  await click('workspace.empty.local');
  await visible('terminal.surface');
  await click('toolbar.ai');
  await send('START_LONG_EXECUTION');
  await h.waitFor(async () => {
    assert.equal(failure, null);
    if ((await h.query('ai.host_approval.accept')).some(shown)) await click('ai.host_approval.accept');
    const record = await executionRecord();
    return record?.stage === 'running' && record.execution_receipt?.start && record.execution_receipt?.native_wake_written ? record : null;
  }, 20000);

  firstFollowupAt = performance.now();
  await send('FOLLOW_ONE');
  await h.waitFor(async () => { assert.equal(failure, null); return waitEmitted || null; }, 10000);
  await h.sleep(1000);
  secondFollowupAt = performance.now();
  await send('FOLLOW_TWO');
  await h.waitFor(async () => { assert.equal(failure, null); return firstReply || null; }, 10000);
  await visible('ai.turn.complete');

  nextTurnAt = performance.now();
  await send('NEXT_TURN');
  await h.waitFor(async () => { assert.equal(failure, null); return secondReply || null; }, 10000);
  await h.waitFor(async () => text(await h.query('ai.response')).includes('NEXT_TURN_OK') || null, 10000);
  assert(delays.every(delay => delay < 10000), `follow-up delays: ${delays}`);
  const active = await executionRecord();
  assert.equal(active.stage, 'running');
  assert.equal(active.execution_receipt.process?.foreground_finished ?? false, false);
  const journal = JSON.parse(await readFile(join(data, 'ai/lifecycle.json'), 'utf8'));
  assert.equal(journal.records.filter((record: any) => record.tool_id === 'host.run_in_terminal' && record.execution).length, 1);

  await writeFile(release, 'release');
  await h.waitFor(async () => {
    const record = await executionRecord();
    return record?.stage === 'succeeded' && record.execution_receipt?.process?.foreground_finished && record.execution_receipt?.local_released || null;
  }, 15000);
  passed = true;
} finally {
  await writeFile(release, 'release').catch(() => {});
  try {
    if (alive()) quitResult = await h.request('POST', '/zerowork/windows', { action: 'quit' });
    const deadline = performance.now() + 15000;
    while (alive() && performance.now() < deadline) {
      for (const id of ['local.close.accept', 'session.close.accept', 'groups.close.accept']) {
        const nodes = await h.query(id);
        if (Array.isArray(nodes) && nodes.some(shown)) await click(id);
      }
      if (alive()) await h.sleep(80);
    }
  } catch (error) { cleanupError = String(error); }
  if (alive()) { app.kill('SIGTERM'); await ended; }
  server.closeAllConnections();
  await new Promise<void>(resolve => server.close(() => resolve()));
  await log.close();
  if (passed && app.exitCode === 0) {
    await rm(isolated, { recursive: true, force: true });
    console.log(JSON.stringify({ status: 'passed', followup_delays_ms: delays }));
  } else {
    process.exitCode = 1;
    console.error(`test data: ${isolated}, exit code: ${app.exitCode}, signal: ${app.signalCode}, quit result: ${JSON.stringify(quitResult)}, cleanup error: ${cleanupError}`);
  }
}
