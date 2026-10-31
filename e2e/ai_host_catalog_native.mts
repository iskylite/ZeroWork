/** Isolated native saved-host approval and durable request-key acceptance.
 * ZW_AI_TEST_PREFIX=/private/tmp/zw-current-tab-scope-build node e2e/ai_host_catalog_native.mts /private/tmp/zw-host-catalog-native
 * Uses a deterministic loopback provider and one real Local Tab. No SSH
 * connection is requested and no production host/configuration is read.
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, writeFile, readFile, open, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? '/private/tmp/zw-current-tab-scope-build');
const out = resolve(process.argv[2] ?? '/private/tmp/zw-host-catalog-native');
await mkdir(out, { recursive: true });
const iso = await mkdtemp('/private/tmp/zw-host-catalog-native-');
const data = join(iso, 'data'), rpc = join(iso, 'rpc'), zdot = join(iso, 'zdot');
for (const dir of [data, rpc, zdot]) await mkdir(dir);
await writeFile(join(zdot, '.zshrc'), "bindkey -e\nPS1='catalog-fixture%# '\n");
await writeFile(join(data, 'hosts.toml'), '[[hosts]]\nname="static-seed"\nhost="192.0.2.10"\nuser="fixture"\nstartup_commands=["CATALOG_DO_NOT_EXPOSE"]\n');

const frame = (delta: any) => 'data: ' + JSON.stringify({ choices: [{ index: 0, delta }] }) + '\n\n';
const wireName = (name: string) => name.replaceAll('_', '_u').replaceAll('.', '__');
const payload = (envelope: any) => {
  for (const block of envelope.content ?? []) try { return JSON.parse(block.text); } catch {}
  return envelope;
};
const createArgs = { request_key: 'catalog-save-once', name: 'catalog-created', host: '192.0.2.42', port: 2222, user: 'fixture', auth_mode: 'password' };
const requests: any[] = [], observed: Record<string, any> = {};
let fixtureFailure: string | null = null, approvalPhase = '', baseline = '';
const server = createServer(async (req, res) => {
  try {
    let raw = ''; for await (const chunk of req) raw += chunk;
    if (!raw) return res.end('{"data":[{"id":"catalog-fixture"}]}');
    const body = JSON.parse(raw); requests.push(body);
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const results = new Map(body.messages.filter((m: any) => m.role === 'tool').map((m: any) => [m.tool_call_id, payload(JSON.parse(m.content))]));
    for (const [id, value] of results) observed[String(id)] = value;
    const emit = async (calls: { id: string, name: string, args: any }[]) => {
      await new Promise(done => setTimeout(done, 300));
      res.end(frame({ tool_calls: calls.map((call, index) => ({ index, id: call.id, type: 'function', function: { name: wireName(call.name), arguments: JSON.stringify(call.args) } })) }) + 'data: [DONE]\n\n');
    };
    const defs = new Set((body.tools ?? []).map((tool: any) => tool.function.name));
    for (const name of ['host.list_hosts', 'host.get_host', 'host.create_host']) assert(defs.has(wireName(name)), name + ' must be advertised');
    for (const name of ['host.update_host', 'host.delete_host']) assert(!defs.has(wireName(name)), name + ' must not be advertised');
    if (!results.has('catalog-list-initial')) return emit([{ id: 'catalog-list-initial', name: 'host.list_hosts', args: {} }]);
    const initial: any = results.get('catalog-list-initial');
    assert.equal(initial.hosts.length, 1);
    assert.deepEqual(Object.keys(initial.hosts[0]).sort(), ['source_ref', 'name', 'protocol', 'host', 'port', 'user'].sort());
    assert.equal(initial.hosts[0].name, 'static-seed');
    assert(!JSON.stringify(initial).includes('CATALOG_DO_NOT_EXPOSE'));
    if (!results.has('catalog-reject')) {
      approvalPhase = 'reject';
      return emit([
        { id: 'catalog-get-initial', name: 'host.get_host', args: { source_ref: initial.hosts[0].source_ref } },
        { id: 'catalog-update-unavailable', name: 'host.update_host', args: { source_ref: initial.hosts[0].source_ref, host: '192.0.2.99' } },
        { id: 'catalog-delete-unavailable', name: 'host.delete_host', args: { source_ref: initial.hosts[0].source_ref } },
        { id: 'catalog-reject', name: 'host.create_host', args: { ...createArgs, request_key: 'catalog-denied-once' } },
      ]);
    }
    assert(JSON.stringify(results.get('catalog-update-unavailable')).includes('ToolNotInRequest'));
    assert(JSON.stringify(results.get('catalog-delete-unavailable')).includes('ToolNotInRequest'));
    assert.equal((results.get('catalog-reject') as any).state, 'rejected');
    if (!results.has('catalog-save')) {
      assert.equal(await readFile(join(data, 'hosts.toml'), 'utf8'), baseline, 'rejected create and unavailable update/delete must not change saved hosts');
      approvalPhase = 'save';
      return emit([
        { id: 'catalog-list-after-reject', name: 'host.list_hosts', args: {} },
        { id: 'catalog-save', name: 'host.create_host', args: createArgs },
      ]);
    }
    const saved: any = results.get('catalog-save');
    assert.equal(saved.saved, true); assert.equal(saved.connection_started, false); assert.equal(saved.idempotent_reuse, false);
    assert.match(saved.operation_ref, /^o1:/); assert.match(saved.host.source_ref, /^c1:/);
    assert.equal((results.get('catalog-list-after-reject') as any).hosts.length, 1);
    if (!results.has('catalog-replay')) {
      approvalPhase = 'collision';
      return emit([
        { id: 'catalog-replay', name: 'host.create_host', args: createArgs },
        { id: 'catalog-key-conflict', name: 'host.create_host', args: { ...createArgs, host: '192.0.2.99' } },
        { id: 'catalog-name-conflict', name: 'host.create_host', args: { ...createArgs, request_key: 'catalog-no-overwrite', host: '192.0.2.99' } },
      ]);
    }
    const replay: any = results.get('catalog-replay');
    assert.equal(replay.saved, true); assert.equal(replay.idempotent_reuse, true);
    assert.equal(replay.operation_ref, saved.operation_ref); assert.equal(replay.host.source_ref, saved.host.source_ref);
    assert(JSON.stringify(results.get('catalog-key-conflict')).includes('IdempotencyConflict'));
    const collision: any = results.get('catalog-name-conflict');
    assert.equal(collision.state, 'outcome_unknown'); // Dispatch was journaled before the atomic transaction refused the duplicate.
    if (!results.has('catalog-get-saved')) {
      approvalPhase = '';
      return emit([
        { id: 'catalog-list-final', name: 'host.list_hosts', args: {} },
        { id: 'catalog-get-saved', name: 'host.get_host', args: { source_ref: saved.host.source_ref } },
      ]);
    }
    const final: any = results.get('catalog-list-final'), exact: any = results.get('catalog-get-saved');
    assert.equal(final.hosts.length, 2); assert.equal(exact.source_ref, saved.host.source_ref); assert.equal(exact.host, '192.0.2.42');
    assert.deepEqual(final.hosts.find((value: any) => value.name === 'static-seed'), initial.hosts[0]);
    assert.equal(exact.port, 2222); assert(!final.hosts.some((value: any) => value.host === '192.0.2.99'));
    const disk = await readFile(join(data, 'hosts.toml'), 'utf8');
    assert.equal((disk.match(/\[\[hosts\]\]/g) ?? []).length, 2);
    assert(!disk.includes('192.0.2.99')); assert(!disk.includes('password_ref'));
    await writeFile(join(out, 'saved-hosts.toml'), disk);
    await writeFile(join(out, 'lifecycle.json'), await readFile(join(data, 'ai/lifecycle.json')));
    res.end(frame({ content: 'CATALOG_NATIVE_FINISHED' }) + 'data: [DONE]\n\n');
  } catch (error) {
    fixtureFailure = String(error);
    res.end(frame({ content: 'CATALOG_FIXTURE_ERROR: ' + fixtureFailure }) + 'data: [DONE]\n\n');
  }
});
await new Promise<void>(done => server.listen(0, '127.0.0.1', done));
await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="catalog-fixture"\npermission_mode="confirm"\n[[ai.providers]]\nid="catalog-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address() as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="catalog-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(join(prefix, 'bin/zerowork'), [], { env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZEROWORK_DATA_DIR: data, ZDOTDIR: zdot, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1' }, stdio: ['ignore', log.fd, log.fd] });
const ended = new Promise<any>(done => app.once('close', (code, signal) => done({ code, signal })));
const shown = (node: any) => node && node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect?.w > 0 && node.rect?.h > 0;
const flat = (node: any): any[] => Array.isArray(node) ? node.flatMap(flat) : node ? [node, ...(node.children ?? []).flatMap(flat)] : [];
const text = (node: any) => flat(node).map(value => value.text ?? '').join(' ');
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
const click = async (id: string) => { await visible(id); assert((await h.clickTestId(id)).ok); };
const report: any = { status: 'running', scope: 'Isolated native App, real Local Tab, deterministic loopback provider; saved-host reads/writes only, no SSH creation or production configuration accessed.', binary_sha256: createHash('sha256').update(await readFile(join(prefix, 'bin/zerowork'))).digest('hex'), approvals: [] };
try {
  await h.waitForServerReady(60000); await h.resizeWindow(1200, 900);
  await click('workspace.empty.local'); await visible('terminal.surface');
  baseline = await readFile(join(data, 'hosts.toml'), 'utf8');
  await click('toolbar.ai'); await click('ai.prompt'); await h.type_('CATALOG_NATIVE_ACCEPTANCE'); await click('ai.send');
  const handled = new Set<string>();
  let followupSent = false;
  await h.waitFor(async () => {
    assert.equal(fixtureFailure, null);
    if ((await h.query('ai.host_approval')).some(shown) && approvalPhase && !handled.has(approvalPhase)) {
      assert.equal(text(await h.query('ai.host_approval.title')), '保存新主机');
      assert.equal(text(await h.query('ai.host_approval.target')), createArgs.name);
      const summary = text(await h.query('ai.host_approval.summary'));
      const config = JSON.parse(summary);
      assert.equal(config.name, createArgs.name); assert.equal(config.host, approvalPhase === 'collision' ? '192.0.2.99' : createArgs.host);
      assert(!summary.includes('request_key')); assert(!summary.includes('c1:'));
      if (approvalPhase !== 'collision') assert.equal(await readFile(join(data, 'hosts.toml'), 'utf8'), baseline, 'pending confirmation must leave the saved host file unchanged');
      await h.screenshot(join(out, 'approval-' + approvalPhase + '.png'));
      report.approvals.push({ phase: approvalPhase, decision: approvalPhase === 'reject' ? 'reject' : 'approve', detail: config });
      handled.add(approvalPhase);
      await click(approvalPhase === 'reject' ? 'ai.host_approval.reject' : 'ai.host_approval.accept');
    }
    // A journaled dispatch that later refuses the duplicate is conservatively
    // unknown. The host stops that tool round; explicitly request a new
    // read-only observation to verify the saved catalog without replaying it.
    if (handled.has('collision') && !followupSent && !(await h.query('ai.stop')).some(shown)) {
      followupSent = true;
      await click('ai.prompt'); await h.type_('CATALOG_NATIVE_AFTER_CONFLICT_READ_ONLY'); await click('ai.send');
    }
    return text(await h.query('ai.panel')).includes('CATALOG_NATIVE_FINISHED') && !(await h.query('ai.stop')).some(shown) || null;
  }, 60000);
  assert.deepEqual([...handled], ['reject', 'save', 'collision']);
  await h.screenshot(join(out, 'catalog-final.png'));
  await writeFile(join(out, 'final-tree.json'), JSON.stringify(await h.query('ai.panel'), null, 2));
  report.status = 'passed';
  report.checks = ['list/get expose only six static fields and stable c1 refs', 'unknown update/delete tools are not advertised and return ToolNotInRequest', 'native rejection leaves host file unchanged', 'exact native approval saves one host through HostsTransaction without connecting', 'same request_key under a new call ID returns original operation and asset without another approval/save', 'changed arguments with same key return IdempotencyConflict', 'same name with a fresh key cannot overwrite the saved host', 'final catalog reads exactly the original and newly saved host'];
} catch (error) {
  report.status = 'failed'; report.error = String(error); report.fixture_failure = fixtureFailure; process.exitCode = 1;
  await h.screenshot(join(out, 'failure.png')).catch(() => {});
  await writeFile(join(out, 'failure-tree.json'), JSON.stringify(await h.tree(), null, 2)).catch(() => {});
} finally {
  try {
    if (app.exitCode === null && app.signalCode === null) {
      await h.request('POST', '/quit');
      await h.waitFor(async () => app.exitCode !== null || app.signalCode !== null || null, 10000);
    }
  } catch (error) { report.shutdown_error = String(error); app.kill('SIGTERM'); }
  report.shutdown = await ended;
  if (report.shutdown.code !== 0 || report.shutdown.signal !== null) { report.status = 'failed'; process.exitCode = 1; }
  server.closeAllConnections(); await new Promise<void>(done => server.close(() => done()));
  await log.close(); await rm(iso, { recursive: true, force: true });
  report.requests = requests.length; report.results = observed;
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ status: report.status, error: report.error, shutdown: report.shutdown, requests: report.requests, evidence: out }));
}
