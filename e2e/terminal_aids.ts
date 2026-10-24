/** Saved terminal aids against a real Local PTY and an existing test-mode app.
 * node e2e/terminal_aids.ts --out DIR [--binary PATH]
 * Uses production settings and public Harness APIs. Does not build the app.
 * Color/font rendering and system clock policies remain separate review items.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { waitForServerReady, waitFor, query, screenPos, inputState, clickTestId, key, type_, resizeWindow, screenshot, sleep, type QueryNode } from "../zig-out/share/zenit/harness/client.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2), options: Record<string, string> = {};
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out"].includes(args[i]) && args[i + 1], `Invalid option ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--out"], "--out is required");
const output = resolve(options["--out"]), binary = resolve(options["--binary"] ?? join(root, "zig-out/bin/zerowork"));
const binaryHash = createHash("sha256").update(await readFile(binary)).digest("hex");
const isolated = await mkdtemp(join(tmpdir(), "zerowork-terminal-aids-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data"), release = join(isolated, "producer.release");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data)]);
const configPath = join(data, "config.toml");
// Pick a system monospace face, but omit size/line-height/aids to exercise
// the actual defaults: 14pt / 22px, timestamps off and input highlight on.
const baseline = '[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Menlo"\n[completion]\nenabled = false\n';
await writeFile(configPath, baseline);
await writeFile(join(output, "config-before.toml"), baseline);
const markers = ["AIDS_ALPHA_0123456789", "AIDS_BETA_abcdefghij"];
const quote = (value: string): string => `'${value.replaceAll("'", "'\\''")}'`;
const producerPath = join(isolated, "producer.zsh");
const payload = "\x1b[0m\x1b[?1049l\x1b[3J\x1b[2J\x1b[H" + markers.join("\r\n") + "\r\n";
const producer = `#!/bin/zsh\nset -eu\nprintf '%s' ${quote(payload)}\nwhile [[ ! -e ${quote(release)} ]]; do /bin/sleep 0.1; done\n`;
await writeFile(producerPath, producer);
await writeFile(join(output, "producer.zsh"), producer);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(output, "app.log"), "w");
const child = spawn(binary, [], { cwd: root, env: {
  ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_ISOLATE_POINTER: "1", ZENIT_E2E_BACKGROUND: "1",
  ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0",
}, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>((done) => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", (error) => { launchError = error; });
const checks: string[] = [], captures: unknown[] = [];
const report: Record<string, unknown> = {
  status: "running", binary, binary_sha256: binaryHash, pid: child.pid, started_at: new Date().toISOString(),
  storage: "runner-owned temporary config, producer files and file RPC",
  functional: { status: "running", checks },
  visual: { status: "pending_review", captures, review: "Compare the input row's full-width accent background with highlight on/off. Inspect actual 14/22 glyphs and 9.5/14 timestamps; functional geometry assertions do not certify pixel parity." },
  limits: [
    "Public query exposes text and rectangles, not font size, background color or switch checked state. Size 14 is verified through the real setting and saved config; actual row/glyph height 22 and timestamp geometry are asserted. Highlight paint requires the saved PNGs to be viewed.",
    "The 2.2-second historical timestamp check proves only that these displayed output timestamps remain fixed while waiting; it does not prove active-input clock ticks, wall-clock provenance or background deadline cancellation.",
    "No OS reduceMotion setting, native IME, physical Option selection, clipboard or background scheduling claim is made.",
    "Producer input uses public Harness type_/key through a real Local PTY, not a native keyboard. Final process termination is cleanup, not normal-window-close evidence.",
  ],
};
type Node = QueryNode & { hidden?: boolean; effective_opacity?: number };
type Rect = QueryNode["rect"];
type Row = { node: Node; body: string; glyphs: Node[]; timestamp?: Node };
type Observation = { pane: Rect; surface: Rect; rows: Row[] };
const timestamp = /^\d{2}:\d{2}:\d{2}$/;
const shown = (node: Node): boolean => node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0;
const near = (actual: number, expected: number, label: string): void => assert(Math.abs(actual - expected) <= 0.25, `${label}: expected ${expected}, got ${actual}`);
async function visible(id: string): Promise<Node> { return waitFor(async () => (await query(id)).find(shown) ?? null); }
async function hidden(id: string): Promise<void> { await waitFor(async () => !(await query(id)).some(shown) || null); }
async function click(id: string): Promise<void> { await visible(id); assert((await clickTestId(id)).ok, `Click ${id}`); }
async function focusTerminal(): Promise<void> {
  await waitFor(async () => { const rect = await screenPos("terminal.surface"); return rect.w > 0 && rect.h > 0 ? rect : null; });
  assert((await clickTestId("terminal.surface")).ok, "Focus actual Local surface");
}
async function footer(value: string): Promise<void> { await waitFor(async () => (await visible("settings.footer.state")).text === value || null); }
async function row(index: number): Promise<Row> {
  const node = await visible(`terminal.surface.row.${index}`);
  const texts = (node.children ?? []).filter((value) => shown(value) && value.tag === "text" && value.text !== undefined);
  const stamp = texts.find((value) => timestamp.test(value.text!));
  const glyphs = texts.filter((value) => value !== stamp).sort((a, b) => a.rect.x - b.rect.x);
  return { node, body: glyphs.map((value) => value.text).join(""), glyphs, timestamp: stamp };
}
async function observe(timestamps: boolean): Promise<Observation> {
  return waitFor(async () => {
    // screenPos returns only the public global logical rect; do not query a
    // full pane/surface subtree, which can overflow Harness's response limit.
    const pane = await screenPos("workspace.pane"), surface = await screenPos("terminal.surface");
    const rows = await Promise.all([row(0), row(1), row(2)]);
    near(surface.x, pane.x, "Surface/pane x");
    near(surface.y, pane.y, "Surface/pane y");
    for (let index = 0; index < 2; index++) {
      const value = rows[index], rect = value.node.rect;
      assert.equal(value.body, markers[index], "The same actual PTY output must survive settings saves");
      near(rect.x - pane.x, 8, "Row/pane inset x");
      near(rect.y - pane.y, 8 + index * 22, "Row/pane inset y");
      near(rect.w, surface.w - 16, "Row width");
      near(rect.h, 22, "Default visual row height");
      near(value.glyphs[0].rect.x - rect.x, timestamps ? 68 : 0, "Body/row x");
      near(value.glyphs[0].rect.x - pane.x, timestamps ? 76 : 8, "Body/pane x");
      for (const glyph of value.glyphs) {
        near(glyph.rect.h, 22, "Default glyph height");
        near(glyph.rect.y, rect.y, "Glyph baseline row box");
      }
      if (timestamps) {
        const stamp = value.timestamp;
        assert(stamp && timestamp.test(stamp.text!), "One complete HH:mm:ss timestamp per output row");
        assert.equal((value.node.children ?? []).filter((child) => shown(child) && timestamp.test(child.text ?? "")).length, 1);
        near(stamp.rect.x - rect.x, 12, "Timestamp/row x");
        near(stamp.rect.x - pane.x, 20, "Timestamp/pane x");
        near(stamp.rect.y - rect.y, 4, "Timestamp/row y");
        near(stamp.rect.w, 48, "Timestamp width");
        near(stamp.rect.h, 14, "Timestamp height");
        near(value.glyphs[0].rect.x - (stamp.rect.x + stamp.rect.w), 8, "Timestamp/body gap");
      } else assert.equal(value.timestamp, undefined, "Disabling timestamps must hide the real time nodes");
    }
    near(rows[2].node.rect.h, 22, "Current input row height");
    return { pane, surface, rows };
  });
}
async function openSettings(): Promise<void> {
  await click("toolbar.settings");
  await click("settings.nav.appearance");
  await visible("settings.appearance.aids.header");
}
async function openAids(): Promise<void> {
  if (!(await query("settings.toggle.timestamp_gutter")).some(shown)) await click("settings.appearance.aids.header");
  await visible("settings.toggle.timestamp_gutter");
  await visible("settings.toggle.input_line_highlight");
}
function configValue(source: string, section: string, field: string): unknown {
  let current = "";
  for (const raw of source.split("\n")) {
    const line = raw.trim();
    if (line.startsWith("[")) { current = line.slice(1, -1); continue; }
    const match = line.match(/^([a-z_]+)\s*=\s*(.+)$/);
    if (current === section && match?.[1] === field) return JSON.parse(match[2]);
  }
  throw new Error(`Missing persisted ${section}.${field}`);
}
async function save(name: string, timestamps: boolean, highlight: boolean, previous: string): Promise<string> {
  await footer("未保存");
  assert.equal(await readFile(configPath, "utf8"), previous, "Editing aids must not publish before Save");
  await click("settings.save");
  await footer("已保存");
  const saved = await readFile(configPath, "utf8");
  assert.equal(configValue(saved, "ui", "timestamp_gutter"), timestamps);
  assert.equal(configValue(saved, "ui", "input_line_highlight"), highlight);
  assert.equal(configValue(saved, "ui", "font_size"), 14);
  assert(Math.abs(Number(configValue(saved, "ui", "line_height")) - 11 / 7) < 0.000001, "Aid saves must preserve the exact default line-height multiplier, not write display-rounded 1.57");
  assert(Number(configValue(saved, "meta", "config_revision")) > Number(configValue(previous, "meta", "config_revision")));
  await writeFile(join(output, `${name}.config.toml`), saved);
  await click("settings.close");
  await hidden("settings.close");
  await focusTerminal();
  return saved;
}
async function capture(name: string, observed: Observation, highlight: boolean): Promise<void> {
  const path = join(output, `${name}.png`);
  assert((await screenshot(path)).ok, `Capture ${name}`);
  await writeFile(join(output, `${name}.queries.json`), JSON.stringify(observed, null, 2));
  captures.push({ name, path, queries: join(output, `${name}.queries.json`), input_highlight_requested: highlight, input_paint: "pending_manual_review" });
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
let failure: unknown;
try {
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), child.pid);
  assert((await resizeWindow(1440, 900)).ok);
  await click("workspace.empty.local");
  await waitFor(async () => descendants().some((value) => value.command.endsWith("/zsh")) || null);
  await focusTerminal();
  assert((await type_(`/bin/zsh -f ${quote(producerPath)}`)).ok);
  assert((await key("enter")).ok);
  const initial = await observe(false);
  await capture("default-timestamps-off-highlight-on", initial, true);
  checks.push("Real Local PTY output uses 22px row/glyph boxes and body x8 with timestamps omitted from the default config");

  await openSettings();
  if (!(await query("settings.field.font_size")).some(shown)) await click("settings.appearance.font.header");
  assert.equal((await inputState("settings.field.font_size")).buffer, "14");
  const displayLineHeight = (await inputState("settings.field.line_height")).buffer;
  assert(Math.abs(Number(displayLineHeight) - 11 / 7) < 0.005, `Default line-height field: ${displayLineHeight}`);
  report.default_typography = { size_field: 14, line_height_field: displayLineHeight, actual_row_height: initial.rows[0].node.rect.h, expected_multiplier: 11 / 7 };
  await openAids();
  await click("settings.toggle.timestamp_gutter");
  let saved = await save("timestamps-on-highlight-on", true, true, baseline);
  const enabled = await observe(true);
  await capture("timestamps-on-highlight-on", enabled, true);
  checks.push("Timestamp Save publishes true while keeping highlight true and default typography; actual time/body x12/68 within rows equals pane x20/76, with 48×14 timestamps and an 8px gap");

  const historyBefore = enabled.rows.slice(0, 2).map((value) => value.timestamp!.text);
  const waitedFrom = performance.now();
  await sleep(2200);
  const afterWait = await observe(true);
  const historyAfter = afterWait.rows.slice(0, 2).map((value) => value.timestamp!.text);
  assert.deepEqual(historyAfter, historyBefore, "Existing output timestamps must not become a live clock");
  report.history_wait = { waited_ms: performance.now() - waitedFrom, before: historyBefore, after: historyAfter, scope: "two visible historical output rows only" };
  await capture("history-after-wait", afterWait, true);
  checks.push("The two real output rows retain their complete timestamp text and original body while waiting at least 2.2 seconds");

  await openSettings();
  await openAids();
  await click("settings.toggle.input_line_highlight");
  saved = await save("timestamps-on-highlight-off", true, false, saved);
  const noHighlight = await observe(true);
  assert.deepEqual(noHighlight.rows.slice(0, 2).map((value) => value.body), initial.rows.slice(0, 2).map((value) => value.body));
  for (let i = 0; i < 3; i++) assert.deepEqual(noHighlight.rows[i].node.rect, enabled.rows[i].node.rect, "Highlight toggle must preserve row geometry");
  await capture("timestamps-on-highlight-off", noHighlight, false);
  checks.push("Highlight-only Save persists false; the same Local output, timestamp/body geometry and current input row dimensions are preserved (paint remains visual review)");

  await openSettings();
  await openAids();
  await click("settings.toggle.timestamp_gutter");
  await click("settings.toggle.input_line_highlight");
  await save("timestamps-off-highlight-on-restored", false, true, saved);
  const restored = await observe(false);
  for (let i = 0; i < 2; i++) near(restored.rows[i].glyphs[0].rect.x, initial.rows[i].glyphs[0].rect.x, "Restored original body origin");
  await capture("timestamps-off-highlight-on-restored", restored, true);
  checks.push("Saving timestamps off restores body x8 without a reserved time column and preserves both output lines; highlight true and exact 14/22 defaults are restored");
  report.status = "passed";
  (report.functional as { status: string }).status = "passed";
} catch (error) {
  failure = launchError ?? error;
  report.status = "failed";
  (report.functional as { status: string }).status = "failed";
  report.error = String(failure);
  if (child.exitCode === null && child.signalCode === null) await Promise.allSettled([
    screenshot(join(output, "failure.png")),
    (async () => {
      const ids = ["settings.footer.state", "settings.toggle.timestamp_gutter", "settings.toggle.input_line_highlight", "terminal.surface.row.0", "terminal.surface.row.1", "terminal.surface.row.2"];
      const results = await Promise.allSettled(ids.map((id) => query(id)));
      await writeFile(join(output, "failure-queries.json"), JSON.stringify(Object.fromEntries(ids.map((id, index) => [id, results[index]])), null, 2));
    })(),
  ]);
} finally {
  await writeFile(release, "finish\n");
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
