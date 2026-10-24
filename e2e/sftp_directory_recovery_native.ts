/** Real main-app directory FIN -> explicit Recover -> fresh authentication -> same card/path.
 * Run only when root grants the native verification slot. The peer listens on
 * loopback only; local writes remain in this run's private temporary directory.
 * No synthetic Snapshot, injected transfer JobSpec, VM or remote mutation.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, cp, mkdir, mkdtemp, open, readFile, readdir, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, clickAt, key, type_, resizeWindow, screenshot, consoleEvents, sleep } from "../zig-out/share/zenit/harness/client.ts";

const options: Record<string, string> = {};
for (let i = 2; i < process.argv.length; i += 2) {
  assert(["--binary", "--expected-sha", "--out", "--prepare-only", "--python", "--theme", "--visual-errors"].includes(process.argv[i]) && process.argv[i + 1], `Invalid argument ${process.argv[i]}`);
  options[process.argv[i]] = process.argv[i + 1];
}
const prepare = options["--prepare-only"] === "1";
const visualErrors = options["--visual-errors"] === "1";
const theme = options["--theme"] ?? "dark";
assert(["dark", "light", "sauber"].includes(theme));
assert(options["--prepare-only"] === undefined || prepare, "--prepare-only accepts 1");
assert(options["--out"], "--out is required and must be a fresh directory");
assert(prepare || (options["--binary"] && /^[0-9a-f]{64}$/.test(options["--expected-sha"] ?? "")), "Run requires the newly integrated --binary and its exact --expected-sha");
const output = resolve(options["--out"]);
await mkdir(output, { recursive: true });
assert.equal((await readdir(output)).length, 0, "Keep previous evidence; use a fresh output directory");
const report: any = {
  status: prepare ? "prepared_not_run" : "running", started_at: new Date().toISOString(), stages: [], actions: [], checks: [], host_key_decisions: [],
  scope: "Real main-app original SFTP directory FIN, stale last list, explicit Recover, new host-key/password auth and same original owner/tab/path restoration",
  evidence: { synthetic_harness_input: true, physical_input_verified: false, synthetic_conflict_snapshot: false, vm_connections: 0, remote_writes_authorized: false },
  prerequisites: ["Fresh main-app test-mode build with explicit directory recovery integration and public Harness client installed", "macOS native verification slot granted by root; no concurrent test app", "Node supporting TypeScript stripping; Python with installed Paramiko; no new packages or service", "SourceFactory no-shell path and gated ZEROWORK_FILE_TRACE diagnostics in the supplied binary"],
  planned_steps: ["Real main-app initial SFTP directory and transfer attach", "Peer FIN only the LIST-owning connection", "Actual Refresh exposes stale original list; no automatic new connection", "Actual Recover then new trust/password, new directory binding and same original path/list/owner/tab", "Close file tab, prove all three actual connections released, original Local retained"],
  limits: ["Prepared report alone is not an executed native test", "GPU screenshots and tree queries are sequential, not atomic; a human still reviews saved native pixels", "The loopback source is controlled data, not a user-server acceptance result", "Own process SIGTERM cleanup is not a normal application window-close acceptance result"],
};
if (prepare) {
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(`prepared_not_run: ${join(output, "report.json")}`);
  process.exit(0);
}

const isolated = await mkdtemp(join(tmpdir(), "zerowork-native-directory-recovery-")), rpc = join(isolated, "rpc"), data = join(isolated, "data"), local = join(isolated, "download-target");
await Promise.all([mkdir(rpc), mkdir(data), mkdir(local)]);
Object.assign(report, { isolated, rpc, data, local_fixture: local });
const binary = join(output, "zerowork-frozen"), sourceBinary = resolve(options["--binary"]);
await copyFile(sourceBinary, binary);
await copyFile(join(dirname(sourceBinary), "zw_ipc.so"), join(output, "zw_ipc.so"));
const sha = createHash("sha256").update(await readFile(binary)).digest("hex");
assert.equal(sha, options["--expected-sha"], "Use root's exact newly integrated binary");
Object.assign(report, { binary, source_binary: sourceBinary, binary_sha256: sha });
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const appLog = await open(join(output, "app.log"), "w"), peerLog = await open(join(output, "peer.log"), "w");
const peerOut = join(output, "peer");
const peer = spawn(options["--python"] ?? "python3", [resolve("e2e/sftp_conflict_loopback.py"), "--out", peerOut, "--directory-fin"], { stdio: ["ignore", peerLog.fd, peerLog.fd] });
const peerEnded = new Promise<void>(done => peer.once("close", () => done()));
let peerError: Error | undefined;
peer.once("error", error => { peerError = error; });
let app: ReturnType<typeof spawn> | undefined, appEnded: Promise<void> | undefined, appError: Error | undefined, ready: any;
function shown(n: any): boolean { return !!n?.rect && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? n.opacity ?? 1) > 0 && n.rect.w > 0 && n.rect.h > 0; }
function nodes(n: any): any[] { return !shown(n) ? [] : [n, ...(n.children ?? []).flatMap(nodes)]; }
function text(n: any): string { return nodes(n).filter(v => typeof v.text === "string" && v.text.length > 0).map(v => v.text).join(" "); }
function inside(n: any, id: string): any { return nodes(n).find(v => v.test_id === id); }
async function visible(id: string, timeout = 15000): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null, timeout); }
async function clickNode(n: any, reason: string): Promise<void> {
  assert(shown(n), reason);
  report.actions.push({ reason, id: n.test_id, node_id: n.id, rect: n.rect, at: new Date().toISOString() });
  assert((await clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok, reason);
}
async function click(id: string): Promise<void> { await clickNode(await visible(id), id); }
async function tabs(): Promise<any[]> { return nodes(await visible("tabs.strip")).filter(n => /^tabs\.tab\.\d+$/.test(n.test_id ?? "")); }
const evidenceIds = ["tabs.strip", "sidebar.host", "auth.challenge.modal", "connection.progress", "files.presentation", "workspace.statusbar", "files.local", "files.remote", "files.error", "files.recover"];
async function capture(name: string): Promise<void> {
  await sleep(120);
  const samples = Object.fromEntries(await Promise.all(evidenceIds.map(async id => [id, await query(id)])));
  const treePath = join(output, `${name}.tree.json`), imagePath = join(output, `${name}.png`);
  await writeFile(treePath, JSON.stringify(samples, null, 2));
  assert((await screenshot(imagePath)).ok, `Real native screenshot ${name}`);
  report.stages.push({ name, at: new Date().toISOString(), tree: treePath, screenshot: imagePath, query_screenshot_atomic: false });
  console.log(`[sftp-directory-recovery] ${name}`);
}
async function traces(): Promise<any[]> {
  const log = await readFile(join(output, "app.log"), "utf8"), complete = log.slice(0, log.lastIndexOf("\n") + 1);
  const prefixes = ["SFTP_WORKSPACE_TRACE ", "SFTP_READONLY_READY ", "FILE_TRANSFER_READY ", "FILE_TRANSFER_ENQUEUED ", "FILE_TRANSFER_VERIFICATION ", "FILE_TRANSFER_MANAGER_VERIFICATION "];
  return complete.split("\n").flatMap((line, index) => {
    const prefix = prefixes.find(p => line.includes(p));
    return prefix ? [{ ...JSON.parse(line.slice(line.indexOf(prefix) + prefix.length)), trace_prefix: prefix.trim(), log_line: index + 1 }] : [];
  });
}
async function settleSftp(done?: () => Promise<boolean>): Promise<void> {
  const deadline = Date.now() + 75000;
  let decisions = 0;
  while (Date.now() < deadline) {
    assert(app && app.exitCode === null && app.signalCode === null, "Owned app remains alive while connecting");
    if (done ? await done() : (await query("files.workspace")).some(shown)) return;
    const modal = (await query("auth.challenge.modal")).find(n => shown(n) && (n.effective_opacity ?? n.opacity ?? 1) >= 0.999);
    const trust = modal && inside(modal, "auth.challenge.trust_once");
    if (trust?.focusable) {
      const endpoint = text(inside(modal, "auth.challenge.endpoint")), fingerprint = text(inside(modal, "auth.challenge.fingerprint"));
      assert(endpoint.includes("127.0.0.1") && endpoint.includes(String(ready.port)) && endpoint.includes(ready.user), `Trust only this exact owned peer: ${endpoint}`);
      assert(fingerprint.includes(ready.fingerprint), "UI must display this peer's actual generated key fingerprint");
      assert(++decisions <= 6, "Bound real trust/password decisions");
      await capture(`01-trust-once-${decisions}`);
      const same = (await query("auth.challenge.modal")).find(n => n.id === modal.id && shown(n));
      const button = same && inside(same, "auth.challenge.trust_once");
      if (button?.focusable && text(inside(same, "auth.challenge.fingerprint")).includes(ready.fingerprint)) {
        await clickNode(button, "Trust this exact loopback host key once through the live modal");
        report.host_key_decisions.push({ endpoint, fingerprint, choice: "trust_once", modal_id: modal.id });
      }
      await sleep(120); continue;
    }
    const answer = modal && inside(modal, "auth.challenge.answer.0");
    if (answer?.focusable) {
      assert(++decisions <= 6);
      assert(!/输入小写 yes|替换已保存/.test(text(modal)), "Key replacement is not authorized");
      assert(text(inside(modal, "auth.challenge.endpoint")).includes("127.0.0.1"));
      await clickNode(answer, "Enter only this peer's fixture password");
      assert((await key("a", { cmd: true })).ok); assert((await type_(ready.password)).ok);
      await clickNode(inside(modal, "auth.challenge.submit"), "Submit real authentication UI");
      await sleep(120); continue;
    }
    await sleep(80);
  }
  throw new Error("Actual loopback file workspace did not attach within 75 seconds");
}
let failure: unknown;
try {
  ready = await waitFor(async () => {
    if (peerError || peer.exitCode !== null || peer.signalCode !== null) throw peerError ?? new Error("Owned peer exited before ready");
    try { return JSON.parse(await readFile(join(peerOut, "ready.json"), "utf8")); } catch (error) { if (error.code === "ENOENT") return null; throw error; }
  }, 15000);
  assert.equal(ready.host, "127.0.0.1"); assert(ready.port > 0); assert.equal(ready.remote_path, "/fixture/release.txt");
  const fixture = `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="sftp"\nauth_mode="password"\noptions={strict_host_key=true}\nname="SFTP Directory Recovery Loopback"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`;
  await writeFile(join(data, "hosts.toml"), fixture);
  await writeFile(join(data, "config.toml"), `[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`);
  report.peer = { pid: peer.pid, ...ready, password: undefined, output: peerOut };
  const sourceFactory = await readFile(resolve("src/host/file_route_factory.zig"), "utf8");
  assert(sourceFactory.includes(".open_shell = false"));
  await writeFile(join(output, "file-route-factory-source.zig"), sourceFactory);
  app = spawn(binary, [], { cwd: process.cwd(), env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZEROWORK_FILE_TRACE: "1", OPENAI_API_KEY: "", ANTHROPIC_API_KEY: "" }, stdio: ["ignore", appLog.fd, appLog.fd] });
  appEnded = new Promise<void>(done => app!.once("close", () => done())); app.once("error", error => { appError = error; });
  report.pid = app.pid;
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), app.pid, "Only this owned native app receives RPC input");
  assert((await resizeWindow(1440, 900)).ok);
  await click("workspace.empty.local"); await visible("terminal.surface");
  const original = await tabs(); assert.equal(original.length, 1); const localTab = original[0].test_id;
  await click("sidebar.host"); await click("sidebar.host.connect");
  await settleSftp();
  assert.equal(report.host_key_decisions.length, 2, "Both independent unknown SFTP connections require actual trust-once UI");
  assert(!(await query("connection.progress")).some(shown));
  const attachedTabs = await tabs(); assert.equal(attachedTabs.length, 2);
  const fileTab = attachedTabs.find(n => n.test_id !== localTab)?.test_id; assert(fileTab);
  const attached = await waitFor(async () => (await traces()).find(t => t.trace_prefix === "SFTP_WORKSPACE_TRACE" && t.event === "attached") ?? null, 10000);
  assert.equal(attached.plugin, "sftp"); assert.equal(attached.terminal_present, false); assert.equal(attached.runtime_present, false);
  report.attachment = attached;
  if (visualErrors) {
   for (const failure of ["missing", "denied"]) {
    const path = inside(await visible("files.remote"), "files.path");
    await clickNode(path, "Navigate to an absent directory on the owned read-only peer");
    await key("a", { cmd: true }); await type_(`/${failure}-visual-directory`); await key("enter");
    await waitFor(async () => !!inside(await visible("files.remote"), "files.error") || null, 20000);
    await capture(`${failure}-directory-wide`);
    await resizeWindow(860, 480); await capture(`${failure}-directory-compact`);
    const retained = await visible("files.remote");
    assert(text(retained).includes("release.txt"), "Failed path keeps last successful listing");
    await clickNode(inside(retained, "files.path"), "Return to original directory using its existing path field");
    await key("a", { cmd: true }); await type_("/fixture"); await key("enter");
    await waitFor(async () => !inside(await visible("files.remote"), "files.error") || null, 20000);
    await resizeWindow(1440, 900);
   }
  }
  const beforeRemote = await visible("files.remote");
  assert.equal(text(inside(beforeRemote, "files.path")), "/fixture");
  const row = nodes(beforeRemote).find(n => n.test_id === "files.row" && inside(n, "files.row.name")?.text === "release.txt"); assert(row);
  await clickNode(row, "Select original remote entry before transport failure");
  await waitFor(async () => text(await visible("files.remote")).includes("已选 1 项") || null);
  const peerState = async () => JSON.parse(await readFile(join(peerOut, "state.json"), "utf8"));
  const before = await peerState(); assert.equal(before.connections.length, 2);
  const directoryConnection = before.calls.find(c => c.operation === "LIST" && c.path === "/fixture")?.connection; assert(directoryConnection);
  const initialDirectory = (await traces()).filter(t => t.trace_prefix === "SFTP_READONLY_READY"); assert.equal(initialDirectory.length, 1);
  assert(!(await query("ai.strip")).some(shown), "Standalone SFTP must not expose a terminal-only AI strip");
  await capture("02-original-remote-list-and-selection");
  await writeFile(join(peerOut, "drop-first"), "FIN only original directory connector\n");
  await waitFor(async () => (await peerState()).calls.some(c => c.operation === "CONTROL_FIN" && c.connection === directoryConnection) || null);
  await clickNode(inside(await visible("files.remote"), "files.refresh"), "Refresh original directory to expose actual socket FIN");
  await waitFor(async () => {
    const card = await visible("files.remote"), recover = inside(card, "files.recover");
    return recover?.focusable && inside(card, "files.error") ? card : null;
  }, 30000);
  const stale = await visible("files.remote");
  const staleRow = nodes(stale).find(n => n.test_id === "files.row" && inside(n, "files.row.name")?.text === "release.txt");
  assert(staleRow, "Last original listing stays visible through FIN");
  const staleCheck = inside(staleRow, "files.row.select");
  assert(staleCheck && nodes(staleCheck).some(n => n.tag === "image" && shown(n)), "Original selection check remains visible while stale footer shows its error status");
  assert.equal(text(inside(stale, "files.path")), "/fixture");
  assert(!(await query("auth.challenge.modal")).some(shown), "No authentication before explicit Recover");
  assert.equal((await peerState()).connections.length, 2, "FIN never automatically creates a replacement");
  assert.equal((await tabs()).find(n => n.test_id === fileTab)?.test_id, fileTab);
  await capture("03-fin-stale-original-card-no-auto-reconnect");
  if (visualErrors) {
    await resizeWindow(860, 480); await capture("fin-error-compact");
    const card = await visible("files.remote"), recover = inside(card, "files.recover");
    assert(recover && recover.rect.y >= card.rect.y && recover.rect.y + recover.rect.h <= card.rect.y + card.rect.h, "Recovery remains reachable inside compact card");
    await resizeWindow(1440, 900);
  }
  await clickNode(inside(stale, "files.recover"), "Explicitly recover only this original SFTP directory");
  await settleSftp(async () => {
    const card = await visible("files.remote"), currentPeer = await peerState();
    return currentPeer.connections.length === 3 && currentPeer.calls.some(c => c.operation === "LIST" && c.connection !== directoryConnection && c.path === "/fixture") && !inside(card, "files.error") && text(card).includes("release.txt");
  });
  const recovered = await visible("files.remote");
  assert.equal(text(inside(recovered, "files.path")), "/fixture");
  assert(text(recovered).includes("已选 1 项"), "Actual refresh preserves original entry key selection");
  assert.deepEqual((await tabs()).map(n => n.test_id), attachedTabs.map(n => n.test_id));
  const readyDirectories = (await traces()).filter(t => t.trace_prefix === "SFTP_READONLY_READY");
  assert.equal(readyDirectories.length, 2);
  assert.notEqual(readyDirectories[0].binding_id, readyDirectories[1].binding_id);
  assert(readyDirectories[1].generation > readyDirectories[0].generation);
  assert.equal(report.host_key_decisions.length, 3, "Recovery authenticates a third fresh connection with exact trust-once UI");
  assert.equal((await traces()).filter(t => t.trace_prefix === "SFTP_WORKSPACE_TRACE" && t.event === "attached").length, 1, "The original file tab is retained");
  assert.equal((await traces()).filter(t => t.trace_prefix === "FILE_TRANSFER_READY").length, 1, "Independent transfer binding is not replaced");
  assert.equal((await traces()).filter(t => t.trace_prefix === "FILE_TRANSFER_ENQUEUED").length, 0, "Directory recovery enqueues no transfer");
  report.recovery = { original_owner: attached.owner, original_tab: fileTab, original_directory: readyDirectories[0], recovered_directory: readyDirectories[1], path: "/fixture", source_entry: "release.txt", trust_count: report.host_key_decisions.length, transfer_binding_count: 1, tasks: 0 };
  await capture("04-new-auth-original-owner-path-and-list-restored");
  await click(fileTab.replace("tabs.tab.", "tabs.close."));
  await waitFor(async () => {
    const current = await tabs(); return current.length === 1 && current[0].test_id === localTab && !(await query("files.workspace")).some(shown) ? current : null;
  }, 30000);
  await visible("terminal.surface");
  const closed = await waitFor(async () => (await traces()).find(t => t.trace_prefix === "SFTP_WORKSPACE_TRACE" && t.event === "closed" && Number(t.tab_id) === Number(attached.tab_id) && t.owner.session_id === attached.owner.session_id && t.owner.generation === attached.owner.generation) ?? null, 15000);
  report.closed_attachment = closed;
  const releasedPeer = await waitFor(async () => {
    const value = JSON.parse(await readFile(join(peerOut, "state.json"), "utf8"));
    return value.connections.length === 3 && value.active_connections === 0 ? value : null;
  }, 15000);
  assert.equal(releasedPeer.forbidden_operations.length, 0); assert.equal(releasedPeer.errors.length, 0);
  assert.deepEqual([...releasedPeer.read_handles_opened].sort(), [...releasedPeer.read_handles_closed].sort());
  assert(releasedPeer.calls.some(c => c.operation === "LIST" && c.path === "/fixture"));
  assert.equal(releasedPeer.calls.filter(c => c.operation === "AUTH" && c.accepted).length, 3);
  assert(releasedPeer.connections.every(c => c.peer_closed_before_stop), "All original and replacement connections close before fixture shutdown");
  report.peer_before_shutdown = releasedPeer;
  assert.equal(await readFile(join(data, "hosts.toml"), "utf8"), fixture);
  assert.equal(await readFile(join(data, "known_hosts"), "utf8").catch(error => { if (error.code === "ENOENT") return ""; throw error; }), "", "Trust-once does not save the key");
  await capture("07-file-tab-released-original-local-retained");
  report.checks.push("Real directory-only FIN preserves stale original listing, selection and tab without automatic reconnect", "Explicit Recover requires fresh authentication, changes directory binding, rereads original path and preserves independent transfer", "All three actual connections release before peer teardown; original Local remains; no transfer enqueued or remote write");
  report.status = "passed";
} catch (error) {
  failure = appError ?? peerError ?? error; report.status = "failed"; report.error = String(failure);
  if (app && app.exitCode === null && app.signalCode === null) {
    try { await capture("failure-live"); } catch (captureError) { report.capture_error = String(captureError); }
    try { await writeFile(join(output, "failure-console.json"), JSON.stringify(await consoleEvents(0, 150), null, 2)); } catch (consoleError) { report.console_error = String(consoleError); }
  }
} finally {
  try { report.runtime_traces = await traces(); } catch (traceError) { report.trace_error = String(traceError); }
  if (app) {
    if (app.exitCode === null && app.signalCode === null) app.kill("SIGTERM");
    await Promise.race([appEnded, sleep(2000)]);
    if (app.exitCode === null && app.signalCode === null) { app.kill("SIGKILL"); await appEnded; }
    report.app_cleanup = { exit_code: app.exitCode, signal: app.signalCode };
  }
  if (peer.exitCode === null && peer.signalCode === null) peer.kill("SIGTERM");
  await Promise.race([peerEnded, sleep(3000)]);
  if (peer.exitCode === null && peer.signalCode === null) { peer.kill("SIGKILL"); await peerEnded; }
  report.peer_cleanup = { exit_code: peer.exitCode, signal: peer.signalCode };
  try { report.peer_final = JSON.parse(await readFile(join(peerOut, "report.json"), "utf8")); } catch (peerReportError) { report.peer_report_error = String(peerReportError); }
  await appLog.close(); await peerLog.close();
  try { await cp(data, join(output, "isolated-data"), { recursive: true }); } catch (copyError) { report.data_copy_error = String(copyError); }
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
