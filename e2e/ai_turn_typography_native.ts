// Real macOS typography and disclosure, with one local SSE reply and no tools or credentials.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const folder = await realpath(await mkdtemp('/tmp/zw-turn-typography-'));
const data = join(folder, 'data'), rpc = join(folder, 'rpc');
const answerText = '你好！这是实际绘制的模型正文。';
const thought = '这是折叠的处理过程。';
let calls = 0;
const chunk = (delta: Record<string, string>) => `data: ${JSON.stringify({ choices: [{ index: 0, delta }] })}\n\n`;
const server = createServer(async (req, res) => {
  if (req.method === 'GET') return void res.end('{"data":[{"id":"turn-typography"}]}');
  assert.equal(req.headers.authorization, undefined);
  for await (const ignored of req) void ignored;
  calls++;
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  res.end(chunk({ reasoning_content: thought }) + chunk({ content: answerText }) + 'data: [DONE]\n\n');
});
let app: ReturnType<typeof spawn> | undefined, ended: Promise<any> | undefined;
let errors = '';
try {
  await mkdir(data, { mode: 0o700 });
  await mkdir(rpc, { mode: 0o700 });
  await mkdir(join(data, 'credentials'), { mode: 0o700 });
  await writeFile(join(data, 'credentials', '.local-storage'), '1', { mode: 0o600 });
  await new Promise<void>((ok, fail) => { server.once('error', fail); server.listen(0, '127.0.0.1', ok); });
  const port = (server.address() as { port: number }).port;
  await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="${process.argv.includes('--light') ? 'reference-light' : 'dark'}"\n[ai]\ndefault_provider="turn-fixture"\nstep_display="collapsed"\n[[ai.providers]]\nid="turn-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="turn-typography"\ncontext_window=32768\ndefault=true\nreasoning=true\n`);
  process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
  const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
  app = spawn(join(prefix, 'bin/zerowork'), [], { env: { ...process.env, ZEROWORK_DATA_DIR: data,
    ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1',
    ZW_TEST_CREDENTIAL_RESPONSE: 'cancel', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: '', ZDOTDIR: folder }, stdio: ['ignore', 'ignore', 'pipe'] });
  app.stderr?.on('data', data => { errors = (errors + String(data)).slice(-2000); });
  ended = once(app, 'close');
  const shown = (n: any) => n && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0.5 && n.rect?.w > 0 && n.rect?.h > 0;
  const get = async (id: string) => (await h.query(id)).find(shown);
  const see = (id: string) => h.waitFor(() => get(id), 10000);
  const click = async (id: string) => {
    const n = await see(id);
    assert((await h.clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok, id);
  };
  const flat = (n: any): any[] => [n, ...(n.children ?? []).flatMap(flat)];
  const text = (n: any) => flat(n).map(child => typeof child.text === 'string' ? child.text : '').join(' ').trim();
  await h.waitForServerReady(20000);
  assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
  await h.resizeWindow(1440, 900);
  await click('toolbar.new_session');
  await click('session.menu.ai');
  await click('ai.prompt');
  assert((await h.type_('验证回合正文和摘要层级')).ok);
  await click('ai.send');
  await see('ai.turn.complete');
  for (const [w, height] of [[1440, 900], [860, 480]]) {
    await h.resizeWindow(w, height);
    const footer = await see('ai.turn.complete'), answer = await see('ai.response'), toggle = await see('ai.turn.process.toggle');
    assert.equal(text(toggle), '处理过程');
    assert(text(answer).includes(answerText));
    const clocks = flat(footer).filter(n => n.test_id === 'ai.turn.elapsed' && shown(n));
    assert.equal(clocks.length, 1);
    assert(text(clocks[0]).includes('处理用时'));
    const body = flat(answer).find(n => typeof n.text === 'string' && n.text.includes(answerText) && shown(n));
    assert(body && body.rect.h > clocks[0].rect.h, 'rendered body must occupy a taller text line than elapsed metadata');
    assert(toggle.rect.y + toggle.rect.h + 7 <= answer.rect.y);
    assert(answer.rect.y + answer.rect.h <= footer.rect.y + 1);
    assert.equal(await get('ai.turn.process'), undefined);
    await click('ai.turn.process.toggle');
    await see('ai.turn.process');
    assert(text(await see('ai.response')).includes(answerText));
    await click('ai.turn.process.toggle');
    await h.waitFor(async () => !(await get('ai.turn.process')) || null, 5000);
  }
  await click('ai.turn.tokens');
  await see('ai.turn.usage.details');
  assert.equal(calls, 1, 'disclosure and usage details never call the model');
  console.log(`PASS native turn typography (${process.argv.includes('--light') ? '晴霜' : 'dark'}, wide and narrow)`);
} catch (error) {
  console.error(errors);
  throw error;
} finally {
  if (app?.exitCode === null) app.kill('SIGTERM');
  if (ended) await ended;
  server.closeAllConnections();
  if (server.listening) await new Promise<void>(ok => server.close(() => ok()));
  await rm(folder, { recursive: true, force: true });
}
