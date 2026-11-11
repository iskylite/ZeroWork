/** Restored interrupted display, process disclosure and Markdown topic spacing.
 * Creates its own journal with a loopback provider, then converts only that
 * isolated journal to the legacy partial-snapshot shape while the App is closed.
 * node e2e/ai_restored_partial_native.ts <test-mode prefix> <output directory>
 */
import assert from 'node:assert/strict';
import {execFile, spawn, type ChildProcess} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, open, readFile, realpath, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';

const prefix = resolve(process.argv[2]);
const out = resolve(process.argv[3]);
const isolated = await realpath(await mkdtemp('/tmp/zw-restored-partial-'));
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc'), zdot = join(isolated, 'zdot');
await Promise.all([mkdir(data), mkdir(rpc), mkdir(zdot), mkdir(out, {recursive: true})]);
await writeFile(join(zdot, '.zshrc'), "PS1='restore-fixture%# '\n");
const response = '已读取终端，保留当前收到的答复。\n\n---\n\n## 下一步\n完成只读检查后，根据结果确定参数。\n\n```text\n---\n```\n\nRESTORED_PARTIAL_MARKER';
const frame = (delta: unknown) => 'data: ' + JSON.stringify({choices: [{index: 0, delta}]}) + '\n\n';
let modelCalls = 0;
const server = createServer(async (req, res) => {
  if (req.method !== 'POST') { res.end('{"data":[{"id":"restore-fixture"}]}'); return; }
  let raw = ''; for await (const part of req) raw += part;
  const body = JSON.parse(raw);
  res.writeHead(200, {'content-type': 'text/event-stream'});
  if (!body.tools?.length) { res.end(frame({content: '恢复检查'}) + 'data: [DONE]\n\n'); return; }
  modelCalls++;
  if (!body.messages.some((m: any) => m.role === 'tool')) {
    const tool = body.tools.find((t: any) => t.function.name === 'host__read_uterminal');
    assert(tool);
    const session_ref = tool.function.parameters.properties.session_ref.enum[0];
    res.end(frame({reasoning_content: '先读取终端，再说明结果。'}) + frame({tool_calls: [{index: 0, id: 'read-once', type: 'function', function: {name: tool.function.name, arguments: JSON.stringify({session_ref, max_lines: 5})}}]}) + 'data: [DONE]\n\n');
  } else res.end(frame({content: response}) + 'data: [DONE]\n\n');
});
await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\n[ai]\ndefault_provider="restore-fixture"\n[[ai.providers]]\nid="restore-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address() as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="restore-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const log = await open(join(out, 'app.log'), 'w');
let app: ChildProcess;
const shown = (n: any) => n && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const flat = (n: any): any[] => Array.isArray(n) ? n.flatMap(flat) : n ? [n, ...(n.children ?? []).flatMap(flat)] : [];
const text = (n: any) => flat(n).map(n => n.text ?? '').join(' ');
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 20000);
const report: any = {status: 'running', isolated, checks: []};
const click = async (id: string) => { report.last_action = id; await visible(id); assert((await h.clickTestId(id)).ok); };
async function launch() {
  app = spawn(join(prefix, 'bin/zerowork'), [], {env: {...process.env, ZEROWORK_DATA_DIR: data, ZDOTDIR: zdot, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'}, stdio: ['ignore', log.fd, log.fd]});
  await h.waitForServerReady(60000);
  await h.waitFor(async () => Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid) === app.pid || null, 10000);
  await h.resizeWindow(1280, 960);
}
async function quit() {
  if (!app || app.exitCode !== null || app.signalCode !== null) return;
  const ended = new Promise<void>(r => app.once('close', () => r()));
  // The harness /quit closes a window; this multi-window App may then remain
  // in the menu bar. Send normal application termination to this exact PID.
  await new Promise<void>((done, reject) => execFile('/usr/bin/swift', ['-e', `import AppKit; if let app = NSRunningApplication(processIdentifier: ${app.pid}) { _ = app.terminate() }`], error => error ? reject(error) : done()));
  const start = performance.now();
  while (app.exitCode === null && app.signalCode === null && performance.now() - start < 15000) {
    try {
      for (const id of ['groups.close.accept', 'local.close.accept', 'session.close.accept', 'ai.session.close.accept']) {
        if ((await h.query(id)).some(shown)) await h.clickTestId(id);
      }
    } catch { if (app.exitCode !== null || app.signalCode !== null) break; }
    await Promise.race([ended, h.sleep(80)]);
  }
  assert.equal(app.exitCode, 0, 'owned test App quits normally');
  assert.equal(app.signalCode, null);
}
async function capture(name: string) {
  assert((await h.screenshot(join(out, name + '.png'))).ok);
  await writeFile(join(out, name + '.json'), JSON.stringify(await h.query('ai.panel'), null, 2));
}
try {
  await launch();
  await click('workspace.empty.local'); await visible('terminal.surface'); await click('toolbar.ai');
  await click('ai.prompt'); await h.type_('检查终端并说明后续步骤'); await click('ai.send');
  await visible('ai.turn.complete'); await visible('ai.turn.process.toggle');
  assert.equal((await h.query('ai.step_group')).filter(shown).length, 0, 'completed process initially folded');
  await visible('ai.message.section_gap');
  assert(text(await h.query('ai.response')).includes('RESTORED_PARTIAL_MARKER'));
  await capture('01-completed');
  await quit();

  // Compatibility fixture: interrupted answer-only response, no completion
  // timestamp/answer, with independently retained prose and old monotonic time.
  const journal = join(data, 'ai-sessions.jsonl');
  const lines = (await readFile(journal, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  let changed = 0;
  for (const line of lines) {
    if (line.event?.presentation) {
      const snapshot = JSON.parse(line.event.presentation);
      for (const message of snapshot.messages) {
        const turn = message.turn;
        if (!turn?.prose.includes('RESTORED_PARTIAL_MARKER')) continue;
        turn.ended_at_ms = null; turn.answer = ''; turn.elapsed_ms = 24000;
        const last = turn.timeline.at(-1)?.message;
        assert(last); last.ended_ms = null;
        changed++;
      }
      line.event.presentation = JSON.stringify(snapshot);
    }
    if (line.event?.task_fact) line.event.task_fact.status = 'interrupted';
    if (line.messages?.at(-1)?.content?.includes('RESTORED_PARTIAL_MARKER')) line.messages.pop();
  }
  assert(changed > 0);
  await writeFile(journal, lines.map(line => JSON.stringify(line)).join('\n') + '\n');
  const originalCalls = modelCalls;
  await launch();
  await click('workspace.empty.local'); await visible('terminal.surface'); await click('toolbar.ai');
  await click('ai.sessions'); await click('ai.session.restore.1');
  if ((await h.query('ai.session.close.accept')).some(shown)) await click('ai.session.close.accept');
  await visible('ai.turn.interrupted'); await visible('ai.turn.process.toggle');
  assert.equal((await h.query('ai.turn.divider')).length, 0, 'process disclosure has no separator line');
  assert.equal((await h.query('ai.turn.running')).filter(shown).length, 0);
  assert.equal((await h.query('ai.step_group')).filter(shown).length, 0, 'recovered process initially folded');
  assert.equal(text(await h.query('ai.response')).split('RESTORED_PARTIAL_MARKER').length - 1, 1, 'partial response remains visible once');
  const elapsed = text(await h.query('ai.turn.elapsed'));
  await h.sleep(1200);
  assert.equal(text(await h.query('ai.turn.elapsed')), elapsed, 'historical timer stays frozen');
  await visible('ai.message.section_gap');
  await capture('02-restored-collapsed');
  await click('ai.turn.process.toggle'); await visible('ai.step_group');
  assert.equal(text(await h.query('ai.response')).split('RESTORED_PARTIAL_MARKER').length - 1, 1);
  await capture('03-restored-expanded');
  assert.equal(modelCalls, originalCalls, 'restart and restore do not request the provider or replay a tool');
  report.checks.push('Fresh completed turn and restored interrupted turn both fold process content', 'Interrupted response stays visible once without a live timer or completion claim', 'Markdown sections use whitespace; fenced rule text is retained', 'Restoring history sends no model request and replays no tool');
  await quit(); report.status = 'passed';
} catch (error) {
  report.status = 'failed'; report.error = String(error); process.exitCode = 1;
  await capture('failure').catch(() => {});
  await quit().catch(e => { report.quit_error = String(e); });
} finally {
  server.closeAllConnections(); await new Promise<void>(r => server.close(() => r()));
  await log.close(); report.modelCalls = modelCalls;
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
}
