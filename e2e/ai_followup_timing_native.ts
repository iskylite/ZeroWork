/** Follow-up admission, response-boundary consumption, and paused-input recovery. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, writeFile, readFile, open, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const prefix = resolve(process.argv[2] ?? '/private/tmp/zw-followup-build');
const out = resolve(process.argv[3] ?? '/private/tmp/zw-followup-evidence');
await mkdir(out, { recursive: true });
const isolated = await mkdtemp('/private/tmp/zw-followup-');
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc'), zdot = join(isolated, 'zdot');
for (const path of [data, rpc, zdot]) await mkdir(path);
await writeFile(join(zdot, '.zshrc'), "PS1='followup-test%# '\n");
const frame = (delta: any) => 'data: ' + JSON.stringify({ choices: [{ index: 0, delta }] }) + '\n\n';
const done = 'data: [DONE]\n\n';
const requests: any[] = [];
let held: any = null, fixtureFailure: string | null = null;
const server = createServer(async (req, res) => {
  try {
    if (req.method !== 'POST') return res.end('{"data":[{"id":"followup-fixture"}]}');
    let raw = ''; for await (const part of req) raw += part;
    const body = JSON.parse(raw);
    res.writeHead(200, { 'content-type': 'text/event-stream' }); res.flushHeaders();
    if (!body.tools?.length) return res.end(frame({ content: '消息引导验证' }) + done);
    requests.push(body);
    if (requests.length === 2) {
      assert(String(body.messages.findLast((m: any) => m.role === 'user')?.content).includes('STEER_ONE'));
      assert(body.messages.some((m: any) => m.role === 'assistant' && String(m.content).includes('第一段')));
      return res.end(frame({ content: 'STEER_FINISHED 已按补充信息完成。' }) + done);
    }
    assert(requests.length === 1 || requests.length === 3);
    res.write(frame({ reasoning_content: '正在处理当前任务。' }));
    res.write(frame({ content: requests.length === 1 ? '第一段响应仍在继续。' : '等待补充消息，验证停止后的保留。' }));
    held = res;
  } catch (error) { fixtureFailure = String(error); res.end(); }
});
await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="sauber"\nfont_size=14\n[ai]\ndefault_provider="followup-fixture"\nfollow_up_mode="steer"\n[[ai.providers]]\nid="followup-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address() as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="followup-fixture"\ncontext_window=200000\ndefault=true\nreasoning=true\n`);
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
const sendHint = async (expected: string) => {
  const button = await visible('ai.send');
  await h.mouseMove(button.rect.x + button.rect.w / 2, button.rect.y + button.rect.h / 2);
  await visible('ai.send.tooltip');
  await h.waitFor(async () => text(await h.query('ai.send.tooltip')).includes(expected) || null, 10000);
  await h.mouseMove(20, 20);
};
const capture = async (name: string) => { assert((await h.screenshot(join(out, name + '.png'))).ok); };
const report: any = { status: 'running', checks: [] };
try {
  await h.waitForServerReady(60000); await h.resizeWindow(1440, 1000);
  await click('workspace.empty.local'); await visible('terminal.surface'); await click('toolbar.ai');
  await send('FIRST_TASK 检查消息引导');
  await h.waitFor(async () => held || null, 15000);
  await sendHint('引导当前任务');
  await send('STEER_ONE 按补充信息继续');
  await visible('ai.followup.pending');
  assert(text(await h.query('ai.followup.status')).includes('待处理'));
  assert.equal(requests.length, 1, 'acceptance does not restart the in-flight response');
  const status = await visible('ai.followup.status');
  await h.mouseMove(status.rect.x + status.rect.w / 2, status.rect.y + status.rect.h / 2);
  await visible('ai.followup.waiting_hint');
  assert(text(await h.query('ai.followup.waiting_hint')).includes('当前响应结束后处理'));
  await capture('01-pending-response');
  await h.mouseMove(20, 20);
  const response = held; held = null; response.end(done);
  await h.waitFor(async () => text(await h.query('ai.response')).includes('STEER_FINISHED') || null, 15000);
  await h.waitFor(async () => !(await h.query('ai.stop')).some(shown) || null, 15000);
  // Completion alone refreshes the hint, without another composer edit.
  await sendHint('发送问题');
  assert.equal((await h.query('ai.followup.consumed')).length, 1);
  assert.equal((await h.query('ai.followup.pending')).length, 0);
  assert.equal((await h.query('ai.followup.status')).length, 0);
  const journal = (await readFile(join(data, 'ai-sessions.jsonl'), 'utf8')).trim().split('\n').map(s => JSON.parse(s));
  const consumed = journal.filter((e: any) => e.receipt?.delivery === 'consumed').map((e: any) => e.receipt);
  assert.equal(consumed.length, 2); assert.equal(consumed[0].turn, consumed[1].turn);
  await capture('02-consumed');
  report.checks.push('Pending response tooltip; no premature request; one consumed message in the same turn; waiting label removed.');
  await send('SECOND_TASK 检查未消费消息保留');
  await h.waitFor(async () => held || null, 15000);
  await send('STEER_PAUSED 停止后保留这条补充');
  await visible('ai.followup.pending');
  await click('ai.stop');
  await h.waitFor(async () => !(await h.query('ai.stop')).some(shown) || null, 15000);
  await h.waitFor(async () => text(await h.query('ai.followup.status')).includes('已暂停') || null, 15000);
  await visible('ai.followup.restore');
  await capture('03-paused');
  await click('ai.followup.restore');
  await h.waitFor(async () => String((await h.inputState('ai.prompt')).buffer).includes('STEER_PAUSED') || null, 10000);
  assert.equal(requests.length, 3, 'restoring a draft never automatically resends it');
  report.checks.push('Stop preserves unconsumed input; restore copies to composer without resending.');
  await capture('04-restored-draft');
  report.status = 'passed';
} catch (error) { report.status = 'failed'; report.error = String(error); process.exitCode = 1; await capture('failure').catch(() => {}); }
finally {
  if (held) held.destroy();
  try { if (alive()) { await h.request('POST', '/zerowork/windows', { action: 'quit' }); await Promise.race([ended, h.sleep(15000)]); } } catch (error) { report.quit_error = String(error); }
  if (alive()) { report.forced = true; app.kill('SIGTERM'); await ended; }
  report.exit_code = app.exitCode; report.signal = app.signalCode; report.requests = requests.length;
  if (report.forced || app.exitCode !== 0) { report.status = 'failed'; process.exitCode = 1; }
  server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve()));
  await log.close(); await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  await rm(isolated, { recursive: true, force: true });
  console.log(JSON.stringify(report));
}
