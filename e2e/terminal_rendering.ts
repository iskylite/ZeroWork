/** Real Local PTY -> Ghostty -> TerminalSurface rendering evidence.
 * node e2e/terminal_rendering.ts --out DIR [--binary PATH]
 * Requires an existing test-mode binary. Uses only public Harness input/query/
 * resize/scroll APIs; writes ordinary shell fixtures, never a service backdoor.
 * Functional assertions do not certify pixels. Review the saved PNGs separately.
 * Harness type_ is not native keyboard, clipboard, or real IME evidence.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, clickTestId, key, type_, resizeWindow, scrollAt, screenshot, sleep, type QueryNode } from "../zig-out/share/zenit/harness/client.ts";

const args = process.argv.slice(2), options: Record<string, string> = {};
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out"].includes(args[i]) && args[i + 1], `Invalid option ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--out"], "--out is required");
const output = resolve(options["--out"]), binary = resolve(options["--binary"] ?? "zig-out/bin/zerowork");
const isolated = await mkdtemp(join(tmpdir(), "zerowork-rendering-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data)]);
await writeFile(join(data, "config.toml"), `[meta]
config_revision = 1
[ui]
theme = "dark"
font_family = "Menlo"
font_size = 14
font_weight = "regular"
line_height = 1.5
timestamp_gutter = false
input_line_highlight = false
[completion]
enabled = false
`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(output, "app.log"), "w");
const child = spawn(binary, [], { env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_ISOLATE_POINTER: "1", ZENIT_E2E_BACKGROUND: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0" }, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>((done) => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", (error) => { launchError = error; });
const report: Record<string, unknown> = {
  status: "running", started_at: new Date().toISOString(), binary,
  binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"), pid: child.pid,
  functional_checks: [], captures: [], shell_stdout: [], pixel_review: "pending", real_ime: "not_tested",
  limits: [
    "A functional pass checks real PTY output, owned grapheme-node geometry, resize/reflow, viewport retention and alternate-screen restoration. It does not certify actual colors, glyph shapes, clipping or font fallback.",
    "PNG/query/rows artifacts and per-capture review criteria require actual pixel review. Public Harness query does not expose terminal SGR colors or mode/geometry revisions.",
    "Input is public Harness type_/key/scrollAt, not native keyboard, clipboard, trackpad or real IME. There are no synthetic IME claims.",
    "The runner's final process termination is cleanup only, never normal-window-close evidence.",
  ],
};
const checks = report.functional_checks as string[];
type Node = QueryNode & { hidden?: boolean; effective_opacity?: number };
type Row = { rect: QueryNode["rect"]; text: string; glyphs: Node[] };
type SurfaceSnapshot = { observation: "bounded-row-queries"; grid: { cols: number; rows: number }; bounds: QueryNode["rect"]; row_nodes: Node[] };
const shown = (node: Node): boolean => node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0;
function allText(node: Node): string { return shown(node) ? (node.text ?? "") + (node.children ?? []).map(allText).join("") : ""; }
async function queryNodes(id: string): Promise<Node[]> {
  const result = await query(id);
  assert(Array.isArray(result), `Harness query ${id} failed: ${JSON.stringify(result)}`);
  return result;
}
async function visible(id: string): Promise<Node> { return waitFor(async () => (await queryNodes(id)).find(shown) ?? null); }
async function surface(): Promise<SurfaceSnapshot> {
  // Never query the entire terminal subtree: a populated grid can exceed the
  // SDK's 256KiB response buffer. Each ordinary public row query stays bounded.
  return waitFor(async () => {
    const size = await grid(), row_nodes: Node[] = [];
    for (let start = 0; start < size.rows; start += 8) {
      const batch = await Promise.all(Array.from({ length: Math.min(8, size.rows - start) }, (_, offset) => queryNodes(`terminal.surface.row.${start + offset}`)));
      for (const result of batch) {
        const matches = result.filter(shown);
        if (matches.length === 0) return null;
        assert.equal(matches.length, 1, "This isolated single-session fixture must have one visible node per row ID");
        row_nodes.push(matches[0]);
      }
    }
    const current = await grid();
    if (current.cols !== size.cols || current.rows !== size.rows) return null;
    const x = Math.min(...row_nodes.map((row) => row.rect.x)), y = Math.min(...row_nodes.map((row) => row.rect.y));
    return { observation: "bounded-row-queries", grid: size, bounds: { x, y, w: Math.max(...row_nodes.map((row) => row.rect.x + row.rect.w)) - x, h: Math.max(...row_nodes.map((row) => row.rect.y + row.rect.h)) - y }, row_nodes };
  });
}
function rows(snapshot: SurfaceSnapshot): Row[] {
  // Surface publishes positioned row boxes containing per-grapheme text nodes.
  // Exclude its direct preedit/message nodes and hidden pooled glyphs.
  return snapshot.row_nodes.map((row) => {
    const glyphs = (row.children ?? []).filter((glyph) => shown(glyph) && glyph.tag === "text" && glyph.text !== undefined).sort((a, b) => a.rect.x - b.rect.x);
    return { rect: row.rect, text: glyphs.map((glyph) => glyph.text).join(""), glyphs };
  }).sort((a, b) => a.rect.y - b.rect.y);
}
async function waitText(marker: string): Promise<Row[]> {
  return waitFor(async () => { const value = rows(await surface()); return value.some((row) => row.text.includes(marker)) ? value : null; });
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
async function pipelineFinished(): Promise<void> { await waitFor(async () => !descendants().some((value) => value.command.endsWith("/tee")) || null); }
const quote = (value: string): string => `'${value.replaceAll("'", "'\\''")}'`;
const emit = (value: string): string => `printf '%s' ${quote(value)}\n`;
const reset = "\x1b[0m\x1b[?1049l\x1b[3J\x1b[2J\x1b[H";
async function command(value: string): Promise<void> {
  assert((await clickTestId("terminal.surface")).ok);
  assert((await type_(value)).ok);
  assert((await key("enter")).ok);
}
async function launchFixture(name: string, body: string, exitSession = false): Promise<string> {
  const script = join(isolated, `${name}.zsh`), raw = join(isolated, `${name}.stdout`);
  await Promise.all([writeFile(script, `#!/bin/zsh\nset -eu\n${body}`), writeFile(join(output, `${name}.zsh`), `#!/bin/zsh\nset -eu\n${body}`)]);
  // tee records exactly what the real shell sends onward to its actual PTY.
  // The command echo only contains filenames, never the asserted output markers.
  await command(`/bin/zsh -f ${quote(script)} | /usr/bin/tee ${quote(raw)}${exitSession ? "; exit" : ""}`);
  return raw;
}
async function verifyStdout(name: string, raw: string, expected: string, complete = true): Promise<void> {
  const wanted = Buffer.from(expected);
  const actual = await waitFor(async () => { const bytes = await readFile(raw); return bytes.equals(wanted) ? bytes : null; });
  if (complete) await pipelineFinished();
  await writeFile(join(output, `${name}.stdout`), actual);
  (report.shell_stdout as unknown[]).push({ name, bytes: actual.length, sha256: createHash("sha256").update(actual).digest("hex"), exact_fixture_match: true, complete });
}
async function capture(name: string, review: string): Promise<void> {
  await sleep(200);
  assert((await screenshot(join(output, `${name}.png`))).ok);
  const node = await surface();
  await writeFile(join(output, `${name}.surface.json`), JSON.stringify(node, null, 2));
  await writeFile(join(output, `${name}.rows.json`), JSON.stringify(rows(node), null, 2));
  (report.captures as unknown[]).push({ name, screenshot: join(output, `${name}.png`), query: join(output, `${name}.surface.json`), query_method: node.observation, pixel_review: "pending", review });
}
async function grid(): Promise<{ cols: number; rows: number }> {
  const label = allText(await visible("local.status.grid")), match = label.match(/(\d+)×(\d+)/);
  assert(match, `Missing actual grid: ${label}`);
  return { cols: Number(match[1]), rows: Number(match[2]) };
}
async function verifyPtyGrid(expected: { cols: number; rows: number }): Promise<void> {
  await command("printf '__TTY_%s__\\n' \"$(stty size)\"");
  await waitText(`__TTY_${expected.rows} ${expected.cols}__`);
}
function checkLongLine(value: Row[], payload: string, cols: number): void {
  const first = value.findIndex((row) => row.text.startsWith("LONG_"));
  assert(first >= 0, "Long-line start must still be retained in the visible viewport");
  const count = Math.ceil(payload.length / cols), wrapped = value.slice(first, first + count);
  assert.equal(wrapped.map((row) => row.text).join(""), payload, "Resize must preserve exactly one logical line, without loss, duplication or UI-created wrapping");
  for (let i = 0; i < wrapped.length; i++) {
    assert.equal(wrapped[i].glyphs.reduce((cells, glyph) => cells + (glyph.text?.length ?? 0), 0), Math.min(cols, payload.length - i * cols), "Only VT cell wrapping may split the ASCII line");
    assert(wrapped[i].glyphs.every((glyph) => Math.abs(glyph.rect.y - wrapped[i].rect.y) < 0.5 && Math.abs(glyph.rect.h - wrapped[i].rect.h) < 0.5), "Glyphs must stay on their published VT row");
    assert(wrapped[i].glyphs.every((glyph) => glyph.rect.x >= wrapped[i].rect.x - 0.5 && glyph.rect.x + glyph.rect.w <= wrapped[i].rect.x + wrapped[i].rect.w + 0.5), "Glyph rectangles must remain inside their row");
  }
}
let failure: unknown;
try {
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), child.pid);
  assert((await resizeWindow(1440, 900)).ok);
  assert((await clickTestId("workspace.empty.local")).ok);
  await surface();
  await waitFor(async () => descendants().some((value) => value.command.endsWith("/zsh")) || null);
  checks.push("A real owned Local zsh PTY exposes the production TerminalSurface");

  // Deliberately small color matrix: all ANSI16 backgrounds, distinguishing
  // indexed colors, RGB values, and explicit black/white against their opposite.
  const swatch = (sgr: string, label: string): string => `\x1b[${sgr}m ${label} \x1b[0m`;
  const colorBytes = reset + "RENDER_COLORS\r\n" + [
    "ANSI 0-7 " + Array.from({ length: 8 }, (_, i) => swatch(`${i < 4 ? 97 : 30};${40 + i}`, String(i))).join(""),
    "ANSI 8-15 " + Array.from({ length: 8 }, (_, i) => swatch(`${i < 4 ? 97 : 30};${100 + i}`, String(i + 8))).join(""),
    "INDEXED " + [16, 21, 46, 196, 201, 231, 244].map((i) => swatch(`38;5;${i === 16 || i === 21 ? 231 : 16};48;5;${i}`, String(i))).join(""),
    "TRUE RGB " + swatch("38;2;0;0;0;48;2;255;255;255", "BLACK") + swatch("38;2;255;255;255;48;2;0;0;0", "WHITE") + swatch("38;2;255;255;255;48;2;18;52;86", "123456"),
    "UNICODE U|A界e\u0301🧪👩‍💻Z|",
    "CJK 中文 / COMBINING Cafe\u0301 / EMOJI 🧪 👩‍💻",
    "RENDER_COLOR_DONE",
  ].join("\r\n") + "\r\n";
  const colorRaw = await launchFixture("colors-unicode", emit(colorBytes));
  await verifyStdout("colors-unicode", colorRaw, colorBytes);
  const colored = await waitText("RENDER_COLOR_DONE"), unicode = colored.find((row) => row.text.startsWith("UNICODE "));
  assert(unicode && unicode.text === "UNICODE U|A界e\u0301🧪👩‍💻Z|", "Unicode must reach the actual owned grapheme projection without replacement text");
  const asciiTail = unicode.glyphs.find((glyph) => glyph.text === "Z|")!;
  const cell = asciiTail.rect.w / 2;
  for (const [grapheme, cells] of [["界", 2], ["e\u0301", 1], ["🧪", 2], ["👩‍💻", 2]] as const) {
    const glyph = unicode.glyphs.filter((value) => value.text === grapheme);
    assert.equal(glyph.length, 1, `${grapheme} must be one published grapheme node`);
    assert(Math.abs(glyph[0].rect.w - cell * cells) < 0.1, `${grapheme} must occupy ${cells} VT cells`);
  }
  await capture("colors-unicode", "Inspect all ANSI16 swatches; indexed 16/231 must be black/white; 21 blue, 46 green, 196 red, 201 magenta, 244 gray. True BLACK/WHITE must use literal RGB 0/255 and opposite backgrounds; 123456 background must be #123456. Check CJK, combining accent and emoji shapes, advance, fallback and clipping at native screenshot resolution.");
  checks.push("Actual shell stdout contains exact ANSI16/indexed/RGB bytes; CJK/combining/emoji survive VT and have one/two-cell grapheme geometry (pixels remain pending)");

  const wide = await grid();
  await verifyPtyGrid(wide);
  const longLine = "LONG_" + "0123456789".repeat(Math.ceil((wide.cols + 41) / 10)).slice(0, wide.cols + 41) + "_END";
  const longBytes = reset + longLine + "\r\nREFLOW_DONE\r\n";
  const longRaw = await launchFixture("reflow", emit(longBytes));
  await verifyStdout("reflow", longRaw, longBytes);
  checkLongLine(await waitText("REFLOW_DONE"), longLine, wide.cols);
  await capture("reflow-wide", "The single LONG_…_END logical line may split only at the PTY/VT column boundary. Inspect baseline, advance, right-edge clipping and absence of an additional text-layout wrap.");
  assert((await resizeWindow(860, 480)).ok);
  const compact = await waitFor(async () => { const next = await grid(); return next.cols !== wide.cols ? next : null; });
  await verifyPtyGrid(compact);
  await waitFor(async () => { checkLongLine(rows(await surface()), longLine, compact.cols); return true; });
  await capture("reflow-compact", "Compare the same logical line to reflow-wide: exact character order and count, wrapping only at the new actual grid width, no overlap or second visual wrap.");
  assert((await resizeWindow(1440, 900)).ok);
  await waitFor(async () => (await grid()).cols === wide.cols || null);
  await verifyPtyGrid(wide);
  await waitFor(async () => { checkLongLine(rows(await surface()), longLine, wide.cols); return true; });
  await capture("reflow-restored", "Compare to reflow-wide: restored wrap boundaries and glyph geometry, no accumulated wrap or duplicated content after resize round-trip.");
  report.pty_grid = { wide, compact };
  checks.push("Real stty winsize agrees with the status grid; an ASCII line reflows at VT columns through wide/compact/wide without loss, duplication or a second UI row wrap");

  // Ordinary files only coordinate a real producer, so new output arrives
  // without typing a command (typing is allowed to scroll back to the bottom).
  const ready = join(isolated, "scroll.ready"), release = join(isolated, "scroll.release"), finish = join(isolated, "scroll.finish");
  const before = reset + Array.from({ length: 120 }, (_, i) => `R_SCROLL_${String(i).padStart(3, "0")}\r\n`).join("");
  const after = Array.from({ length: 20 }, (_, i) => `R_NEW_${String(i).padStart(3, "0")}\r\n`).join("") + "R_NEW_DONE\r\n";
  const scrollRaw = await launchFixture("scroll", emit(before) + `: > ${quote(ready)}\nwhile [[ ! -e ${quote(release)} ]]; do /bin/sleep 0.05; done\n` + emit(after) + `while [[ ! -e ${quote(finish)} ]]; do /bin/sleep 0.05; done\n` + emit("R_SCROLL_FINISHED\r\n"));
  await waitFor(async () => (await readFile(ready)).length === 0 || null);
  const bottom = await waitText("R_SCROLL_119"), bottomFirst = bottom.find((row) => row.text.startsWith("R_SCROLL_"))!.text;
  const host = await surface(), rowHeight = bottom.find((row) => row.text.startsWith("R_SCROLL_"))!.rect.h;
  const point = { x: host.bounds.x + host.bounds.w * 0.6, y: host.bounds.y + host.bounds.h * 0.5 };
  // Public Harness keeps the native AppKit sign: positive dy scrolls upward;
  // the Surface converts it to Ghostty's negative-up row delta exactly once.
  assert((await scrollAt(point.x, point.y, 0, rowHeight * 12)).ok);
  const pinned = await waitFor(async () => {
    const value = rows(await surface()), first = value.find((row) => row.text.startsWith("R_SCROLL_"))?.text;
    return first && first < bottomFirst ? value : null;
  });
  const signature = pinned.map((row) => row.text).join("\n");
  await capture("scroll-pinned-before", "Record the visible R_SCROLL row range and top-line position before the producer emits more output.");
  await writeFile(release, "continue\n");
  await verifyStdout("scroll-before-finish", scrollRaw, before + after, false);
  // Assert retention repeatedly while the real producer has already emitted
  // all new bytes. Bottom verification below proves those bytes reached VT.
  for (let i = 0; i < 5; i++) {
    await sleep(100);
    assert.equal(rows(await surface()).map((row) => row.text).join("\n"), signature, "Incoming PTY output must preserve the scrolled-up visible rows");
  }
  await capture("scroll-pinned-after", "Compare pixel positions and content with scroll-pinned-before: new output must not pull the viewport to the bottom or move the retained lines.");
  assert((await scrollAt(point.x, point.y, 0, -rowHeight * 1000)).ok);
  await waitText("R_NEW_DONE");
  await writeFile(finish, "finish\n");
  await verifyStdout("scroll-complete", scrollRaw, before + after + "R_SCROLL_FINISHED\r\n");
  await waitText("R_SCROLL_FINISHED");
  checks.push("Public scrollAt moves the real VT viewport upward; new PTY output preserves visible rows across five observations, and scrolling down reveals the actual new tail");

  // Last scenario exits the actual interactive shell too, so the final frame
  // must survive EOF/process exit rather than merely returning to a prompt.
  const altRelease = join(isolated, "alt.release");
  const primary = reset + "PRIMARY_BEFORE_ALT\r\n";
  const alt = "\x1b[?1049h\x1b[2J\x1b[HALT_ACTIVE 界 🧪\r\n";
  const tail = "\x1b[?1049l\r\nAFTER_ALT_TAIL\r\nFINAL_EOF_TAIL\r\n";
  const altRaw = await launchFixture("alternate-screen", emit(primary + alt) + `while [[ ! -e ${quote(altRelease)} ]]; do /bin/sleep 0.05; done\n` + emit(tail), true);
  const alternate = await waitText("ALT_ACTIVE 界 🧪");
  assert(!alternate.some((row) => row.text.includes("PRIMARY_BEFORE_ALT")), "Alternate screen must replace, rather than append to, the primary viewport");
  await capture("alternate-active", "Only ALT_ACTIVE belongs to the alternate viewport; inspect CJK/emoji there and absence of primary-screen ghosting.");
  await writeFile(altRelease, "leave\n");
  await verifyStdout("alternate-screen", altRaw, primary + alt + tail);
  const restored = await waitText("FINAL_EOF_TAIL");
  assert(restored.some((row) => row.text.includes("PRIMARY_BEFORE_ALT")), "Leaving alternate screen must restore primary contents");
  assert(restored.some((row) => row.text.includes("AFTER_ALT_TAIL")), "Post-alternate output must survive final process exit");
  assert(!restored.some((row) => row.text.includes("ALT_ACTIVE")), "Alternate contents must not leak into the restored primary screen");
  await visible("local.ended.new");
  await waitFor(async () => !descendants().some((value) => value.command.endsWith("/zsh")) || null);
  await capture("alternate-exited-tail", "Primary contents, AFTER_ALT_TAIL and FINAL_EOF_TAIL remain readable after the real shell exits. Inspect the final row and tombstone for truncation, clearing or stale alternate pixels.");
  checks.push("Actual DEC1049 alternate-screen entry/exit restores primary contents and retains post-alternate/final output after the owned zsh exits");
  report.status = "functional_checks_passed_pixels_pending";
} catch (error) {
  failure = launchError ?? error;
  report.status = "failed";
  report.error = String(failure);
  if (child.exitCode === null && child.signalCode === null) {
    await Promise.allSettled([capture("failure", "Failure diagnostics only; not a passing visual result."), writeFile(join(output, "remaining-processes.json"), JSON.stringify(descendants(), null, 2))]);
  }
} finally {
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
