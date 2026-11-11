/** Production transcript: steering boundaries, skipped old plans, and >16 rounds / >64 calls. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, writeFile, readFile, open, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? '/private/tmp/zw-ai-steer-build');
const out = resolve(process.argv[2] ?? '/private/tmp/zw-ai-steer-evidence');
await mkdir(out, { recursive: true });
const isolated = await mkdtemp('/private/tmp/zw-ai-steer-');
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
    if (requests.length > 20) {
      res.end(frame({ content: 'FOLLOWUP_ACTIONS_COMPLETE' }) + done);
      return;
    }
    assert(String(body.messages.findLast((m: any) => m.role === 'user')?.content).includes('STEER_INPUT'));
    assert(body.messages.some((m: any) => m.role === 'tool' && m.tool_call_id === 'old-plan' && m.content.includes('not_dispatched_due_to_new_input')));
    if (requests.length <= 19) {
      res.end(frame({ reasoning_content: `引导后：执行第 ${requests.length - 1} 批只读检查。` }) + frame({ tool_calls: Array.from({ length: requests.length === 2 ? 20 : 4 }, (_, i) => call(`new-${requests.length}-${i}`, i)) }) + done);
      return;
    }
    assert.equal(requests.length, 20);
    res.write(frame({ reasoning_content: '引导后：88 次检查已完成，准备汇总。' }));
    last = res;
  } catch (error) { fixtureFailure = String(error); res.end(); }
});
await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="sauber"\nfont_size=14\n[ai]\ndefault_provider="steer-fixture"\nstep_display="collapsed"\nfollow_up_mode="steer"\n[[ai.providers]]\nid="steer-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address() as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="steer-fixture"\ncontext_window=200000\ndefault=true\nreasoning=true\n`);
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
  await h.waitFor(async () => { assert.equal(fixtureFailure, null); return last || null; }, 60000);
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
  const results = requests.at(-1).messages.filter((m: any) => m.role === 'tool' && String(m.tool_call_id).startsWith('new-'));
  assert.equal(results.length, 88, 'production runtime passes the former 64-call limit');
  assert(results.every((message: any) => JSON.parse(message.content).status === 'succeeded'), 'all 88 tool receipts report actual success');
  report.checks.push('20 model requests and 88 completed read-only calls without count limits; steering keeps the same task');
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
  const toggle = await visible('ai.turn.process.toggle');
  const answer = (await h.query('ai.response')).find((n: any) => shown(n) && text(n).includes('STEER_FINISHED'));
  const footer = await visible('ai.turn.complete');
  assert(answer && toggle.rect.y + toggle.rect.h <= answer.rect.y && answer.rect.y + answer.rect.h <= footer.rect.y, 'process toggle precedes the answer and the original summary follows it');
  const footerIds = new Set(flat(footer).map((n: any) => n.test_id));
  assert(['ai.turn.logo', 'ai.turn.tokens', 'ai.turn.copy', 'ai.turn.fork'].every(id => footerIds.has(id)), 'original summary controls stay together');
  assert.equal(text(footer).includes('～回合结束～'), true);
  assert.equal(text(toggle).trim(), '回合完成');
  assert.equal((await h.query('ai.followup.consumed')).length, 0, 'completed process starts collapsed');
  await click('ai.turn.process.toggle');
  await visible('ai.followup.consumed');
  assert.equal((await visible('ai.turn.complete')).id, footer.id, 'expanding process leaves the summary intact');
  report.checks.push('The process toggle is separate; the original summary remains below the final answer');
  assert.equal((await h.query('ai.followup.consumed')).length, 1);
  const journal = (await readFile(join(data, 'ai-sessions.jsonl'), 'utf8')).trim().split('\n').map(s => JSON.parse(s));
  const consumed = journal.filter((e: any) => e.receipt?.delivery === 'consumed').map((e: any) => e.receipt);
  assert.equal(consumed.length, 2); assert.equal(consumed[0].turn, consumed[1].turn);
  await capture('03-completed');
  // Consumed inputs use the production user-message actions and exact identity.
  const original = 'STEER_INPUT 按补充信息继续检查';
  const edited = 'STEER_INPUT 已修改的补充信息';
  await visible('ai.followup.copy'); await visible('ai.followup.edit'); await visible('ai.followup.rewind');
  await click('ai.followup.copy'); await click('ai.prompt'); await h.key('v', { cmd: true });
  assert.equal((await h.inputState('ai.prompt')).buffer, original);
  await h.key('a', { cmd: true }); await h.key('backspace');
  await click('ai.followup.edit'); await visible('ai.message.edit.input');
  await click('ai.message.edit.input'); await h.key('a', { cmd: true }); await h.type_('CANCELLED_EDIT');
  await click('ai.followup.edit.cancel');
  assert(text(await h.query('ai.followup.consumed')).includes(original));
  await click('ai.followup.edit'); await click('ai.message.edit.input');
  assert.equal((await h.inputState('ai.message.edit.input')).buffer, original);
  await h.key('a', { cmd: true }); await h.type_(edited); await click('ai.followup.edit.save');
  await h.waitFor(async () => text(await h.query('ai.followup.consumed')).includes(edited) || null, 10000);
  assert.equal(requests.length, 20, 'editing does not send a request');
  await capture('04-edited-input');
  await send('CONTINUE_AFTER_EDIT');
  await h.waitFor(async () => text(await h.query('ai.response')).includes('FOLLOWUP_ACTIONS_COMPLETE') || null, 15000);
  await h.waitFor(async () => !(await h.query('ai.stop')).some(shown) || null, 10000);
  assert(requests[20].messages.some((m: any) => m.role === 'user' && m.content === edited));
  assert(!requests[20].messages.some((m: any) => m.role === 'user' && m.content === original));
  await h.resizeWindow(860, 480); await capture('05-compact-actions');
  await click('ai.followup.rewind');
  await h.waitFor(async () => (await h.inputState('ai.prompt')).buffer === edited || null, 10000);
  assert.equal((await h.query('ai.followup.consumed')).length, 0, 'discarded receipt does not resurrect the input');
  assert(!text(await h.query('ai.conversation')).includes('FOLLOWUP_ACTIONS_COMPLETE'));
  assert.equal((await h.query('ai.step_group.header')).length, 1, 'pre-input group remains');
  assert(text(await h.query('ai.message.user.text')).includes('FIRST_TASK'));
  assert.equal(requests.length, 21, 'rewind does not send a request');
  await capture('06-rewound-prefix');
  await click('ai.prompt'); await h.key('a', { cmd: true }); await h.type_('REPLACEMENT_AFTER_REWIND'); await click('ai.send');
  await h.waitFor(async () => requests.length === 22 || null, 15000);
  await h.waitFor(async () => !(await h.query('ai.stop')).some(shown) || null, 10000);
  const replacement = requests[21].messages;
  assert(replacement.some((m: any) => m.role === 'user' && String(m.content).includes('FIRST_TASK')));
  assert(!JSON.stringify(replacement).includes(edited));
  assert(!JSON.stringify(replacement).includes('CONTINUE_AFTER_EDIT'));
  assert(!replacement.some((m: any) => String(m.tool_call_id).startsWith('new-')));
  assert(replacement.some((m: any) => m.tool_call_id === 'old-plan'), 'earlier result remains in context');
  report.checks.push('Consumed steering input supports exact copy, cancel/save edits without sending, and edited text reaches the next model request');
  report.checks.push('Rewind restores edited input, removes later turns/tool context, preserves the earlier group/context, and never resurrects the consumed receipt');
  await capture('07-replacement-complete'); report.status = 'passed';
} catch (error) { report.status = 'failed'; report.error = error instanceof Error ? error.stack ?? error.message : String(error); process.exitCode = 1; await capture('failure').catch(() => {}); }
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
