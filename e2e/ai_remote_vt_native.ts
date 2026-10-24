/** Real AI remote/VT attachment acceptance. Reuses SSH loopback + public Harness.
 * Root alone owns native launch and CUA; prepare-only does not start anything.
 * Physical CUA selects original VT text and opens its ordinary context menu.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { copyFile, mkdir, mkdtemp, open, readFile, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, clickAt, key, type_, inputState, resizeWindow, screenshot, sleep } from "../zig-out/share/zenit/harness/client.ts";

const options: Record<string, string> = {};
for (let i = 2; i < process.argv.length; i += 2) {
  assert(["--binary", "--expected-sha", "--out", "--prepare-only", "--python", "--abort", "--config"].includes(process.argv[i]) && process.argv[i + 1], `Invalid option ${process.argv[i]}`);
  options[process.argv[i]] = process.argv[i + 1];
}
const prepare = options["--prepare-only"] === "1";
assert(options["--prepare-only"] === undefined || prepare);
assert(options["--out"], "Use a fresh --out directory; previous evidence is retained");
assert(prepare || (options["--binary"] && /^[0-9a-f]{64}$/.test(options["--expected-sha"] ?? "")), "Run requires root's fixed binary and SHA");
const output = resolve(options["--out"]);
const abortMarker = resolve(options["--abort"] ?? join(output, "abort"));
await mkdir(output, { recursive: true });
assert.equal((await readdir(output)).length, 0);
const report: any = {
  status: prepare ? "prepared_not_run" : "running", started_at: new Date().toISOString(), stages: [], actions: [], trust_decisions: [], checks: [], handoffs: [],
  abort_marker: abortMarker,
  scope: "Original SSH owner -> real readonly SFTP remote picker -> explicit attachment + real VT selection -> one real MiMo request",
  prerequisites: ["Root grants serial native slot and supplies frozen binary SHA plus private MiMo config", "CUA selects unique VT token and middle-clicks exact PID terminal", "Completion marker synchronizes only; actual menu/preview is checked", "Existing Python/Paramiko and public Harness"],
  evidence: { synthetic_harness_input: true, physical_input_verified: false, remote_write: false, user_vm_connections: 0 },
  limits: ["Prepared report is not executed acceptance", "Fixture shell channel emits controlled VT output without running a shell subprocess", "Root must capture CUA separately for physical selection evidence", "SIGTERM cleanup does not prove normal tab-close lifecycle", "UI metadata proves original owner ID; generation/ref counts are covered by separate domain tests"],
};
if (prepare) {
  report.scope = "Original SSH owner -> real readonly SFTP remote picker -> explicit attachment + real VT selection -> one real MiMo request";
  report.next_steps = ["Run with root-frozen binary, expected SHA and private MiMo config", "Trust generated loopback fingerprint via actual modal", "Read unique remote text through original-owner picker, confirm preview explicitly", "CUA select unique VT sentinel and middle-click original terminal; harness clicks ask_ai", "Confirm terminal preview explicitly and send both refs in one MiMo request", "Compare exact two attachment-only sentinels; reopen sent previews and compare immutable source metadata"];
  report.cua = "One foreground handoff: drag-select entire unique ZW_CLIP_SSH token on original SSH terminal then middle-click that terminal; do not paste or type sentinel";
  report.prerequisites.push("--config points to private real MiMo config; never log or copy it to evidence");
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(`prepared_not_run: ${join(output, "report.json")}`);
  process.exit(0);
}
const isolated = await mkdtemp(join(tmpdir(), "zerowork-ai-remote-vt-native-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
await Promise.all([mkdir(rpc), mkdir(data)]);
Object.assign(report, { isolated, rpc, data });
const appName = `ZeroWork AI Remote VT ${process.pid}`;
const bundleId = `local.zerowork.airemotevt.${randomUUID()}`;
const bundlePath = join(output, `${appName}.app`), contents = join(bundlePath, "Contents");
const binary = join(contents, "MacOS", "zerowork");
await mkdir(join(contents, "MacOS"), { recursive: true });
await mkdir(join(contents, "Resources"), { recursive: true });
await copyFile(resolve("assets/macos/AppIcon.icns"), join(contents, "Resources", "AppIcon.icns"));
await writeFile(join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>${bundleId}</string><key>CFBundleName</key><string>${appName}</string><key>CFBundleDisplayName</key><string>${appName}</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleVersion</key><string>1</string><key>NSHighResolutionCapable</key><true/></dict></plist>`);
await copyFile(resolve(options["--binary"]), binary);
await copyFile(join(dirname(resolve(options["--binary"])), "zw_ipc.so"), join(contents, "MacOS", "zw_ipc.so"));
const sha = createHash("sha256").update(await readFile(binary)).digest("hex");
assert.equal(sha, options["--expected-sha"]);
Object.assign(report, { bundle_id: bundleId, app_path: bundlePath, app_name: appName, launch_mode: "foreground_native_with_system_pointer", binary, source_binary: resolve(options["--binary"]), binary_sha256: sha });
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
// CUA handoff has a separate bounded synchronization deadline.
process.env.ZENIT_E2E_TIMEOUT_MS = "240000";
const appLog = await open(join(output, "app.log"), "w"), peerLog = await open(join(output, "peer.log"), "w");
const peerOut = join(output, "peer");
const peer = spawn(options["--python"] ?? "python3", [resolve("e2e/ssh_aux_download_loopback.py"), "--out", peerOut, "--ai-material"], { stdio: ["ignore", peerLog.fd, peerLog.fd] });
const peerEnded = new Promise<void>(done => peer.once("close", () => done()));
let peerError: Error | undefined, appError: Error | undefined;
peer.once("error", error => { peerError = error; });
let app: ReturnType<typeof spawn> | undefined, appEnded: Promise<void> | undefined, ready: any;
function shown(n: any): boolean { return !!n?.rect && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? n.opacity ?? 1) > 0 && n.rect.w > 0 && n.rect.h > 0; }
function nodes(n: any): any[] {
  if (!n || n.hidden === true || n.visible === false || (n.effective_opacity ?? n.opacity ?? 1) <= 0) return [];
  // ScrollArea's intermediate nodes may have no geometry; never prune their children.
  return [n, ...(n.children ?? []).flatMap(nodes)];
}
function text(n: any): string { return nodes(n).filter(v => typeof v.text === "string" && v.text.length > 0).map(v => v.text).join(" "); }
function inside(n: any, id: string): any { return nodes(n).find(v => v.test_id === id); }
async function visible(id: string, timeout = 15000): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null, timeout); }
async function clickNode(n: any, reason: string): Promise<void> {
  assert(shown(n), reason);
  report.actions.push({ reason, test_id: n.test_id, id: n.id, rect: n.rect });
  assert((await clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok, reason);
}
async function click(id: string): Promise<void> { await clickNode(await visible(id), id); }
async function tabs(): Promise<any[]> { return nodes(await visible("tabs.strip")).filter(n => /^tabs\.tab\.\d+$/.test(n.test_id ?? "")); }
const evidenceIds = ["ai.panel", "ai.remote.picker", "ai.remote.status", "ai.attachment.preview", "ai.attachment.preview.text", "ai.attachment.preview.metadata", "ai.attachments", "ai.response", "tabs.strip", "sidebar.host", "workspace.pane", "workspace.statusbar", "connection.progress", "auth.challenge.modal", "context.menu", "context.menu.ask_ai"];
async function capture(name: string): Promise<void> {
  const samples = Object.fromEntries(await Promise.all(evidenceIds.map(async id => [id, await query(id)])));
  await writeFile(join(output, `${name}.tree.json`), JSON.stringify(samples, null, 2));
  const image = join(output, `${name}.png`);
  assert((await screenshot(image)).ok);
  report.stages.push({ name, screenshot: image, tree: join(output, `${name}.tree.json`), query_screenshot_atomic: false });
  console.log(`[ai-remote-vt] ${name}`);
}
async function peerState(): Promise<any> { return JSON.parse(await readFile(join(peerOut, "state.json"), "utf8")); }
async function traces(): Promise<any[]> {
  const log = await readFile(join(output, "app.log"), "utf8"), complete = log.slice(0, log.lastIndexOf("\n") + 1);
  const prefixes = ["FILE_SESSION_TRANSFER_ENQUEUED ", "FILE_TRANSFER_READY ", "FILE_TRANSFER_VERIFICATION ", "FILE_TRANSFER_MANAGER_VERIFICATION "];
  return complete.split("\n").flatMap((line, index) => {
    const prefix = prefixes.find(p => line.includes(p));
    return prefix ? [{ ...JSON.parse(line.slice(line.indexOf(prefix) + prefix.length)), trace_prefix: prefix.trim(), log_line: index + 1 }] : [];
  });
}
async function settleAuthentication(done: () => Promise<boolean>, stage: string): Promise<void> {
  let decisions = 0;
  const deadline = Date.now() + 75000;
  while (Date.now() < deadline) {
    assert(app && app.exitCode === null && app.signalCode === null, "Owned app remains alive");
    if (await done()) return;
    const modal = (await query("auth.challenge.modal")).find(n => shown(n) && (n.effective_opacity ?? n.opacity ?? 1) >= 0.999);
    const trust = modal && inside(modal, "auth.challenge.trust_once");
    if (trust?.focusable) {
      const endpoint = text(inside(modal, "auth.challenge.endpoint")), fingerprint = text(inside(modal, "auth.challenge.fingerprint"));
      assert(endpoint.includes("127.0.0.1") && endpoint.includes(String(ready.port)) && endpoint.includes(ready.user));
      assert(fingerprint.includes(ready.fingerprint), "Trust only this actual generated peer key");
      assert(++decisions <= 6);
      await capture(`${stage}-trust-once-${decisions}`);
      const fresh = (await query("auth.challenge.modal")).find(n => n.id === modal.id && shown(n));
      const button = fresh && inside(fresh, "auth.challenge.trust_once");
      if (button?.focusable && text(inside(fresh, "auth.challenge.fingerprint")).includes(ready.fingerprint)) {
        await clickNode(button, "Actual trust-once button for exact original endpoint");
        report.trust_decisions.push({ stage, endpoint, fingerprint, choice: "trust_once", modal_id: modal.id });
      }
      await sleep(100); continue;
    }
    const answer = modal && inside(modal, "auth.challenge.answer.0");
    if (answer?.focusable) {
      assert(++decisions <= 6);
      assert(text(inside(modal, "auth.challenge.endpoint")).includes("127.0.0.1"));
      assert(!/输入小写 yes|替换已保存/.test(text(modal)));
      await clickNode(answer, "Enter only this isolated peer's password");
      assert((await key("a", { cmd: true })).ok); assert((await type_(ready.password)).ok);
      await clickNode(inside(modal, "auth.challenge.submit"), "Submit actual typed challenge");
      await sleep(100); continue;
    }
    await sleep(100);
  }
  throw new Error(`Actual ${stage} authentication/attach did not finish`);
}
async function handoff(stage: string, details: any): Promise<() => Promise<void>> {
  const completed = join(output, `${stage}.completed`);
  const value = { stage, status: "waiting_for_cua", pid: app?.pid, bundle_id: bundleId, app_path: bundlePath, app_name: appName, completed_marker: completed, abort_marker: abortMarker, ...details };
  report.handoffs.push(value);
  await writeFile(join(output, "handoff.json"), JSON.stringify(value, null, 2));
  await writeFile(join(output, "report.in-progress.json"), JSON.stringify(report, null, 2));
  console.log(`[ai-remote-vt] CUA HANDOFF ${stage}: ${JSON.stringify(value)}`);
  return async () => {
    const deadline = Date.now() + 180000;
    while (Date.now() < deadline) {
      assert(app && app.exitCode === null && app.signalCode === null, "Owned app is still alive during CUA handoff");
      let abortReason: string | undefined;
      try { abortReason = await readFile(abortMarker, "utf8"); }
      catch (error) { if (error.code !== "ENOENT") throw error; }
      if (abortReason !== undefined) {
        report.operator_abort = { stage, reason: abortReason.slice(0, 1000) };
        value.status = "operator_aborted";
        throw new Error(`Native operator aborted ${stage}: ${abortReason.slice(0, 1000)}`);
      }
      try { await readFile(completed); value.status = "cua_marker_received_ui_verification_pending"; return; }
      catch (error) { if (error.code !== "ENOENT") throw error; }
      await sleep(200);
    }
    throw new Error(`CUA ${stage} did not finish; missing ${completed}`);
  };
}
let failure: unknown;
async function fill(id: string, value: string): Promise<void> {
  await click(id); assert((await key("a", { cmd: true })).ok); assert((await type_(value)).ok);
  assert.equal((await inputState(id)).buffer, value);
}
async function preview(expected: string): Promise<{text: string, metadata: string, path: string}> {
  await visible("ai.attachment.preview");
  const value = { text: text(await visible("ai.attachment.preview.text")), metadata: text(await visible("ai.attachment.preview.metadata")), path: text(await visible("ai.attachment.preview.path")) };
  assert(value.text.includes(expected), "Preview must contain sentinel obtained only from actual source bytes");
  assert(/#\d+/.test(value.metadata), "Preview identifies original session owner");
  return value;
}
try {
  assert(options["--config"], "Run requires private --config (never logged or copied to evidence)");
  ready = await waitFor(async () => {
    if (peerError || peer.exitCode !== null) throw peerError ?? new Error("Owned peer exited");
    try { return JSON.parse(await readFile(join(peerOut, "ready.json"), "utf8")); } catch (error) { if (error.code === "ENOENT") return null; throw error; }
  }, 15000);
  assert.equal(ready.host, "127.0.0.1"); assert(ready.file_sentinel && ready.clipboard_sentinel);
  const fixture = `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="AI Remote VT Loopback"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`;
  await writeFile(join(data, "hosts.toml"), fixture);
  // Copy credentials only to isolated private runtime data, never to evidence.
  await copyFile(resolve(options["--config"]), join(data, "config.toml"));
  report.peer = { ...ready, password: undefined, pid: peer.pid, output: peerOut };
  execFileSync("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", bundlePath]);
  const environment = { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "0", ZENIT_E2E_ISOLATE_POINTER: "0", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZEROWORK_TERMINAL_POINTER_TRACE: "1" };
  delete environment.ZEROWORK_AI_MOCK;
  app = spawn(binary, [], { cwd: process.cwd(), detached: true, env: environment, stdio: ["ignore", appLog.fd, appLog.fd] });
  appEnded = new Promise<void>(done => app!.once("close", () => done())); app.once("error", error => { appError = error; }); report.pid = app.pid;
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), app.pid);
  assert((await resizeWindow(1440, 900)).ok);
  await click("workspace.empty.local"); await visible("terminal.surface");
  const originals = await tabs(); assert.equal(originals.length, 1);
  await click("sidebar.host"); await click("sidebar.host.connect");
  await settleAuthentication(async () => !(await query("connection.progress")).some(shown) && text((await query("workspace.pane")).find(shown)).includes("ZW_AUX_SOURCE_READY"), "01-original-ssh");
  assert.equal((await tabs()).length, 2);
  await capture("01-original-owner");
  await click("toolbar.ai"); await visible("ai.prompt");
  await click("ai.composer.attachment"); await click("ai.attachment.remote_file");
  await visible("ai.remote.picker");
  await settleAuthentication(async () => (await query("ai.remote.entry")).some(shown), "02-original-owner-readonly");
  await fill("ai.remote.path", "/fixture"); await click("ai.remote.go");
  const entry = await waitFor(async () => (await query("ai.remote.entry")).find(n => shown(n) && text(n).includes("release.txt")) ?? null, 20000);
  await clickNode(entry, "Select actual remote release.txt row"); await click("ai.remote.read");
  const remote = await waitFor(async () => (await query("ai.attachment.preview.text")).some(n => shown(n) && text(n).includes(ready.file_sentinel)) ? preview(ready.file_sentinel) : null, 20000);
  assert.equal(remote.path, ready.remote_path);
  assert(!(await query("ai.attachments")).filter(shown).some(n => nodes(n).some(c => c.test_id === "ai.attachment.remote_file")), "Candidate preview is not yet a ready attachment");
  report.remote_candidate = remote;
  await capture("03-remote-candidate-before-explicit-attach");
  await click("ai.attachment.preview.keep");
  await visible("ai.attachment.remote_file");
  await click("ai.close");
  await capture("04-ready-for-vt-selection");
  const pane = await visible("workspace.pane");
  const sentinelRow = nodes(pane).find(n => n.text === ready.clipboard_sentinel && shown(n));
  assert(sentinelRow, "Run-unique VT token has an actual rendered terminal row");
  const metrics = await waitFor(async () => {
    const log = await readFile(join(output, "app.log"), "utf8");
    const values = log.split("\n").filter(line => line.startsWith("TERMINAL_POINTER_METRICS ")).map(line => JSON.parse(line.slice("TERMINAL_POINTER_METRICS ".length)));
    return values.reverse().find(value => nodes(pane).some(n => n.id === value.node_id) && value.cell_width > 0 && Math.abs(value.origin_x - sentinelRow.rect.x) < 0.5) ?? null;
  }, 5000);
  const drag = {
    from: [metrics.origin_x + metrics.cell_width * 0.25, sentinelRow.rect.y + sentinelRow.rect.h / 2],
    to: [metrics.origin_x + metrics.cell_width * (ready.clipboard_sentinel.length - 0.75), sentinelRow.rect.y + sentinelRow.rect.h / 2],
  };
  const waitSelection = await handoff("05-vt-select-and-middle-click", {
    sentinel_row_rect: sentinelRow.rect, actual_terminal_metrics: metrics, drag_logical_points: drag,
    drag_reference_2x_screenshot_pixels: { from: drag.from.map(n => n * 2), to: drag.to.map(n => n * 2) },
    expected_selected_text: ready.clipboard_sentinel,
    instruction: "On this exact PID original SSH terminal, drag-select ONLY the whole visible ZW_CLIP_SSH token, then middle-click within original terminal to open context menu. Do not use clipboard paste, do not type any sentinel. Write marker after menu opens.",
    pane: (await query("workspace.pane")).find(shown)?.rect,
  });
  await waitSelection();
  let previousMenu: any, stableMenuSamples = 0;
  const menuItem = await waitFor(async () => {
    const menu = (await query("context.menu")).find(n => shown(n) && (n.effective_opacity ?? n.opacity ?? 1) >= 0.999);
    const item = menu && inside(menu, "context.menu.ask_ai");
    if (!item || !shown(item) || !item.focusable) { stableMenuSamples = 0; return null; }
    const signature = JSON.stringify({ id: item.id, rect: item.rect });
    stableMenuSamples = signature === previousMenu ? stableMenuSamples + 1 : 0;
    previousMenu = signature;
    return stableMenuSamples >= 2 ? item : null;
  }, 10000);
  await capture("05b-stable-ask-ai-menu-before-action");
  const freshMenuItem = (await query("context.menu.ask_ai")).find(n => shown(n) && n.id === menuItem.id && JSON.stringify(n.rect) === JSON.stringify(menuItem.rect));
  assert(freshMenuItem, "Original menu row remains stable immediately before click");
  await clickNode(freshMenuItem, "context.menu.ask_ai");
  const vt = await preview(ready.clipboard_sentinel);
  assert.equal(vt.metadata.match(/#\d+/)?.[0], remote.metadata.match(/#\d+/)?.[0], "Both captures preserve original SSH owner");
  report.terminal_candidate = vt;
  await capture("06-vt-candidate-before-explicit-attach");
  await click("ai.attachment.preview.keep"); await visible("ai.attachment.terminal_text");
  await visible("ai.attachment.remote_file");
  const before = await peerState();
  assert.equal(before.shell_requests.length, 1); assert.equal(before.pty_requests.length, 1);
  assert.equal(before.terminal_received_total, 0, "VT selection and AI attachment must not write terminal bytes");
  assert.equal(before.forbidden_operations.length, 0); assert.equal(before.errors.length, 0);
  assert.deepEqual([...before.read_handles_opened].sort(), [...before.read_handles_closed].sort());
  const prompt = "Read the two attached resources. Reply with exactly the value after 'File sentinel:' in the remote file, then a single space, then the ZW_CLIP_SSH token in the terminal selection. No labels, explanation, tools, or commands.";
  assert(!prompt.includes(ready.file_sentinel) && !prompt.includes(ready.clipboard_sentinel));
  await fill("ai.prompt", prompt); await capture("07-two-refs-one-draft"); await click("ai.send");
  const expected = `${ready.file_sentinel} ${ready.clipboard_sentinel}`;
  await waitFor(async () => !(await query("ai.stop")).some(shown) && (await query("ai.response")).some(n => shown(n) && text(n).trim() === expected) || null, 120000);
  report.response = expected;
  await capture("08-real-mimo-exact-two-sentinels");
  // Sent cards retain their captured references; opening them must not re-read.
  const readsBeforeHistory = (await peerState()).calls.filter(c => c.operation === "READ").length;
  for (const [id, original, sentinel] of [["ai.attachment.remote_file", remote, ready.file_sentinel], ["ai.attachment.terminal_text", vt, ready.clipboard_sentinel]] as const) {
    const card = await visible(id); const open = inside(card, "ai.attachment.open"); assert(open);
    await clickNode(open, "Reopen original sent immutable reference");
    assert.deepEqual(await preview(sentinel), original, "Sent preview preserves exact source bytes, owner and capture metadata");
    await capture(id.includes("terminal") ? "10-sent-vt-ref" : "09-sent-remote-ref");
    await click("ai.attachment.preview.close");
  }
  assert.equal((await peerState()).calls.filter(c => c.operation === "READ").length, readsBeforeHistory, "History preview must not read remote again");
  report.checks.push("Real original SSH owner and readonly SFTP remote picker", "Remote and VT previews require explicit attachment", "No terminal input/remote writes or extra shell", "One real MiMo request receives both attachment-only unique sentinels", "Sent history keeps identical bytes, source owner and capture metadata without rereading");
  report.status = "passed";
} catch (error) {
  failure = appError ?? peerError ?? error; report.status = "failed"; report.error = String(failure);
  if (app && app.exitCode === null && !report.operator_abort) try { await capture("failure-live"); } catch (error) { report.capture_error = String(error); }
} finally {
  if (app) {
    if (app.exitCode === null && app.signalCode === null) app.kill("SIGTERM");
    await Promise.race([appEnded, sleep(2000)]);
    if (app.exitCode === null && app.signalCode === null) { app.kill("SIGKILL"); await appEnded; }
    report.app_cleanup = { exit_code: app.exitCode, signal: app.signalCode };
  }
  if (peer.exitCode === null && peer.signalCode === null) peer.kill("SIGTERM");
  await Promise.race([peerEnded, sleep(3000)]);
  if (peer.exitCode === null && peer.signalCode === null) { peer.kill("SIGKILL"); await peerEnded; }
  try { report.peer_final = JSON.parse(await readFile(join(peerOut, "report.json"), "utf8")); } catch (error) { report.peer_report_error = String(error); }
  await appLog.close(); await peerLog.close();
  // Do not copy isolated data: config.toml contains the provider credential.
  report.finished_at = new Date().toISOString(); await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
