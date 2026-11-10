/** Production assistant: 568 successful calls, over 512 history messages, no output cap, and durable completion. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, writeFile, readFile, open, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? '/private/tmp/zw-ai-limits-build');
const out = resolve(process.argv[2] ?? '/private/tmp/zw-ai-limits-evidence');
await mkdir(out, { recursive: true });
const isolated = await mkdtemp('/private/tmp/zw-ai-limits-');
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc'), zdot = join(isolated, 'zdot');
for (const path of [data, rpc, zdot]) await mkdir(path);
await writeFile(join(zdot, '.zshrc'), "PS1='steer-test%# '\n");
const frame = (delta: any) => 'data: ' + JSON.stringify({ choices: [{ index: 0, delta }] }) + '\n\n';
const done = 'data: [DONE]\n\n';
const wire = (name: string) => name.replaceAll('_', '_u').replaceAll('.', '__');
let held: any = null, last: any = null, fixtureFailure: string | null = null;
const requests: any[] = [];
const server = createServer(async (req, res) => {
  try {
    if (req.method !== 'POST') return res.end('{"data":[{"id":"steer-fixture"}]}');
    let raw = ''; for await (const part of req) raw += part;
    const body = JSON.parse(raw); requests.push(body);
    res.writeHead(200, { 'content-type': 'text/event-stream' }); res.flushHeaders();
    const call = (id: string, index: number) => ({ index, id, type: 'function', function: { name: wire('host.get_current_context'), arguments: '{}' } });
    if (requests.length === 1) {
      res.write(frame({ reasoning_content: '引导前：正在按原计划检查当前会话。' }));
      res.write(frame({ tool_calls: [call('old-plan', 0)] }));
      held = res; return;
    }
    assert(String(body.messages.findLast((m: any) => m.role === 'user')?.content).includes('STEER_INPUT'));
    assert(body.messages.some((m: any) => m.role === 'tool' && m.tool_call_id === 'old-plan' && m.content.includes('not_dispatched_due_to_new_input')));
    if (requests.length <= 19) {
      res.end(frame({ reasoning_content: `引导后：执行第 ${requests.length - 1} 批只读检查。` }) + frame({ tool_calls: Array.from({ length: requests.length === 2 ? 500 : 4 }, (_, i) => call(`new-${requests.length}-${i}`, i)) }) + done);
      return;
    }
    assert.equal(requests.length, 20);
    res.write(frame({ reasoning_content: '引导后：568 次检查已完成，准备汇总。' }));
    last = res;
  } catch (error) { fixtureFailure = String(error); res.end(); }
});
await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="sauber"\nfont_size=14\n[ai]\ndefault_provider="steer-fixture"\nstep_display="collapsed"\nfollow_up_mode="steer"\n[[ai.providers]]\nid="steer-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address() as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="steer-fixture"\ncontext_window=1000000\ndefault=true\nreasoning=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(join(prefix, 'bin/zerowork'), [], { env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZEROWORK_DATA_DIR: data, ZDOTDIR: zdot, ZEROWORK_AUTOCONNECT: '0', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: '' }, stdio: ['ignore', log.fd, log.fd] });
const ended = new Promise<void>(resolve => app.once('close', () => resolve()));
const alive = () => app.exitCode === null && app.signalCode === null;
const shown = (n: any) => n && n.visible !== false && !n.hidden && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const flat = (n: any): any[] => Array.isArray(n) ? n.flatMap(flat) : n ? [n, ...(n.children ?? []).flatMap(flat)] : [];
const text = (n: any) => flat(n).map(n => typeof n.text === 'string' ? n.text : '').join(' ');
const visible = (id: string) => h.waitFor(async () => { assert.equal(fixtureFailure, null); return (await h.query(id)).find(shown) ?? null; }, 15000);
const click = async (id: string) => { await visible(id); assert((await h.clickTestId(id)).ok, id); };
const send = async (value: string) => { await click('ai.prompt'); await h.type_(value); await click('ai.send'); };
const capture = async (name: string) => { assert((await h.screenshot(join(out, name + '.png'))).ok); await writeFile(join(out, name + '.json'), JSON.stringify({ headers: await h.query('ai.step_group.header'), inputs: await h.query('ai.followup.consumed'), skipped: await h.query('ai.request.unsent') }, null, 2)); };
const report: any = { status: 'running', checks: [] };
try {
  await h.waitForServerReady(60000); await h.resizeWindow(1440, 1000);
  await click('workspace.empty.local'); await visible('terminal.surface'); await click('toolbar.ai');
  await send('FIRST_TASK 检查当前会话');
  await h.waitFor(async () => held || null, 20000);
  await h.waitFor(async () => (await h.query('ai.step_group.header')).length === 1 || null, 10000);
  await send('STEER_INPUT 按补充信息继续检查'); await visible('ai.followup.pending');
  assert.equal(requests.length, 1, 'steering waits for the streaming response boundary');
  held.end(done); held = null;
  await h.waitFor(async () => { assert.equal(fixtureFailure, null); return last || null; }, 120000);
  await h.waitFor(async () => (await h.query('ai.step_group.header')).length === 2 || null, 15000);
  const groups = await h.query('ai.step_group.header'), bubble = await visible('ai.followup.consumed');
  assert.equal((await h.query('ai.followup.consumed')).length, 1, 'consumed input is rendered once');
  assert.equal((await h.query('ai.followup.pending')).length, 0);
  assert(groups[0].rect.y + groups[0].rect.h <= bubble.rect.y, 'old group precedes the input');
  assert(bubble.rect.y + bubble.rect.h <= groups[1].rect.y, 'new group follows the input');
  assert.equal(groups[0].rect.h, 32); assert.equal(groups[1].rect.h, 32);
  assert(!text(await h.query('ai.step_group.summary')).includes('失败'), 'skipped old plan does not fail its group');
  assert.equal((await h.query('ai.recovery')).length, 0);
  assert.equal(requests.length, 20, 'production runtime passes the former 16-round limit');
  assert(requests.every((request: any) => request.max_tokens === undefined), 'ordinary requests have no imposed output limit');
  assert(requests.at(-1).messages.length > 512, 'active context exceeds the old 512-message cap');
  report.history_messages = requests.at(-1).messages.length;
  report.context_bytes = requests.at(-1).messages.reduce((sum: number, message: any) => sum + Buffer.byteLength(message.content ?? ''), 0);
  assert(report.context_bytes > 512 * 1024, 'active text exceeds the old 512 KiB cap');
  const results = requests.at(-1).messages.filter((m: any) => m.role === 'tool' && String(m.tool_call_id).startsWith('new-'));
  assert.equal(results.length, 568, 'production runtime passes the former 64-call limit');
  assert(results.every((message: any) => JSON.parse(message.content).status === 'succeeded'), 'all 568 tool receipts report actual success');
  report.checks.push('20 model requests and 568 completed read-only calls without count limits; steering keeps the same task');
  report.checks.push('One consumed message lies between two distinct step groups; skipped old plan does not mark the group failed');
  await capture('01-steering-groups');
  await click('ai.step_group.header');
  await h.waitFor(async () => text(await h.query('ai.request.unsent')).includes('因新消息跳过') || null, 10000);
  await h.sleep(250);
  await visible('ai.request.unsent');
  await capture('02-skipped-old-plan');
  last.end(frame({ content: 'STEER_FINISHED 所有检查已完成。' }) + done); last = null;
  await h.waitFor(async () => text(await h.query('ai.response')).includes('STEER_FINISHED') || null, 15000);
  await h.waitFor(async () => !(await h.query('ai.stop')).some(shown) || null, 10000);
  assert.equal((await h.query('ai.followup.consumed')).length, 1);
  assert.equal((await h.query('ai.recovery')).length, 0);
  const journal = (await readFile(join(data, 'ai-sessions.jsonl'), 'utf8')).trim().split('\n').map(s => JSON.parse(s));
  const consumed = journal.filter((e: any) => e.receipt?.delivery === 'consumed').map((e: any) => e.receipt);
  assert.equal(consumed.length, 2); assert.equal(consumed[0].turn, consumed[1].turn);
  await capture('03-completed'); report.status = 'passed';
} catch (error) { report.status = 'failed'; report.error = String(error); process.exitCode = 1; await capture('failure').catch(() => {}); }
finally {
  if (held) held.destroy(); if (last) last.destroy();
  try { if (alive()) { await h.request('POST', '/zerowork/windows', { action: 'quit' }); await Promise.race([ended, h.sleep(15000)]); } } catch (error) { report.quit_error = String(error); }
  if (alive()) { report.forced = true; app.kill('SIGTERM'); await ended; }
  report.exit_code = app.exitCode; report.signal = app.signalCode; report.requests = requests.length;
  if (report.forced || app.exitCode !== 0) { report.status = 'failed'; process.exitCode = 1; }
  server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve()));
  await log.close(); await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  await rm(isolated, { recursive: true, force: true });
  console.log(JSON.stringify(report));
}
