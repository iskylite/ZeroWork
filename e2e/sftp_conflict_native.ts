/** Real main-app download conflict -> local overwrite UI -> SFTP/MD5 result.
 * Run only when root grants the native verification slot. The peer listens on
 * loopback only; local writes remain in this run's private temporary directory.
 * No synthetic Snapshot, injected transfer JobSpec, VM or remote mutation.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, cp, mkdir, mkdtemp, open, readFile, readdir, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, clickAt, key, type_, resizeWindow, screenshot, consoleEvents, sleep, mouseDown, mouseMove, mouseUp } from "../zig-out/share/zenit/harness/client.ts";

const options: Record<string, string> = {};
for (let i = 2; i < process.argv.length; i += 2) {
  assert(["--binary", "--expected-sha", "--out", "--prepare-only", "--python", "--file-menus", "--drag-download", "--physical-drag"].includes(process.argv[i]) && process.argv[i + 1], `Invalid argument ${process.argv[i]}`);
  options[process.argv[i]] = process.argv[i + 1];
}
const prepare = options["--prepare-only"] === "1";
const fileMenus = options["--file-menus"] === "1";
const dragDownload = options["--drag-download"] === "1";
const physicalDrag = options["--physical-drag"] === "1";
assert(options["--physical-drag"] === undefined || physicalDrag, "--physical-drag accepts 1");
assert(!physicalDrag || dragDownload, "--physical-drag requires --drag-download 1");
assert(options["--drag-download"] === undefined || dragDownload);
assert(!(fileMenus && dragDownload), "Use separate fresh runs for menu and drag acceptance");
assert(options["--file-menus"] === undefined || fileMenus);
assert(options["--prepare-only"] === undefined || prepare, "--prepare-only accepts 1");
assert(options["--out"], "--out is required and must be a fresh directory");
assert(prepare || (options["--binary"] && /^[0-9a-f]{64}$/.test(options["--expected-sha"] ?? "")), "Run requires the newly integrated --binary and its exact --expected-sha");
const output = resolve(options["--out"]);
await mkdir(output, { recursive: true });
assert.equal((await readdir(output)).length, 0, "Keep previous evidence; use a fresh output directory");
const report: any = {
  file_menus: fileMenus, drag_download: dragDownload, physical_drag: physicalDrag, status: prepare ? "prepared_not_run" : "running", started_at: new Date().toISOString(), stages: [], actions: [], checks: [], host_key_decisions: [],
  scope: "Real main-app sidebar/file-workspace/Manager/SftpEngine conflict and local overwrite, against an owned immutable loopback SFTP peer",
  evidence: { synthetic_harness_input: true, physical_input_verified: false, synthetic_conflict_snapshot: false, vm_connections: 0, remote_writes_authorized: false },
  prerequisites: ["Fresh main-app test-mode build with current conflict/MD5/file transfer integration and public Harness client installed", "macOS native verification slot granted by root; no concurrent test app", "Node supporting TypeScript stripping; Python with installed Paramiko; no new packages or service", "SourceFactory no-shell path and gated ZEROWORK_FILE_TRACE diagnostics in the supplied binary"],
  planned_steps: ["Owned loopback peer and private data/RPC/local destination", "Actual sidebar SFTP connect and exact fingerprint trust-once UI for both connections", "Actual file row selection and download confirmation with MD5 enabled through UI", "Actual same-name conflict; choose overwrite and inspect local confirmation; Back preserves old bytes", "Choose overwrite again; only explicit local confirmation permits replacement", "Actual downloaded bytes/full MD5, original Manager job/attempt completion, no owned temp, foreign partial unchanged", "Close exact file tab and retain original Local; peer records both connections released"],
  limits: ["Prepared report alone is not an executed native test", "GPU screenshots and tree queries are sequential, not atomic; a human still reviews saved native pixels", "The loopback source is controlled data, not a user-server acceptance result", "Own process SIGTERM cleanup is not a normal application window-close acceptance result"],
};
if (prepare) {
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(`prepared_not_run: ${join(output, "report.json")}`);
  process.exit(0);
}

const isolated = await mkdtemp(join(tmpdir(), "zerowork-native-conflict-")), rpc = join(isolated, "rpc"), data = join(isolated, "data"), local = join(isolated, "download-target");
await Promise.all([mkdir(rpc), mkdir(data), mkdir(local)]);
Object.assign(report, { isolated, rpc, data, local_fixture: local });
const binary = join(output, "zerowork-frozen"), sourceBinary = resolve(options["--binary"]);
await copyFile(sourceBinary, binary);
await copyFile(join(dirname(sourceBinary), "zw_ipc.so"), join(output, "zw_ipc.so"));
const sha = createHash("sha256").update(await readFile(binary)).digest("hex");
assert.equal(sha, options["--expected-sha"], "Use root's exact newly integrated binary");
Object.assign(report, { binary, source_binary: sourceBinary, binary_sha256: sha });
const appPath = physicalDrag ? join(output, "ZeroWork-Physical-Drag.app") : undefined;
const bundleId = physicalDrag ? `local.zerowork.physical-drag.${process.pid}` : undefined;
const launchServices = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
let executable = binary, appRegistered = false;
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const appLog = await open(join(output, "app.log"), "w"), peerLog = await open(join(output, "peer.log"), "w");
const peerOut = join(output, "peer");
const peer = spawn(options["--python"] ?? "python3", [resolve("e2e/sftp_conflict_loopback.py"), "--out", peerOut], { stdio: ["ignore", peerLog.fd, peerLog.fd] });
const peerEnded = new Promise<void>(done => peer.once("close", () => done()));
let peerError: Error | undefined;
peer.once("error", error => { peerError = error; });
let app: ReturnType<typeof spawn> | undefined, appEnded: Promise<void> | undefined, appError: Error | undefined, ready: any;
const oldBytes = Buffer.from("ZEROWORK_PRIVATE_OLD_LOCAL_TARGET_DO_NOT_REPLACE_BEFORE_CONFIRM\n"), foreignPart = Buffer.from("UNRELATED_PARTIAL_MUST_NOT_BE_ADOPTED_OR_REMOVED\n");
const destination = join(local, "release.txt"), unrelated = join(local, "release.txt.part");
await writeFile(destination, oldBytes); await writeFile(unrelated, foreignPart);

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
async function stableMenuItem(menuId: string, itemId: string): Promise<any> {
  let previous = "", stable = 0;
  return waitFor(async () => {
    const menu = (await query(menuId)).find(n => shown(n) && (n.effective_opacity ?? n.opacity ?? 1) >= 0.999);
    const item = menu && inside(menu, itemId);
    if (!menu || !shown(item) || !item.focusable || item.rect.x < menu.rect.x || item.rect.y < menu.rect.y || item.rect.x + item.rect.w > menu.rect.x + menu.rect.w + 1 || item.rect.y + item.rect.h > menu.rect.y + menu.rect.h + 1) { stable = 0; return null; }
    const current = JSON.stringify([menu.id, menu.rect, item.id, item.rect]);
    stable = current === previous ? stable + 1 : 0;
    previous = current;
    await sleep(80);
    return stable >= 2 ? item : null;
  }, 15000);
}
async function tabs(): Promise<any[]> { return nodes(await visible("tabs.strip")).filter(n => /^tabs\.tab\.\d+$/.test(n.test_id ?? "")); }
const evidenceIds = ["tabs.strip", "sidebar.host", "auth.challenge.modal", "connection.progress", "files.presentation", "transfer.confirmation", "transfer.conflict", "transfer.manager", "workspace.statusbar", "files.context.menu", "files.history.menu", "files.drag.preview", "files.drag.target", "files.copy.confirmation"];
async function capture(name: string): Promise<void> {
  await sleep(120);
  const samples = Object.fromEntries(await Promise.all(evidenceIds.map(async id => [id, await query(id)])));
  const treePath = join(output, `${name}.tree.json`), imagePath = join(output, `${name}.png`);
  await writeFile(treePath, JSON.stringify(samples, null, 2));
  assert((await screenshot(imagePath)).ok, `Real native screenshot ${name}`);
  report.stages.push({ name, at: new Date().toISOString(), tree: treePath, screenshot: imagePath, query_screenshot_atomic: false });
  console.log(`[sftp-conflict] ${name}`);
}
async function traces(): Promise<any[]> {
  const log = await readFile(join(output, "app.log"), "utf8"), complete = log.slice(0, log.lastIndexOf("\n") + 1);
  const prefixes = ["SFTP_WORKSPACE_TRACE ", "SFTP_READONLY_READY ", "FILE_TRANSFER_READY ", "FILE_TRANSFER_ENQUEUED ", "FILE_TRANSFER_VERIFICATION ", "FILE_TRANSFER_MANAGER_VERIFICATION "];
  return complete.split("\n").flatMap((line, index) => {
    const prefix = prefixes.find(p => line.includes(p));
    return prefix ? [{ ...JSON.parse(line.slice(line.indexOf(prefix) + prefix.length)), trace_prefix: prefix.trim(), log_line: index + 1 }] : [];
  });
}
async function unchanged(reason: string): Promise<void> {
  assert.deepEqual(await readFile(destination), oldBytes, reason);
  assert.deepEqual(await readFile(unrelated), foreignPart, "Unrelated partial bytes remain unchanged");
  report.checks.push(reason);
}
async function settleSftp(): Promise<void> {
  const deadline = Date.now() + 75000;
  let decisions = 0;
  while (Date.now() < deadline) {
    assert(app && app.exitCode === null && app.signalCode === null, "Owned app remains alive while connecting");
    if ((await query("files.workspace")).some(shown)) return;
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
async function navigateLocal(): Promise<void> {
  const path = inside(await visible("files.local"), "files.path");
  await clickNode(path, "Set the actual local pane destination to private fixture");
  assert((await key("a", { cmd: true })).ok); assert((await type_(local)).ok); assert((await key("return")).ok);
  const canonical = await realpath(local);
  const result = await waitFor(async () => {
    const card = await visible("files.local");
    const path = inside(card, "files.path"), renderedValues = nodes(path).filter(n => typeof n.text === "string");
    const rows = nodes(card).filter(n => n.test_id === "files.row").map(n => ({ name: inside(n, "files.row.name")?.text, size: inside(n, "files.row.size")?.text }));
    return path?.tag === "input" && renderedValues.length === 1 && renderedValues[0].text === canonical &&
      rows.some(n => n.name === "release.txt" && n.size === `${oldBytes.length} B`) &&
      rows.some(n => n.name === "release.txt.part" && n.size === `${foreignPart.length} B`) &&
      !inside(card, "files.error") ? { card, path, renderedValue: renderedValues[0].text, rows } : null;
  }, 20000);
  report.local_navigation = { canonical_path: canonical, rendered_input_text: result.renderedValue, input_node_id: result.path.id, actual_rows: result.rows };
}
async function conflict(confirmation: boolean): Promise<any> {
  let previous = "";
  return waitFor(async () => {
    const card = (await query("transfer.conflict")).find(shown);
    if (!card || !!inside(card, "transfer.conflict.confirm.paths") !== confirmation || !text(card).includes(confirmation ? "确认覆盖本地文件" : "同名文件处理")) { previous = ""; return null; }
    const viewport = inside(card, "transfer.conflict.viewport"), content = viewport?.children?.find(shown), footer = inside(card, "transfer.conflict.footer");
    const buttons = [inside(card, "transfer.conflict.apply"), ...(confirmation ? [inside(card, "transfer.conflict.back")] : [])];
    // Match the production S.panel contract: long paths grow the 228px local
    // confirmation to natural body height + 116px chrome (this fixture: 244).
    const expectedHeight = content ? Math.max(confirmation ? 228 : 409, content.rect.h + 116) : 0;
    const within = (n: any, parent: any): boolean => !!n && !!parent && n.rect.x >= parent.rect.x - 0.5 && n.rect.y >= parent.rect.y - 0.5 && n.rect.x + n.rect.w <= parent.rect.x + parent.rect.w + 0.5 && n.rect.y + n.rect.h <= parent.rect.y + parent.rect.h + 0.5;
    if (!content || !footer || Math.abs(card.rect.w - (confirmation ? 480 : 620)) > 0.5 || Math.abs(card.rect.h - expectedHeight) > 0.5 ||
      Math.abs(content.rect.w - (card.rect.w - 28)) > 0.5 || !within(footer, card) || buttons.some(n => !within(n, footer))) { previous = ""; return null; }
    const geometry = JSON.stringify([card.id, card.rect, content.rect, footer.rect, ...buttons.map(n => [n.id, n.rect])]);
    if (geometry !== previous) { previous = geometry; return null; }
    return card;
  }, 15000);
}
async function conflictClick(confirmation: boolean, id: string, reason: string, originalCard: any): Promise<void> {
  const expectedButton = inside(originalCard, id);
  assert(expectedButton, `Original modal contains ${id}`);
  const fresh = await conflict(confirmation);
  assert.equal(fresh.id, originalCard.id, "Re-query the same live modal entity after screenshot/layout changes");
  const button = inside(fresh, id);
  assert.equal(button?.id, expectedButton.id, "Decision targets the same actual button, using its current geometry");
  assert(button?.focusable, "Decision button is actually enabled before synthetic pointer input");
  await clickNode(button, reason);
}

let failure: unknown;
try {
  ready = await waitFor(async () => {
    if (peerError || peer.exitCode !== null || peer.signalCode !== null) throw peerError ?? new Error("Owned peer exited before ready");
    try { return JSON.parse(await readFile(join(peerOut, "ready.json"), "utf8")); } catch (error) { if (error.code === "ENOENT") return null; throw error; }
  }, 15000);
  assert.equal(ready.host, "127.0.0.1"); assert(ready.port > 0); assert.equal(ready.remote_path, "/fixture/release.txt");
  const fixture = `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="sftp"\nauth_mode="password"\noptions={strict_host_key=true}\nname="SFTP Loopback Conflict"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`;
  await writeFile(join(data, "hosts.toml"), fixture);
  await writeFile(join(data, "config.toml"), '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
  report.peer = { pid: peer.pid, ...ready, password: undefined, output: peerOut };
  const sourceFactory = await readFile(resolve("src/host/file_route_factory.zig"), "utf8");
  assert(sourceFactory.includes(".open_shell = false"));
  await writeFile(join(output, "file-route-factory-source.zig"), sourceFactory);
  if (physicalDrag) {
    const contents = join(appPath!, "Contents"), macos = join(contents, "MacOS"), resources = join(contents, "Resources");
    await Promise.all([mkdir(macos, { recursive: true }), mkdir(resources, { recursive: true })]);
    executable = join(macos, "zerowork");
    await copyFile(binary, executable);
    await copyFile(join(output, "zw_ipc.so"), join(macos, "zw_ipc.so"));
    await copyFile(resolve("assets/macos/AppIcon.icns"), join(resources, "AppIcon.icns"));
    await writeFile(join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>${bundleId}</string><key>CFBundleName</key><string>ZeroWork Physical Drag ${process.pid}</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
    // Sign the copied runtime bundle; preserve the verified frozen source bytes above.
    execFileSync("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", `${bundleId}.ipc`, join(macos, "zw_ipc.so")]);
    execFileSync("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", bundleId!, appPath!]);
    execFileSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath!]);
    Object.assign(report, { app_path: appPath, bundle_id: bundleId, runtime_binary: executable, runtime_binary_sha256: createHash("sha256").update(await readFile(executable)).digest("hex") });
    appRegistered = true;
    execFileSync(launchServices, ["-f", appPath!]);
  }
  app = spawn(executable, [], { cwd: process.cwd(), env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: physicalDrag ? "0" : "1", ZENIT_E2E_ISOLATE_POINTER: physicalDrag ? "0" : "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZEROWORK_FILE_TRACE: "1", OPENAI_API_KEY: "", ANTHROPIC_API_KEY: "" }, stdio: ["ignore", appLog.fd, appLog.fd] });
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
  await navigateLocal();
  if (fileMenus) {
    await clickNode(inside(await visible("files.remote"), "files.history"), "Open original remote card history");
    const history = await visible("files.history.menu");
    assert(text(history).includes("远程路径历史") && text(history).includes("/fixture"));
    assert(Math.abs(history.rect.w - 340) <= 1, "Bridge history panel is 340px");
    await capture("01a-real-original-card-path-history");
    const historyListCount = JSON.parse(await readFile(join(peerOut, "state.json"), "utf8")).calls.filter(c => c.operation === "LIST").length;
    await clickNode(await stableMenuItem("files.history.menu", "files.history.navigate"), "Navigate using this original card history record");
    await waitFor(async () => JSON.parse(await readFile(join(peerOut, "state.json"), "utf8")).calls.filter(c => c.operation === "LIST").length > historyListCount || null, 15000);
    await waitFor(async () => !(await query("files.history.menu")).some(shown) && text(inside(await visible("files.remote"), "files.path")) === "/fixture" || null, 15000);
  }
  const remote = await visible("files.remote"); assert.equal(text(inside(remote, "files.path")), "/fixture");
  const row = nodes(remote).find(n => n.test_id === "files.row" && nodes(n).some(v => v.test_id === "files.row.name" && v.text === "release.txt")); assert(row);
  await clickNode(row, "Select the real immutable peer file");
  await waitFor(async () => /已选 1 项/.test(text(await visible("files.remote"))) || null, 10000);
  if (fileMenus) {
    await clickNode(inside(await visible("files.remote"), "files.context"), "Open selected original remote card menu");
    const context = await visible("files.context.menu");
    assert(Math.abs(context.rect.w - 260) <= 1, "Bridge context panel is 260px");
    assert(text(context).includes("下载所选") && text(context).includes("复制完整路径"));
    assert(!inside(context, "files.context.rename").focusable, "Design's rename remains unavailable");
    await capture("01b-real-original-card-selected-context");
    await clickNode(await stableMenuItem("files.context.menu", "files.context.transfer"), "Open frozen selected source and destination confirmation from menu");
    report.checks.push("Real original-card history navigates; 340px history and 260px context are rendered; rename is disabled; context opens actual transfer confirmation");
  } else if (dragDownload) {
    const freshRow = nodes(await visible("files.remote")).find(n => n.test_id === "files.row" && inside(n, "files.row.name")?.text === "release.txt"); assert(freshRow);
    const source = inside(freshRow, "files.row.drag"), destination = inside(await visible("files.local"), "files.data_clip"); assert(source && destination);
    const from = { x: source.rect.x + Math.min(100, source.rect.w / 2), y: source.rect.y + source.rect.h / 2 };
    const to = { x: destination.rect.x + 140, y: destination.rect.y + Math.min(160, destination.rect.h / 2) };
    if (physicalDrag) {
      assert(!(await query("transfer.confirmation")).some(shown) && !(await query("files.copy.confirmation")).some(shown));
      assert.equal(text(await visible("toolbar.transfers")), "0", "No job before physical drag handoff");
      assert(!(await traces()).some(t => t.trace_prefix === "FILE_TRANSFER_ENQUEUED"), "No premature job before handoff");
      await unchanged("Physical drag handoff starts with original destination bytes intact");
      await capture("01c-physical-drag-ready");
      const completionMarker = join(output, "physical-drag-complete.json"), abortMarker = join(output, "physical-drag-abort");
      const deadline = Date.now() + 5 * 60 * 1000;
      const handoff = {
        status: "awaiting_physical_drag", app_pid: app!.pid, app_path: appPath, bundle_id: bundleId,
        screenshot: join(output, "01c-physical-drag-ready.png"), tree: join(output, "01c-physical-drag-ready.tree.json"),
        coordinate_space: "window logical coordinates; map to CUA app screenshot coordinates before dragging",
        source: { node_id: source.id, test_id: source.test_id, rect: source.rect, point: from },
        target: { node_id: destination.id, test_id: destination.test_id, rect: destination.rect, point: to },
        completion_marker: completionMarker, completion_content: { status: "completed", app_pid: app!.pid, input: "cua.app.drag" },
        abort_marker: abortMarker, deadline: new Date(deadline).toISOString(),
        instructions: "Select app_path or bundle_id with CUA, verify the owned app_pid, use app.drag, then write completion_content to completion_marker. Write any text to abort_marker to abort. No held-preview screenshot required.",
      };
      report.physical_drag_handoff = handoff;
      await writeFile(join(output, "handoff.json"), JSON.stringify(handoff, null, 2));
      console.log(`[sftp-conflict] physical drag ready: ${join(output, "handoff.json")}`);
      let completion: any;
      while (Date.now() < deadline) {
        assert(app!.exitCode === null && app!.signalCode === null, "Owned app remains alive during physical drag handoff");
        const aborted = await readFile(abortMarker, "utf8").then(() => true, error => { if (error.code === "ENOENT") return false; throw error; });
        assert(!aborted, "Physical drag handoff aborted by operator");
        const marker = await readFile(completionMarker, "utf8").catch(error => { if (error.code === "ENOENT") return null; throw error; });
        if (marker !== null) {
          completion = JSON.parse(marker);
          assert.equal(completion.status, "completed"); assert.equal(completion.app_pid, app!.pid); assert.equal(completion.input, "cua.app.drag");
          break;
        }
        await sleep(250);
      }
      assert(completion, "Physical drag completion marker required within five minutes");
      await visible("files.copy.confirmation");
      assert(!(await query("files.drag.preview")).some(shown), "Physical release clears the drag preview");
      assert.equal((await query("files.copy.confirmation")).filter(shown).length, 1, "Physical release opens exactly one inline confirmation");
      assert.equal(text(await visible("toolbar.transfers")), "0", "Physical drop alone never enqueues a transfer");
      assert(!(await traces()).some(t => t.trace_prefix === "FILE_TRANSFER_ENQUEUED"), "No job before explicit inline submit");
      await unchanged("Physical drop confirmation leaves original destination bytes intact");
      report.evidence.physical_input_verified = true;
      report.evidence.physical_input_verification = { completion_marker: completionMarker, ...completion, held_preview_verified: false };
      report.checks.push("Externally attested CUA physical drag opens exactly one original inline confirmation with zero premature jobs; held preview not inspected");
    } else {
      assert((await mouseDown(from.x, from.y)).ok);
      assert((await mouseMove(from.x + 8, from.y)).ok);
      assert((await mouseMove(to.x, to.y)).ok);
      const preview = await visible("files.drag.preview");
      assert(text(preview).includes("松开下载 1 项") && text(preview).includes(await realpath(local)));
      assert(!(await query("transfer.confirmation")).some(shown) && !(await query("files.copy.confirmation")).some(shown));
      assert.equal(text(await visible("toolbar.transfers")), "0", "A held drag never enqueues a transfer");
      await capture("01c-real-cross-card-drag-frozen-target-preview");
      assert((await mouseUp(to.x, to.y)).ok);
      await visible("files.copy.confirmation");
      assert(!(await query("files.drag.preview")).some(shown), "Pointer release clears only the drag preview");
      report.checks.push("Actual public mouseDown/move/up crosses original SFTP to original local card; no pre-release task, target preview and one confirmation on release");
    }
  } else await clickNode(inside(await visible("files.remote"), "files.transfer"), "Open actual remote-card download confirmation");
  const panel = await visible("files.copy.confirmation");
  assert.equal(Math.round(panel.rect.h), 132, "Native original-card confirmation matches Bridge height");
  const md5 = inside(panel, "files.copy.md5"); assert(md5);
  await clickNode(md5, "Enable full MD5 using production inline confirmation checkbox");
  const canonicalLocal = await realpath(local);
  assert(text(panel).includes(`#${attached.owner.session_id}`));
  assert(text(inside(panel, "files.copy.source")).includes("/fixture"));
  assert(text(inside(panel, "files.copy.target")).includes(canonicalLocal));
  assert.equal(text(await visible("toolbar.transfers")), "0", "Inline draft alone never enqueues a job");
  await unchanged("Before enqueue, actual original local bytes and unrelated partial remain intact");
  await capture("02-original-owner-download-confirmation");
  await click("files.copy.submit");
  let card = await conflict(false);
  assert(text(card).includes(join(canonicalLocal, "release.txt")) && text(card).includes(`会话#${attached.owner.session_id}`));
  assert(inside(card, "transfer.conflict.overwrite") && inside(card, "transfer.conflict.save_as") && inside(card, "transfer.conflict.keep_both") && inside(card, "transfer.conflict.skip"));
  await unchanged("Actual engine conflict is waiting: original target remains unchanged before any choice");
  await capture("03-real-engine-conflict-choice");
  await conflictClick(false, "transfer.conflict.overwrite", "Choose overwrite for this actual original conflict", card);
  await conflictClick(false, "transfer.conflict.apply", "Apply the actual overwrite choice", card);
  card = await conflict(true);
  assert.equal(text(inside(card, "transfer.conflict.confirm.paths")), join(canonicalLocal, "release.txt"));
  assert(text(inside(card, "transfer.conflict.confirm.metadata")).includes(`会话#${attached.owner.session_id}`));
  await unchanged("Choosing overwrite opens a second confirmation and still leaves original bytes intact");
  await capture("04-local-overwrite-confirmation-no-write");
  await conflictClick(true, "transfer.conflict.back", "Return without authorizing replacement", card);
  card = await conflict(false);
  await unchanged("Returning from confirmation preserves the original file and leaves the same conflict waiting");
  await capture("05-back-to-same-original-conflict");
  await conflictClick(false, "transfer.conflict.overwrite", "Choose overwrite after returning", card);
  await conflictClick(false, "transfer.conflict.apply", "Apply overwrite after returning", card);
  card = await conflict(true);
  await unchanged("Immediately before explicit confirmation, no premature overwrite occurred");
  await conflictClick(true, "transfer.conflict.apply", "Explicitly authorize actual local replacement", card);
  await waitFor(async () => {
    const bytes = await readFile(destination); return createHash("sha256").update(bytes).digest("hex") === ready.sha256 ? bytes : null;
  }, 45000);
  await waitFor(async () => !(await query("transfer.conflict")).some(shown) || null, 15000);
  const proof = await waitFor(async () => {
    const current = await traces();
    const accepted = current.filter(t => t.trace_prefix === "FILE_TRANSFER_ENQUEUED" && Number(t.owner_id) === Number(attached.owner.session_id) && Number(t.owner_generation) === Number(attached.owner.generation));
    assert(accepted.length <= 1, "One UI confirmation queues only one original job"); if (!accepted.length) return null;
    const job = accepted[0]; assert.equal(job.md5_check, true);
    const backend = current.find(t => t.trace_prefix === "FILE_TRANSFER_VERIFICATION" && t.binding_id === job.binding_id && t.generation === job.binding_generation && t.engine_state === "succeeded" && t.verification_state === "passed");
    const manager = current.find(t => t.trace_prefix === "FILE_TRANSFER_MANAGER_VERIFICATION" && t.job === job.job && t.owner_id === job.owner_id && t.owner_generation === job.owner_generation && t.state === "succeeded" && t.verification_state === "passed");
    return backend && manager ? { enqueued: job, backend, manager } : null;
  }, 20000);
  for (const value of [proof.backend, proof.manager]) { assert.equal(value.source_md5, ready.md5); assert.equal(value.target_md5, ready.md5); }
  report.actual_transfer = proof;
  const downloaded = await readFile(destination); assert.equal(downloaded.length, ready.size);
  assert.deepEqual(downloaded, await readFile(join(peerOut, "source.bin")));
  assert.deepEqual(await readFile(unrelated), foreignPart);
  assert.deepEqual((await readdir(local)).sort(), ["release.txt", "release.txt.part"], "Completed engine leaves no owned .zerowork-*.part artifact and preserves foreign partial");
  await copyFile(destination, join(output, "actual-downloaded-release.bin"));
  await click("toolbar.transfers");
  const manager = await waitFor(async () => {
    const current = await visible("transfer.manager");
    const task = nodes(current).find(n => n.test_id === "transfer.task" && text(n).includes("release.txt") && text(n).includes("已完成"));
    return task ? { current, task } : null;
  }, 20000);
  await clickNode(inside(manager.task, "transfer.task.expand"), "Inspect the real completed original transfer");
  await waitFor(async () => {
    const current = await visible("transfer.manager"), value = text(current);
    return value.includes(`任务 #${proof.enqueued.job} · 尝试 ${proof.manager.attempt}`) && value.includes(ready.remote_path) && value.includes(canonicalLocal) ? current : null;
  }, 10000);
  await capture("06-actual-overwrite-md5-manager-completed");
  await clickNode(inside(await visible("transfer.manager"), "transfer.window.close"), "Close only the inline download list");
  await waitFor(async () => !(await query("transfer.manager")).some(shown) || null, 10000);
  const refreshedSize = `${(ready.size / 1024).toFixed(1)} KiB`;
  report.destination_refresh = { expected_directory: canonicalLocal, actual_filesystem_bytes: downloaded.length, expected_download_display_size: refreshedSize, foreign_partial_bytes: foreignPart.length };
  await waitFor(async () => {
    const card = await visible("files.local"), path = inside(card, "files.path");
    const renderedPath = nodes(path).filter(n => typeof n.text === "string");
    const rows = nodes(card).filter(n => n.test_id === "files.row").map(n => ({ name: inside(n, "files.row.name")?.text, size: inside(n, "files.row.size")?.text }));
    report.destination_refresh.last_sample = { directory: renderedPath.map(n => n.text), rows };
    return path?.tag === "input" && renderedPath.length === 1 && renderedPath[0].text === canonicalLocal &&
      rows.some(n => n.name === "release.txt" && n.size === refreshedSize) &&
      rows.some(n => n.name === "release.txt.part" && n.size === `${foreignPart.length} B`) && !inside(card, "files.error") ? card : null;
  }, 15000);
  assert.equal((await readFile(destination)).length, ready.size, "Visible destination row describes the actual newly published 65829-byte file");
  assert.deepEqual(await readFile(unrelated), foreignPart);
  await capture("06a-destination-refreshed-new-file-size");
  report.checks.push("After actual succeeded/released and closing the inline list, the original local pane automatically shows the new 65829-byte file as 64.3 KiB and retains the unrelated 49 B partial");
  await click(fileTab.replace("tabs.tab.", "tabs.close."));
  await waitFor(async () => {
    const current = await tabs(); return current.length === 1 && current[0].test_id === localTab && !(await query("files.workspace")).some(shown) ? current : null;
  }, 30000);
  await visible("terminal.surface");
  const closed = await waitFor(async () => (await traces()).find(t => t.trace_prefix === "SFTP_WORKSPACE_TRACE" && t.event === "closed" && Number(t.tab_id) === Number(attached.tab_id) && t.owner.session_id === attached.owner.session_id && t.owner.generation === attached.owner.generation) ?? null, 15000);
  report.closed_attachment = closed;
  const peerState = await waitFor(async () => {
    const value = JSON.parse(await readFile(join(peerOut, "state.json"), "utf8"));
    return value.connections.length === 2 && value.active_connections === 0 ? value : null;
  }, 15000);
  assert.equal(peerState.forbidden_operations.length, 0); assert.equal(peerState.errors.length, 0);
  assert.deepEqual([...peerState.read_handles_opened].sort(), [...peerState.read_handles_closed].sort());
  assert(peerState.calls.some(c => c.operation === "LIST" && c.path === "/fixture"));
  assert(peerState.calls.some(c => c.operation === "READ" && c.path === ready.remote_path && c.returned > 0));
  assert(peerState.connections.every(c => c.peer_closed_before_stop), "Both actual connections close before fixture shutdown");
  report.peer_before_shutdown = peerState;
  assert.equal(await readFile(join(data, "hosts.toml"), "utf8"), fixture);
  assert.equal(await readFile(join(data, "known_hosts"), "utf8").catch(error => { if (error.code === "ENOENT") return ""; throw error; }), "", "Trust-once does not save the key");
  await capture("07-file-tab-released-original-local-retained");
  report.checks.push("Actual explicit local overwrite completes with identical full source/target MD5 and visible same-job/attempt success", "Both actual read-only SFTP connections and read handles released before peer teardown; original Local remains");
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
  if (appRegistered) {
    try { execFileSync(launchServices, ["-u", appPath!]); report.app_registration_removed = true; }
    catch (registrationError) { report.app_registration_cleanup_error = String(registrationError); }
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
