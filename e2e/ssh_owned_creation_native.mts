/** Compare saved-source new_only with the ordinary sidebar connection.
 * Uses only disposable configuration, a deterministic provider and owned
 * loopback SSH peer. No external model, host, or production App is accessed.
 * ZW_AI_TEST_PREFIX=/path/to/test-build node e2e/ssh_owned_creation_native.mts /tmp/evidence
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer as httpServer } from 'node:http';
import { createServer as tcpServer, createConnection } from 'node:net';
import { mkdir, mkdtemp, open, readFile, readdir, realpath, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? '/private/tmp/zw-handoff-retention-build');
const out = resolve(process.argv[2] ?? '/private/tmp/zw-ssh-owned-creation-native');
const resetFirst = process.argv[3] === 'reset-first';
const rejectAuth = process.argv[3] === 'reject-auth';
const rejectHostKey = process.argv[3] === 'reject-host-key';
const expectRejected = rejectAuth || rejectHostKey;
await mkdir(out, { recursive: true });
const iso = await realpath(await mkdtemp('/private/tmp/zw-ssh-owned-native-'));
const data = join(iso, 'data'), rpc = join(iso, 'rpc'), zdot = join(iso, 'zdot');
for (const directory of [data, rpc, zdot]) await mkdir(directory);
await writeFile(join(zdot, '.zshrc'), "bindkey -e\nPS1='owned-loopback%# '\n");
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const peerLog = await open(join(out, 'peer.log'), 'w');
const peer = spawn('python3', ['e2e/builtin_records_ssh_peer.py', '--out', join(out, 'peer'), ...(rejectAuth ? ['--reject-password'] : [])], { stdio: ['ignore', peerLog.fd, peerLog.fd] });
const peerEnded = new Promise(done => peer.once('close', done));
const ready = await h.waitFor(async () => {
  try { return JSON.parse(await readFile(join(out, 'peer/ready.json'), 'utf8')); } catch { return null; }
}, 15000);
const sockets = new Set<any>(), connections: any[] = [];
const proxy = tcpServer(client => {
  sockets.add(client);
  const connection: any = { index: connections.length + 1, client_port: client.remotePort, accepted: Date.now(), identification_bytes: 0, identification_hash: '0', identification_complete: false };
  connections.push(connection);
  let hash = 14695981039346656037n;
  client.on('data', bytes => {
    for (const byte of bytes) {
      if (connection.identification_complete) break;
      hash = BigInt.asUintN(64, (hash ^ BigInt(byte)) * 1099511628211n);
      ++connection.identification_bytes;
      if (byte === 10) connection.identification_complete = true;
    }
    connection.identification_hash = hash.toString(16);
    if (resetFirst && connection.index === 1 && connection.identification_complete) {
      connection.reset_before_server_banner = true;
      client.resetAndDestroy();
    }
  });
  if (resetFirst && connection.index === 1) {
    client.on('error', error => { connection.socket_error = String(error); });
    client.on('close', () => sockets.delete(client));
    return;
  }
  const upstream = createConnection({ host: '127.0.0.1', port: ready.port });
  sockets.add(upstream);
  for (const socket of [client, upstream]) {
    socket.on('error', error => { connection.socket_error = String(error); client.destroy(); upstream.destroy(); });
    socket.on('close', () => sockets.delete(socket));
  }
  client.pipe(upstream); upstream.pipe(client);
});
await new Promise<void>(done => proxy.listen(0, '127.0.0.1', done));
const port = (proxy.address() as any).port;
await writeFile(join(data, 'known_hosts'), rejectHostKey ? '' : ready.known_host.replace(`[127.0.0.1]:${ready.port}`, `[127.0.0.1]:${port}`));
await writeFile(join(data, 'hosts.toml'), `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="Owned loopback comparison"\nhost="127.0.0.1"\nport=${port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\noptions={strict_host_key=true}\n`);
const frame = (delta: any) => 'data: ' + JSON.stringify({ choices: [{ index: 0, delta }] }) + '\n\n';
const wire = (name: string) => name.replaceAll('_', '_u').replaceAll('.', '__');
const payload = (envelope: any) => { for (const block of envelope.content ?? []) try { return JSON.parse(block.text); } catch {} return envelope; };
const calls: any[] = [], results: any = {};
let providerFailure: string | null = null, ownedSettled = false;
const provider = httpServer(async (request, response) => {
  try {
    let raw = ''; for await (const chunk of request) raw += chunk;
    if (!raw) return response.end('{"data":[{"id":"owned-loopback"}]}');
    const body = JSON.parse(raw);
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    const map = new Map(body.messages.filter((message: any) => message.role === 'tool').map((message: any) => [message.tool_call_id, JSON.parse(message.content)]));
    const result = (id: string): any => {
      const envelope: any = map.get(id); if (!envelope) return null;
      if (!(expectRejected && id.startsWith('owned-ready-'))) assert.equal(envelope.status, 'succeeded', id + ': ' + JSON.stringify(envelope));
      return results[id] = payload(envelope);
    };
    const emit = (id: string, name: string, args: any) => {
      assert(!calls.some(call => call.id === id), 'a creation call must not be replayed');
      calls.push({ id, name, args });
      response.end(frame({ tool_calls: [{ index: 0, id, type: 'function', function: { name: wire(name), arguments: JSON.stringify(args) } }] }) + 'data: [DONE]\n\n');
    };
    const context = result('owned-context'); if (!context) return emit('owned-context', 'host.get_current_context', {});
    const group = result('owned-group'); if (!group) return emit('owned-group', 'host.create_group', { initial_session_ref: context.binding_ref, name: 'SSH ownership comparison', request_key: 'owned-group-once' });
    const moved = result('owned-moved'); if (!moved) return emit('owned-moved', 'host.get_current_context', {});
    assert.equal(moved.binding_ref, group.group_ref);
    const catalog = result('owned-catalog'); if (!catalog) return emit('owned-catalog', 'host.list_hosts', {});
    assert.equal(catalog.hosts.length, 1);
    assert(catalog.hosts[0].source_ref.startsWith('c1:'));
    const opened = result('owned-open'); if (!opened) return emit('owned-open', 'host.open_session', { group_ref: moved.binding_ref, source_ref: catalog.hosts[0].source_ref, connection_policy: 'new_only', retention: 'keep', request_key: 'owned-ssh-once' });
    let settled = opened;
    for (let i = 0; !['ready', 'failed', 'cancelled'].includes(settled.state) && i < 12; ++i) {
      const id = 'owned-ready-' + i, next = result(id);
      if (!next) return emit(id, 'host.wait_session_ready', { operation_ref: opened.operation_ref, after_revision: settled.source_revision, wait_ms: 5000 });
      settled = next;
    }
    assert.equal(settled.state, expectRejected ? 'failed' : 'ready'); assert.equal(settled.membership_committed, !expectRejected);
    assert.equal(settled.session_ref, opened.session_ref, 'retry must retain the original owned handle');
    assert.equal(settled.ownership, 'created_task'); ownedSettled = true;
    response.end(frame({ content: expectRejected ? 'OWNED_LOOPBACK_REJECTED' : 'OWNED_LOOPBACK_READY' }) + 'data: [DONE]\n\n');
  } catch (error) {
    providerFailure = String(error); response.end(frame({ content: 'FIXTURE_ERROR' }) + 'data: [DONE]\n\n');
  }
});
await new Promise<void>(done => provider.listen(0, '127.0.0.1', done));
await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ai]\ndefault_provider="owned-loopback"\npermission_mode="confirm"\nsession_retention="keep"\n[[ai.providers]]\nid="owned-loopback"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(provider.address() as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="owned-loopback"\ncontext_window=500000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(out, 'app.log'), 'w');
const app = spawn(join(prefix, 'bin/zerowork'), [], { env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZDOTDIR: zdot }, stdio: ['ignore', log.fd, log.fd] });
const ended = new Promise(done => app.once('close', done));
const shown = (node: any) => node && node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect?.w > 0 && node.rect?.h > 0;
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
const click = async (id: string) => { await visible(id); assert((await h.clickTestId(id)).ok, id); };
const report: any = { status: 'running', reset_first: resetFirst, reject_auth: rejectAuth, reject_host_key: rejectHostKey, binary_sha256: createHash('sha256').update(await readFile(join(prefix, 'bin/zerowork'))).digest('hex'), scope: 'Native product saved_source+new_only; optional first banner reset or host-key/auth rejection; successful cases compare ordinary sidebar creation. Deterministic provider and loopback SSH only.', limits: ['Does not reproduce an external network reset or prove the external network path.', 'No production App, user configuration, external host, external model, or remote helper is accessed.'] };
try {
  await h.waitForServerReady(60000);
  assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
  await click('workspace.empty.local'); await visible('terminal.surface');
  await click('toolbar.ai'); await click('ai.prompt'); await h.type_('Compare one saved-source new_only SSH creation.'); await click('ai.send');
  await h.waitFor(async () => {
    assert.equal(providerFailure, null);
    if ((await h.query('ai.host_approval.accept')).some(shown)) await click('ai.host_approval.accept');
    if (rejectHostKey && (await h.query('plugin.challenge.cancel')).some(shown)) await click('plugin.challenge.cancel');
    return ownedSettled && !(await h.query('ai.stop')).some(shown) || null;
  }, 45000);
  assert.equal(connections.length, resetFirst ? 2 : 1);
  await h.screenshot(join(out, expectRejected ? 'owned-rejected.png' : 'owned-ready.png'));
  if (expectRejected) {
    await h.sleep(1700);
    assert.equal(connections.length, 1, 'rejection must never schedule another TCP attempt');
    const logs = await Promise.all((await readdir(join(data, 'logs'))).filter(name => /^app-.*\.log$/.test(name)).map(name => readFile(join(data, 'logs', name), 'utf8')));
    assert(!logs.join('\n').includes('connect retry scheduled'));
    if (rejectAuth) assert.equal(JSON.parse(await readFile(join(out, 'peer/auth-rejected.json'), 'utf8')).rejected, true);
    report.status = 'passed';
  } else {
  await click('ai.collapse');
  const row = await visible('sidebar.host');
  assert((await h.clickAt(row.rect.x + 60, row.rect.y + row.rect.h / 2)).ok);
  await h.waitFor(async () => {
    const names = await readdir(join(data, 'logs')).catch(() => []);
    const logs = await Promise.all(names.filter(name => /^app-.*\.log$/.test(name)).map(name => readFile(join(data, 'logs', name), 'utf8')));
    return logs.join('\n').match(/connect OK session=/g)?.length === 2 || null;
  }, 20000);
  assert.equal(connections.length, resetFirst ? 3 : 2, 'only the explicitly injected first reset adds one transport attempt');
  for (const connection of connections) assert.equal(connection.identification_complete, true);
  assert.equal(connections[0].identification_bytes, connections[1].identification_bytes);
  assert.equal(connections[0].identification_hash, connections[1].identification_hash);
  assert.equal(calls.filter(call => call.name === 'host.open_session').length, 1);
  if (resetFirst) {
    assert.equal(connections[0].reset_before_server_banner, true);
    const logs = await Promise.all((await readdir(join(data, 'logs'))).filter(name => /^app-.*\.log$/.test(name)).map(name => readFile(join(data, 'logs', name), 'utf8')));
    const transportLog = logs.join('\n');
    assert.match(transportLog, /connect retry scheduled session=2 attempt=2\/3 delay_ms=500 cause=SshHandshakeReceiveFailed/);
    assert(!transportLog.includes('attempt=3/3'));
    assert.match(transportLog, /recv_code=-54 recv_errno=54 received_bytes=0/);
  }
  await h.screenshot(join(out, 'ordinary-ready.png'));
  report.status = 'passed';
  }
} catch (error) {
  report.status = 'failed'; report.error = String(error); process.exitCode = 1;
  console.error(report.error);
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  await h.screenshot(join(out, 'failure.png')).catch(() => {});
  await writeFile(join(out, 'failure-tree.json'), JSON.stringify(await h.tree(), null, 2)).catch(() => {});
} finally {
  await h.request('POST', '/quit').catch(() => {});
  const deadline = performance.now() + 15000;
  while (app.exitCode === null && app.signalCode === null && performance.now() < deadline) {
    for (const id of ['groups.close.accept', 'local.close.accept', 'session.close.accept']) {
      const matches = await h.query(id).catch(() => []);
      if (Array.isArray(matches) && matches.some(shown)) await h.clickTestId(id);
    }
    await Promise.race([ended, h.sleep(100)]);
  }
  if (app.exitCode === null && app.signalCode === null) { report.shutdown_error = 'Normal quit timed out'; app.kill('SIGTERM'); await ended; }
  report.exit_code = app.exitCode; report.signal = app.signalCode;
  if (report.exit_code !== 0 || report.signal !== null) { report.status = 'failed'; process.exitCode = 1; }
  for (const name of await readdir(join(data, 'logs')).catch(() => [])) if (/^app-.*\.log$/.test(name)) await writeFile(join(out, name), await readFile(join(data, 'logs', name)));
  for (const socket of sockets) socket.destroy();
  await new Promise<void>(done => proxy.close(() => done()));
  provider.closeAllConnections(); await new Promise<void>(done => provider.close(() => done()));
  peer.kill('SIGTERM'); await peerEnded;
  await log.close(); await peerLog.close();
  report.connections = connections; report.calls = calls; report.results = results;
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  await rm(iso, { recursive: true, force: true });
  console.log(JSON.stringify({ status: report.status, error: report.error, out }));
}
