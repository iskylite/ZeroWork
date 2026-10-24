/** Real Local session ownership/lifecycle checks through the public Harness.
 * node e2e/local_session_edges.ts --out DIR [--binary PATH]
 * Requires an existing test-mode binary. This file does not build the app.
 * Normal exit -> "新建本地会话" creates a NEW SessionId, not a generation retry.
 * Failed-start retry and right-click directory duplication need separate native
 * UI coverage; this runner never invents a failure or invokes domain backdoors.
 * PNGs need visual review. Harness input is not native keyboard or IME evidence.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, writeFile, rm, realpath, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, focused, clickAt, key, type_, resizeWindow, screenshot, sleep, type QueryNode } from "../zig-out/share/zenit/harness/client.ts";

const args = process.argv.slice(2), options: Record<string, string> = {};
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out"].includes(args[i]) && args[i + 1], `Invalid option ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--out"], "--out is required");
const output = resolve(options["--out"]), binary = resolve(options["--binary"] ?? "zig-out/bin/zerowork");
const binaryHash = createHash("sha256").update(await readFile(binary)).digest("hex");
const isolated = await mkdtemp(join(tmpdir(), "zerowork-local-edges-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
const cwdA = join(isolated, "alpha directory 'quoted'"), cwdB = join(isolated, "beta directory");
await Promise.all([output, rpc, data, cwdA, cwdB].map((path) => mkdir(path, { recursive: true })));
const expectedCwdA = await realpath(cwdA), expectedCwdB = await realpath(cwdB);
await writeFile(join(data, "config.toml"), `[meta]
config_revision = 1
[ui]
theme = "dark"
font_family = "Menlo"
font_size = 14
timestamp_gutter = false
input_line_highlight = false
[completion]
enabled = false
`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const shellScope = "ZEROWORK_E2E_LOCAL_EDGE_SCOPE";
const env = { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_ISOLATE_POINTER: "1", ZENIT_E2E_BACKGROUND: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0" };
delete env[shellScope];
const log = await open(join(output, "app.log"), "w");
const child = spawn(binary, [], { env, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>((done) => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", (error) => { launchError = error; });
const report: Record<string, unknown> = {
  status: "running", binary, binary_sha256: binaryHash, pid: child.pid, started_at: new Date().toISOString(),
  functional_checks: [], sessions: {}, shell_receipts: [], captures: [], pixel_review: "pending", real_ime: "not_tested",
  unverified: [
    { requirement: "Duplicate a Local session in its current directory", status: "requires_cua", reason: "The actual entry is the tab right-click menu (context.menu.clone_session). The current public Harness mouse endpoint only dispatches left presses; Local Surface does not intercept the legacy @dup palette. No copy is simulated." },
    { requirement: "Failed-start retry increments the same SessionId generation", status: "not_exercised", reason: "local.start.retry is only visible for a real failed startup with released cleanup. No artificial failure is injected. Normal exit exposes local.ended.new and creates a distinct SessionId; exact generation is not exposed by the public UI." },
    { requirement: "Native keyboard, clipboard and real IME", status: "not_tested", reason: "All input uses public Harness type_/key/click APIs." },
  ],
};
const checks = report.functional_checks as string[];
type Node = QueryNode & { hidden?: boolean; effective_opacity?: number };
type Surface = { grid: { cols: number; rows: number }; rows: { rect: QueryNode["rect"]; text: string }[] };
type Session = { tab: string; session_id: string; focus_id: number; shell_pid: number; cwd: string; marker: string };
const shown = (node: Node): boolean => node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0;
const quote = (value: string): string => `'${value.replaceAll("'", "'\\''")}'`;
function text(node: Node): string { return shown(node) ? (node.text ?? "") + (node.children ?? []).map(text).join("") : ""; }
function flatten(node: Node): Node[] { return [node, ...(node.children ?? []).flatMap(flatten)]; }
async function nodes(id: string): Promise<Node[]> {
  const value = await query(id);
  assert(Array.isArray(value), `Harness query ${id} failed: ${JSON.stringify(value)}`);
  return value;
}
async function visible(id: string): Promise<Node> { return waitFor(async () => (await nodes(id)).find(shown) ?? null); }
async function clickVisible(id: string): Promise<void> {
  // Several pane-local IDs exist once per session. Never click the first hidden
  // match by test_id: resolve the actually visible node before sending a click.
  const node = await visible(id);
  assert((await clickAt(node.rect.x + node.rect.w / 2, node.rect.y + node.rect.h / 2)).ok);
}
async function tabs(): Promise<string[]> {
  const strips = (await nodes("tabs.strip")).filter(shown);
  return strips.flatMap((strip) => flatten(strip).filter((node) => shown(node) && /^tabs\.tab\.\d+$/.test(node.test_id ?? "")).map((node) => node.test_id!));
}
async function newTab(previous: string[]): Promise<string> {
  return waitFor(async () => {
    const current = await tabs(), added = current.filter((id) => !previous.includes(id));
    if (added.length === 0) return null;
    assert.equal(added.length, 1, "A single UI activation must create exactly one tab");
    assert.deepEqual(current.filter((id) => previous.includes(id)), previous, "Creating a tab must retain the existing ordered tab IDs");
    return added[0];
  });
}
async function grid(): Promise<Surface["grid"]> {
  const label = text(await visible("local.status.grid")), match = label.match(/(\d+)×(\d+)/);
  assert(match, `Missing real grid: ${label}`);
  return { cols: Number(match[1]), rows: Number(match[2]) };
}
async function surface(): Promise<Surface> {
  // Avoid the populated terminal.surface subtree (SDK response limit 256KiB).
  // A hidden pane may share each row ID, so only accept its visible projection.
  return waitFor(async () => {
    const size = await grid(), rows: Surface["rows"] = [];
    for (let start = 0; start < size.rows; start += 8) {
      const batch = await Promise.all(Array.from({ length: Math.min(8, size.rows - start) }, (_, offset) => nodes(`terminal.surface.row.${start + offset}`)));
      for (const values of batch) {
        const active = values.filter(shown);
        if (!active.length) return null;
        assert.equal(active.length, 1, "Only one pane may publish a visible row for an active workspace");
        const row = active[0];
        rows.push({ rect: row.rect, text: (row.children ?? []).filter((node) => shown(node) && node.tag === "text").sort((a, b) => a.rect.x - b.rect.x).map((node) => node.text ?? "").join("") });
      }
    }
    if (JSON.stringify(await grid()) !== JSON.stringify(size)) return null;
    return { grid: size, rows: rows.sort((a, b) => a.rect.y - b.rect.y) };
  });
}
async function waitText(marker: string): Promise<Surface> {
  return waitFor(async () => { const value = await surface(); return value.rows.some((row) => row.text.includes(marker)) ? value : null; });
}
async function focusId(): Promise<number> {
  return waitFor(async () => { const value = await focused(); return value.id && value.test_id?.startsWith("tabs.tab.") !== true ? value.id : null; });
}
async function select(session: Session): Promise<void> {
  await clickVisible(session.tab);
  await waitFor(async () => (await focused()).id === session.focus_id || null);
  await waitText(session.marker);
  // No terminal click or explicit focus call is allowed here: typing below
  // must reach the original terminal solely through the tab's public action.
}
async function sessionId(): Promise<string> {
  await clickVisible("local.status.identity");
  const result = await waitFor(async () => text(await visible("status.detail")).match(/会话 #(\d+)/)?.[1] ?? null);
  await clickVisible("status.detail.close");
  return result;
}
function descendants(): { pid: number; parent: number; command: string }[] {
  const all = execFileSync("/bin/ps", ["-axo", "pid=,ppid=,comm="], { encoding: "utf8" }).trim().split("\n").flatMap((line) => {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/);
    return match ? [{ pid: Number(match[1]), parent: Number(match[2]), command: match[3] }] : [];
  });
  const owned = new Set([child.pid!]);
  for (let i = 0; i < all.length; i++) {
    let changed = false;
    for (const value of all) if (owned.has(value.parent) && !owned.has(value.pid)) { owned.add(value.pid); changed = true; }
    if (!changed) break;
  }
  return all.filter((value) => value.pid !== child.pid && owned.has(value.pid));
}
async function exists(path: string): Promise<boolean> {
  try { await access(path); return true; } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return false; throw error; }
}
let phase = 0;
async function shell(label: string, options: { scope?: string; cwd?: string; clear?: boolean; exit?: boolean } = {}): Promise<{ pid: number; cwd: string; scope: string; marker: string }> {
  const number = ++phase, name = `${number}-${label}`, script = join(isolated, `${name}.zsh`), receipt = join(isolated, `${name}.receipt`);
  const body = [
    "# Sourced in the actual interactive shell; $$ must remain that shell's PID.",
    ...(options.scope !== undefined ? [`${shellScope}=${quote(options.scope)}`] : []),
    ...(options.cwd ? [`cd -- ${quote(options.cwd)} || return 1`] : []),
    "PROMPT='edge> '; RPROMPT=''",
    ...(options.clear ? ["printf '\\033[3J\\033[2J\\033[H'"] : []),
    `printf '%s\\n' "$$" "$PWD" "\${${shellScope}-unset}" > ${quote(receipt)}`,
    `printf '__SESSION_EDGE_%s_%s__\\n' ${quote(label)} ${number}`,
    ...(options.exit ? ["exit 0"] : []),
    "",
  ].join("\n");
  await Promise.all([writeFile(script, body), writeFile(join(output, `${name}.zsh`), body)]);
  assert((await type_(`. ${quote(script)}`)).ok);
  assert((await key("enter")).ok);
  const receiptText = await waitFor(async () => await exists(receipt) && (await readFile(receipt, "utf8")).split("\n").length === 4 ? await readFile(receipt, "utf8") : null);
  const [pid, cwd, scope] = receiptText.split("\n");
  assert(/^\d+$/.test(pid) && Number(pid) > 1 && cwd.startsWith("/"), `Invalid actual shell receipt: ${receiptText}`);
  const marker = `__SESSION_EDGE_${label}_${number}__`;
  await waitText(marker);
  const result = { pid: Number(pid), cwd, scope, marker };
  await writeFile(join(output, `${name}.receipt.json`), JSON.stringify(result, null, 2));
  (report.shell_receipts as unknown[]).push({ name, ...result });
  return result;
}
async function capture(name: string): Promise<void> {
  await sleep(180);
  assert((await screenshot(join(output, `${name}.png`))).ok);
  const value = await surface();
  const queries: Record<string, Node[]> = {};
  for (const id of ["tabs.strip", "local.statusbar", "local.ended.new", "local.ended.close", "local.start.retry"]) queries[id] = await nodes(id);
  await writeFile(join(output, `${name}.json`), JSON.stringify({ focused: await focused(), surface: value, queries }, null, 2));
  (report.captures as unknown[]).push({ name, screenshot: join(output, `${name}.png`), evidence: join(output, `${name}.json`), pixel_review: "pending" });
}

let failure: unknown;
try {
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), child.pid);
  assert((await resizeWindow(1440, 900)).ok);
  await clickVisible("workspace.empty.local");
  const aTab = await newTab([]);
  await surface();
  const aFocus = await focusId(), initialA = await shell("A", { scope: "alpha", cwd: expectedCwdA, clear: true });
  assert.equal(initialA.cwd, expectedCwdA);
  assert.equal(initialA.scope, "alpha");
  assert(descendants().some((value) => value.pid === initialA.pid && value.command.endsWith("/zsh")), "A's receipt must come from an app-owned interactive zsh");
  const a: Session = { tab: aTab, session_id: await sessionId(), focus_id: aFocus, shell_pid: initialA.pid, cwd: initialA.cwd, marker: initialA.marker };
  (report.sessions as Record<string, Session>).a = a;
  await select(a);
  assert((await type_("printf '__PENDING_A_%s__\\n' RESTORED")).ok); // deliberately no Return

  assert((await key("t", { cmd: true })).ok);
  await clickVisible("session.menu.local");
  const bTab = await newTab([a.tab]);
  await surface();
  const bFocus = await focusId(), initialB = await shell("B", { scope: "beta", cwd: expectedCwdB, clear: true });
  assert.equal(initialB.cwd, expectedCwdB);
  assert.equal(initialB.scope, "beta");
  assert.notEqual(initialB.pid, a.shell_pid);
  assert.notEqual(bFocus, a.focus_id);
  assert(descendants().some((value) => value.pid === initialB.pid && value.command.endsWith("/zsh")), "B must own another actual interactive zsh");
  const b: Session = { tab: bTab, session_id: await sessionId(), focus_id: bFocus, shell_pid: initialB.pid, cwd: initialB.cwd, marker: initialB.marker };
  assert.notEqual(b.session_id, a.session_id);
  (report.sessions as Record<string, Session>).b = b;
  assert(!(await surface()).rows.some((row) => row.text.includes(a.marker)), "B's projection must not show A's output");
  checks.push("Two public Local entry actions create distinct TabIds, displayed SessionIds, focused terminal nodes and app-owned shell PIDs with separate cwd and unexported variables");

  await select(a);
  assert((await key("enter")).ok);
  await waitText("__PENDING_A_RESTORED__");
  const resumedA = await shell("A-resumed");
  assert.deepEqual([resumedA.pid, resumedA.cwd, resumedA.scope], [a.shell_pid, a.cwd, "alpha"]);
  assert(!(await surface()).rows.some((row) => row.text.includes(b.marker)));
  await capture("a-restored");
  await select(b);
  const resumedB = await shell("B-resumed");
  assert.deepEqual([resumedB.pid, resumedB.cwd, resumedB.scope], [b.shell_pid, b.cwd, "beta"]);
  assert(!(await surface()).rows.some((row) => row.text.includes(a.marker)));
  await capture("b-restored");
  checks.push("Tab clicks restore each original terminal focus without clicking the pane; A's unsubmitted line survives switching, and both real shells retain their own content, PID, cwd and variables");

  await select(a);
  const finalA = await shell("A-final", { exit: true });
  assert.equal(finalA.pid, a.shell_pid);
  await waitFor(async () => !descendants().some((value) => value.pid === a.shell_pid) || null);
  await visible("local.ended.new");
  await visible("local.ended.close");
  await waitFor(async () => text(await visible("local.status.identity")).includes("已退出") || null);
  assert.equal((await nodes("local.start.retry")).filter(shown).length, 0, "Normal exit must not expose failed-start retry");
  assert.deepEqual(await tabs(), [a.tab, b.tab], "Normal exit preserves the original tab");
  assert(text(await visible(a.tab)).includes("已退出"));
  const readonlyRows = (await waitText(finalA.marker)).rows.map((row) => row.text);
  const denied = join(isolated, "readonly-input-must-not-run");
  assert((await type_(`printf '%s' READONLY_INPUT_MUST_NOT_RUN > ${quote(denied)}`)).ok);
  assert((await key("enter")).ok);
  await sleep(400);
  assert.equal(await exists(denied), false, "Read-only tombstone input must not execute in any session");
  assert.deepEqual((await surface()).rows.map((row) => row.text), readonlyRows, "Typing into the tombstone must preserve its actual final VT output");
  assert(descendants().some((value) => value.pid === b.shell_pid), "A's normal exit must leave B's shell alive");
  await capture("a-exited-readonly");
  checks.push("A exits normally with code 0 through its actual shell; its process disappears while its tab/final output and visible ended actions remain, typing cannot execute or alter the read-only grid, and B stays alive");

  await clickVisible("local.ended.new");
  const cTab = await newTab([a.tab, b.tab]);
  await surface();
  const cFocus = await focusId(), initialC = await shell("C-new", { clear: true });
  assert(![a.shell_pid, b.shell_pid].includes(initialC.pid));
  assert(![a.focus_id, b.focus_id].includes(cFocus));
  assert.equal(initialC.scope, "unset", "The new session must not inherit either other shell's private variable");
  assert(descendants().some((value) => value.pid === initialC.pid && value.command.endsWith("/zsh")));
  const c: Session = { tab: cTab, session_id: await sessionId(), focus_id: cFocus, shell_pid: initialC.pid, cwd: initialC.cwd, marker: initialC.marker };
  assert(![a.session_id, b.session_id].includes(c.session_id), "Ended-session New must allocate a distinct SessionId, not retry the old generation");
  (report.sessions as Record<string, Session>).c = c;
  await select(c);
  await capture("new-session-from-ended");
  await select(a);
  await waitText(finalA.marker);
  await visible("local.ended.new");
  await select(b);
  const afterExitB = await shell("B-after-A-exit");
  assert.deepEqual([afterExitB.pid, afterExitB.cwd, afterExitB.scope], [b.shell_pid, b.cwd, "beta"]);
  assert.deepEqual(await tabs(), [a.tab, b.tab, c.tab]);
  checks.push("The real ended banner's New action creates a fresh TabId/SessionId/shell PID with its own private state, leaves A's tombstone intact, and B remains usable with its original owner and cwd");
  report.status = "covered_functional_checks_passed_native_menu_and_retry_pending";
} catch (error) {
  failure = launchError ?? error;
  report.status = "failed";
  report.error = String(failure);
  if (child.exitCode === null && child.signalCode === null) await Promise.allSettled([capture("failure"), writeFile(join(output, "remaining-processes.json"), JSON.stringify(descendants(), null, 2))]);
} finally {
  // Only this runner's process tree. Forced cleanup is not lifecycle acceptance.
  if (child.exitCode === null && child.signalCode === null) {
    const remaining = descendants();
    report.forced_child_cleanup = remaining.map((value) => value.pid);
    for (const value of remaining.reverse()) { try { process.kill(value.pid, "SIGHUP"); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error; } }
    child.kill("SIGTERM");
  }
  await Promise.race([ended, sleep(2000)]);
  if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await ended; }
  report.process_cleanup = { exit_code: child.exitCode, signal: child.signalCode };
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  await log.close();
  await rm(isolated, { recursive: true, force: true });
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
