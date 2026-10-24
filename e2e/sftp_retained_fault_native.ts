/** Actual main app: normal close -> retained attempt 2 -> real peer TCP FIN
 * (paused by default, during READ with --active-fin 1) -> attempt 3 MD5.
 * Invoke only through sftp_retained_fault_loopback.py; no VM or remote mutation.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, cp, mkdir, mkdtemp, open, readFile, readdir, realpath, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, clickAt, key, type_, resizeWindow, screenshot, consoleEvents, sleep } from "../zig-out/share/zenit/harness/client.ts";

const options: Record<string, string> = {}, args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--expected-sha", "--peer", "--out", "--prepare-only", "--active-fin", "--saved-md5"].includes(args[i]) && args[i + 1], `Invalid argument ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--peer"] && options["--out"]);
const prepareOnly = options["--prepare-only"] === "1", activeFin = options["--active-fin"] === "1";
const savedMd5 = options["--saved-md5"] === "1";
assert(prepareOnly || (options["--binary"] && /^[0-9a-f]{64}$/.test(options["--expected-sha"] ?? "")), "Run requires the root's exact frozen binary SHA");
const peer = JSON.parse(await readFile(resolve(options["--peer"]), "utf8"));
assert.equal(peer.host, "127.0.0.1");
assert(Number.isSafeInteger(peer.port) && peer.port > 0 && peer.port <= 65535);
assert.equal(peer.source, "/retained-fixture.bin");
assert.equal(peer.fault_mode ?? "paused", activeFin ? "active" : "paused", "Use the matching controlled peer mode");
const output = resolve(options["--out"]), isolated = await mkdtemp(join(tmpdir(), "zerowork-retained-fault-main-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data"), localDirectory = join(isolated, "owned-download");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data), mkdir(localDirectory)]);
const fixtureName = "SFTP 原任务断连保留续传验收";
// Deliberately omit credentials: every new protocol connection must use the
// existing interactive password consumer, including the retained connection.
const fixture = `[registry]\nschema_version = 2\nrevision = 1\nnext_connection_id = 2\nnext_group_id = 1\n\n[[hosts]]\nconnection_id = 1\nrevision = 1\nprotocol = "sftp"\nauth_mode = "password"\noptions = { strict_host_key = true }\nname = "${fixtureName}"\nhost = "${peer.host}"\nport = ${peer.port}\nuser = "${peer.user}"\n`;
await writeFile(join(data, "hosts.toml"), fixture);
await writeFile(join(data, "config.toml"), '[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Menlo"\nfont_size = 14\n' + (savedMd5 ? '[transfer]\nverify_md5 = true\nresume = true\n' : ""));
const report: Record<string, any> = {
  status: prepareOnly ? "prepared_not_run" : "running", visual_status: prepareOnly ? "not_run" : "needs_review",
  started_at: new Date().toISOString(), isolated, rpc, data, local_directory: localDirectory,
  fault_mode: activeFin ? "active_read_fin" : "paused_fin",
  stages: [], actions: [], checks: [], authentication: [],
  tree_capture: { mode: "scoped production subtrees", prior_limit: "retained run2 full /tree returned tree too large for RESULT_BUF_SIZE; preserved as failure evidence" },
  input: "Synthetic public Harness click/key/type in the owned actual background Metal main app; no physical input claim",
  remote: { host: peer.host, port: peer.port, source: peer.source, immutable_bytes: peer.source_size, writes_authorized: false },
  limits: ["Only loopback peer and own temporary local files are used; no VM, shell, exec, PTY or remote mutation.",
    "Normal close and a later real FIN are consumed by the integrated main app; changed transfer bindings, exact original job/owner and authenticated attempt 3 completion prove recovery. No test-only resource graph or injected fault replaces the app.",
    "Native screenshot review is separate from functional assertions; queries and retained screenshots are not claimed to be atomic.",
    "Final own-process termination is cleanup, not proof of native window-close lifecycle."],
};
if (prepareOnly) {
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(`prepared_not_run: ${join(output, "report.json")}`);
  process.exit(0);
}
const binary = join(output, "zerowork-frozen");
await copyFile(resolve(options["--binary"]), binary);
const binarySha = createHash("sha256").update(await readFile(binary)).digest("hex");
assert.equal(binarySha, options["--expected-sha"]);
Object.assign(report, { binary, source_binary: resolve(options["--binary"]), binary_sha256: binarySha });
const routeSource = await readFile(resolve("src/host/file_route_factory.zig"), "utf8");
assert(routeSource.includes(".open_shell = false"));
await writeFile(join(output, "file-route-factory-source.zig"), routeSource);
report.no_shell_source = { sha256: createHash("sha256").update(routeSource).digest("hex"), open_shell_false: true };
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const appLog = join(output, "app.log"), log = await open(appLog, "w");
const environment = { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZEROWORK_FILE_TRACE: "1", OPENAI_API_KEY: "", ANTHROPIC_API_KEY: "" };
delete environment.ZEROWORK_AI_MOCK;
const child = spawn(binary, [], { cwd: process.cwd(), env: environment, stdio: ["ignore", log.fd, log.fd] });
report.pid = child.pid;
const ended = new Promise<void>(done => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", error => { launchError = error; });

function shown(n: any): boolean { return !!n?.rect && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect.w > 0 && n.rect.h > 0; }
function nodes(n: any): any[] { return !shown(n) ? [] : [n, ...(n.children ?? []).flatMap(nodes)]; }
function text(n: any): string { return nodes(n).map(value => value.text ?? "").join(""); }
function byId(n: any, id: string): any[] { return nodes(n).filter(value => value.test_id === id); }
async function visible(id: string): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null, 15000); }
async function stableNode(resolveNode: () => Promise<any>): Promise<any> {
  let previous = "";
  return waitFor(async () => {
    const current = await resolveNode();
    if (!shown(current)) { previous = ""; return null; }
    const geometry = JSON.stringify({ id: current.id, rect: current.rect });
    const stable = previous === geometry;
    previous = geometry;
    return stable ? current : null;
  }, 10000);
}
async function clickNode(n: any, description: string): Promise<void> {
  assert(shown(n), description);
  report.actions.push({ kind: "click", description, node_id: n.id, test_id: n.test_id, rect: n.rect, at: new Date().toISOString() });
  assert((await clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok, description);
}
async function click(id: string): Promise<void> { await clickNode(await stableNode(async () => (await query(id)).find(shown)), id); }
async function tabs(): Promise<any[]> { return nodes(await visible("tabs.strip")).filter(value => /^tabs\.tab\.\d+$/.test(value.test_id ?? "")); }
async function marker(name: string): Promise<void> { await writeFile(join(peer.controls, name), `${Date.now()}\n`); }
async function peerState(): Promise<any> { return JSON.parse(await readFile(peer.state, "utf8")); }
async function traces(): Promise<any[]> {
  const contents = await readFile(appLog, "utf8"), complete = contents.slice(0, contents.lastIndexOf("\n") + 1);
  const prefixes = ["SFTP_WORKSPACE_TRACE ", "SFTP_READONLY_READY ", "FILE_TRANSFER_READY ", "FILE_TRANSFER_ENQUEUED ", "FILE_TRANSFER_VERIFICATION ", "FILE_TRANSFER_MANAGER_VERIFICATION "];
  return complete.split("\n").flatMap((line, index) => {
    const prefix = prefixes.find(value => line.includes(value));
    return prefix ? [{ ...JSON.parse(line.slice(line.indexOf(prefix) + prefix.length)), trace_prefix: prefix.trim(), log_line: index + 1 }] : [];
  });
}
async function capture(name: string): Promise<void> {
  const ids = ["tabs.strip", "files.presentation", "transfer.confirmation.overlay", "transfer.confirmation", "transfer.manager", "auth.challenge.modal", "connection.progress", "workspace.pane"];
  const current = Object.fromEntries(await Promise.all(ids.map(async id => {
    const value = await query(id);
    assert(Array.isArray(value), `Scoped ${id} query failed: ${JSON.stringify(value)}`);
    return [id, value];
  }))), screenshotPath = join(output, `${name}.png`);
  await writeFile(join(output, `${name}.tree.json`), JSON.stringify(current, null, 2));
  assert((await screenshot(screenshotPath)).ok, `Capture ${name}`);
  report.stages.push({ name, screenshot: screenshotPath, tree: join(output, `${name}.tree.json`), at: new Date().toISOString() });
  console.log(`[sftp-retained-fault-main] ${name}`);
}
async function authenticateUntil(phase: "original" | "retained_before_fault" | "fault_recovery", complete: () => Promise<boolean>, timeout = 60000): Promise<void> {
  const deadline = Date.now() + timeout;
  let decisions = 0;
  while (Date.now() < deadline) {
    const modal = (await query("auth.challenge.modal")).find(n => shown(n) && (n.effective_opacity ?? 1) >= 0.999);
    const inside = (id: string) => modal ? byId(modal, id)[0] : undefined;
    if (modal && inside("auth.challenge.trust_once")?.focusable) {
      assert(++decisions <= 10, "Bound all original-identity authentication decisions");
      const endpoint = text(inside("auth.challenge.endpoint")), fingerprint = text(inside("auth.challenge.fingerprint"));
      assert(endpoint.includes(peer.host) && endpoint.includes(peer.user));
      assert(fingerprint.includes(peer.fingerprint), "Trust only this run's actual ephemeral peer key");
      await capture(`${phase}-trust-${decisions}`);
      const button = await stableNode(async () => {
        const fresh = (await query("auth.challenge.modal")).find(n => n.id === modal.id && shown(n));
        assert(!fresh || text(byId(fresh, "auth.challenge.fingerprint")[0]).includes(peer.fingerprint));
        return fresh && byId(fresh, "auth.challenge.trust_once").find(n => n.focusable);
      });
      if (button) {
        await clickNode(button, `${phase}: trust this exact loopback challenge once`);
        report.authentication.push({ phase, kind: "trust_once", endpoint, fingerprint, modal_id: modal.id, at: new Date().toISOString() });
      }
      await sleep(80);
      continue;
    }
    if (modal && inside("auth.challenge.answer.0")?.focusable) {
      assert(++decisions <= 10);
      assert(!/替换已保存|输入小写 yes/.test(text(modal)), "Changed-key replacement is never authorized");
      await capture(`${phase}-password-${decisions}`);
      const answer = await stableNode(async () => {
        const fresh = (await query("auth.challenge.modal")).find(n => n.id === modal.id && shown(n));
        return fresh && byId(fresh, "auth.challenge.answer.0").find(n => n.focusable);
      });
      if (answer) {
        await clickNode(answer, `${phase}: answer original password request`);
        assert((await key("a", { cmd: true })).ok);
        assert((await type_(peer.password)).ok);
        const submit = await stableNode(async () => {
          const current = (await query("auth.challenge.modal")).find(n => n.id === modal.id && shown(n));
          return current && byId(current, "auth.challenge.submit").find(n => n.focusable);
        });
        assert(submit, "The same visible challenge owns its submit");
        await clickNode(submit, `${phase}: submit exact challenge`);
        report.authentication.push({ phase, kind: "password", modal_id: modal.id, at: new Date().toISOString() });
      }
      await sleep(80);
      continue;
    }
    if (await complete()) return;
    assert(child.exitCode === null && child.signalCode === null, "The owned app stays alive");
    await sleep(80);
  }
  throw new Error(`Timed out during ${phase} authentication/operation`);
}
async function task(): Promise<any> {
  const manager = await visible("transfer.manager"), tasks = byId(manager, "transfer.task").filter(value => text(value).includes(basename(peer.source)));
  assert(tasks.length <= 1, "The original selected file always has exactly one global task");
  return tasks[0] ?? null;
}
async function taskState(label: string): Promise<any> { return waitFor(async () => { const current = await task(); return current && text(current).includes(label) ? current : null; }, 20000); }
async function taskGroup(): Promise<any> {
  const manager = await visible("transfer.manager");
  const rows = byId(manager, "transfer.task").filter(value => text(value).includes(basename(peer.source)));
  assert(rows.length <= 1, "Only the exact original file task may own the inspected details");
  if (!rows.length) return null;
  // renderTask's stack owns the row and detail as siblings. The transfer.task
  // ID belongs to the row only, so its subtree cannot contain the heading.
  const group = nodes(manager).find(value => value.children?.some(child => child.id === rows[0].id));
  assert(group, "The real Manager tree contains the original row's direct parent");
  return group;
}
async function expandTask(attempt = 1): Promise<any> {
  const original = report.original_job, expected = `任务 #${original.enqueue.job} · 尝试 ${attempt} · 会话 #${original.attached.owner.session_id}`;
  const current = await taskGroup(); assert(current);
  const detailAlreadyOpen = nodes(current).some(value => typeof value.text === "string" && value.text.startsWith(`任务 #${original.enqueue.job} · 尝试 `));
  if (!detailAlreadyOpen) {
    await clickNode(await stableNode(async () => {
      const group = await taskGroup();
      return group && byId(group, "transfer.task.expand")[0];
    }), "Inspect the original task identity");
  }
  return waitFor(async () => {
    const current = await taskGroup();
    return current && nodes(current).some(value => value.text === expected) ? current : null;
  }, 10000);
}
async function originalLocalOnly(localTab: string): Promise<boolean> {
  const current = await tabs();
  return current.length === 1 && current[0].test_id === localTab && !(await query("files.workspace")).some(shown);
}
async function ownPart(): Promise<{ name: string; bytes: number; inode: number }> {
  const names = (await readdir(localDirectory)).filter(name => name.includes(".zerowork-") && name.endsWith(".part"));
  assert(names.length <= 1, "A single original task owns at most one partial artifact");
  if (names.length !== 1) return { name: "", bytes: 0, inode: 0 };
  const value = await stat(join(localDirectory, names[0]));
  return { name: names[0], bytes: value.size, inode: value.ino };
}

let failure: unknown;
try {
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), child.pid);
  assert((await resizeWindow(1440, 900)).ok);
  await click("workspace.empty.local"); await visible("terminal.surface");
  const originalTabs = await tabs(); assert.equal(originalTabs.length, 1);
  const localTab = originalTabs[0].test_id;
  report.original_local_tab = localTab;
  await click("sidebar.host"); await click("sidebar.host.connect");
  await authenticateUntil("original", async () => (await query("files.workspace")).some(shown));
  const openedTabs = await tabs(); assert.equal(openedTabs.length, 2);
  const fileTab = openedTabs.find(value => value.test_id !== localTab).test_id;
  report.original_file_tab = fileTab;
  const attached = await waitFor(async () => (await traces()).find(value => value.trace_prefix === "SFTP_WORKSPACE_TRACE" && value.event === "attached" && Number(value.tab_id) === Number(fileTab.split(".").at(-1))) ?? null, 10000);
  assert.equal(attached.plugin, "sftp"); assert.equal(attached.terminal_present, false); assert.equal(attached.runtime_present, false);
  const originalOwner = attached.owner;
  const local = await visible("files.local"), path = byId(local, "files.path")[0];
  await clickNode(path, "Navigate only the local file-service pane to the owned download directory");
  assert((await key("a", { cmd: true })).ok); assert((await type_(localDirectory)).ok); assert((await key("return")).ok);
  const canonicalLocal = await realpath(localDirectory);
  await waitFor(async () => text(byId(await visible("files.local"), "files.path")[0]) === canonicalLocal || null, 20000);
  const row = await waitFor(async () => byId(await visible("files.remote"), "files.row").find(value => byId(value, "files.row.name").some(name => name.text === basename(peer.source))) ?? null, 20000);
  assert(row);
  await capture("00-original-real-file-workspace");
  await clickNode(await stableNode(async () => byId(await visible("files.remote"), "files.row").find(value => byId(value, "files.row.name").some(name => name.text === basename(peer.source)))), "Select the immutable remote source");
  await waitFor(async () => /已选 1 项/.test(text(await visible("files.remote"))) || null, 10000);
  await clickNode(byId(await visible("files.remote"), "files.transfer")[0], "Download with the frozen original owner");
  let confirm = await visible("transfer.confirmation");
  assert(text(confirm).includes(fixtureName) && text(confirm).includes(`#${originalOwner.session_id}`));
  assert(text(confirm).includes(peer.source) && text(confirm).includes(peer.host));
  assert(text(byId(confirm, "transfer.local_directory")[0]).includes(canonicalLocal));
  assert(text(confirm).includes("断点续传 · 开"), "Enable checkpoint retention through the actual default option");
  // Preserve the full original modal subtree before interacting: a positive
  // node rect alone does not prove its clipping ancestors expose the button.
  await capture("00b-before-md5-confirmation-click");
  confirm = await visible("transfer.confirmation");
  if (savedMd5) {
    assert(text(confirm).includes("MD5 校验 · 开"), "Saved MD5 default must reach the actual main confirmation without a toggle");
    report.saved_md5_default_verified = true;
  } else {
    const md5 = nodes(confirm).find(value => value.component === "Button" && text(value) === "MD5 校验 · 关");
    assert(md5); await clickNode(md5, "Enable actual MD5 verification");
  }
  confirm = await waitFor(async () => { const current = await visible("transfer.confirmation"); return text(current).includes("MD5 校验 · 开") ? current : null; }, 10000);
  await capture("01-original-owner-md5-confirmation");
  await click("transfer.confirmation.submit");
  const enqueue = await waitFor(async () => (await traces()).find(value => value.trace_prefix === "FILE_TRANSFER_ENQUEUED") ?? null, 15000);
  assert.equal(enqueue.owner_id, originalOwner.session_id); assert.equal(enqueue.owner_generation, originalOwner.generation);
  assert.equal(enqueue.md5_check, true); assert.equal(enqueue.resume_transfer, true);
  report.original_job = { enqueue, attached, local_tab: localTab, file_tab: fileTab };
  await waitFor(async () => { const current = await peerState(); return current.gate ? current : null; }, 20000);
  await click("toolbar.transfers");
  const progressed = await waitFor(async () => {
    const current = await task(), partial = await ownPart();
    const visibleBytes = current && Number(text(current).match(/([\d.]+) MiB \/ [\d.]+ MiB/)?.[1] ?? 0);
    return current && visibleBytes > 0 && partial.bytes >= 32768 && partial.bytes < peer.source_size ? { current, partial, visible_mib: visibleBytes } : null;
  }, 15000);
  await capture("02-original-nonzero-bytes-read-gated");
  await marker("pause-requested");
  await clickNode(await stableNode(async () => byId(await task(), "transfer.task.primary")[0]), "Pause the original nonzero-byte task");
  await taskState("停止请求中"); await marker("pausing-visible");
  await marker("read-release");
  await taskState("已暂停");
  const paused = await expandTask(), partial = await ownPart();
  assert(text(paused).includes(`任务 #${enqueue.job} · 尝试 1`));
  assert(text(paused).includes(`会话 #${originalOwner.session_id}`));
  assert(partial.bytes > 0 && partial.bytes < peer.source_size);
  report.paused = { task: paused, partial, original_visible_mib: progressed.visible_mib, peer_gate: (await peerState()).gate };
  await capture("03-original-paused-released-keeps-own-part");
  await key("escape");
  await waitFor(async () => !(await query("transfer.manager")).some(shown) || null, 10000);
  await click(fileTab.replace("tabs.tab.", "tabs.close."));
  const closeTree = await waitFor(async () => {
    const current = await visible("workspace.pane");
    return nodes(current).some(value => value.component === "Button" && text(value) === "仍然关闭") ? current : null;
  }, 10000);
  assert(text(closeTree).includes("尚有未完成任务，关闭将暂停并保留续传数据"), "Actual session-close risk names the real retained transfer");
  await capture("04-original-session-real-close-confirmation");
  await clickNode(await stableNode(async () => nodes(await visible("workspace.pane")).find(value => value.component === "Button" && text(value) === "仍然关闭")), "Confirm closing only the original SFTP tab");
  await waitFor(async () => await originalLocalOnly(localTab) || null, 30000);
  await visible("terminal.surface");
  const released = await waitFor(async () => (await traces()).find(value => value.trace_prefix === "SFTP_WORKSPACE_TRACE" && value.event === "closed" && value.tab_id === attached.tab_id && JSON.stringify(value.owner) === JSON.stringify(originalOwner)) ?? null, 10000);
  const oldPeer = await waitFor(async () => {
    const current = await peerState();
    return current.connections.length >= 2 && current.connections.every(value => value.client_closed_before_peer_cleanup === true) ? current : null;
  }, 20000);
  const closedPart = await ownPart(); assert.equal(closedPart.name, partial.name); assert.equal(closedPart.bytes, partial.bytes);
  report.closed_original = { receipt: released, peer_connection_ids: oldPeer.connections.map(value => value.id), peer: oldPeer, remaining_tabs: (await tabs()).map(value => value.test_id), partial: closedPart };
  await marker("original-tab-closed");
  await capture("05-original-released-local-tab-and-retained-part");
  await click("toolbar.transfers");
  const retained = await expandTask(); assert(text(retained).includes("已暂停"));
  assert(text(retained).includes(`任务 #${enqueue.job} · 尝试 1`) && text(retained).includes(`会话 #${originalOwner.session_id}`));
  const resume = byId(retained, "transfer.task.primary")[0]; assert(resume?.focusable, "Original retained job can resume after its session is actually closed");
  await capture("06-retained-original-job-resume-on-local-tab");
  await writeFile(join(peer.controls, "retained-gate.json"), JSON.stringify({ min_offset: closedPart.bytes + 6 * 32768 }) + "\n");
  await marker("resume-requested");
  await clickNode(await stableNode(async () => byId(await task(), "transfer.task.primary").find(value => value.focusable)), "Resume the original retained job without opening a new file tab");
  const destination = join(localDirectory, basename(peer.source));
  await authenticateUntil("retained_before_fault", async () => {
    assert(await originalLocalOnly(localTab), "Retained authentication never revives the original closed tab");
    return !!(await peerState()).gates?.retained;
  });
  const retainedAuthentication = report.authentication.filter(value => value.phase === "retained_before_fault");
  assert(retainedAuthentication.some(value => value.kind === "trust_once") && retainedAuthentication.some(value => value.kind === "password"), "Retained attempt 2 uses the actual trust/password UI");
  const resumedBeforeFault = await waitFor(async () => {
    const current = await expandTask(2), currentPart = await ownPart(), state = await peerState();
    return text(current).includes("传输中") && currentPart.bytes > closedPart.bytes && currentPart.bytes < peer.source_size && state.gates?.retained
      ? { current, partial: currentPart, gate: state.gates.retained } : null;
  }, 20000);
  assert.equal(resumedBeforeFault.partial.name, closedPart.name);
  assert.equal(resumedBeforeFault.partial.inode, closedPart.inode);
  await capture("07-retained-attempt-two-nonzero-read-gated");
  if (!activeFin) {
    await marker("retained-pause-requested");
    await clickNode(await stableNode(async () => {
      const current = await task();
      return current && byId(current, "transfer.task.primary").find(value => value.focusable);
    }), "Pause the actual retained attempt 2 before faulting its connector");
    const stopping = await waitFor(async () => {
      const current = await task();
      return current && /停止请求中|已暂停/.test(text(current)) ? current : null;
    }, 10000);
    await marker(text(stopping).includes("停止请求中") ? "retained-pausing-visible" : "retained-paused-visible-before-release");
    await marker("retained-read-release");
    await taskState("已暂停");
  }
  const beforeFaultTask = await expandTask(2), beforeFaultPart = await ownPart();
  assert(beforeFaultPart.bytes > closedPart.bytes && beforeFaultPart.bytes < peer.source_size);
  assert.equal(beforeFaultPart.name, closedPart.name); assert.equal(beforeFaultPart.inode, closedPart.inode);
  if (activeFin) {
    assert(text(beforeFaultTask).includes("传输中"), "Send active FIN while the real task is still running");
    assert(!(await peerState()).gates.retained.released, "Real retained READ remains in flight; no UI pause was requested");
  }
  const preFaultDiagnostics = await traces(), originalBinding = `${enqueue.binding_id}:${enqueue.binding_generation}`;
  const retainedReady = preFaultDiagnostics.filter(value => value.trace_prefix === "FILE_TRANSFER_READY" && `${value.binding_id}:${value.generation}` !== originalBinding);
  assert.equal(retainedReady.length, 1, "Only one actual retained connector exists before FIN");
  assert.equal(retainedReady[0].channel_absent, true);
  assert(!preFaultDiagnostics.some(value => value.trace_prefix === "FILE_TRANSFER_MANAGER_VERIFICATION" && value.job === enqueue.job), "The gated retained transfer is incomplete before fault injection");
  await marker(activeFin ? "retained-active-confirmed" : "retained-paused");
  await capture(activeFin ? "08-retained-attempt-two-active-read-before-real-fin" : "08-retained-attempt-two-paused-released-before-real-fin");
  // This is a peer transport control only. It neither calls an application API
  // nor mutates a JobSpec, resource graph or FaultSnapshot.
  await writeFile(join(peer.controls, "fault-fin"), JSON.stringify({ connection: resumedBeforeFault.gate.connection,
    binding_id: retainedReady[0].binding_id, binding_generation: retainedReady[0].generation,
    original_job: enqueue.job, original_owner: originalOwner, at: new Date().toISOString() }) + "\n");
  const finPeer = await waitFor(async () => {
    const current = await peerState(), fault = current.faults?.find(value => value.connection === resumedBeforeFault.gate.connection && value.fin_sent === true);
    return fault ? { current, fault } : null;
  }, 10000);
  await stableNode(async () => {
    const current = await task();
    if (!current || !text(current).includes("已暂停")) return null;
    return byId(current, "transfer.task.primary").find(value => value.focusable);
  });
  const faultTask = await expandTask(2), faultPart = await ownPart();
  assert.equal(faultPart.name, beforeFaultPart.name); assert.equal(faultPart.inode, beforeFaultPart.inode);
  if (activeFin) assert(faultPart.bytes >= beforeFaultPart.bytes && faultPart.bytes < peer.source_size, "Actual FIN keeps the confirmed prefix without completing the file");
  else assert.equal(faultPart.bytes, beforeFaultPart.bytes);
  if (activeFin) await marker("retained-read-release");
  assert(await originalLocalOnly(localTab), "FIN handling never recreates the original file tab");
  assert(!(await query("auth.challenge.modal")).some(n => shown(n) && (n.effective_opacity ?? 1) >= .999), "Fault retention never reauthenticates before an explicit resume");
  report.fault_retained = { attempt: 2, job: enqueue.job, owner: originalOwner, binding: retainedReady[0],
    peer_connection_id: resumedBeforeFault.gate.connection, peer_fin: finPeer.fault,
    part_before_fin: beforeFaultPart, part_after_fin: faultPart, task_before: beforeFaultTask, task_after: faultTask,
    read_gate: finPeer.current.gates.retained, remaining_tabs: (await tabs()).map(value => value.test_id) };
  await capture("09-real-fin-main-retains-same-job-part-and-original-local-tab");
  await marker("fault-resume-requested");
  await clickNode(await stableNode(async () => {
    const current = await task();
    return current && byId(current, "transfer.task.primary").find(value => value.focusable);
  }), "Explicitly resume the same fault-retained job through a new authentication operation");
  await authenticateUntil("fault_recovery", async () => {
    assert(await originalLocalOnly(localTab), "Fault recovery never revives or replaces the closed tab");
    return (await traces()).some(value => value.trace_prefix === "FILE_TRANSFER_MANAGER_VERIFICATION" && value.job === enqueue.job && value.attempt === 3 && value.state === "succeeded" && value.verification_state === "passed");
  });
  const resumedAuthentication = report.authentication.filter(value => value.phase === "fault_recovery");
  assert(resumedAuthentication.some(value => value.kind === "trust_once") && resumedAuthentication.some(value => value.kind === "password"), "Fault recovery completes actual fresh trust and password UI");
  const downloaded = await readFile(destination), actualSha = createHash("sha256").update(downloaded).digest("hex"), actualMd5 = createHash("md5").update(downloaded).digest("hex");
  assert.equal(downloaded.byteLength, peer.source_size); assert.equal(actualSha, peer.source_sha256); assert.equal(actualMd5, peer.source_md5);
  assert.deepEqual((await readdir(localDirectory)).filter(name => name.endsWith(".part")), []);
  const diagnostics = await traces(), managerProof = diagnostics.find(value => value.trace_prefix === "FILE_TRANSFER_MANAGER_VERIFICATION" && value.job === enqueue.job && value.attempt === 3);
  assert(managerProof && managerProof.owner_id === originalOwner.session_id && managerProof.owner_generation === originalOwner.generation);
  assert.equal(managerProof.source_md5, actualMd5); assert.equal(managerProof.target_md5, actualMd5);
  const freshReady = diagnostics.filter(value => value.trace_prefix === "FILE_TRANSFER_READY" && `${value.binding_id}:${value.generation}` !== originalBinding);
  assert.equal(freshReady.length, 2, "Normal retention and fault recovery each establish one actual new transfer binding");
  const faultReady = freshReady.find(value => value.binding_id !== retainedReady[0].binding_id || value.generation !== retainedReady[0].generation);
  assert(faultReady && faultReady.channel_absent === true, "Fault recovery uses a different actual no-shell connector binding");
  const backendProof = diagnostics.find(value => value.trace_prefix === "FILE_TRANSFER_VERIFICATION" && value.binding_id === faultReady.binding_id && value.generation === faultReady.generation && value.engine_state === "succeeded" && value.verification_state === "passed");
  assert(backendProof); assert.equal(backendProof.source_md5, actualMd5); assert.equal(backendProof.target_md5, actualMd5);
  assert.equal(diagnostics.filter(value => value.trace_prefix === "FILE_TRANSFER_ENQUEUED").length, 1, "Neither normal nor fault resume enqueues a replacement Job");
  assert.equal(diagnostics.filter(value => value.trace_prefix === "SFTP_WORKSPACE_TRACE" && value.event === "attached").length, 1, "Neither authentication installs a replacement file tab");
  assert(await originalLocalOnly(localTab));
  if (!(await query("transfer.manager")).some(shown)) await click("toolbar.transfers");
  await taskState("已完成");
  const finalTask = await expandTask(3);
  assert(text(finalTask).includes(`任务 #${enqueue.job} · 尝试 3`) && text(finalTask).includes(`会话 #${originalOwner.session_id}`));
  const finalPeer = await waitFor(async () => {
    const current = await peerState(), excluded = new Set([...report.closed_original.peer_connection_ids, report.fault_retained.peer_connection_id]);
    const fresh = current.connections.filter(value => !excluded.has(value.id));
    return fresh.length === 1 && fresh.every(value => value.authenticated_at_ns && value.client_closed_before_peer_cleanup) ? current : null;
  }, 20000);
  report.resumed = { peer_connection_ids: finalPeer.connections.filter(value => ![...report.closed_original.peer_connection_ids, report.fault_retained.peer_connection_id].includes(value.id)).map(value => value.id),
    manager: managerProof, backend: backendProof, actual_ready_binding: faultReady, task: finalTask,
    source_sha256: peer.source_sha256, actual_sha256: actualSha, actual_md5: actualMd5,
    bytes: downloaded.byteLength, destination, partials: [], remaining_tabs: (await tabs()).map(value => value.test_id) };
  await capture("10-fault-retained-same-job-attempt-three-md5-completed");
  assert.equal(await readFile(join(data, "hosts.toml"), "utf8"), fixture);
  assert.equal(await readFile(join(data, "known_hosts"), "utf8").catch(error => { if (error.code === "ENOENT") return ""; throw error; }), "");
  report.checks = ["Original task has actual nonzero bytes and pauses through the real Manager UI",
    "Actual close confirmation releases both original connections and closes the original SFTP tab",
    "Normal retained resume creates a new authenticated no-shell connector and preserves the same Job/owner at attempt 2",
    activeFin ? "Attempt 2 writes more confirmed bytes; its actual READ stays blocked and no UI pause is sent before FIN" : "Attempt 2 writes additional nonzero bytes, pauses/released and keeps its original owned partial inode",
    "Peer sends actual TCP FIN only to the exact attempt-2 connector; main retains the task without automatic auth or a revived tab",
    "Explicit UI resume completes new trust/password UI and imports to a different real binding at attempt 3",
    "Backend and Manager both pass actual MD5; final local bytes match SHA256 and MD5; no .part remains",
    "Final connector releases before peer cleanup; only the original Local tab remains"];
  report.status = "passed";
} catch (error) {
  failure = launchError ?? error; report.status = "failed"; report.error = String(failure);
  await marker("failure-cleanup"); await marker("read-release"); await marker("retained-read-release");
  if (child.exitCode === null && child.signalCode === null) {
    try { await capture("failure-live"); } catch (captureError) { report.capture_error = String(captureError); }
    try { await writeFile(join(output, "failure-console.json"), JSON.stringify(await consoleEvents(0, 150), null, 2)); } catch (consoleError) { report.console_error = String(consoleError); }
  }
} finally {
  await marker("read-release"); await marker("retained-read-release");
  try { report.runtime_traces = await traces(); } catch (traceError) { report.trace_error = String(traceError); }
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
  await Promise.race([ended, sleep(2000)]);
  if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await ended; }
  report.process_cleanup = { exit_code: child.exitCode, signal: child.signalCode };
  await log.close();
  try { await cp(data, join(output, "isolated-data"), { recursive: true }); } catch (copyError) { report.copy_error = String(copyError); }
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
