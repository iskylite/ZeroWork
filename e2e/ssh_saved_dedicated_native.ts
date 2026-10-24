/** Real SSH tab -> normal menu/source Input -> actual system directory picker
 * -> separate auxiliary SFTP/MD5 download. Native CUA is required only for the
 * middle-click menu trigger and AppKit picker; there is no injected JobSpec,
 * picker grant, @dl local-directory parameter, or synthetic transfer snapshot.
 * Dedicated Save consumer: root handles only the mandatory AppKit picker.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { copyFile, cp, mkdir, mkdtemp, open, readFile, readdir, realpath, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, clickAt, key, type_, inputState, resizeWindow, screenshot, consoleEvents, sleep } from "../zig-out/share/zenit/harness/client.ts";

const options: Record<string, string> = {};
for (let i = 2; i < process.argv.length; i += 2) {
  assert(["--binary", "--expected-sha", "--out", "--prepare-only", "--python", "--abort", "--saved-download-dir", "--shared-pacing-kbps", "--skip-clipboard"].includes(process.argv[i]) && process.argv[i + 1], `Invalid option ${process.argv[i]}`);
  options[process.argv[i]] = process.argv[i + 1];
}
const prepare = options["--prepare-only"] === "1";
const sharedMode = options["--shared-pacing-kbps"] !== undefined;
const sharedPacing = sharedMode ? Number(options["--shared-pacing-kbps"]) : 0;
assert(!sharedMode || (/^\d+$/.test(options["--shared-pacing-kbps"]) && Number.isSafeInteger(sharedPacing) && sharedPacing >= 0 && sharedPacing <= 4294967295), "Shared pacing is a saved unsigned KB/s setting, including 0");
const skipClipboard = options["--skip-clipboard"] === "1";
assert(options["--skip-clipboard"] === undefined || skipClipboard);
const savedDownloadDirectory = options["--saved-download-dir"] === "1";
assert(options["--prepare-only"] === undefined || prepare);
assert(options["--saved-download-dir"] === undefined || ["0", "1"].includes(options["--saved-download-dir"]));
assert(options["--out"], "Use a fresh --out directory; previous evidence is retained");
assert(prepare || (options["--binary"] && /^[0-9a-f]{64}$/.test(options["--expected-sha"] ?? "")), "Run requires root's fixed binary and SHA");
const output = resolve(options["--out"]);
const abortMarker = resolve(options["--abort"] ?? join(output, "abort"));
await mkdir(output, { recursive: true });
assert.equal((await readdir(output)).length, 0);
const report: any = {
  status: prepare ? "prepared_not_run" : "running", started_at: new Date().toISOString(), stages: [], actions: [], trust_decisions: [], checks: [], handoffs: [],
  abort_marker: abortMarker,
  saved_download_directory_mode: savedDownloadDirectory,
  shared_transfer_mode: sharedMode, shared_pacing_kbps: sharedMode ? sharedPacing : null, clipboard_revalidation_skipped: skipClipboard,
  scope: sharedMode ? "Saved shared SSH transfer policy and pacing, ordinary session menu/source/picker, original SSH transport SFTP and MD5 publication" : "Real SSH drag-release clipboard/right-click input, ordinary session menu, editable remote source, native system directory selection, auxiliary SFTP connection and MD5 publication",
  prerequisites: ["Root grants the single native verification slot and supplies a fixed test-mode binary SHA", "CUA operates this runner's exact PID only: drag-select the unique SSH sentinel, right-click without Enter, middle-click original terminal, then cancel/select the private directory in AppKit", "After each CUA action, root writes the printed completed marker (synchronization only; actual UI state is checked independently)", "Python/Paramiko and existing public file-RPC Harness; no new services or dependencies"],
  evidence: { synthetic_harness_input: true, physical_input_verified: false, real_native_picker_required: true, injected_job_spec: false, remote_write: false, user_vm_connections: 0 },
  limits: ["Prepared report is not an executed acceptance", "The original SSH terminal is a real SSH shell channel with controlled fixture output, not a system shell subprocess", "Native system-picker CUA evidence is collected separately by root; successful typed field output alone does not prove physical input", "Own SIGTERM teardown is separate from normal tab-close release evidence"],
};
if (prepare) {
  report.download_defaults_plan = {
    configured_download_dir: savedDownloadDirectory ? "Fresh owned absolute directory named Saved Downloads With Spaces, written through config.toml [transfer] download_dir" : "Built-in transfer.download_dir=~/Downloads",
    expected_initial_directory: savedDownloadDirectory ? "The runtime-created canonical directory, printed in handoff.json" : process.env.HOME ? join(process.env.HOME, "Downloads") : "No expanded hint when HOME is absent",
    selection_candidate: savedDownloadDirectory ? "The same owned Saved Downloads With Spaces directory; explicit AppKit Open is still required" : "Fresh owned download-target directory, printed in handoff.json",
    picker_receipt_injected: false, native_initial_directory_verified: false,
  };
  report.next_steps = ["Create isolated original SSH connection and trust only generated loopback fingerprint", "CUA drag-select unique SSH sentinel and right-click without Enter; assert actual pasteboard and original peer bytes", "CUA middle-click original terminal; click actual context.menu.download_file", "Check default path before and after typing remote source; Start remains disabled", "CUA inspect actual AppKit initial directory then Cancel; path/owner/source remain with no job", "Reopen actual AppKit picker and explicitly Open the selected directory; same path alone must not authorize Start", "Enable MD5 and submit once; real auxiliary authentication UI; verify bytes/job/owner/MD5", "Close exact SSH tab, preserve Local, prove no second shell or extra tab and both real connections released"];
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(`prepared_not_run: ${join(output, "report.json")}`);
  process.exit(0);
}
const isolated = await mkdtemp(join(tmpdir(), "zerowork-ssh-aux-native-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data"), local = join(isolated, savedDownloadDirectory ? "Saved Downloads With Spaces" : "download-target");
await Promise.all([mkdir(rpc), mkdir(data), mkdir(local)]);
const localDirectory = await realpath(local);
const expectedDownloadDirectory = savedDownloadDirectory ? localDirectory : process.env.HOME ? join(process.env.HOME, "Downloads") : "";
Object.assign(report, { isolated, rpc, data, local_fixture: local, download_defaults: {
  configured_download_dir: savedDownloadDirectory ? localDirectory : "~/Downloads", expected_initial_directory: expectedDownloadDirectory,
  selection_candidate: localDirectory, same_directory_must_be_explicitly_opened: savedDownloadDirectory,
  picker_receipt_injected: false, native_initial_directory_verified_by_runner: false,
} });
const appName = `ZeroWork SSH Download ${process.pid}`;
const bundleId = `local.zerowork.sshaux.${randomUUID()}`;
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
// An AppKit runModal may block the initiating click until CUA closes the picker.
process.env.ZENIT_E2E_TIMEOUT_MS = "240000";
const appLog = await open(join(output, "app.log"), "w"), peerLog = await open(join(output, "peer.log"), "w");
const peerOut = join(output, "peer");
const peer = spawn(options["--python"] ?? "python3", [resolve("e2e/ssh_aux_download_loopback.py"), "--out", peerOut], { stdio: ["ignore", peerLog.fd, peerLog.fd] });
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
const evidenceIds = ["tabs.strip", "sidebar.host", "workspace.pane", "workspace.statusbar", "connection.progress", "auth.challenge.modal", "context.menu.download_file", "transfer.confirmation", "transfer.remote_source", "transfer.local_directory.input", "transfer.manager", "toolbar.transfers"];
async function capture(name: string): Promise<void> {
  const samples = Object.fromEntries(await Promise.all(evidenceIds.map(async id => [id, await query(id)])));
  await writeFile(join(output, `${name}.tree.json`), JSON.stringify(samples, null, 2));
  const image = join(output, `${name}.png`);
  assert((await screenshot(image)).ok);
  report.stages.push({ name, screenshot: image, tree: join(output, `${name}.tree.json`), query_screenshot_atomic: false });
  console.log(`[ssh-aux-download] ${name}`);
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
  console.log(`[ssh-aux-download] CUA HANDOFF ${stage}: ${JSON.stringify(value)}`);
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
try {
  ready = await waitFor(async () => {
    if (peerError || peer.exitCode !== null || peer.signalCode !== null) throw peerError ?? new Error("Owned peer exited");
    try { return JSON.parse(await readFile(join(peerOut, "ready.json"), "utf8")); } catch (error) { if (error.code === "ENOENT") return null; throw error; }
  }, 15000);
  assert.equal(ready.host, "127.0.0.1"); assert.equal(ready.remote_path, "/fixture/release.txt");
  const fixture = `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="SSH Auxiliary Download Loopback"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`;
  await writeFile(join(data, "hosts.toml"), fixture);
  const configuration = '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n' +
    `\n[transfer]\ndedicated_connection=false\nverify_md5=false\nshared_pacing_kbps=2048\n` +
    (savedDownloadDirectory ? `download_dir=${JSON.stringify(localDirectory)}\n` : "");
  await writeFile(join(data, "config.toml"), configuration);
  report.peer = { ...ready, password: undefined, pid: peer.pid, output: peerOut };
  const routeSource = await readFile(resolve("src/host/file_route_factory.zig"), "utf8");
  assert(routeSource.includes(".open_shell = false"));
  await writeFile(join(output, "file-route-factory-source.zig"), routeSource);
  const registration = execFileSync("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", bundlePath], { encoding: "utf8" });
  report.launch_services_registration = { app_path: bundlePath, bundle_id: bundleId, exit_code: 0, output: registration.trim() };
  app = spawn(binary, [], { cwd: process.cwd(), detached: true, env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "0", ZENIT_E2E_ISOLATE_POINTER: "0", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZEROWORK_FILE_TRACE: "1", ZEROWORK_TERMINAL_POINTER_TRACE: "1", OPENAI_API_KEY: "", ANTHROPIC_API_KEY: "" }, stdio: ["ignore", appLog.fd, appLog.fd] });
  appEnded = new Promise<void>(done => app!.once("close", () => done())); app.once("error", error => { appError = error; }); report.pid = app.pid;
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), app.pid);
  assert((await resizeWindow(1440, 900)).ok);
  await click("workspace.empty.local"); await visible("terminal.surface");
  const originals = await tabs(); assert.equal(originals.length, 1); const localTab = originals[0].test_id;
  await click("sidebar.host"); await click("sidebar.host.connect");
  await settleAuthentication(async () => !(await query("connection.progress")).some(shown) && text((await query("workspace.pane")).find(shown)).includes("ZW_AUX_SOURCE_READY"), "01-original-ssh");
  const attached = await tabs(); assert.equal(attached.length, 2);
  const sshTab = attached.find(n => n.test_id !== localTab)?.test_id; assert(sshTab);
  await capture("02-original-ssh-terminal");
  assert.equal((await peerState()).connections.length, 1);
  await click("toolbar.settings"); await click("settings.nav.transfer");
  for (const field of ["verify_md5", "dedicated_connection"]) {
    await click("settings.search"); await key("a", {cmd:true}); await type_(field);
    await click(`settings.field.${field}`);
    await capture(`02-settings-draft-${field}`);
  }
  await click("settings.save");
  await waitFor(async()=>{
    const c=await readFile(join(data,"config.toml"),"utf8");
    return ["verify_md5 = true", "dedicated_connection = true"].every(x=>c.includes(x))?true:null;
  },10000);
  report.saved_transfer_values={verify_md5:true,dedicated_connection:true};
  report.scope="Actual UI Save false-to-true dedicated_connection then ordinary SSH menu download consumer with independent no-shell TCP and real hashes";
  await capture("03-settings-saved-policy"); await click("settings.close");
  const pane=await visible("workspace.pane");
  const menuDone=await handoff("03-open-terminal-menu", {action:"Use native CUA middle-click inside this exact original SSH terminal; leave its menu open", original_ssh_tab:sshTab,pane_rect:pane.rect});
  await menuDone();
  await click("context.menu.download_file");
  const initialPanel = await visible("transfer.confirmation");
  assert.equal((await inputState("transfer.local_directory.input")).buffer, expectedDownloadDirectory, "A new form shows the saved/default download suggestion");
  assert(!inside(initialPanel, "transfer.confirmation.submit")?.focusable, "A suggested directory alone does not grant Start");
  assert.equal((await peerState()).connections.length, 1, "A fresh suggested directory opens no auxiliary connection");
  assert.equal(text(await visible("toolbar.transfers")), "0");
  await capture("04a-fresh-form-default-directory-without-receipt");
  const source = await visible("transfer.remote_source");
  await clickNode(source, "Enter original remote path in the real source Input");
  assert((await key("a", { cmd: true })).ok); assert((await type_(ready.remote_path)).ok);
  assert.equal((await inputState("transfer.remote_source")).buffer, ready.remote_path);
  const panel = await visible("transfer.confirmation"), ownerMatch = text(panel).match(/所属会话[^#]*#(\d+)/); assert(ownerMatch);
  report.original_owner_id = Number(ownerMatch[1]);
  assert(text(panel).includes("SSH Auxiliary Download Loopback") && text(panel).includes("127.0.0.1"));
  assert.equal(panel.id, initialPanel.id);
  assert.equal((await inputState("transfer.local_directory.input")).buffer, expectedDownloadDirectory, "Entering the remote source preserves the suggested picker location");
  assert(!inside(panel, "transfer.confirmation.submit")?.focusable, "A typed source alone cannot bypass mandatory system selection");
  assert.equal((await peerState()).connections.length, 1, "Opening the form creates no auxiliary connection or job");
  assert.deepEqual(await traces(), [], "No transfer is ready or verified from a suggested path and typed source");
  report.download_defaults.before_source = expectedDownloadDirectory;
  report.download_defaults.after_source = (await inputState("transfer.local_directory.input")).buffer;
  report.download_defaults.start_before_picker = false;
  await capture("04-source-entered-default-directory-no-receipt-no-job");
  const pickerDone = await handoff("05b-native-directory-select", {
    action: savedDownloadDirectory ? "The next actual folder-button click reopens AppKit at expected_initial_directory. Explicitly choose this same directory and click Open; merely leaving the unchanged path visible is insufficient. Write completed_marker only after Open closes the picker" : "The next actual folder-button click reopens AppKit. Select exactly local_directory and explicitly click Open; write completed_marker after the picker closes",
    expected_initial_directory: expectedDownloadDirectory, local_directory: localDirectory,
    same_directory_as_default: savedDownloadDirectory, explicit_open_required: true, original_owner_id: report.original_owner_id,
  });
  const pickerClick = click("transfer.directory.choose").then(() => ({ ok: true }), error => ({ ok: false, error }));
  await pickerDone();
  const clickResult = await pickerClick; if (!clickResult.ok) throw clickResult.error;
  const selectedDirectory = (await inputState("transfer.local_directory.input")).buffer;
  const selectedCanonicalDirectory = await realpath(selectedDirectory);
  assert.equal(selectedCanonicalDirectory, localDirectory, "The actual picker result resolves to the selected owned directory");
  const [selectedStat, ownedStat] = await Promise.all([stat(selectedDirectory), stat(local)]);
  assert(selectedStat.isDirectory() && ownedStat.isDirectory());
  assert.equal(selectedStat.dev, ownedStat.dev, "Picker result stays on the owned directory's device");
  assert.equal(selectedStat.ino, ownedStat.ino, "Picker result names the exact owned directory inode");
  const freshPanel = await visible("transfer.confirmation");
  assert.equal(freshPanel.id, panel.id);
  assert(inside(freshPanel, "transfer.confirmation.submit")?.focusable, "Explicit AppKit Open grants this intent a receipt, even if its path is unchanged");
  assert.equal(text(await visible("toolbar.transfers")), "0", "A picker receipt alone creates no job before explicit Start");
  assert.deepEqual(await traces(), [], "Selection alone does not create a ready/verified transfer");
  report.picker_selection = { same_form_id: freshPanel.id, original_owner_id: report.original_owner_id, local_directory: selectedDirectory,
    canonical_directory: selectedCanonicalDirectory, owned_directory_identity: { dev: ownedStat.dev, ino: ownedStat.ino }, selected_directory_identity: { dev: selectedStat.dev, ino: selectedStat.ino },
    same_path_as_suggestion: selectedDirectory === expectedDownloadDirectory, same_directory_as_suggestion: selectedCanonicalDirectory === expectedDownloadDirectory,
    start_before: false, start_after: true, global_transfer_badge_before_submit: "0", actual_system_picker_receipt_required: true };
  assert(text(freshPanel).replaceAll(" ", "").includes("MD5校验·开"), "Saved MD5 default is used without manual override");
  assert.equal((await peerState()).connections.length, 1);
  await capture("05-actual-system-directory-selected");
  const transferStarted = Date.now();
  await click("transfer.confirmation.submit");
  await settleAuthentication(async () => (await traces()).some(t => t.trace_prefix === "FILE_TRANSFER_MANAGER_VERIFICATION" && Number(t.owner_id) === report.original_owner_id && t.state === "succeeded" && t.verification_state === "passed"), "06-auxiliary-sftp");
  const proof = (await traces()).find(t => t.trace_prefix === "FILE_TRANSFER_MANAGER_VERIFICATION" && Number(t.owner_id) === report.original_owner_id && t.state === "succeeded" && t.verification_state === "passed"); assert(proof);
  // The independent no-shell runtime emits this trace. Shared SSH uses the
  // original worker instead; its real verification is delivered to manager.
  const backend = (await traces()).find(t => t.trace_prefix === "FILE_TRANSFER_VERIFICATION" && t.engine_state === "succeeded" && t.verification_state === "passed");
  if (!sharedMode) assert(backend);
  const actual = await readFile(join(local, "release.txt"));
  assert.equal(actual.length, ready.source_size); assert.deepEqual(actual, await readFile(join(peerOut, "source.bin")));
  for (const value of [proof, ...(backend ? [backend] : [])]) { assert.equal(value.source_md5, ready.source_md5); assert.equal(value.target_md5, ready.source_md5); }
  assert.equal(createHash("sha256").update(actual).digest("hex"), ready.source_sha256);
  assert.deepEqual(await readdir(local), ["release.txt"], "No owned temporary file remains after safe publication");
  const enqueued = (await traces()).find(t => t.trace_prefix === "FILE_SESSION_TRANSFER_ENQUEUED" && Number(t.job) === Number(proof.job));
  assert(enqueued, "Actual main-app submission trace is required");
  assert.equal(enqueued.dedicated_connection, !sharedMode);
  assert.equal(Number(enqueued.pacing_kbps), sharedMode ? sharedPacing : 0);
  assert.equal(Number(enqueued.owner_id), report.original_owner_id);
  const afterTransfer = await peerState();
  assert.equal(afterTransfer.connections.length, sharedMode ? 1 : 2, "Saved connection policy determines actual TCP count");
  if (sharedMode) {
    assert(afterTransfer.calls.some(c => c.operation === "SUBSYSTEM" && c.name === "sftp" && c.connection === afterTransfer.terminal_connection), "Shared SFTP runs on the original terminal transport");
    assert.equal(report.trust_decisions.filter(v => v.stage === "06-auxiliary-sftp").length, 0, "Shared transfer never reauthenticates another connection");
  }
  const runtimeReady = (await traces()).filter(t => t.trace_prefix === "FILE_TRANSFER_READY");
  assert.equal(runtimeReady.length, sharedMode ? 0 : 1); if (!sharedMode) assert.equal(runtimeReady[0].channel_absent, true);
  assert.deepEqual((await tabs()).map(n => n.test_id), attached.map(n => n.test_id), "Auxiliary transfer opens no terminal or extra tab");
  report.transfer = { manager: proof, engine: backend ?? null, auxiliary_ready: runtimeReady[0] ?? null, submission: enqueued, elapsed_ms: Date.now() - transferStarted, actual_tcp_connections: afterTransfer.connections.length, downloaded_bytes: actual.length };
  await copyFile(join(local, "release.txt"), join(output, "actual-downloaded-release.bin"));
  await click("toolbar.transfers");
  const manager = await visible("transfer.manager");
  const task = nodes(manager).find(n => n.test_id === "transfer.task" && text(n).includes("release.txt") && text(n).includes("已完成")); assert(task);
  await clickNode(inside(task, "transfer.task.expand"), "Inspect actual job's original owner and paths");
  await waitFor(async () => {
    const value = text(await visible("transfer.manager"));
    return value.includes(`任务 #${proof.job} · 尝试 ${proof.attempt} · 会话 #${report.original_owner_id}`) && value.includes(ready.remote_path) && value.includes(selectedDirectory) || null;
  }, 15000);
  await capture("07-ordinary-ssh-auxiliary-download-completed");
  await clickNode(inside(await visible("transfer.manager"), "transfer.window.close"), "Close only current-window transfer list");
  await click(sshTab.replace("tabs.tab.", "tabs.close."));
  await waitFor(async () => { const current = await tabs(); return current.length === 1 && current[0].test_id === localTab ? current : null; }, 30000);
  await visible("terminal.surface");
  const released = await waitFor(async () => {
    const value = await peerState(); return value.connections.length === (sharedMode ? 1 : 2) && value.active_connections === 0 ? value : null;
  }, 15000);
  assert.equal(released.shell_requests.length, 1); assert.equal(released.pty_requests.length, 1);
  assert(released.shell_requests[0].accepted && released.pty_requests[0].accepted);
  assert(released.calls.some(c => c.operation === "SUBSYSTEM" && c.name === "sftp" && (sharedMode ? c.connection === released.terminal_connection : c.connection !== released.terminal_connection)));
  assert.equal(released.errors.length, 0); assert.equal(released.forbidden_operations.length, 0);
  assert.deepEqual([...released.read_handles_opened].sort(), [...released.read_handles_closed].sort());
  assert(released.connections.every(c => c.peer_closed_before_stop), "Original SSH and exact auxiliary connection both release before fixture shutdown");
  report.peer_before_shutdown = released;
  report.saved_config_after_transfer = await readFile(join(data, "config.toml"), "utf8");
  assert(["dedicated_connection = true", "verify_md5 = true"].every(x => report.saved_config_after_transfer.includes(x)));
  assert.equal(await readFile(join(data, "hosts.toml"), "utf8"), fixture);
  assert.equal(await readFile(join(data, "known_hosts"), "utf8").catch(error => { if (error.code === "ENOENT") return ""; throw error; }), "");
  await capture("08-original-ssh-and-aux-released-local-retained");
  report.checks.push("Saved/default directory appears before and after remote source input without granting Start", "Native picker cancellation preserves default path/source/owner, leaves Start disabled and zero transfer badge/auxiliary connection", "Explicit AppKit Open grants the matching receipt, including an unchanged saved path, but creates no job before Start", "Real ordinary SSH menu and editable source with mandatory system-directory result", sharedMode ? "Actual original-SSH shared SFTP, original job/owner and complete matching MD5" : "Actual independent no-shell auxiliary SFTP, original job/owner and complete matching MD5", sharedMode ? "No extra TCP connection/shell/terminal tab, actual bytes published, original connection released" : "No extra shell/terminal tab, actual bytes published, original and auxiliary connections released");
  if (sharedMode) report.checks.push("Saved shared policy and pacing consumed by the original-owner JobSpec; SFTP and shell share exactly one TCP connection, with matching MD5 and actual release");
  report.checks = ["Actual UI Save dedicated_connection=false to true before ordinary SSH download", "Actual ordinary SSH menu form; MD5 default never manually toggled", "Root selects owned directory through mandatory AppKit picker", "Submission consumes dedicated=true; peer records two TCP connections and only one original shell/PTY", "Actual downloaded bytes and both MD5 values plus SHA256 match", "Original and auxiliary connections release before peer shutdown"];
  report.status = "passed";
} catch (error) {
  failure = appError ?? peerError ?? error; report.status = "failed"; report.error = String(failure);
  if (app && app.exitCode === null && app.signalCode === null && !report.operator_abort) {
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
  try { report.peer_final = JSON.parse(await readFile(join(peerOut, "report.json"), "utf8")); } catch (error) { report.peer_report_error = String(error); }
  await appLog.close(); await peerLog.close();
  try { await cp(data, join(output, "isolated-data"), { recursive: true }); } catch (error) { report.data_copy_error = String(error); }
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
