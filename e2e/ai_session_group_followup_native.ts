/** Single-SSH follow-up: keep a real foreground process running across
 * create_group -> catalog refresh -> open_session. The default provider is a
 * deterministic fixture; ZW_SESSION_GROUP_LIVE=1 uses an explicitly supplied
 * loopback model gateway with only synthetic data and guarded tool calls.
 *
 * ZW_AI_TEST_PREFIX=/tmp/zw-session-group-build ZW_TEST_PYTHON=/path/to/python \
 *   node e2e/ai_session_group_followup_native.ts /tmp/zw-session-group-evidence
 * Set ZW_SESSION_GROUP_MONITOR=1 to also run one fixed read-only size sampler
 * in the new session and verify its result while the original process runs.
 * ZW_SESSION_GROUP_DEEPEP=1 regresses the original DeepEP version request.
 * ZW_SESSION_GROUP_NATURAL=1 sends only the original follow-up. In that mode,
 * ZW_SESSION_GROUP_REVIEW_SAMPLER=1 lets the operator review model commands
 * outside the built-in patterns using the paired review/approved JSON files.
 * ZW_SESSION_GROUP_CLEANUP=1 exercises the restricted catalog after grouping.
 * ZW_SESSION_GROUP_CLEANUP_TIMEOUT=1 also keeps the first wait blocked.
 * ZW_SESSION_GROUP_RECONNECT=1 tests a real SSH reconnect and stale execution.
 * With ZW_SESSION_GROUP_LIVE=1, interrupt the real model's task after its
 * first read-only command and observe how it recovers without further input.
 * ZW_SESSION_GROUP_RECONNECT_DURING_COMMAND=1 drops the connection before
 * that command finishes. AFTER_DROP=1 starts a separate post-loss control.
 * ZW_SESSION_GROUP_RECONNECT_FAILURE=1 rejects the successor at the SSH peer.
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, open, readFile, realpath, rm, stat, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? '/tmp/zw-session-group-build');
const binary = join(prefix, 'bin/zerowork');
const out = resolve(process.argv[2] ?? '/tmp/zw-session-group-evidence');
const live = process.env.ZW_SESSION_GROUP_LIVE === '1';
const monitor = process.env.ZW_SESSION_GROUP_MONITOR === '1';
const deepEP = process.env.ZW_SESSION_GROUP_DEEPEP === '1';
const deepEPPrompt = '你重新开启一个会话，然后读取下容器内的deep-ep库的版本';
const deepEPCommand = 'nerdctl -n k8s.io exec spb-deepep-r1 python3 -m pip show deep_ep';
const deepEPVersion = '1.1.0+loopback.fixture';
// Optional exact screenshot follow-up: the real model chooses a sampler. The
// peer guard still accepts only narrowly parsed, read-only fixture commands.
const natural = monitor && process.env.ZW_SESSION_GROUP_NATURAL === '1';
const reviewSampler = natural && process.env.ZW_SESSION_GROUP_REVIEW_SAMPLER === '1';
const disconnected = process.env.ZW_SESSION_GROUP_DISCONNECTED === '1';
const reconnect = process.env.ZW_SESSION_GROUP_RECONNECT === '1';
const liveReconnect = reconnect && live;
const reconnectAfterDrop = liveReconnect && process.env.ZW_SESSION_GROUP_RECONNECT_AFTER_DROP === '1';
const reconnectDuringCommand = liveReconnect && process.env.ZW_SESSION_GROUP_RECONNECT_DURING_COMMAND === '1';
const reconnectGroup = liveReconnect && process.env.ZW_SESSION_GROUP_RECONNECT_GROUP === '1';
const targetName = 'Reconnect Target';
const siblingName = 'Online Peer';
const autoReconnect = process.env.ZW_SESSION_GROUP_AUTO_RECONNECT === '1' || (!disconnected && !reconnect);
const reconnectPrompt = reconnectGroup ? `请在组内的 ${targetName} 执行 \`pwd; sleep 4\`。如果这个成员中途断线，请恢复它的连接后在同一成员执行 \`pwd\`，把结果告诉我。` : reconnectAfterDrop ? '当前 SSH 已经断线了，请恢复连接后运行 pwd，把结果告诉我。' : reconnectDuringCommand ? '请在当前 SSH 会话执行 `pwd; sleep 4`。如果运行中意外断开，请恢复连接后执行 `pwd`，把恢复后的结果告诉我。' : '请在当前 SSH 会话运行 pwd，把结果告诉我。如果连接中途意外断开，请恢复连接后再运行一次 pwd，把恢复后的结果也告诉我。';
const reconnectFailure = reconnect && process.env.ZW_SESSION_GROUP_RECONNECT_FAILURE === '1';
const reconnectNextTask = liveReconnect && process.env.ZW_SESSION_GROUP_RECONNECT_NEXT_TASK === '1';
const nextReconnectPrompt = reconnectGroup ? `${targetName} 的 SSH 服务已经恢复，请重新连接组内这个成员，连接就绪后在它的终端执行一次 pwd，把结果告诉我。` : 'SSH 服务已经恢复，请重新连接当前会话，连接就绪后执行一次 pwd，把结果告诉我。';
const cleanup = process.env.ZW_SESSION_GROUP_CLEANUP === '1';
const cleanupTimeout = cleanup && process.env.ZW_SESSION_GROUP_CLEANUP_TIMEOUT === '1';
const followUpMode = process.env.ZW_SESSION_GROUP_FOLLOWUP ?? 'steer';
assert(['steer', 'queue'].includes(followUpMode));
assert(!disconnected || (!live && !monitor));
assert(!cleanup || (!monitor && !disconnected && !(live && cleanupTimeout)));
assert(!reconnect || (!monitor && !disconnected && !cleanup));
assert(!liveReconnect || followUpMode === 'steer');
assert(!(reconnectAfterDrop && reconnectDuringCommand));
assert(!reconnectNextTask || (reconnectFailure && reconnectDuringCommand && autoReconnect));
assert(!reconnectGroup || reconnectNextTask);
const executionMode = process.env.ZW_SESSION_GROUP_EXECUTION_MODE ?? 'attached_pty';
assert(['attached_pty', 'auto'].includes(executionMode));
assert(!deepEP || (!live && !monitor && !cleanup && !disconnected && !reconnect && followUpMode === 'steer' && executionMode === 'attached_pty'));
const gateway = process.env.ZW_SESSION_GROUP_GATEWAY;
const gatewayKey = process.env.ZW_SESSION_GROUP_GATEWAY_KEY;
const liveModel = process.env.ZW_SESSION_GROUP_MODEL;
if (live) {
  assert(gateway && liveModel, 'Live mode requires an explicit loopback gateway and model');
  const endpoint = new URL(gateway);
  assert.equal(endpoint.protocol, 'http:'); assert.equal(endpoint.hostname, '127.0.0.1');
  assert.equal(endpoint.pathname, '/v1/chat/completions'); assert(!endpoint.search && !endpoint.hash);
}
await mkdir(out, { recursive: true });
const isolated = await realpath(await mkdtemp('/tmp/zw-session-group-'));
const data = join(isolated, 'data'), rpc = join(isolated, 'rpc'), peerDir = join(isolated, 'peer');
const cleanupRelease = join(isolated, 'cleanup-released');
for (const dir of [data, rpc, peerDir]) await mkdir(dir);
const peerCode = String.raw`
import base64, hashlib, json, os, posixpath, signal, socket, sys, time
from pathlib import Path
import paramiko
sys.path.insert(0, sys.argv[1])
from ssh_shell_execution_loopback import Fixture, Peer
original_execve=os.execve
def fixture_execve(path, args, env):
 env.update({'HOST':'fixture','HOSTNAME':'fixture','USER':'fixture'})
 env['PATH']=str(Path(sys.argv[2])/'bin')+':'+env['PATH']
 original_execve(path,args,env)
os.execve=fixture_execve
class Files(paramiko.SFTPServerInterface):
 def __init__(self, server, *args, **kwargs):
  super().__init__(server,*args,**kwargs); self.server=server
 def target(self, path):
  path=posixpath.normpath('/fixture' if path in ('','.') else path)
  home=self.server.fixture.home
  if path in ('/','/fixture',home): return Path(home)
  if path in ('/fixture/progress.json','/fixture/progress.bin',home+'/progress.json',home+'/progress.bin'):
   return Path(self.server.fixture.home)/posixpath.basename(path)
  return None
 def canonicalize(self, path): return '/fixture' if path in ('','.') else posixpath.normpath(path)
 def stat(self, path):
  target=self.target(path)
  if target is None or not target.exists(): return paramiko.SFTP_NO_SUCH_FILE
  return paramiko.SFTPAttributes.from_stat(target.stat())
 lstat=stat
 def list_folder(self, path):
  if posixpath.normpath('/fixture' if path in ('','.') else path) not in ('/','/fixture',self.server.fixture.home): return paramiko.SFTP_NO_SUCH_FILE
  values=[]
  for name in ('progress.json','progress.bin'):
   target=Path(self.server.fixture.home)/name
   if target.exists():
    item=paramiko.SFTPAttributes.from_stat(target.stat()); item.filename=name; values.append(item)
  return values
 def open(self, path, flags, attrs):
  target=self.target(path)
  if target is None or not target.is_file(): return paramiko.SFTP_NO_SUCH_FILE
  if flags & (os.O_WRONLY|os.O_RDWR|os.O_CREAT|os.O_TRUNC|os.O_APPEND): return paramiko.SFTP_PERMISSION_DENIED
  handle=paramiko.SFTPHandle(flags); handle.readfile=target.open('rb'); return handle
class TestPeer(Peer):
 def check_channel_subsystem_request(self, channel, name):
  self.fixture.actions.append([channel.chanid,'subsystem',name])
  return paramiko.ServerInterface.check_channel_subsystem_request(self,channel,name) if name=='sftp' else False
class TestFixture(Fixture):
 def accept(self):
  while not self.stop.is_set():
   try: sock,_=self.listener.accept()
   except socket.timeout: continue
   except OSError: return
   if (out/'hold-reconnect-handshake').exists() and (out/'disconnected').exists():
    until=time.monotonic()+(12 if (out/'fixed-handshake-failure').exists() else 20)
    while not stopped and not (out/'reject-reconnect').exists() and time.monotonic()<until: time.sleep(.02)
    self.actions.append([-1,'reconnect-rejected']); sock.close(); continue
   if (out/'reject-reconnect').exists():
    self.actions.append([-1,'reconnect-rejected']); sock.close(); continue
   if (out/'disconnected').exists(): self.actions.append([-1,'reconnect-transport'])
   transport=paramiko.Transport(sock); transport.add_server_key(self.key)
   transport.get_security_options().kex=['diffie-hellman-group14-sha256']
   transport.set_subsystem_handler('sftp',paramiko.SFTPServer,Files)
   self.transports.append(transport)
   try: transport.start_server(server=TestPeer(self))
   except (EOFError,OSError): pass
out=Path(sys.argv[2]); home=out/'home'; home.mkdir()
fixture=TestFixture('/bin/zsh','nominal',str(home)); stopped=False
def stop(*_):
 global stopped; stopped=True
signal.signal(signal.SIGTERM,stop)
(out/'ready.json').write_text(json.dumps({'port':fixture.port,'fingerprint':'SHA256:'+base64.b64encode(hashlib.sha256(fixture.key.asbytes()).digest()).decode().rstrip('=')}))
try:
 while not stopped:
  if ((out/'disconnect').exists() or ((out/'disconnect-during-command').exists() and b'pwd; sleep 4' in fixture.inputs)) and not (out/'disconnected').exists():
   for transport in fixture.transports: transport.close()
   (out/'disconnected').touch()
  if b'\x1b]133;B;zw_ctx=' in fixture.outputs: (out/'shell-ready').touch()
  if fixture.outputs.count(b'\x1b]133;B;zw_ctx=') >= 2: (out/'second-shell-ready').touch()
  if any(item[1:] == ['subsystem','sftp'] for item in fixture.actions): (out/'sftp-ready').touch()
  if (out/'fixed-handshake-failure').exists() and (out/'disconnected').exists():
   snapshot=out/'live-actions.tmp'; snapshot.write_text(json.dumps(fixture.actions)); snapshot.replace(out/'live-actions.json')
  time.sleep(.05)
finally:
 fixture.close()
 (out/'report.json').write_text(json.dumps({'actions':fixture.actions,'errors':fixture.errors}))
 (out/'inputs.bin').write_bytes(fixture.inputs)
 (out/'outputs.bin').write_bytes(fixture.outputs)
`;
const fixtureCode = `import json, os, time\nfrom pathlib import Path\np=Path('.')\npid=os.getpid()\nprint('COPY_FIXTURE_RUNNING', str((p/'progress.bin').resolve()) if ${monitor ? 'True' : 'False'} else '/fixture/progress.bin', flush=True)\ntick=0\nwith (p/'progress.bin').open('wb', buffering=0) as output:\n while not (p/'release').exists() and tick < 2400:\n  tick += 1\n  output.write(bytes(4096))\n  (p/'progress.json').write_text(json.dumps({'pid':pid,'tick':tick}))\n  time.sleep(0.25)\nprint('COPY_FIXTURE_DONE', flush=True)\n(p/'done.json').write_text(json.dumps({'pid':pid,'tick':tick,'released':(p/'release').exists()}))\n`;
const peerLog = await open(join(out, 'peer.log'), 'w');
await mkdir(join(peerDir, 'bin'));
// The screenshot uses a Linux peer. Keep its common read-only GNU stat
// syntax available on this macOS fixture, using the actual file's metadata.
await writeFile(join(peerDir, 'bin', 'stat'), `#!/bin/sh
if [ "$#" = 3 ] && [ "$1" = -c ]; then
  case "$2" in
    '%s') exec /usr/bin/stat -f '%z' "$3" ;;
    '%s bytes %y') exec /usr/bin/stat -f '%z bytes %Sm' "$3" ;;
    '%s bytes  %y') exec /usr/bin/stat -f '%z bytes  %Sm' "$3" ;;
  esac
fi
exec /usr/bin/stat "$@"
`, { mode: 0o700 });
if (deepEP) await writeFile(join(peerDir, 'bin', 'nerdctl'), `#!/bin/sh
[ "$*" = '${deepEPCommand.slice('nerdctl '.length)}' ] || exit 64
printf 'Name: deep_ep\\nVersion: ${deepEPVersion}\\n'
`, { mode: 0o700 });
const peer = spawn(process.env.ZW_TEST_PYTHON ?? 'python3', ['-u', '-c', peerCode, resolve('e2e'), peerDir], { stdio: ['ignore', peerLog.fd, peerLog.fd] });
const peerEnded = new Promise<void>(done => peer.once('close', () => done()));
const waitFile = async (path: string, timeout = 15000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try { return JSON.parse(await readFile(path, 'utf8')); } catch { await new Promise(done => setTimeout(done, 50)); }
  }
  throw Error(`Timed out waiting for ${path}`);
};
const ready = await waitFile(join(peerDir, 'ready.json'));
const siblingDir = join(isolated, 'online-peer');
const siblingLog = reconnectGroup ? await open(join(out, 'online-peer.log'), 'w') : null;
if (reconnectGroup) await mkdir(siblingDir);
const sibling = siblingLog ? spawn(process.env.ZW_TEST_PYTHON ?? 'python3', ['-u', '-c', peerCode, resolve('e2e'), siblingDir], { stdio: ['ignore', siblingLog.fd, siblingLog.fd] }) : null;
const siblingEnded = sibling ? new Promise<void>(done => sibling.once('close', () => done())) : null;
const siblingReady = sibling ? await waitFile(join(siblingDir, 'ready.json')) : null;
const home = join(peerDir, 'home');
const progressPath = monitor ? join(home, 'progress.bin') : '/fixture/progress.bin';
assert(!progressPath.includes("'"));
const monitorCommand = `printf 'MONITOR_BEGIN='; stat -f %z '${progressPath}'; sleep 2; printf 'MONITOR_END='; stat -f %z '${progressPath}'`;
await writeFile(join(home, 'copy_fixture.py'), fixtureCode);
const savedHost = (id: number, name: string, port: number) => `[[hosts]]\nconnection_id=${id}\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="${name}"\nhost="127.0.0.1"\nport=${port}\nuser="shell-fixture"\n`;
await writeFile(join(data, 'hosts.toml'), `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=${siblingReady ? 3 : 2}\nnext_group_id=1\n` + savedHost(1, reconnectGroup ? targetName : 'Isolated SSH fixture', ready.port) + (siblingReady ? savedHost(2, siblingName, siblingReady.port) : ''));

const wire = (name: string) => name.replaceAll('_', '_u').replaceAll('.', '__');
const frame = (delta: any) => 'data: ' + JSON.stringify({ choices: [{ index: 0, delta }] }) + '\n\n';
const done = 'data: [DONE]\n\n';
const requests: any[] = [], responses: any[] = [];
let providerFailure = '', waitEmitted = false, followupSent = false, heldAtMilestone = false, finishedWithoutGroup = false;
let readyToQueue = false, queued = false;
let cleanupBinding: { conversation_id: string, task_id: string, binding_revision: number, tool_cleanup: string } | null = null;
let cleanupCallId = cleanupTimeout ? 'cleanup-retry' : 'cleanup', openCallId = 'open';
let reconnectCheck: any = null;
let liveReconnectEvidence: any = { reconnect_calls: [], waits: [], commands: [], disconnected_at: null };
let nextReconnectStarted = false;
let groupTargetPane = '', groupSiblingPane = '';
let siblingRef = '';
const observedLiveCalls = new Set<string>();
let liveReconnectFinished = false;
let disconnectObserved = false;
let userSubmissions = 0;
let activeReconnectModelRequests = 0;
let heldResponse: any = null;
let sourceRef = '', savedRef = '', executionRef = '', groupRef = '', openedRef = '', readyRef = '', monitorRef = '';
let deepEPResult: any = null;
let foregroundIssued = false, monitorAttempts = 0, monitorOutput = '', modelReported = '', modelBlockedText = '';
let monitorBlocked: any = null, originalStart: any = null;
let monitorOwner: number | null = null;
let sizes: { start: number, end: number } | null = null;
let firstNaturalSample: number | null = null;
let monitorFinished = false;
const reviewedSamplers = new Set<string>();
const naturalOutputs = new Map<string, string>();
const finishedSamplers = new Set<string>();
const naturalSampler = (command: string) => {
  if (typeof command !== 'string' || command.includes('@PATH@')) return false;
  // Permit this Python sampler only with the synthetic file and bounded work.
  const pythonSample = `python3 -u - <<'EOF'
import os,time
p="${progressPath}"
prev=None;pt=None
for i in range(12):
    try:
        s=os.stat(p).st_size
    except FileNotFoundError:
        s=None
    t=time.time()
    if prev is not None and s is not None and pt is not None:
        dt=t-pt; d=s-prev
        print("%s size=%s delta=%s rate=%.1f KiB/s" % (time.strftime('%H:%M:%S'), s, d, d/dt/1024.0))
    else:
        print("%s size=%s" % (time.strftime('%H:%M:%S'), s))
    prev=s; pt=t
    time.sleep(1)
EOF`;
  if (command.trim() === pythonSample) return true;
  const normal = command.replaceAll(`'${progressPath}'`, '@PATH@').replaceAll(`"${progressPath}"`, '@PATH@').replaceAll(progressPath, '@PATH@').trim();
  if (/^for i in \$\(seq 1 (?:[2-9]|10)\); do printf '%s size=%s\\n' "\$\(date \+%H:%M:%S\)" "\$\(stat -f %z @PATH@ 2>\/dev\/null \|\| stat -c %s @PATH@ 2>\/dev\/null\)"; sleep [1-5]; done$/.test(normal)) return true;
  if (/^for i in(?: (?:[1-9]|10)){2,10}; do printf '%s %s\\n' "\$\(date \+%H:%M:%S\)" "\$\(wc -c < @PATH@ 2>\/dev\/null \|\| echo NA\)"; sleep [1-5]; done$/.test(normal)) return true;
  const parts = normal.split(';').map(part => part.trim()).filter(Boolean);
  if (!parts.length || parts.length > 6) return false;
  let sample = false;
  for (const part of parts) {
    if (/^stat\s+(?:-f\s*%z|-c\s*%s)\s+@PATH@$/.test(part) || /^wc\s+-c\s*(?:<\s*)?@PATH@$/.test(part) || /^ls\s+-l\s+@PATH@$/.test(part)) sample = true;
    else if (!/^sleep\s+[1-5]$/.test(part)) return false;
  }
  return sample;
};
const bodyOf = (envelope: any) => {
  for (const block of envelope.content ?? []) try { return JSON.parse(block.text); } catch {}
  return envelope;
};
const callFromSse = (raw: string) => {
  const calls = new Map<number, any>();
  let text = '', reportedModel: string | null = null;
  for (const line of raw.split('\n')) {
    if (!line.startsWith('data: ') || line.includes('[DONE]')) continue;
    let delta: any;
    try {
      const event = JSON.parse(line.slice(6));
      if (event.model) reportedModel = event.model;
      delta = event.choices?.[0]?.delta;
    } catch { continue; }
    text += delta?.content ?? '';
    for (const item of delta?.tool_calls ?? []) {
      const prior = calls.get(item.index) ?? { id: '', name: '', arguments: '' };
      prior.id += item.id ?? '';
      prior.name += item.function?.name ?? '';
      prior.arguments += item.function?.arguments ?? '';
      calls.set(item.index, prior);
    }
  }
  return { text, reported_model: reportedModel, calls: [...calls.values()].map(call => ({ ...call, arguments: JSON.parse(call.arguments || '{}') })) };
};
const safeRead = new Set(['host.get_current_context', 'host.list_sessions', 'host.get_session', 'host.list_groups', 'host.get_group', 'host.list_group_members', 'host.list_hosts', 'host.get_host', 'host.read_terminal', 'host.search_terminal', 'host.list_terminal_commands', 'host.get_execution', 'host.wait_execution', 'host.wait_session_ready', 'list_remote_files', 'read_remote_file', 'file.read_text']);
const logicalName = (name: string) => name === 'run_command' || name === 'list_remote_files' || name === 'read_remote_file' ? name : name.replaceAll('__', '.').replaceAll('_u', '_');
const validateCalls = async (calls: any[]) => {
  for (const call of calls) {
    const name = logicalName(call.name), args = call.arguments;
    if (liveReconnect) {
      const accepted = liveReconnectEvidence.accepted;
      if (name === 'host.reconnect_session') {
        liveReconnectEvidence.reconnect_calls.push(call);
        assert.equal(liveReconnectEvidence.reconnect_calls.length, 1, 'The model issued another reconnect');
        assert(liveReconnectEvidence.disconnected_at && (reconnectGroup ? args.session_ref !== siblingRef && args.session_ref.split(':')[2] === sourceRef.split(':')[2] : args.session_ref === (liveReconnectEvidence.original_ref || sourceRef)), 'Reconnect must target the disconnected fixture');
        assert.notEqual(args.connection_policy, 'reuse_only');
      } else if (name === 'host.wait_session_ready') {
        liveReconnectEvidence.waits.push(call);
        const operation = accepted?.operation_ref ?? liveReconnectEvidence.automatic_operation;
        assert(operation && args.operation_ref === operation && !args.session_ref, 'The model must wait with the accepted operation reference');
        if (reconnectFailure && !nextReconnectStarted) await writeFile(join(peerDir, 'reject-reconnect'), 'reject');
      } else if (name === 'host.run_in_terminal' || name === 'run_command') {
        liveReconnectEvidence.commands.push(call);
        assert(!reconnectFailure || nextReconnectStarted || !liveReconnectEvidence.disconnected_at, 'The model tried to execute after the connection failed');
        assert(args.command.trim() === 'pwd' || (reconnectDuringCommand && !liveReconnectEvidence.disconnected_at && args.command.trim() === 'pwd; sleep 4'), 'Only the requested read-only fixture command may run');
        if (name === 'host.run_in_terminal') {
          const original = liveReconnectEvidence.original_ref || sourceRef;
          const separator = original.lastIndexOf(':');
          const next = original.slice(0, separator + 1) + (Number(original.slice(separator + 1)) + 1);
          assert([original, next].includes(args.session_ref), 'Command must target the isolated original or successor generation');
        }
        else assert.deepEqual(args.session_ids, [Number(sourceRef.split(':')[2])]);
      } else {
        assert(safeRead.has(name) && !['file.read_text', 'list_remote_files', 'read_remote_file'].includes(name), `Tool blocked by the isolated reconnect fixture: ${name}`);
      }
      continue;
    }
    if (cleanup && (name === 'host.run_in_terminal' || name === 'run_command')) {
      throw Error('Cleanup verification exercises only the new-session lifecycle');
    } else if (name === 'host.wait_tool_cleanup') {
      assert(cleanup && groupRef && cleanupBinding, 'The model must observe the restricted group catalog before waiting');
      assert.deepEqual(args, {});
      assert.equal(cleanupCallId, 'cleanup', 'The fixture releases resources on the first wait');
      cleanupCallId = call.id;
      setTimeout(() => { void writeFile(cleanupRelease, 'released').catch(error => { providerFailure = String(error); }); }, 1000);
    } else if (name === 'host.run_in_terminal') {
      if (args.command === 'python3 -u copy_fixture.py') {
        assert.equal(args.session_ref, sourceRef);
        assert(!foregroundIssued, 'The original command may only be submitted once');
        foregroundIssued = true;
      } else {
        assert(openedRef && readyRef === openedRef && args.session_ref === openedRef, 'The sampler must target the ready new session');
        if (natural) assert(monitorAttempts < 8, 'The fixture bounds natural sampler calls');
        else assert(!monitorRef && monitorAttempts < 2 && (monitorAttempts === 0 || monitorBlocked?.state === 'cancelled_unsent'), 'A sampler may be retried only after a definite unsent result');
        if (reviewSampler && !naturalSampler(args.command)) {
          const digest = createHash('sha256').update(args.command).digest('hex');
          await writeFile(join(out, `review-${digest}.json`), JSON.stringify(args, null, 2));
          const approval = await waitFile(join(out, `approved-${digest}.json`), 60000);
          assert.equal(approval.command, args.command, 'Review only approves the exact model-generated fixture command');
          reviewedSamplers.add(args.command);
        }
        assert(monitor && (args.command === monitorCommand || (natural && (naturalSampler(args.command) || reviewedSamplers.has(args.command)))), 'Only an approved read-only fixture sampler may run in the new session');
        monitorAttempts++;
      }
    }
    else if (name === 'run_command') {
      // The attached_pty route rejects batch dispatch. The isolated SSH peer
      // also rejects every non-diagnostic exec request, even in auto mode.
      const ids = [sourceRef, openedRef].filter(Boolean).map(ref => Number(ref.split(':')[2]));
      assert(Array.isArray(args.session_ids) && args.session_ids.length && args.session_ids.every((id: number) => ids.includes(id)), 'Batch targets must belong to this fixture');
    }
    else if (name === 'host.create_group') assert.equal(args.initial_session_ref, sourceRef, 'Only the isolated original session may be grouped');
    else if (name === 'host.open_session') {
      assert.equal(args.group_ref, groupRef, 'Only the newly created fixture group may be used');
      assert(args.source_ref === sourceRef || (savedRef && args.source_ref === savedRef), 'Only the isolated fixture session or its saved source may be used');
      assert.equal(args.connection_policy, 'new_only', 'The work session must use its own SSH connection');
      if (cleanup) {
        assert.notEqual(cleanupCallId, 'cleanup', 'The model must actively wait before opening');
        assert.equal(openCallId, 'open', 'Only one new session may be opened');
        openCallId = call.id;
      }
    } else {
      assert(safeRead.has(name), `Tool blocked by fixture guard: ${name}`);
      if (name === 'file.read_text') assert([join(home, 'progress.bin'), join(home, 'progress.json')].includes(args.path), 'Local reads stay within synthetic fixture data');
    }
    if (name === 'host.wait_execution') waitEmitted = true;
  }
};
const server = createServer(async (req, res) => {
  try {
    if (req.method !== 'POST') return res.end(JSON.stringify({ data: [{ id: live ? liveModel : 'session-group-fixture' }] }));
    let raw = ''; for await (const part of req) raw += part;
    const body = JSON.parse(raw);
    const tools = (body.tools ?? []).map((item: any) => item.function.name);
    if (!tools.length) return res.end(frame({ content: '会话测试' }) + done);
    const results = new Map<string, any>();
    const calls = new Map<string, any>();
    for (const message of body.messages ?? []) {
      for (const call of message.tool_calls ?? []) calls.set(call.id, call);
      if (message.role === 'tool') {
        try { results.set(message.tool_call_id, JSON.parse(message.content)); }
        catch (error) {
          // The next task receives prior tool results as historical text.
          // Relay it unchanged and inspect only this task's live receipts.
          if (!nextReconnectStarted || !observedLiveCalls.has(message.tool_call_id)) throw error;
        }
      }
    }
    const monitorChunks: string[] = [];
    for (const [id, envelope] of results) {
      const original = calls.get(id);
      const name = logicalName(original?.function.name ?? ''), result = bodyOf(envelope);
      const args = original?.function.arguments ? JSON.parse(original.function.arguments) : {};
      if (name === 'host.get_current_context' && result.binding_ref?.startsWith('s1:')) sourceRef = result.binding_ref;
      if (liveReconnect && !observedLiveCalls.has(id)) {
        observedLiveCalls.add(id);
        if (reconnectDuringCommand && !nextReconnectStarted && name === 'host.run_in_terminal' && !liveReconnectEvidence.original_execution) {
          const first = liveReconnectEvidence.commands.find((call: any) => call.arguments.command.trim() === 'pwd; sleep 4');
          if (first && id === first.id) {
            liveReconnectEvidence.original_ref = args.session_ref;
            liveReconnectEvidence.original_execution = { result, receipt: envelope.receipt };
          }
        }
        if (name === 'host.run_in_terminal' && result.snapshot?.process?.exit_code === 0 && args.command?.trim() === 'pwd') {
          assert.equal(envelope.status, 'succeeded');
          if (!reconnectAfterDrop && !nextReconnectStarted && !liveReconnectEvidence.original_execution) {
            liveReconnectEvidence.original_ref = args.session_ref;
            liveReconnectEvidence.original_execution = { result, receipt: envelope.receipt };
            await writeFile(join(peerDir, 'disconnect'), 'disconnect');
            liveReconnectEvidence.disconnected_at = new Date().toISOString();
          } else if (liveReconnectEvidence.ready?.session_ref === args.session_ref) {
            liveReconnectEvidence.successor_execution = { result, receipt: envelope.receipt };
          }
        }
        if (name === 'host.reconnect_session') {
          liveReconnectEvidence.reconnect_result = envelope;
          if (result.state === 'accepted') liveReconnectEvidence.accepted = { ...result, receipt: envelope.receipt };
        }
        if (name === 'host.wait_session_ready' && result.state === 'ready') liveReconnectEvidence.ready = { ...result, receipt: envelope.receipt };
        if (name === 'host.wait_session_ready') {
          liveReconnectEvidence.wait_result = envelope;
          if (result.state === 'failed') {
            assert.equal(envelope.status, 'failed');
            liveReconnectEvidence.failed = { ...result, receipt: envelope.receipt };
          }
        }
        if (reconnectGroup && !nextReconnectStarted && name === 'host.get_session' && result.session?.session_id === Number(sourceRef.split(':')[2])) liveReconnectEvidence.target_status = result.session;
      }
      if (name === 'host.list_sessions') {
        const original = result.sessions?.find((item: any) => item.session_ref === sourceRef);
        if (original?.source_ref) savedRef = original.source_ref;
        const opened = result.sessions?.find((item: any) => item.session_ref === openedRef);
        if (opened?.ready && opened.capabilities?.trusted_pty_execution) readyRef = openedRef;
      }
      if ((name === 'host.list_hosts' || name === 'host.get_host') && sourceRef) {
        const candidate = JSON.stringify(result).match(/c1:[0-9a-f]+:1:1/)?.[0];
        if (candidate?.split(':')[1] === sourceRef.split(':')[1]) savedRef = candidate;
      }
      if (name === 'host.run_in_terminal' && args.command === 'python3 -u copy_fixture.py' && result.execution_ref) executionRef = result.execution_ref;
      if (monitor && name === 'host.run_in_terminal' && (args.command === monitorCommand || (natural && (naturalSampler(args.command) || reviewedSamplers.has(args.command))))) {
        if (envelope.status === 'succeeded') {
          if (!monitorRef && result.execution_ref) monitorRef = result.execution_ref;
          if (natural && result.execution_ref && result.snapshot?.owner?.session_id === Number(openedRef.split(':')[2]) && typeof result.output === 'string') {
            naturalOutputs.set(result.execution_ref, result.output);
          }
          if (monitorRef && result.execution_ref === monitorRef) {
            if (result.snapshot?.owner?.session_id) monitorOwner = result.snapshot.owner.session_id;
            if (typeof result.output === 'string') monitorChunks.push(result.output);
          }
        } else {
          assert.equal(envelope.status, 'cancelled_unsent', `The monitoring call failed: ${JSON.stringify(envelope)}`);
          assert.equal(result.side_effect_started, false);
          monitorBlocked = { ...result, receipt: envelope.receipt };
        }
      }
      if (natural && (name === 'host.wait_execution' || name === 'host.get_execution') && naturalOutputs.has(result.execution_ref) && typeof result.output === 'string') naturalOutputs.set(result.execution_ref, result.output);
      if (natural && naturalOutputs.has(result.execution_ref) && result.snapshot?.process?.exit_code === 0) finishedSamplers.add(result.execution_ref);
      if (monitor && result.execution_ref === monitorRef && monitorRef && result.snapshot?.process?.exit_code === 0) monitorFinished = true;
      if (monitor && monitorRef && (name === 'host.wait_execution' || name === 'host.get_execution') && result.execution_ref === monitorRef && typeof result.output === 'string') monitorChunks.push(result.output);
      if (monitor && !natural && name === 'host.read_terminal' && result.source_ref === openedRef) monitorChunks.push(JSON.stringify(result));
      if (name === 'host.create_group' && result.state === 'committed') groupRef = result.group_ref;
      if (name === 'host.open_session' && result.session_ref) openedRef = result.session_ref;
      if (name === 'host.open_session' && result.state === 'ready') readyRef = result.session_ref;
      if (name === 'host.wait_session_ready' && result.state === 'ready') readyRef = result.session_ref;
      if (name === 'host.get_session' && result.session?.session_ref === openedRef && result.session?.ready && result.session?.capabilities?.trusted_pty_execution) readyRef = openedRef;
    }
    if (monitor) {
      if (monitorChunks.length) monitorOutput = monitorChunks.join('');
      const start = /MONITOR_BEGIN=(\d+)/.exec(monitorOutput), end = /MONITOR_END=(\d+)/.exec(monitorOutput);
      if (start && end) sizes = { start: Number(start[1]), end: Number(end[1]) };
      if (natural) {
        for (const [ref, output] of naturalOutputs) {
          const clean = output.replace(/\x1b\][^\x07]*\x07/g, '').replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');
          const values = clean.split(/[\r\n]+/).map(line => /(?:^|\s)size=\s*(\d{4,})(?=\s|$)/.exec(line) ?? /^\s*(?:\d\d:\d\d:\d\d\s+)?(\d{4,})(?:\s+bytes\b|(?:\s+\S+)?\s*$)/.exec(line) ?? /^-[rwxStTs-]{9}[@+]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+/.exec(line)).filter(Boolean).map(match => Number(match![1]));
          const pair = /(?:^|\s)(?:t0|size_a|size1|sample1)=(\d+)\s+(?:t\d+|size_b|size2|sample2)=(\d+)(?=\s|$)/i.exec(clean);
          if (pair) values.unshift(Number(pair[1]), Number(pair[2]));
          if (values.length === 0) continue;
          firstNaturalSample ??= values[0];
          const start = values.length > 1 ? values[0] : firstNaturalSample;
          if (values.at(-1)! <= start) continue;
          monitorRef = ref;
          monitorOutput = output;
          monitorFinished = finishedSamplers.has(ref);
          sizes = { start, end: values.at(-1)! };
          break;
        }
      }
    }
    requests.push({ at: new Date().toISOString(), model: body.model, effort: body.reasoning_effort, tools, messages: body.messages });
    if (live) {
      assert.equal(body.model, liveModel);
      assert.equal(body.reasoning_effort, 'xhigh');
      if (reconnectGroup && !nextReconnectStarted) for (const message of body.messages) {
        if (message.role !== 'user' || !message.content.startsWith('{')) continue;
        const loss = JSON.parse(message.content).group_reconnects?.find((entry: any) => entry.previous_session_ref === sourceRef);
        if (!loss?.operation_ref) continue;
        assert.equal(loss.previous_session_ref, sourceRef);
        if (liveReconnectEvidence.automatic_operation) assert.equal(loss.operation_ref, liveReconnectEvidence.automatic_operation);
        liveReconnectEvidence.automatic_operation = loss.operation_ref;
      }
      if (liveReconnect && liveReconnectEvidence.disconnected_at && !disconnectObserved) {
        const deadline = Date.now() + 15000;
        while (!disconnectObserved && Date.now() < deadline) await new Promise(done => setTimeout(done, 50));
        assert(disconnectObserved, 'The SSH disconnect must reach the application before the next provider round');
      }
      if (followUpMode === 'queue' && executionRef && !queued) {
        readyToQueue = true;
        const deadline = Date.now() + 30000;
        while (!queued && Date.now() < deadline) await new Promise(done => setTimeout(done, 50));
        assert(queued, 'The original request must remain active until the follow-up is queued');
      }
      // Hold the next provider round after the requested evidence is present,
      // instead of allowing an unrelated model-supplied command to execute.
      if ((!monitor && groupRef && openedRef && readyRef === openedRef) || (monitor && monitorRef && sizes && modelReported && !natural)) {
        heldAtMilestone = true;
        heldResponse = res;
        res.writeHead(200, { 'content-type': 'text/event-stream' }); res.flushHeaders();
        return;
      }
      if (cleanup && tools.includes(wire('host.wait_tool_cleanup'))) {
        assert(!tools.includes(wire('host.open_session')));
        assert(JSON.stringify(body).includes('temporarily blocked by that cleanup'), 'The actual model request must explain the cleanup restriction');
        const notices = body.messages.filter((msg: any) => msg.role === 'user').flatMap((msg: any) => { try { return [JSON.parse(msg.content)]; } catch { return []; } });
        cleanupBinding = notices.findLast((notice: any) => notice.host_context_notice && notice.tool_cleanup === 'pending') ?? null;
        assert(cleanupBinding?.task_id);
      }
      if (cleanup && tools.includes(wire('host.open_session'))) {
        const waited = results.get(cleanupCallId);
        assert.equal(bodyOf(waited).state, 'cleanup_released');
        assert.equal(waited.receipt.side_effect_started, false);
        assert.equal(waited.receipt.task_id, cleanupBinding?.task_id);
        assert.equal(waited.receipt.conversation_id, cleanupBinding?.conversation_id);
        assert.equal(waited.receipt.binding_revision, cleanupBinding?.binding_revision);
        assert(!tools.includes(wire('host.wait_tool_cleanup')));
        assert(body.messages.some((message: any) => { try { return JSON.parse(message.content).tool_cleanup === 'released'; } catch { return false; } }));
      }
      const headers: Record<string, string> = { 'content-type': 'application/json' };
      if (gatewayKey) headers.authorization = `Bearer ${gatewayKey}`;
      if (liveReconnect) activeReconnectModelRequests++;
      const stream = await (async () => {
        try {
          const upstream = await fetch(gateway!, { method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(180000) });
          assert(upstream.ok, `Model gateway HTTP ${upstream.status}`);
          return await upstream.text();
        } finally {
          if (liveReconnect) activeReconnectModelRequests--;
        }
      })();
      const result = callFromSse(stream);
      if (result.reported_model) assert.equal(result.reported_model, liveModel, 'The gateway must not substitute a different model');
      responses.push({ at: new Date().toISOString(), ...result });
      await writeFile(join(out, `model-response-${responses.length}.json`), JSON.stringify(responses.at(-1), null, 2));
      if (monitor && sizes && result.text) {
        const displayed = result.text.replaceAll(',', '');
        if (displayed.includes(String(sizes.start)) && displayed.includes(String(sizes.end))) modelReported = result.text;
      }
      if (monitor && monitorBlocked && !monitorRef && result.text && result.calls.length === 0) modelBlockedText = result.text;
      if (!groupRef && result.calls.length === 0 && result.text.trim() && body.messages.some((msg: any) => msg.role === 'user' && typeof msg.content === 'string' && msg.content.startsWith('你可以再开会话监控下带宽或者文件大小呢'))) finishedWithoutGroup = true;
      // Source/group refs are also available in host-generated request facts
      // before the model elects to query the current context.
      if (reconnectGroup && !sourceRef) {
        const binding = JSON.stringify(body.messages);
        const refs = [...binding.matchAll(/s1:[0-9a-f]+:\d+:\d+/g)].map(match => match[0]);
        sourceRef = refs.find(ref => ref.split(':')[2] === groupTargetPane.split('.').at(-1)) ?? '';
        siblingRef = refs.find(ref => ref.split(':')[2] === groupSiblingPane.split('.').at(-1)) ?? '';
        assert(sourceRef && siblingRef, 'The group model request must include both exact member references');
        const group = body.messages.filter((message: any) => message.role === 'system').flatMap((message: any) => String(message.content).split('\n')).flatMap((line: string) => { try { return [JSON.parse(line).binding?.group]; } catch { return []; } }).find((id: number) => id > 0);
        assert(group, 'The model must be bound to the group');
        report.group_binding = { group_id: group, target_ref: sourceRef, sibling_ref: siblingRef };
      } else if (!sourceRef) {
        const match = JSON.stringify(body.messages).match(/s1:[0-9a-f]+:\d+:\d+/);
        if (match) sourceRef = match[0];
      }
      await validateCalls(result.calls);
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      if (liveReconnect && result.text.trim() && result.calls.length === 0) liveReconnectFinished = true;
      return res.end(stream);
    }
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const emit = (id: string, name: string, args: any) => {
      assert(tools.includes(wire(name)), `Current catalog lacks ${name}`);
      if (name === 'host.wait_execution') waitEmitted = true;
      res.end(frame({ tool_calls: [{ index: 0, id, type: 'function', function: { name: wire(name), arguments: JSON.stringify(args) } }] }) + done);
    };
    const result = (id: string, expected = 'succeeded') => {
      const envelope = results.get(id); if (!envelope) return null;
      assert.equal(envelope.status, expected, `${id}: ${JSON.stringify(envelope)}`);
      return bodyOf(envelope);
    };
    if (!sourceRef) {
      const context = result('context');
      if (!context) return emit('context', 'host.get_current_context', {});
      sourceRef = context.binding_ref;
    }
    if (reconnect) {
      const request = { session_ref: sourceRef, connection_policy: 'new_only', request_key: 'reconnect-once' };
      const accepted = result('reconnect');
      if (!accepted) return emit('reconnect', 'host.reconnect_session', request);
      assert.equal(accepted.state, 'accepted');
      assert.equal(accepted.session_ref, null);
      assert.equal(accepted.previous_session_ref, sourceRef);
      const terminal = result('reconnect-wait', reconnectFailure ? 'failed' : 'succeeded');
      if (!terminal) return emit('reconnect-wait', 'host.wait_session_ready', { operation_ref: accepted.operation_ref, wait_for: reconnectFailure ? 'transport' : 'interactive', wait_ms: 15000 });
      assert.equal(terminal.operation_ref, accepted.operation_ref);
      assert.equal(terminal.state, reconnectFailure ? 'failed' : 'ready');
      assert.equal(terminal.generation, Number(sourceRef.split(':')[3]) + 1);
      if (reconnectFailure) {
        assert.equal(terminal.error_code, 'SshHandshakeReceiveFailed');
        assert.equal(terminal.retryable, false);
      }
      else assert.equal(terminal.execution_readiness, 'ready');
      const repeated = result('reconnect-repeat');
      if (!repeated) return emit('reconnect-repeat', 'host.reconnect_session', request);
      assert.equal(repeated.operation_ref, accepted.operation_ref);
      assert.equal(repeated.state, terminal.state);
      assert.equal(repeated.idempotent_reuse, true);
      assert.equal(results.get('reconnect-repeat').receipt.side_effect_started, false);
      assert.equal(results.get('reconnect').receipt.task_id, results.get('reconnect-wait').receipt.task_id);
      assert.equal(results.get('reconnect').receipt.task_id, results.get('reconnect-repeat').receipt.task_id);
      if (reconnectFailure) {
        const successorRef = `${sourceRef.slice(0, sourceRef.lastIndexOf(':') + 1)}${terminal.generation}`;
        for (const [id, target] of [['reconnect-new-key-original', sourceRef], ['reconnect-new-key-successor', successorRef]]) {
          const blocked = results.get(id);
          if (!blocked) return emit(id, 'host.reconnect_session', { ...request, session_ref: target, request_key: id });
          assert.equal(blocked.status, 'failed');
          assert.equal(bodyOf(blocked).code, 'ReconnectFailedForTask');
          assert.equal(blocked.receipt.side_effect_started, false);
        }
      } else {
        const old = results.get('old-generation-command');
        if (!old) return emit('old-generation-command', 'host.run_in_terminal', { session_ref: sourceRef, request_key: 'stale-command', command: 'printf NEVER_ON_RECONNECTED_SHELL', wait_ms: 2000 });
        assert.notEqual(old.status, 'succeeded', 'Old generation must have no executable authority');
        const current = result('new-generation-command');
        if (!current) return emit('new-generation-command', 'host.run_in_terminal', { session_ref: terminal.session_ref, request_key: 'fresh-command', command: 'printf RECONNECT_NEW_GENERATION_OK', wait_ms: 5000 });
        assert.equal(current.snapshot.owner.generation, terminal.generation);
        assert(current.output.includes('RECONNECT_NEW_GENERATION_OK'));
      }
      reconnectCheck = { accepted, terminal, repeated, blocked_original: results.get('reconnect-new-key-original') ?? null, blocked_successor: results.get('reconnect-new-key-successor') ?? null, old_generation_result: results.get('old-generation-command') ?? null, task_id: results.get('reconnect').receipt.task_id };
      return res.end(frame({ content: 'RECONNECT_VERIFIED' }) + done);
    }
    const hasFollowup = body.messages.some((msg: any) => msg.role === 'user' && typeof msg.content === 'string' && (deepEP ? msg.content === deepEPPrompt : msg.content.startsWith('你可以再开会话监控下带宽或者文件大小呢')));
    if (disconnected) {
      const state = result('disconnected');
      if (!state) return emit('disconnected', 'host.get_session', { session_ref: sourceRef });
      assert(['failed', 'ended'].includes(state.session.state));
    } else if (!hasFollowup && !cleanup) {
      const started = result('foreground');
      if (!started) return emit('foreground', 'host.run_in_terminal', { session_ref: sourceRef, command: 'python3 -u copy_fixture.py', request_key: 'foreground', wait_ms: 2000 });
      executionRef = started.execution_ref;
      if (followUpMode === 'queue' && followupSent) return res.end(frame({ content: '原命令已在前台启动。' }) + done);
      return emit('wait', 'host.wait_execution', { execution_ref: executionRef, until: 'decision', wait_ms: followUpMode === 'queue' ? 8000 : 30000 });
    }
    const group = result('group');
    if (!group) return emit('group', 'host.create_group', { initial_session_ref: sourceRef, name: '前台命令验证', request_key: 'group' });
    assert.equal(group.state, 'committed'); groupRef = group.group_ref;
    if (cleanup) {
      const waited = result('cleanup');
      const retried = cleanupTimeout && waited ? result('cleanup-retry') : null;
      if (!waited || (cleanupTimeout && !retried)) {
        assert(!tools.includes(wire('host.open_session')), 'Opening must be unavailable before cleanup release');
        assert(JSON.stringify(body).includes('temporarily blocked by that cleanup'), 'Model must receive the cleanup reason');
        const notices = body.messages.filter((msg: any) => msg.role === 'user').flatMap((msg: any) => { try { return [JSON.parse(msg.content)]; } catch { return []; } });
        cleanupBinding = notices.findLast((notice: any) => notice.host_context_notice) ?? null;
        assert(cleanupBinding?.task_id);
        assert.equal(cleanupBinding.tool_cleanup, 'pending');
        if (!cleanupTimeout || waited) {
          if (cleanupTimeout) {
            assert.equal(waited?.state, 'cleanup_pending');
            assert.equal(waited?.timed_out, true);
          }
          setTimeout(() => { void writeFile(cleanupRelease, 'released').catch(error => { providerFailure = String(error); }); }, 1000);
        }
        return emit(waited ? 'cleanup-retry' : 'cleanup', 'host.wait_tool_cleanup', {});
      }
      assert.equal((retried || waited).state, 'cleanup_released');
      assert(!tools.includes(wire('host.wait_tool_cleanup')));
      assert(body.messages.some((message: any) => { try { return JSON.parse(message.content).tool_cleanup === 'released'; } catch { return false; } }));
      const receipt = results.get(retried ? 'cleanup-retry' : 'cleanup').receipt;
      assert.equal(receipt.conversation_id, cleanupBinding?.conversation_id);
      assert.equal(receipt.task_id, cleanupBinding?.task_id);
      assert.equal(receipt.binding_revision, cleanupBinding?.binding_revision);
      assert.equal(receipt.side_effect_started, false);
    }
    const opened = result('open');
    if (!opened) return emit('open', 'host.open_session', { group_ref: groupRef, source_ref: sourceRef, connection_policy: 'new_only', retention: 'keep', request_key: 'open' });
    openedRef = opened.session_ref;
    const readyResult = result('ready');
    if (!readyResult) return emit('ready', 'host.wait_session_ready', { operation_ref: opened.operation_ref, wait_for: 'interactive', wait_ms: 30000 });
    assert.equal(readyResult.state, 'ready'); assert.equal(readyResult.execution_readiness, 'ready'); assert.equal(readyResult.session_ref, openedRef);
    if (deepEP) {
      assert(hasFollowup, 'The provider must receive the exact composer follow-up');
      const version = result('deep-ep-version');
      if (!version) return emit('deep-ep-version', 'host.run_in_terminal', { session_ref: readyResult.session_ref, command: deepEPCommand, request_key: 'deep-ep-version', wait_ms: 10000 });
      assert(version.execution_ref);
      const [, , sessionId, generation] = readyResult.session_ref.split(':');
      assert.equal(version.snapshot.owner.session_id, Number(sessionId));
      assert.equal(version.snapshot.owner.generation, Number(generation));
      assert.equal(version.snapshot.process.exit_code, 0);
      assert(version.output.includes(`Version: ${deepEPVersion}`));
      deepEPResult = { prompt: deepEPPrompt, command: deepEPCommand, session_ref: readyResult.session_ref, execution_ref: version.execution_ref, owner: version.snapshot.owner, output: version.output };
      return res.end(frame({ content: `DeepEP 版本为 ${deepEPVersion}。` }) + done);
    }
    if (monitor) {
      const monitorEnvelope = results.get('monitor');
      if (monitorEnvelope && monitorEnvelope.status !== 'succeeded') {
        modelBlockedText = '监控命令被运行方式限制，未发送。';
        return res.end(frame({ content: modelBlockedText }) + done);
      }
      const startedMonitor = result('monitor');
      if (!startedMonitor) {
        monitorAttempts++;
        return emit('monitor', 'host.run_in_terminal', { session_ref: openedRef, command: monitorCommand, request_key: 'monitor', wait_ms: 2000 });
      }
      monitorRef = startedMonitor.execution_ref;
      if (!sizes) for (let i = 0; i < 5; i++) {
        if (!result('monitor-wait-' + i)) return emit('monitor-wait-' + i, 'host.wait_execution', { execution_ref: monitorRef, until: 'decision', wait_ms: 10000 });
      }
      assert(sizes && sizes.end > sizes.start, `Missing growing monitor output: ${monitorOutput}`);
      modelReported = `文件大小从 ${sizes.start} 字节增长到 ${sizes.end} 字节。`;
      return res.end(frame({ content: modelReported }) + done);
    }
    return res.end(frame({ content: 'GROUP_AND_SESSION_READY' }) + done);
  } catch (error) {
    providerFailure = String(error);
    console.error(`Test provider stopped: ${providerFailure}`);
    if (!res.headersSent) res.writeHead(500, { 'content-type': 'text/plain' });
    res.end(providerFailure);
  }
});
await new Promise<void>(done => server.listen(0, '127.0.0.1', done));
const syntheticExtensions = JSON.stringify(JSON.stringify({ skills: [{ id: '1'.repeat(32), revision: '2'.repeat(64), name: 'synthetic-fixture', description: 'Synthetic test metadata; unrelated to shell or monitoring tasks.', enabled: true }], servers: [] }));
await writeFile(join(data, 'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ssh]\nauto_reconnect=${autoReconnect}\n[ai]\ndefault_provider="fixture"\npermission_mode="auto"\nexecution_mode="${executionMode}"\nfollow_up_mode="${followUpMode}"\nextensions=${syntheticExtensions}\n[[ai.providers]]\nid="fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address() as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname=${JSON.stringify(live ? liveModel : 'session-group-fixture')}\ncontext_window=200000\ndefault=true\nreasoning=${live}\n${live ? 'efforts=["xhigh"]\n' : ''}`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const appLog = await open(join(out, 'app.log'), 'w');
const app = spawn(binary, [], { env: { ...process.env, ZW_TEST_AI_TOOL_CLEANUP_RELEASE: cleanup ? cleanupRelease : undefined, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', OPENAI_API_KEY: '', ANTHROPIC_API_KEY: '' }, stdio: ['ignore', appLog.fd, appLog.fd] });
const ended = new Promise<void>(done => app.once('close', () => done()));
const alive = () => app.exitCode === null && app.signalCode === null;
const shown = (node: any) => node && node.visible !== false && !node.hidden && (node.effective_opacity ?? 1) > 0 && node.rect?.w > 0 && node.rect?.h > 0;
const flat = (node: any): any[] => Array.isArray(node) ? node.flatMap(flat) : node ? [node, ...(node.children ?? []).flatMap(flat)] : [];
const text = (node: any) => flat(node).map(n => n.text ?? '').join(' ');
const visible = (id: string, timeout = 15000) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, timeout);
const click = async (id: string) => { report.last_action = id; await visible(id); assert((await h.clickTestId(id)).ok, id); };
const send = async (value: string) => { await click('ai.prompt'); assert((await h.type_(value)).ok); await click('ai.send'); userSubmissions++; };
const report: any = { status: 'running', live, monitor, natural, disconnected, follow_up_mode: followUpMode, execution_mode: executionMode, binary_sha256: createHash('sha256').update(await readFile(binary)).digest('hex'), checks: [], approvals: [], isolated };
if (liveReconnect) {
  report.reconnect = liveReconnectEvidence;
  report.reconnect_after_drop = reconnectAfterDrop;
  report.reconnect_during_command = reconnectDuringCommand;
  report.reconnect_failure = reconnectFailure;
  report.reconnect_group = reconnectGroup;
  report.ssh_auto_reconnect = autoReconnect;
  report.permission_mode = 'auto';
}
const pump = async () => {
  if (providerFailure) throw Error(providerFailure);
  if (finishedWithoutGroup) throw Error('The real model finished without creating a group');
  assert(alive(), 'Isolated application exited');
  if (liveReconnect && (liveReconnectEvidence.disconnected_at || reconnectDuringCommand) && !disconnectObserved) {
    const peerDropped = await stat(join(peerDir, 'disconnected')).then(() => true, () => false);
    if (peerDropped) liveReconnectEvidence.disconnected_at ??= new Date().toISOString();
    disconnectObserved = peerDropped && (reconnectGroup ? !text(await h.query(groupTargetPane)).includes('在线') : !text(await h.query('status.connection.identity')).includes('已连接'));
    if (disconnectObserved) liveReconnectEvidence.app_observed_disconnect_at = new Date().toISOString();
  }
  for (const id of ['ai.host_approval.accept', 'ai.interaction.approve']) if ((await h.query(id)).some(shown)) {
    report.approvals.push({ id, summary: text(await h.query('ai.host_approval.summary')) });
    await click(id);
  }
  for (const prefix of ['plugin.challenge', 'auth.challenge']) {
    const modal = (await h.query(prefix + '.modal')).find(shown); if (!modal) continue;
    const trust = flat(modal).find(n => [prefix + '.choice.0', prefix + '.trust_once'].includes(n.test_id) && shown(n));
    if (trust) { assert([ready.fingerprint, siblingReady?.fingerprint].filter(Boolean).some(fingerprint => text(modal).includes(fingerprint))); await click(trust.test_id); return; }
    const answer = flat(modal).find(n => [prefix + '.answer.0', prefix + '.secret'].includes(n.test_id) && shown(n));
    if (answer) { await click(answer.test_id); await h.key('a', { cmd: true }); await h.type_('fixture-only'); await click(prefix + '.submit'); return; }
  }
};
const waitStrict = async (predicate: () => Promise<any>, timeout: number) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    await pump();
    const value = await predicate(); if (value) return value;
    await h.sleep(100);
  }
  throw Error(`Timed out after ${timeout}ms`);
};
let success = false;
try {
  await h.waitForServerReady(60000); await h.resizeWindow(1440, 900);
  await click('sidebar.host'); await click('sidebar.host.connect');
  await h.sleep(1000);
  await writeFile(join(out, 'connect-tree.json'), JSON.stringify(Object.fromEntries(await Promise.all(['sidebar.host', 'workspace.pane', 'connection.progress', 'status.connection.identity', 'plugin.challenge.modal', 'auth.challenge.modal'].map(async id => [id, await h.query(id)]))), null, 2));
  await waitStrict(async () => text(await h.query('status.connection.identity')).includes('已连接') || null, 45000);
  await visible('terminal.surface');
  await waitStrict(async () => { try { await readFile(join(peerDir, 'shell-ready')); return true; } catch { return null; } }, 15000);
  await h.sleep(500);
  await click('toolbar.ai');
  await click('ai.composer.attachment'); await click('ai.attachment.remote_file');
  await visible('ai.remote.picker');
  await waitStrict(async () => { try { await readFile(join(peerDir, 'sftp-ready')); return true; } catch { return null; } }, 30000);
  if ((await h.query('ai.remote.close')).some(shown)) await click('ai.remote.close');
  await h.sleep(300);
  if (!(await h.query('ai.prompt')).some(shown)) await click('toolbar.ai');
  if (reconnectGroup) {
    const joinGroup = async () => {
      await click('terminal.surface');
      for (let attempt = 0; attempt < 3; attempt++) {
        await h.type_('@');
        try { await visible('terminal.commands', 4000); break; }
        catch (error) { await h.key('c', { ctrl: true }); if (attempt === 2) throw error; }
      }
      await h.type_('grp Reconnect Check');
      await h.key('right');
      await h.waitFor(async () => !(await h.query('terminal.commands')).some(shown), 5000);
      await h.key('return');
      await visible('groups.workspace');
    };
    const groupPanes = async () => flat(await visible('groups.workspace')).filter(node => /^groups\.pane\.\d+$/.test(node.test_id ?? '') && shown(node));
    if ((await h.query('ai.collapse')).some(shown)) await click('ai.collapse');
    await joinGroup();
    const hostRow = (await h.query('sidebar.host')).find(node => shown(node) && text(node).includes(siblingName));
    assert(hostRow, 'The second SSH fixture must be in the sidebar');
    assert((await h.clickAt(hostRow.rect.x + hostRow.rect.w / 2, hostRow.rect.y + hostRow.rect.h / 2)).ok);
    const connect = flat((await h.query('sidebar.host')).find(node => shown(node) && text(node).includes(siblingName))).find(node => node.test_id === 'sidebar.host.connect' && shown(node));
    assert(connect, 'Find the connection action for the second SSH fixture');
    assert((await h.clickAt(connect.rect.x + connect.rect.w / 2, connect.rect.y + connect.rect.h / 2)).ok);
    await waitStrict(async () => stat(join(siblingDir, 'shell-ready')).then(() => true, () => false), 45000);
    await joinGroup();
    const panes = await waitStrict(async () => { const values = await groupPanes(); return values.length === 2 ? values : null; }, 15000);
    groupTargetPane = panes.find((pane: any) => text(pane).includes(targetName))?.test_id;
    groupSiblingPane = panes.find((pane: any) => text(pane).includes(siblingName))?.test_id;
    assert(groupTargetPane && groupSiblingPane && groupTargetPane !== groupSiblingPane);
    report.group_panes = { target: groupTargetPane, sibling: groupSiblingPane };
    if (!(await h.query('ai.prompt')).some(shown)) await click('toolbar.ai');
  }
  if (liveReconnect) {
    if (reconnectFailure) await writeFile(join(peerDir, 'hold-reconnect-handshake'), 'hold');
    if (reconnectGroup) await writeFile(join(peerDir, 'fixed-handshake-failure'), 'armed');
    if (reconnectAfterDrop) {
      await writeFile(join(peerDir, 'disconnect'), 'disconnect');
      liveReconnectEvidence.disconnected_at = new Date().toISOString();
      await waitStrict(async () => disconnectObserved, 30000);
    }
    if (reconnectDuringCommand) await writeFile(join(peerDir, 'disconnect-during-command'), 'armed');
    await send(reconnectPrompt);
    await waitStrict(async () => {
      if (liveReconnectFinished) return true;
      if (!reconnectAfterDrop && disconnectObserved && activeReconnectModelRequests === 0 && !(await h.query('ai.stop')).some(shown)) {
        const lastRequest = requests.at(-1);
        if (Date.now() - Date.parse(responses.at(-1)?.at ?? lastRequest?.at ?? liveReconnectEvidence.disconnected_at) > 8000) throw Error('The assistant task stopped after the SSH disconnect');
      }
      return null;
    }, 180000);
    const { accepted, ready: successor, original_execution: original, successor_execution: next } = liveReconnectEvidence;
    const failed = liveReconnectEvidence.failed;
    const automaticOnly = reconnectGroup && !accepted && !liveReconnectEvidence.reconnect_calls.length;
    const terminal = reconnectFailure ? failed : successor;
    assert(disconnectObserved, 'The SSH peer must actually disconnect during the scenario');
    if (!automaticOnly) {
      assert(accepted && terminal, 'The model must receive accepted, then wait for the terminal result');
      assert.equal(liveReconnectEvidence.reconnect_calls.length, 1);
      assert(liveReconnectEvidence.waits.length > 0);
      assert.equal(terminal.operation_ref, accepted.operation_ref);
      assert.equal(terminal.receipt.task_id, accepted.receipt.task_id);
      assert.equal(accepted.session_ref, null);
      assert.equal(terminal.generation, Number(accepted.previous_session_ref.split(':')[3]) + 1);
      if (reconnectGroup) assert.equal(accepted.operation_ref, liveReconnectEvidence.automatic_operation);
    } else {
      assert(failed && liveReconnectEvidence.automatic_operation, 'The model must observe the automatic reconnect receipt');
      assert.equal(failed.operation_ref, liveReconnectEvidence.automatic_operation);
      assert.equal(failed.generation, Number(sourceRef.split(':')[3]) + 1);
      assert.equal(failed.receipt.task_id, original.receipt.task_id);
    }
    if (reconnectFailure) {
      assert.equal(liveReconnectEvidence.commands.length, 1);
      if (automaticOnly) {
        assert.equal(failed.session_ref, null);
        assert.equal(failed.error_code, 'SshHandshakeReceiveFailed');
        assert.match(responses.at(-1).text, /握手|handshake/i);
      } else {
        assert.equal(failed.session_ref, null);
        assert.equal(failed.error_code, 'SshHandshakeReceiveFailed');
        assert.match(responses.at(-1).text, /握手|handshake/i);
        assert.equal(original.receipt.task_id, accepted.receipt.task_id);
      }
    } else {
      assert(next && next.result.snapshot.owner.generation === successor.generation, 'The model must run the second pwd on the new generation');
      assert.equal(next.receipt.task_id, accepted.receipt.task_id);
      if (!reconnectAfterDrop) {
        assert(liveReconnectEvidence.app_observed_disconnect_at);
        assert.equal(next.receipt.task_id, original.receipt.task_id);
        assert.notEqual(next.result.execution_ref, original.result.execution_ref);
        assert.equal(next.result.snapshot.has_input_grant, false, 'The new command must release its own input grant');
      }
    }
    for (const request of requests) {
      const submitted = request.messages.filter((message: any) => {
        if (message.role !== 'user') return false;
        try { return !JSON.parse(message.content).host_context_notice; } catch { return true; }
      });
      assert.deepEqual(submitted.map((message: any) => message.content), [reconnectPrompt]);
    }
    const journal = JSON.parse(await readFile(join(data, 'ai/lifecycle.json'), 'utf8'));
    const records = journal.records.filter((record: any) => record.tool_id === 'host.reconnect_session');
    if (!automaticOnly && !reconnectGroup) {
      assert.equal(records.length, 1);
      assert.equal(records[0].stage, reconnectFailure ? 'failed' : 'succeeded');
    }
    report.checks.push({ composer_submissions: 1, reconnect_journal_stage: records[0]?.stage ?? null, automatic_reconnect_only: automaticOnly });
    if (reconnectGroup) {
      const online = text(await h.query(groupSiblingPane));
      assert.match(online, /在线|已连接|运行中/);
      report.other_member_after_failure = online;
      report.first_task_reconnect_stages = records.map((record: any) => ({ stage: record.stage, dispatch_started: record.dispatch_started, task_id: record.context.task_id }));
    }
    if (reconnectNextTask) {
      await waitStrict(async () => !(await h.query('ai.stop')).some(shown) && (await h.query('ai.send')).some(shown), 30000);
      const previous = accepted?.previous_session_ref ?? sourceRef;
      let failedGeneration = failed?.generation ?? Number(previous.split(':').at(-1)) + 1;
      if (reconnectGroup) {
        const nativeFailures = async () => [...(await readFile(join(out, 'app.log'), 'utf8')).matchAll(/^NOTIFICATION_FACT (.+)$/gm)].map(match => JSON.parse(match[1])).filter(event => event.kind === 'reconnect' && event.result === 'failed' && event.owner_id === Number(sourceRef.split(':')[2]));
        const initial = await nativeFailures();
        if (!failed && initial.length < 5 && !records.some((record: any) => record.dispatch_started)) {
          await waitStrict(async () => (await nativeFailures()).length >= 5, 90000);
        }
        const failures = await nativeFailures();
        assert(failures.length, 'The selected member must fail a real SSH reconnect');
        failedGeneration = failures.at(-1).owner_revision;
        report.first_task_native_failures = failures;
      }
      const failedRef = `${previous.slice(0, previous.lastIndexOf(':') + 1)}${failedGeneration}`;
      const firstRequestCount = requests.length;
      const firstResponseCount = responses.length;
      // Keep the same listener and host key. Remove the handshake fault only
      // after task one has ended, without reconnecting the app ourselves.
      await rm(join(peerDir, 'hold-reconnect-handshake'));
      await rm(join(peerDir, 'reject-reconnect'), { force: true });
      nextReconnectStarted = true;
      liveReconnectFinished = false;
      liveReconnectEvidence = { reconnect_calls: [], waits: [], commands: [], original_ref: failedRef, disconnected_at: report.reconnect.disconnected_at };
      report.next_reconnect = liveReconnectEvidence;
      report.ssh_restored_at = new Date().toISOString();
      await send(nextReconnectPrompt);
      await waitStrict(async () => liveReconnectFinished, 180000);
      const { accepted: second, ready, successor_execution: executed, commands, waits, reconnect_calls: reconnectCalls } = liveReconnectEvidence;
      assert(second && ready && executed, 'The next task must reconnect, wait, and execute');
      assert.equal(reconnectCalls.length, 1);
      assert(waits.length > 0);
      assert.equal(second.previous_session_ref, failedRef);
      assert.equal(second.session_ref, null);
      assert.notEqual(second.operation_ref, accepted?.operation_ref);
      assert.notEqual(second.receipt.task_id, original.receipt.task_id);
      assert.equal(second.receipt.conversation_id, original.receipt.conversation_id);
      assert.equal(ready.operation_ref, second.operation_ref);
      assert.equal(ready.receipt.task_id, second.receipt.task_id);
      assert.equal(ready.generation, failedGeneration + 1);
      assert.equal(ready.execution_readiness, 'ready');
      assert.equal(commands.length, 1);
      assert.equal(commands[0].arguments.session_ref, ready.session_ref);
      assert.equal(executed.receipt.task_id, second.receipt.task_id);
      assert.equal(executed.result.snapshot.owner.generation, ready.generation);
      assert.equal(executed.result.snapshot.process.exit_code, 0);
      assert.notEqual(executed.result.execution_ref, original.result.execution_ref);
      for (const request of requests.slice(firstRequestCount)) {
        const submitted = request.messages.filter((message: any) => {
          if (message.role !== 'user') return false;
          if (message.content.startsWith('[历史环境，仅作记录]\n')) return false;
          try { return !JSON.parse(message.content).host_context_notice; } catch { return true; }
        }).map((message: any) => message.content);
        assert.deepEqual(submitted, [nextReconnectPrompt]);
      }
      assert(responses.slice(firstResponseCount).at(-1)?.text.includes(home), 'The next model answer must report the observed directory');
      const completed = JSON.parse(await readFile(join(data, 'ai/lifecycle.json'), 'utf8'));
      const stages = completed.records.filter((record: any) => record.tool_id === 'host.reconnect_session' && record.dispatch_started).map((record: any) => record.stage);
      if (!reconnectGroup) assert.deepEqual(stages, automaticOnly ? ['succeeded'] : ['failed', 'succeeded']);
      else assert.equal(stages.at(-1), 'succeeded');
      report.checks.push({ composer_submissions: 2, reconnect_journal_stages: stages });
    }
  } else if (reconnect) {
    await writeFile(join(peerDir, 'disconnect'), 'disconnect');
    await waitStrict(async () => text(await h.query('status.connection.identity')).includes('已连接') ? null : true, 30000);
    if (reconnectFailure) await writeFile(join(peerDir, 'reject-reconnect'), 'reject');
    await send('请重连当前会话一次，并等待连接结果。');
    await waitStrict(async () => reconnectCheck, 60000);
    const journal = JSON.parse(await readFile(join(data, 'ai/lifecycle.json'), 'utf8'));
    const records = journal.records.filter((record: any) => record.tool_id === 'host.reconnect_session');
    assert.equal(records.filter((record: any) => record.dispatch_started).length, 1);
    assert.equal(records.find((record: any) => record.dispatch_started).stage, reconnectFailure ? 'failed' : 'succeeded');
    report.checks.push(reconnectCheck);
  } else if (disconnected || cleanup) {
    if (disconnected) {
      await writeFile(join(peerDir, 'disconnect'), 'disconnect');
      await waitStrict(async () => text(await h.query('status.connection.identity')).includes('已连接') ? null : true, 30000);
    }
    await send('你可以再开会话监控下带宽或者文件大小呢');
    await waitStrict(async () => groupRef && openedRef && readyRef === openedRef && (!cleanup || !live || heldAtMilestone) ? true : null, 90000);
    assert.notEqual(openedRef, sourceRef);
    if (cleanup) {
      const lookup = (id: string) => requests.flatMap(request => request.messages).find((message: any) => message.role === 'tool' && message.tool_call_id === id);
      const opened = JSON.parse(lookup(openCallId)?.content ?? '{}');
      assert.equal(opened.receipt.task_id, cleanupBinding?.task_id);
      assert.equal(opened.receipt.conversation_id, cleanupBinding?.conversation_id);
      assert.equal(opened.receipt.binding_revision, cleanupBinding?.binding_revision);
      for (const request of requests.filter(request => request.tools.includes(wire('host.wait_tool_cleanup')) || request.tools.includes(wire('host.open_session')))) {
        const composerMessages = request.messages.filter((message: any) => {
          if (message.role !== 'user') return false;
          try { return !JSON.parse(message.content).host_context_notice; } catch { return true; }
        });
        assert.deepEqual(composerMessages.map((message: any) => message.content), ['你可以再开会话监控下带宽或者文件大小呢']);
      }
      report.checks.push({ cleanup_binding: cleanupBinding, cleanup_call_id: cleanupCallId, open_call_id: openCallId, waited_for_timeout: cleanupTimeout, composer_submissions: 1, group_ref: groupRef, opened_ref: openedRef, opened_receipt: opened.receipt });
    } else report.checks.push({ disconnected_source: sourceRef, group_ref: groupRef, opened_ref: openedRef });
  } else {
    await send(`请在当前终端逐字执行 \`python3 -u copy_fixture.py\`，进度文件为 ${progressPath}，${followUpMode === 'queue' ? '启动后简短观察一次，然后回复已启动并结束本轮，保留原命令继续运行。' : '启动后等待命令完成。'}`);
    const before = await waitStrict(async () => { try { const state = JSON.parse(await readFile(join(home, 'progress.json'), 'utf8')); return state.tick > 1 && (live && followUpMode === 'queue' ? readyToQueue : waitEmitted) ? state : null; } catch { return null; } }, live ? 180000 : 45000);
    originalStart = before;
    process.kill(before.pid, 0);
    followupSent = true;
    await send(deepEP ? deepEPPrompt : monitor && !natural ? `你可以再开会话监控下带宽或者文件大小呢。请在新会话逐字运行 \`${monitorCommand}\`，报告两次文件大小（字节）和变化，不要在原会话输入。` : '你可以再开会话监控下带宽或者文件大小呢');
    queued = true;
    await waitStrict(async () => groupRef && openedRef && readyRef === openedRef ? true : null, live ? 240000 : 90000);
    assert.notEqual(openedRef, sourceRef, 'The work session must be distinct from the foreground session');
    await waitStrict(async () => { try { await readFile(join(peerDir, 'second-shell-ready')); return true; } catch { return null; } }, 30000);
    const after = await waitFile(join(home, 'progress.json'));
    assert.equal(after.pid, before.pid); assert(after.tick > before.tick, 'Original foreground process continued across the handoff');
    process.kill(after.pid, 0);
    const groupRequest = requests.find(item => item.tools.includes(wire('host.open_session')));
    assert(groupRequest, 'The actual refreshed catalog must advertise open_session');
    report.checks.push({ before, after, group_ref: groupRef, opened_ref: openedRef, catalog_refreshed: true });
    if (deepEP) {
      await waitStrict(async () => deepEPResult, 45000);
      const during = await waitFile(join(home, 'progress.json'));
      assert.equal(during.pid, before.pid);
      process.kill(during.pid, 0);
      report.checks.push({ ...deepEPResult, foreground_during: during });
    }
    if (monitor) {
      await waitStrict(async () => (monitorRef && sizes && (natural ? monitorFinished : modelReported)) || (monitorBlocked && modelBlockedText) ? true : null, live ? 180000 : 45000);
      if (monitorBlocked && !monitorRef) throw Error(`Monitoring was not dispatched: ${JSON.stringify(monitorBlocked)}`);
      assert(sizes && sizes.end > sizes.start, `The monitored file must grow: ${JSON.stringify(sizes)}`);
      if (!(await h.query('ai.prompt')).some(shown)) await click('toolbar.ai');
      const displayed = natural ? null : await waitStrict(async () => {
        const value = text(await h.query('ai.response')).replaceAll(',', '');
        return value.includes(String(sizes!.start)) && value.includes(String(sizes!.end)) ? value : null;
      }, 15000);
      const during = await waitFile(join(home, 'progress.json'));
      assert.equal(during.pid, before.pid); assert(during.tick >= after.tick && during.tick > before.tick);
      process.kill(during.pid, 0);
      const observedFileSize = (await stat(join(home, 'progress.bin'))).size;
      assert(observedFileSize >= sizes.end, 'The independently observed fixture file must contain the reported data');
      const monitorReceipt = await waitStrict(async () => {
        try {
          const journal = JSON.parse(await readFile(join(data, 'ai/lifecycle.json'), 'utf8'));
          return journal.records.find((record: any) => record.tool_id === 'host.run_in_terminal' && record.execution_receipt?.execution_id === monitorRef.slice(3) && record.stage === 'succeeded') ?? null;
        } catch { return null; }
      }, 20000);
      assert.equal(monitorOwner, Number(openedRef.split(':')[2]), 'The actual monitor receipt must belong to the new session');
      assert.equal(monitorReceipt.execution_receipt.process?.exit_code, 0);
      report.checks.push({ monitor_command: natural ? 'model-selected, read-only fixture sampler' : monitorCommand, monitor_ref: monitorRef, monitor_owner: monitorOwner, sizes, monitor_output: monitorOutput, model_reported: modelReported, user_visible: displayed, foreground_during: during, observed_file_size: observedFileSize, monitor_exit: monitorReceipt.execution_receipt.process });
    }
    await writeFile(join(home, 'release'), 'release');
    const completed = await waitFile(join(home, 'done.json'));
    assert.equal(completed.pid, before.pid); assert.equal(completed.released, true);
    assert(completed.tick >= after.tick, 'The original process finished only after the fixture released it');
    const receipt = await waitStrict(async () => {
      try {
        const journal = JSON.parse(await readFile(join(data, 'ai/lifecycle.json'), 'utf8'));
        return journal.records.find((record: any) => record.tool_id === 'host.run_in_terminal' && record.execution_receipt?.execution_id === executionRef.slice(3) && record.stage === 'succeeded') ?? null;
      } catch { return null; }
    }, 20000);
    assert.equal(receipt.execution_receipt.process?.exit_code, 0);
    assert.equal(receipt.execution_receipt.process?.foreground_finished, true);
    report.checks.push({ completed, execution_receipt: { stage: receipt.stage, process: receipt.execution_receipt.process } });
  }
  if (natural) {
    // The first completed sampler already returned its measurements to the
    // model. Let it finish describing them after the original process exits.
    for (let i = 0; i < 50 && (responses.at(-1)?.calls.length || !responses.at(-1)?.text); i++) await h.sleep(200);
    report.model_final_text = responses.at(-1)?.calls.length === 0 ? responses.at(-1).text : null;
    if (responses.at(-1)?.calls.length && (await h.query('ai.stop')).some(shown)) await click('ai.stop');
  }
  if (heldResponse) {
    // This test-only marker ends the held provider round after all real-model
    // calls and host receipts have been captured. It is not a model answer.
    heldResponse.end(frame({ content: '[测试收尾：已记录会话创建回执。]' }) + done);
    report.synthetic_completion_after_milestone = true;
    await h.sleep(1000);
  }
  success = true;
} catch (error) {
  report.error = String(error); process.exitCode = 1;
  report.monitor_blocked = monitorBlocked; report.model_blocked_text = modelBlockedText || null;
  if (originalStart) {
    try {
      const state = await waitFile(join(home, 'progress.json'), 2000);
      process.kill(state.pid, 0);
      report.original_before_cleanup = { before: originalStart, latest: state, same_process: state.pid === originalStart.pid, still_running: true };
    } catch (observationError) { report.original_observation_error = String(observationError); }
  }
  const diagnostics: any = {};
  for (const id of ['sidebar.host', 'workspace.pane', 'connection.progress', 'status.connection.identity', 'plugin.challenge.modal', 'auth.challenge.modal', 'ai.panel', 'ai.remote.picker', 'ai.remote.close', 'ai.prompt']) {
    try { diagnostics[id] = await h.query(id); } catch (queryError) { diagnostics[id] = String(queryError); }
  }
  await writeFile(join(out, 'failure-tree.json'), JSON.stringify(diagnostics, null, 2));
} finally {
  await writeFile(join(home, 'release'), 'release').catch(() => {});
  if (originalStart && !success) {
    try {
      const completed = await waitFile(join(home, 'done.json'), 10000);
      const deadline = Date.now() + 10000;
      let originalReceipt: any = null;
      while (Date.now() < deadline && !originalReceipt) {
        try {
          const journal = JSON.parse(await readFile(join(data, 'ai/lifecycle.json'), 'utf8'));
          originalReceipt = journal.records.find((record: any) => record.tool_id === 'host.run_in_terminal' && record.execution_receipt?.execution_id === executionRef.slice(3) && record.stage === 'succeeded');
        } catch {}
        if (!originalReceipt) await new Promise(done => setTimeout(done, 100));
      }
      report.original_cleanup = { completed, stage: originalReceipt?.stage, process: originalReceipt?.execution_receipt?.process };
    } catch (cleanupError) { report.original_cleanup_error = String(cleanupError); }
  }
  try {
    if (alive()) await h.request('POST', '/zerowork/windows', { action: 'quit' });
    const deadline = Date.now() + 15000;
    while (alive() && Date.now() < deadline) {
      for (const id of ['groups.close.accept', 'session.close.accept', 'local.close.accept']) {
        try {
          const nodes = await h.query(id);
          if (Array.isArray(nodes) && nodes.some(shown)) await h.clickTestId(id);
        } catch {}
      }
      await Promise.race([ended, h.sleep(80)]);
    }
  } catch (error) { report.quit_error = String(error); }
  if (alive()) { report.forced_quit = true; app.kill('SIGTERM'); await ended; }
  peer.kill('SIGTERM'); await peerEnded;
  if (sibling) { sibling.kill('SIGTERM'); await siblingEnded; await siblingLog!.close(); }
  server.closeAllConnections(); await new Promise<void>(done => server.close(() => done()));
  await peerLog.close(); await appLog.close();
  report.peer = await readFile(join(peerDir, 'report.json'), 'utf8').then(JSON.parse).catch(() => null);
  if (reconnect && !reconnectFailure && !liveReconnect) {
    const terminalInput = await readFile(join(peerDir, 'inputs.bin'), 'utf8').catch(() => 'NEVER_ON_RECONNECTED_SHELL');
    report.old_generation_sent = terminalInput.includes('NEVER_ON_RECONNECTED_SHELL');
    report.new_generation_sent = terminalInput.includes('RECONNECT_NEW_GENERATION_OK');
  }
  let peerCommandsMatch = true;
  if (deepEP) {
    const terminalInput = await readFile(join(peerDir, 'inputs.bin'), 'utf8').catch(() => '');
    report.peer_deep_ep_submissions = terminalInput.split(deepEPCommand).length - 1;
    peerCommandsMatch = report.peer_deep_ep_submissions === 1;
    if (success && !peerCommandsMatch) report.error = 'The SSH peer must receive exactly one DeepEP version query';
  }
  if (liveReconnect) {
    const terminalInput = await readFile(join(peerDir, 'inputs.bin'), 'utf8').catch(() => '');
    report.peer_pwd_submissions = terminalInput.split(/\r?\n/).filter(line => line === 'pwd' || line === 'pwd; sleep 4');
    const originalCommand = reconnectDuringCommand ? 'pwd; sleep 4' : 'pwd';
    const expected = reconnectAfterDrop ? ['pwd'] : reconnectFailure && !reconnectNextTask ? [originalCommand] : [originalCommand, 'pwd'];
    peerCommandsMatch = JSON.stringify(report.peer_pwd_submissions) === JSON.stringify(expected);
    if (success && !peerCommandsMatch) report.error = 'The SSH peer did not receive exactly the requested commands';
  }
  report.process_exit = app.exitCode; report.provider_failure = providerFailure || null;
  if (liveReconnect) report.composer_submissions = userSubmissions;
  report.scenario_passed = success;
  report.held_at_lifecycle_milestone = heldAtMilestone;
  report.requests = requests; report.responses = responses;
  // The peer explicitly rejects (and never executes) non-diagnostic batch
  // execs. In auto mode a model may try one before choosing the real PTY;
  // retain those refusals as evidence instead of treating them as peer faults.
  const peerErrors: string[] = report.peer?.errors ?? ['missing-peer-report'];
  report.denied_batch_exec = peerErrors.filter(value => value.startsWith('forbidden-exec:'));
  const unexpectedPeerErrors = peerErrors.filter(value => !value.startsWith('forbidden-exec:'));
  if (executionMode === 'attached_pty') unexpectedPeerErrors.push(...report.denied_batch_exec);
  const shells = report.peer?.actions.filter((item: any[]) => item[1] === 'shell').length;
  const expectedShells = reconnect ? shells === (reconnectFailure && !reconnectNextTask ? 1 : 2) : shells >= 2;
  const rejectedReconnects = report.peer?.actions.filter((item: any[]) => item[1] === 'reconnect-rejected').length;
  const reconnectTransports = report.peer?.actions.filter((item: any[]) => item[1] === 'reconnect-transport').length;
  if (reconnect) report.reconnect_transport_count = reconnectTransports;
  if (reconnectFailure) report.rejected_reconnect_count = rejectedReconnects;
  const executionFenced = !reconnect || liveReconnect || reconnectFailure || (!report.old_generation_sent && report.new_generation_sent);
  let siblingUntouched = true;
  if (reconnectGroup) {
    const otherPeer = await readFile(join(siblingDir, 'report.json'), 'utf8').then(JSON.parse).catch(() => null);
    const otherInputs = await readFile(join(siblingDir, 'inputs.bin'), 'utf8').catch(() => '');
    report.other_peer = otherPeer;
    report.other_peer_pwd_submissions = otherInputs.split(/\r?\n/).filter(line => line === 'pwd' || line === 'pwd; sleep 4');
    siblingUntouched = otherPeer?.errors.length === 0 && otherPeer.actions.filter((item: any[]) => item[1] === 'shell').length === 1 && report.other_peer_pwd_submissions.length === 0;
  }
  const expectedReconnects = !reconnect || (reconnectTransports === (reconnectFailure && !reconnectNextTask ? 0 : 1) && (!reconnectFailure || rejectedReconnects === 1));
  if (reconnectGroup && !expectedReconnects && !report.error) report.error = 'The SSH peer recorded more than one failed reconnect before service restoration';
  report.status = success && executionFenced && peerCommandsMatch && siblingUntouched && app.exitCode === 0 && !report.forced_quit && unexpectedPeerErrors.length === 0 && expectedShells && expectedReconnects && report.peer.actions.some((item: any[]) => item[1] === 'subsystem' && item[2] === 'sftp') ? 'passed' : 'failed';
  if (report.status !== 'passed') process.exitCode = 1;
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  if (report.status === 'passed') await rm(isolated, { recursive: true, force: true });
  console.log(JSON.stringify({ status: report.status, error: report.error, out }));
}
