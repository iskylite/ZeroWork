/** Isolated real ZSH/Metal shell controls acceptance. Prepared by a subagent;
 * only root may run it in the serialized native slot. Public Harness input is
 * synthetic. Screenshots require separate human/model visual review.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, open, readFile, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { waitForServerReady, waitFor, query, inputState, clickAt, key, type_, resizeWindow, screenshot, sleep } from "../zig-out/share/zenit/harness/client.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const options: Record<string, string> = {};
for (let i = 2; i < process.argv.length; i += 2) {
  assert(["--binary", "--expected-sha", "--out", "--prepare-only"].includes(process.argv[i]) && process.argv[i + 1], `Invalid option ${process.argv[i]}`);
  options[process.argv[i]] = process.argv[i + 1];
}
const prepared = options["--prepare-only"] === "1";
assert(options["--prepare-only"] === undefined || prepared);
assert(options["--out"], "Use a fresh --out directory");
assert(prepared || (options["--binary"] && /^[a-f0-9]{64}$/.test(options["--expected-sha"] ?? "")), "Run requires root's immutable binary and full SHA-256");
const output = resolve(options["--out"]);
await mkdir(output, { recursive: true });
assert.equal((await readdir(output)).length, 0, "Preserve previous evidence; output must be empty");
const report: any = {
  status: prepared ? "prepared_not_run" : "running", started_at: new Date().toISOString(),
  scope: "Isolated real ZSH, Tab rename/save/cancel, standard/compact Local status, font_size settings search, Dark/Light/Sauber and captured Local close confirmation",
  checks: [], actions: [], screenshots: [],
  visual_status: "not_reviewed", native_started: false,
  input: "Synthetic public Harness pointer/key/text; no CUA/IME or physical mouse claim",
  network: "No saved hosts or external connection is created; SSH/AI API/forwarding are outside this runner",
  limits: ["No background image is enabled, so three-theme shell evidence is not global-material acceptance", "Figma exports and app screenshots are separate observations, never the same frame", "Final SIGTERM cleanup is not normal application-close proof"],
};
if (prepared) {
  report.expected_prototype = { rename: { width: 380, height: 191 }, status_popover: { width: 360, gap_above_bar: 6 }, viewport: [[1440, 900], [860, 480]] };
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(`prepared_not_run: ${join(output, "report.json")}`);
  process.exit(0);
}

const sourceBinary = resolve(options["--binary"]), binary = join(output, "zerowork-frozen");
await copyFile(sourceBinary, binary);
const binarySha = createHash("sha256").update(await readFile(binary)).digest("hex");
assert.equal(binarySha, options["--expected-sha"]);
const isolated = await mkdtemp(join(tmpdir(), "zerowork-shell-controls-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
await Promise.all([mkdir(rpc), mkdir(data)]);
const configPath = join(data, "config.toml");
await writeFile(configPath, '[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Menlo"\nfont_size = 14\nfont_weight = "regular"\nline_height = 1.5\n');
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(output, "app.log"), "w");
const environment = { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", OPENAI_API_KEY: "", ANTHROPIC_API_KEY: "" };
delete environment.ZEROWORK_AI_MOCK;
const child = spawn(binary, [], { cwd: root, env: environment, stdio: ["ignore", log.fd, log.fd] });
report.native_started = true;
Object.assign(report, { pid: child.pid, binary, source_binary: sourceBinary, binary_sha256: binarySha, isolated, rpc, data });
const ended = new Promise<void>(done => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", error => { launchError = error; });
type Node = any;
function shown(n: Node): boolean { return !!n?.rect && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect.w > 0 && n.rect.h > 0; }
function flatten(n: Node): Node[] { return shown(n) ? [n, ...(n.children ?? []).flatMap(flatten)] : []; }
function text(n: Node): string { return flatten(n).map(v => v.text ?? "").join(""); }
async function visible(id: string): Promise<Node> { return waitFor(async () => (await query(id)).find(shown) ?? null, 15000); }
async function hidden(id: string): Promise<void> { await waitFor(async () => !(await query(id)).some(shown) || null, 10000); }
async function stable(id: string): Promise<Node> {
  let previous = "";
  return waitFor(async () => { const n = (await query(id)).find(shown); if (!n) { previous = ""; return null; } const current = JSON.stringify({ id: n.id, rect: n.rect }); const ready = current === previous; previous = current; return ready ? n : null; }, 10000);
}
async function click(id: string): Promise<void> {
  const n = await stable(id);
  report.actions.push({ kind: "click", test_id: id, node_id: n.id, rect: n.rect, at: new Date().toISOString() });
  assert((await clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok, id);
}
async function edit(id: string, value: string): Promise<void> {
  await click(id);
  assert((await key("a", { cmd: true })).ok);
  assert((await key("backspace")).ok);
  if (value) assert((await type_(value)).ok);
  await waitFor(async () => (await inputState(id)).buffer === value || null, 10000);
}
async function tabs(): Promise<Node[]> { return flatten(await visible("tabs.strip")).filter(n => /^tabs\.tab\.\d+$/.test(n.test_id ?? "")); }
async function capture(name: string): Promise<void> {
  await sleep(200);
  const file = join(output, `${name}.png`);
  assert((await screenshot(file)).ok);
  const scopes: Record<string, unknown> = {};
  for (const id of ["tabs.strip", "tabs.rename", "tabs.rename.input", "local.statusbar", "status.detail", "status.theme", "local.close.confirmation", "settings.search", "settings.content", "settings.field.font_size", "settings.footer.state"]) scopes[id] = await query(id);
  await writeFile(join(output, `${name}.queries.json`), JSON.stringify(scopes, null, 2));
  report.screenshots.push({ name, path: file, queries: `${name}.queries.json` });
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(`[shell-controls] ${name}`);
}
function descendants(): { pid: number; parent: number; command: string }[] {
  const all = execFileSync("/bin/ps", ["-axo", "pid=,ppid=,comm="], { encoding: "utf8" }).trim().split("\n").flatMap(line => { const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/); return m ? [{ pid: Number(m[1]), parent: Number(m[2]), command: m[3] }] : []; });
  const owned = new Set([child.pid!]);
  for (let i = 0; i < all.length; i++) { let changed = false; for (const p of all) if (owned.has(p.parent) && !owned.has(p.pid)) { owned.add(p.pid); changed = true; } if (!changed) break; }
  return all.filter(p => p.pid !== child.pid && owned.has(p.pid));
}
async function expectDetail(kind: string, barId = "local.statusbar"): Promise<void> {
  const detail = await stable("status.detail"), bar = await visible(barId);
  assert(text(detail).includes(kind), `Expected detail ${kind}`);
  assert.equal(detail.rect.w, 360);
  const viewportWidth = report.viewport[0];
  assert(detail.rect.x >= 8 && detail.rect.x + detail.rect.w <= viewportWidth - 8 + 0.5);
  assert(Math.abs(bar.rect.y - detail.rect.y - detail.rect.h - 6) <= 1, "Detail must anchor 6pt above its real bar");
}
async function resize(width: number, height: number): Promise<void> { assert((await resizeWindow(width, height)).ok); report.viewport = [width, height]; await stable("local.statusbar"); }
async function closeRisk(tab: string, name: string, foregroundPid: number): Promise<void> {
  await click(tab.replace("tabs.tab.", "tabs.close."));
  await visible("local.close.confirmation");
  await capture(name);
  await click("local.close.cancel");
  await hidden("local.close.confirmation");
  assert(descendants().some(p => p.pid === foregroundPid), "Cancel must preserve the same owned foreground process");
}
let failure: unknown;
try {
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), child.pid);
  assert((await resizeWindow(1440, 900)).ok); report.viewport = [1440, 900];
  await click("workspace.empty.local");
  await visible("terminal.surface");
  await waitFor(async () => descendants().some(p => p.command.endsWith("/zsh")) || null, 10000);
  const firstTabs = await tabs(); assert.equal(firstTabs.length, 1);
  const originalTab = firstTabs[0].test_id, originalTitle = text(firstTabs[0]);
  await click("toolbar.new_session"); await click("session.menu.local");
  const currentTabs = await waitFor(async () => { const list = await tabs(); return list.length === 2 ? list : null; }, 15000);
  const renamedTab = currentTabs.find(n => n.test_id !== originalTab)!.test_id;
  report.tabs = { original: originalTab, renamed: renamedTab };
  assert((await key("r", { cmd: true, shift: true })).ok);
  const rename = await stable("tabs.rename");
  assert.equal(rename.rect.w, 380); assert.equal(rename.rect.h, 191);
  const field = await visible("tabs.rename.input"), save = await visible("tabs.rename.save");
  for (const control of [field, save]) assert(control.rect.x >= rename.rect.x && control.rect.y >= rename.rect.y && control.rect.x + control.rect.w <= rename.rect.x + rename.rect.w + 0.5 && control.rect.y + control.rect.h <= rename.rect.y + rename.rect.h + 0.5, "Rename field/save must stay within the exact 380x191 dialog");
  await capture("01-rename-exact-dialog");
  const title = `Shell-${process.pid}`;
  await edit("tabs.rename.input", title); await click("tabs.rename.save"); await hidden("tabs.rename");
  await waitFor(async () => text(await visible(renamedTab)).includes(title) || null, 10000);
  assert.equal(text(await visible(originalTab)), originalTitle, "Rename must not change the other Local tab");
  assert((await key("r", { cmd: true, shift: true })).ok); await edit("tabs.rename.input", "discarded-title"); await click("tabs.rename.cancel"); await hidden("tabs.rename");
  assert(text(await visible(renamedTab)).includes(title));
  report.checks.push("Exact 380x191 rename field/save are visible, pointer save changes only the captured tab, cancel preserves its title");
  await capture("02-renamed-original-owner-preserved");

  await click("local.status.identity"); await expectDetail("本地终端"); await capture("03-local-identity"); await click("status.detail.close");
  await click("local.status.encoding"); await expectDetail("终端编码"); assert(text(await visible("status.detail")).includes("UTF-8")); await capture("04-local-encoding"); await click("status.detail.close");
  await click("local.status.grid"); await expectDetail("终端网格"); await capture("05-local-grid"); await click("status.detail.close");
  await click("local.status.more"); await expectDetail("更多状态"); assert(!text(await visible("status.detail")).includes("往返延迟"), "Local More must not advertise SSH RTT"); await capture("06-local-more"); await click("status.detail.close");
  await resize(860, 480); await capture("07-local-compact");
  await click("local.status.more"); await expectDetail("更多状态"); await capture("08-local-compact-more"); await click("status.detail.close");
  await resize(1440, 900);
  report.checks.push("Standard and compact Local identity/encoding/grid/More are real bounded entry points; no fictitious network RTT");

  await click("toolbar.settings"); await edit("settings.search", "font_size");
  const font = await stable("settings.field.font_size");
  assert.equal((await inputState("settings.field.font_size")).buffer, "14");
  const content = await visible("settings.content");
  assert(font.rect.y >= content.rect.y && font.rect.y + font.rect.h <= content.rect.y + content.rect.h + 0.5, "Search must display the actual font-size input inside its content area");
  await capture("09-settings-font-size-search-actual-input");
  await edit("settings.search", ""); await click("settings.close"); await hidden("settings.search");
  report.checks.push("Searching schema key font_size renders the actual current Input rather than an empty section or legacy summary");

  await click("terminal.surface"); assert((await type_("printf '__SHELL_CONTROLS_%s__\\n' READY")).ok); assert((await key("return")).ok);
  await waitFor(async () => text(await visible("terminal.surface")).includes("__SHELL_CONTROLS_READY__") || null, 10000);
  assert((await type_("/bin/sleep 180")).ok); assert((await key("return")).ok);
  const sleeper = await waitFor(async () => descendants().find(p => p.command.endsWith("/sleep")) ?? null, 10000);
  report.foreground_pid = sleeper.pid;
  await closeRisk(renamedTab, "10-local-close-dark-original-process", sleeper.pid);
  for (const theme of ["light", "sauber", "dark"]) {
    await click("local.status.theme"); await visible("status.theme"); await click(`status.theme.item.${theme}`);
    await waitFor(async () => new RegExp(`theme\\s*=\\s*"${theme}"`).test(await readFile(configPath, "utf8")) || null, 10000);
    await click("status.theme.close"); await hidden("status.theme");
    await capture(`11-${theme}-standard`);
    await resize(860, 480); await capture(`12-${theme}-compact`); await resize(1440, 900);
    await closeRisk(renamedTab, `13-${theme}-close-original-process`, sleeper.pid);
  }
  report.checks.push("Dark/Light/Sauber persist through real global palette and yield separate standard/compact screenshots; each close Cancel preserves the same real ZSH foreground PID");
  await click(renamedTab.replace("tabs.tab.", "tabs.close.")); await visible("local.close.confirmation"); await click("local.close.accept");
  await hidden(renamedTab); await waitFor(async () => !descendants().some(p => p.pid === sleeper.pid) || null, 10000);
  assert((await tabs()).some(n => n.test_id === originalTab), "Closing renamed tab preserves the original Local tab");
  await click(originalTab.replace("tabs.tab.", "tabs.close."));
  if ((await query("local.close.confirmation")).some(shown)) await click("local.close.accept");
  await hidden(originalTab); await visible("workspace.empty.local");
  await waitFor(async () => !descendants().some(p => p.command.endsWith("/zsh") || p.command.endsWith("/sleep")) || null, 10000);
  await capture("14-local-sessions-released");
  report.checks.push("Explicit close releases owned foreground/shell processes and both tabs; normal tab-close evidence precedes application cleanup");
  await copyFile(configPath, join(output, "config-after.toml"));
  report.status = "passed";
} catch (error) {
  failure = launchError ?? error; report.status = "failed"; report.error = String(failure);
  if (child.exitCode === null && child.signalCode === null) await Promise.allSettled([capture("failure-live"), writeFile(join(output, "remaining-processes.json"), JSON.stringify(descendants(), null, 2))]);
} finally {
  if (child.exitCode === null && child.signalCode === null) {
    const remaining = descendants(); report.forced_child_cleanup = remaining.map(p => p.pid);
    for (const process_ of remaining.reverse()) { try { process.kill(process_.pid, "SIGHUP"); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error; } }
    child.kill("SIGTERM");
  }
  await Promise.race([ended, sleep(2000)]);
  if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await ended; }
  report.process_cleanup = { exit_code: child.exitCode, signal: child.signalCode };
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2)); await log.close();
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
