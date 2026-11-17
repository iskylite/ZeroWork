/** Isolated macOS app and loopback model for the Boost and role-template UI. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer, type ServerResponse } from 'node:http';
import { mkdir, mkdtemp, open, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const out = resolve(process.argv[2]);
const theme = process.argv[3] ?? 'dark';
const allPassed = theme === 'light';
const checkStall = process.argv.includes('--stall');
let finalResponse: ServerResponse | null = null;
await mkdir(out, { recursive: true });
const isolation = await realpath(await mkdtemp('/tmp/zw-boost-native-'));
const data = join(isolation, 'data');
const rpc = join(isolation, 'rpc');
for (const dir of [data, rpc]) await mkdir(dir);
const journal = async () => (await readFile(join(data, 'ai-sessions-active.jsonl'), 'utf8').catch(() => '')).trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
const taskFact = async (name: string) => (await journal()).map(row => row.event?.task_fact).filter(fact => fact?.label === name).at(-1);
const wire = (name: string) => name.replaceAll('_', '_u').replaceAll('.', '__');
const send = (res: ServerResponse, delta: unknown) =>
  res.end('data: ' + JSON.stringify({ choices: [{ index: 0, delta }] }) + '\n\ndata: [DONE]\n\n');
const sendTool = (res: ServerResponse, id: string, args: unknown) =>
  send(res, { tool_calls: [{ index: 0, id, type: 'function', function: { name: wire('host.agent_tasks'), arguments: JSON.stringify(args) } }] });
const childCalls: { task: string, model: string, receivedReport: boolean, previousSettled: boolean }[] = [];
let providerError: unknown;
const server = createServer(async (req, res) => {
  if (req.method !== 'POST') {
    res.end(JSON.stringify({ data: [{ id: 'base-model' }, { id: 'review-model' }] }));
    return;
  }
  let raw = '';
  for await (const chunk of req) raw += chunk;
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  res.flushHeaders();
  try {
    const body = JSON.parse(raw);
    const user = String(body.messages.filter((message: any) => message.role === 'user').at(-1)?.content ?? '');
    const system = body.messages.filter((message: any) => message.role === 'system').map((message: any) => message.content).join(' ');
    if (!body.tools?.some((tool: any) => tool.function?.name === wire('host.agent_tasks'))) {
      const task = ['NATIVE_IMPLEMENT', 'NATIVE_CHALLENGE', 'NATIVE_REPAIR'].find(marker => user.includes(marker));
      if (!task) return send(res, { content: 'Boost 验收' });
      const previousSettled = task !== 'NATIVE_REPAIR' || (await taskFact('复审校验'))?.status === 'succeeded';
      childCalls.push({ task, model: body.model, receivedReport: user.includes('IMPLEMENT_EVIDENCE'), previousSettled });
      if (task === 'NATIVE_CHALLENGE') await new Promise(done => setTimeout(done, 1500));
      return send(res, { content: task === 'NATIVE_IMPLEMENT' ? 'IMPLEMENT_EVIDENCE 已交付校验规则' : task === 'NATIVE_CHALLENGE' ? '发现一个遗漏场景' : 'REPAIR_EVIDENCE 边界场景已补齐' });
    }
    assert.match(system, /你是本次深度攻坚的领队/);
    const results = new Map<string, { status: string; data: any }>();
    for (const message of body.messages.filter((item: any) => item.role === 'tool')) {
      try {
        const envelope = JSON.parse(message.content);
        const data = JSON.parse(envelope.content?.[0]?.text ?? '{}');
        results.set(message.tool_call_id, { status: envelope.status, data });
      } catch {
        // Historical abbreviated receipts carry no live tool results.
      }
    }
    const submitted = String(body.messages.filter((message: any) => message.role === 'user').map((item: any) => item.content).join(' '));
    assert(submitted.includes('NATIVE_BOOST'));
    const child = (id: string, name: string, text: string, extra = {}) =>
      sendTool(res, id, { action: 'create', name, text, request_key: id, session_refs: [], ...extra });
    if (!results.has('implementation')) return child('implementation', '实现校验', 'NATIVE_IMPLEMENT');
    assert.equal(results.get('implementation')?.status, 'succeeded');
    if (!results.has('challenge')) {
      for (let trial = 0; trial < 160 && (await taskFact('实现校验'))?.status !== 'succeeded'; trial++) await new Promise(done => setTimeout(done, 60));
      assert.equal((await taskFact('实现校验'))?.status, 'succeeded');
      return child('challenge', '复审校验', 'NATIVE_CHALLENGE', { purpose: 'challenge', challenge_target: '@1' });
    }
    assert.equal(results.get('challenge')?.status, 'succeeded');
    if (!results.has('repair')) return child('repair', '修复校验', 'NATIVE_REPAIR', { depends_on: ['@2'] });
    assert.equal(results.get('repair')?.status, 'succeeded');
    if (!results.has('early-verification')) return sendTool(res, 'early-verification', {
      action: 'verify_boost',
      verification: [{ requirement: '等待修复交付', passed: true, detail: '提前提交应被拒绝' }],
    });
    assert.equal(results.get('early-verification')?.status, 'rejected');
    if (!results.has('verification')) {
      for (let trial = 0; trial < 160 && (await taskFact('修复校验'))?.status !== 'succeeded'; trial++) await new Promise(done => setTimeout(done, 60));
      assert.equal((await taskFact('修复校验'))?.status, 'succeeded');
      return sendTool(res, 'verification', {
        action: 'verify_boost',
        verification: [
          { requirement: '覆盖边界输入', passed: true, detail: '修复报告包含已覆盖的边界用例。' },
          { requirement: '核对空输入提示', passed: allPassed, detail: allPassed ? '空输入用例通过。' : '现有材料缺少空输入的运行结果。' },
        ],
      });
    }
    assert.equal(results.get('verification')?.status, 'succeeded');
    if (checkStall) {
      finalResponse = res;
      res.write('data: {"choices":[{"index":0,"delta":{"content":"正在汇总。"}}]}\n\n');
      const timer = setInterval(() => {
        if (!res.writableEnded && !res.destroyed) res.write('data: {"choices":[{"index":0,"delta":{}}]}\n\n');
      }, 3000);
      res.once('close', () => clearInterval(timer));
      return;
    }
    send(res, { content: 'BOOST_NATIVE_DONE' });
  } catch (error) {
    providerError = error;
    send(res, { content: '本地验收场景异常' });
  }
});
await new Promise<void>(done => server.listen(0, '127.0.0.1', done));
const port = (server.address() as { port: number }).port;
await writeFile(join(data, 'config.toml'), `[meta]
config_revision=1
[ui]
theme="${theme}"
[ai]
default_provider="fixture"
child_request_concurrency=4
child_max_active=6
swarm_stall_parent_minutes=1
[[ai.providers]]
id="fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:${port}/v1"
enabled=true
[[ai.providers.models]]
name="base-model"
context_window=200000
default=true
[[ai.providers.models]]
name="review-model"
context_window=200000
reasoning=true
efforts=["low","high"]
`);

process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const zenit = await import(join(prefix, 'share/zenit/harness/client.ts'));
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(join(prefix, 'bin/zerowork'), [], {
  env: { ...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0',
    ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: '' },
  stdio: ['ignore', log.fd, log.fd],
});
const exited = new Promise<void>(done => app.once('close', () => done()));
const shown = (node: any) => !node.hidden && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect?.w > 0 && node.rect?.h > 0;
const find = async (id: string) => (await zenit.query(id)).find(shown);
const visible = async (id: string) => zenit.waitFor(async () => {
  if (providerError) throw providerError;
  return await find(id) ?? null;
}, 10000);
const text = (node: any): string => (node?.text ?? '') + ' ' + (node?.children ?? []).map(text).join(' ');
const click = async (id: string) => {
  const target = await visible(id);
  const result = await zenit.clickAt(target.rect.x + target.rect.w / 2, target.rect.y + target.rect.h / 2);
  assert(result.ok, id + ' ' + JSON.stringify(result));
  await zenit.sleep(270);
};
const capture = async (name: string) => {
  await zenit.mouseMove(1, 1);
  await zenit.sleep(500);
  assert((await zenit.screenshot(join(out, name + '.png'))).ok);
};
let error: unknown;
try {
  await zenit.waitForServerReady(30000);
  await zenit.resizeWindow(1280, 860);
  await click('toolbar.settings');
  await click('settings.nav.ai');
  await click('settings.search');
  await zenit.type_('角色模板');
  await click('settings.template.create');
  await click('settings.template.name');
  await zenit.key('a', { cmd: true });
  await zenit.type_('验收模板');
  await click('settings.template.model.2');
  await click('settings.template.model.option.1');
  await click('settings.template.effort.2');
  await click('settings.template.effort.high');
  await zenit.resizeWindow(860, 480);
  const settingsViewport = (await visible('settings.viewport')).rect;
  await zenit.scrollAt(settingsViewport.x + settingsViewport.w / 2, settingsViewport.y + settingsViewport.h / 2, 0, -520);
  await zenit.sleep(400);
  const apply = (await visible('settings.template.apply')).rect;
  assert(apply.y >= settingsViewport.y && apply.y + apply.h <= settingsViewport.y + settingsViewport.h, 'the complete editor is reachable by scrolling');
  await capture('01-narrow-template-editor');
  await click('settings.template.apply');
  await zenit.resizeWindow(1280, 860);
  await click('settings.template.toggle.0');
  await visible('settings.template.editor');
  await click('settings.template.toggle.0');
  assert(!await find('settings.template.editor'));
  assert(!await find('settings.template.copy.0'));
  await capture('01-template-collapsed');
  await click('settings.template.toggle.0');
  await click('settings.template.copy.0');
  await visible('settings.template.editor');
  await click('settings.template.close');
  await click('settings.template.toggle.1');
  await click('settings.template.remove.1');
  await click('settings.template.toggle.0');
  await click('settings.template.make_default.0');
  await click('settings.save');
  await zenit.waitFor(async () => ((await readFile(join(data, 'config.toml'), 'utf8')).includes('review-model') && (await readFile(join(data, 'config.toml'), 'utf8')).includes('is_default')) || null, 12000);
  await zenit.resizeWindow(860, 480);
  await click('settings.close');
  if (await find('settings.confirmation.save')) await click('settings.confirmation.save');
  await click('workspace.empty.local');
  await visible('terminal.surface');
  if (!await find('toolbar.ai')) await click('toolbar.expand');
  await click('toolbar.ai');
  await click('ai.composer.mode');
  const mode = await visible('ai.mode.menu');
  assert.doesNotMatch(text(mode), /角色模板/);
  assert(mode.rect.x >= 0 && mode.rect.y >= 0 && mode.rect.x + mode.rect.w <= 860 && mode.rect.y + mode.rect.h <= 480);
  await capture('02-narrow-mode');
  await click('ai.mode.boost');
  await click('ai.prompt');
  await zenit.type_('NATIVE_BOOST 检查校验逻辑');
  await click('ai.send');
  if (checkStall) {
    await zenit.waitFor(() => finalResponse ?? null, 25000);
    await click('ai.children');
    const banner = await zenit.waitFor(async () => await find('ai.children.stall') ?? null, 80000);
    assert.match(text(banner), /进度停滞/);
    assert.equal(await find('ai.children.stall.stop'), undefined, 'settled children have no stop action');
    assert.doesNotMatch(text(await visible('ai.children.panel')), /0 运行中|最近结束/);
    const stallPanel = (await visible('ai.children.panel')).rect;
    assert(stallPanel.y + stallPanel.h <= 480);
    await capture('05-narrow-stall');
    await zenit.key('escape');
    await zenit.sleep(320);
    send(finalResponse!, { content: 'BOOST_NATIVE_DONE' });
  }
  await zenit.waitFor(async () => {
    if (providerError) throw providerError;
    return text(await find('ai.panel')).includes('BOOST_NATIVE_DONE') || null;
  }, 45000);
  assert(childCalls.some(call => call.task === 'NATIVE_CHALLENGE' && call.model === 'review-model' && call.receivedReport));
  assert(childCalls.some(call => call.task === 'NATIVE_REPAIR' && call.previousSettled));
  const facts = await Promise.all(['实现校验', '复审校验', '修复校验'].map(taskFact));
  assert.deepEqual(facts.map(fact => fact.boost_round.number), [1, 2, 3]);
  assert.deepEqual(facts.map(fact => fact.boost_round.phase), ['implementation', 'challenge', 'repair']);
  assert.equal(facts[1].boost_round.previous, facts[0].task);
  assert.equal(facts[2].boost_round.previous, facts[1].task);
  assert.equal(facts[1].read_only, true);
  const persisted = (await journal()).find(row => row.event?.task_fact?.verification)?.event.task_fact.verification;
  assert.deepEqual(persisted.map((item: any) => item.passed), [true, allPassed]);

  await click('ai.children');
  await click('ai.children.tab.rounds');
  const panel = await visible('ai.children.panel');
  assert.equal(panel.rect.w, 360);
  assert(panel.rect.y >= 0 && panel.rect.y + panel.rect.h <= 480);
  assert.match(text(await visible('ai.children.rounds')), /第 3 轮 · 修复/);
  assert.match(text(await visible('ai.children.rounds.verify')), /终验/);
  assert(text(await visible('ai.children.rounds.verify')).includes(allPassed ? '终验通过' : '终验未通过'));
  await capture('03-narrow-rounds');
  await click('ai.children.rounds.verify');
  assert.match(text(await visible('ai.children.rounds.verification')), /核对空输入提示/);
  await capture('04-narrow-verification');
} catch (failure) {
  error = failure;
  await capture('failure').catch(() => {});
} finally {
  await zenit.request('POST', '/zerowork/windows', { action: 'quit' }).catch(() => {});
  server.closeAllConnections();
  server.close();
  await Promise.race([exited, new Promise(done => setTimeout(done, 6000))]);
  if (app.exitCode === null && app.signalCode === null) {
    app.kill();
    await exited;
  }
  await log.close();
  const result = { status: error || app.exitCode !== 0 ? 'failed' : 'passed', error: error ? String(error) : null, childCalls, exitCode: app.exitCode };
  await writeFile(join(out, 'report.json'), JSON.stringify(result, null, 2));
  await rm(isolation, { recursive: true, force: true });
  console.log(result);
  if (result.status === 'failed') process.exitCode = 1;
}
