/** Saved material geometry and visual evidence through production controls.
 * node e2e/material_geometry.ts --out DIR [--binary PATH]
 * Requires an existing test-mode binary. No native picker or pixel parity claim.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync } from "node:zlib";
import { waitForServerReady, waitFor, query, inputState, clickTestId, key, type_, resizeWindow, screenshot, sleep } from "../zig-out/share/zenit/harness/client.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2), options: Record<string, string> = {};
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out"].includes(args[i]) && args[i + 1], `Invalid option ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--out"], "--out is required");
const output = resolve(options["--out"]);
const binary = resolve(options["--binary"] ?? join(root, "zig-out/bin/zerowork"));
const binaryHash = createHash("sha256").update(await readFile(binary)).digest("hex");
const isolated = await mkdtemp(join(tmpdir(), "zerowork-material-ui-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data)]);
const source = { width: 640, height: 256, pixels_per_point: 1 };
const windowSize = { width: 1440, height: 900 };

// A normal RGBA PNG without density metadata. Four asymmetric color quadrants,
// a black border and 8px black/white checks expose scale, crop, phase and blur.
function fixturePng(): Buffer {
  function chunk(kind: string, data: Buffer): Buffer {
    const payload = Buffer.concat([Buffer.from(kind), data]);
    let crc = 0xffffffff;
    for (const byte of payload) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    const length = Buffer.alloc(4), checksum = Buffer.alloc(4);
    length.writeUInt32BE(data.length); checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([length, payload, checksum]);
  }
  const rows = Buffer.alloc((source.width * 4 + 1) * source.height);
  const colors = [[240, 70, 40], [35, 105, 240], [25, 185, 100], [245, 205, 35]];
  for (let y = 0; y < source.height; y++) for (let x = 0; x < source.width; x++) {
    const index = y * (source.width * 4 + 1) + 1 + x * 4;
    let color = colors[(y >= 96 ? 2 : 0) + (x >= 272 ? 1 : 0)];
    if (x < 4 || y < 4 || x >= source.width - 4 || y >= source.height - 4) color = [0, 0, 0];
    else if (x >= 288 && x < 352) color = (Math.floor(x / 8) + Math.floor(y / 8)) % 2 ? [255, 255, 255] : [0, 0, 0];
    rows.set([...color, 255], index);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(source.width, 0); ihdr.writeUInt32BE(source.height, 4);
  ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from("89504e470d0a1a0a", "hex"), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0))]);
}
const fixture = fixturePng(), image = join(data, "material-pattern.png"), configPath = join(data, "config.toml");
await Promise.all([writeFile(image, fixture), writeFile(join(output, "fixture.png"), fixture)]);
const baseline = `[meta]
config_revision = 1
[ui]
theme = "dark"
font_family = "Menlo"
font_size = 14
font_weight = "regular"
line_height = 1.5
[ui.materials]
blur_px = 0
[ui.materials.background]
enabled = true
path = ${JSON.stringify(image)}
fit = "fill"
alignment_x = "center"
alignment_y = "center"
transparency = 1
`;
await Promise.all([writeFile(configPath, baseline), writeFile(join(output, "config-before.toml"), baseline)]);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(output, "app.log"), "w");
const child = spawn(binary, [], { cwd: root, env: {
  ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_ISOLATE_POINTER: "1",
  ZENIT_E2E_BACKGROUND: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0",
}, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>((done) => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", (error) => { launchError = error; });
type Fit = "fill" | "fit" | "center" | "tile";
type Horizontal = "left" | "center" | "right";
type Vertical = "top" | "center" | "bottom";
type Case = { name: string; fit: Fit; x: Horizontal; y: Vertical; transparency: number; blur: number };
const center = { x: "center" as const, y: "center" as const, transparency: 0, blur: 0 };
const cases: Case[] = (["fill", "fit", "tile", "center"] as Fit[]).map((fit) => ({ name: `fit-${fit}`, fit, ...center }));
for (const y of ["top", "center", "bottom"] as Vertical[]) for (const x of ["left", "center", "right"] as Horizontal[]) {
  // Center/center is already captured by fit-center; do not repeat it.
  if (x !== "center" || y !== "center") cases.push({ name: `align-${y}-${x}`, fit: "center", x, y, transparency: 0, blur: 0 });
}
cases.push({ name: "transparency-100", fit: "fill", ...center, transparency: 100 });
cases.push({ name: "blur-16", fit: "fill", ...center, blur: 16 });
const report: Record<string, unknown> = {
  status: "running", started_at: new Date().toISOString(), binary, binary_sha256: binaryHash, pid: child.pid,
  source: { ...source, png_sha256: createHash("sha256").update(fixture).digest("hex"), fixture: join(output, "fixture.png"),
    pattern: "quadrant split x=272/y=96: orange, blue, green, yellow; 4px black border; x=288..351 has 8px black/white checks; all pixels opaque" },
  expected_geometry_source: "docs/DESIGN/V0.1.2_LOCAL_TERMINAL.md §7.3; src/config/background_geometry.zig resolve; src/ui/background_repeat.zig grid. One transform in window logical coordinates; density=1 independent of Retina scale.",
  expected_formulas: "Fill: max(W/sw,H/sh); Fit: min(W/sw,H/sh); Center/Tile: scale=1. Origin=(window-image)*alignment fraction (0,0.5,1). Tile first=phase+floor(-phase/period)*period. Alpha=1-transparency/100; blur acts on background, not foreground.",
  visual_review: "pending", cases: [], limits: [
    "Functional pass verifies controls, real persisted config and image-node rectangles, not raster correctness. Actual screenshots require visual review for crop/tiling/alpha/blur and foreground legibility.",
    "A normal saved background fixture enters the real worker; native picker, replacement/cancellation and real IME are not tested.",
    "No Local/SSH sessions are created; shared image phase across split terminal panes is not covered.",
    "Only the runner-owned process tree is terminated; cleanup is not normal-close evidence.",
  ],
};
type Node = Awaited<ReturnType<typeof query>>[number] & { hidden?: boolean; effective_opacity?: number };
type Rect = { x: number; y: number; w: number; h: number };
function shown(node: Node): boolean { return node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0; }
async function visible(id: string): Promise<Node> { return await waitFor(async () => (await query(id)).find(shown) ?? null); }
async function hidden(id: string): Promise<void> { await waitFor(async () => !(await query(id)).some(shown) || null); }
async function click(id: string): Promise<void> { await visible(id); assert((await clickTestId(id)).ok, `Click ${id}`); }
async function edit(id: string, value: number): Promise<void> {
  if (Number((await inputState(id)).buffer) === value) return;
  await click(id);
  assert((await key("a", { cmd: true })).ok);
  assert((await type_(String(value))).ok);
  assert((await key("return")).ok);
  await waitFor(async () => Number((await inputState(id)).buffer) === value || null);
}
const alignNames = [["左上", "上中", "右上"], ["左中", "居中", "右中"], ["左下", "下中", "右下"]];
function alignmentName(c: Case): string { return alignNames[["top", "center", "bottom"].indexOf(c.y)][["left", "center", "right"].indexOf(c.x)]; }
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
function expected(c: Case) {
  const scale = c.fit === "fill" ? Math.max(windowSize.width / source.width, windowSize.height / source.height)
    : c.fit === "fit" ? Math.min(windowSize.width / source.width, windowSize.height / source.height) : 1;
  const w = source.width * scale, h = source.height * scale;
  const x = (windowSize.width - w) * ["left", "center", "right"].indexOf(c.x) / 2;
  const y = (windowSize.height - h) * ["top", "center", "bottom"].indexOf(c.y) / 2;
  const rects: Rect[] = [];
  const firstX = c.fit === "tile" ? x + Math.floor(-x / w) * w : x;
  const firstY = c.fit === "tile" ? y + Math.floor(-y / h) * h : y;
  const cols = c.fit === "tile" ? Math.ceil((windowSize.width - firstX) / w) : 1;
  const rows = c.fit === "tile" ? Math.ceil((windowSize.height - firstY) / h) : 1;
  for (let row = 0; row < rows; row++) for (let col = 0; col < cols; col++) rects.push({ x: firstX + col * w, y: firstY + row * h, w, h });
  return { image: { x, y, w, h }, pixels_to_points: scale, repeats: c.fit === "tile", image_rects: rects,
    alpha: 1 - c.transparency / 100, blur_px: c.blur, visual_check: c.transparency === 100 ? "Compare to fit-fill: image fully hidden behind theme base; foreground unchanged" : c.blur ? "Compare to fit-fill: background checker edges soften; foreground text stays sharp" : "Inspect quadrant placement, aspect ratio, crop/empty margins or tile phase; compare to image rects" };
}
function imageRects(node: Node, parentVisible = true): Rect[] {
  const active = parentVisible && shown(node);
  if (!active) return [];
  return [...(node.tag === "image" ? [node.rect] : []), ...(node.children ?? []).flatMap((child) => imageRects(child, active))];
}
function sameRects(actual: Rect[], wanted: Rect[]): boolean {
  return actual.length === wanted.length && actual.every((rect, i) => (["x", "y", "w", "h"] as const).every((axis) => Math.abs(rect[axis] - wanted[i][axis]) <= 0.5));
}
function descendants(): { pid: number; parent: number; command: string }[] {
  const all = execFileSync("/bin/ps", ["-axo", "pid=,ppid=,comm="], { encoding: "utf8" }).trim().split("\n").flatMap((line) => {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/);
    return match ? [{ pid: Number(match[1]), parent: Number(match[2]), command: match[3] }] : [];
  });
  const owned = new Set([child.pid]);
  for (let i = 0; i < all.length; i++) {
    let changed = false;
    for (const value of all) if (owned.has(value.parent) && !owned.has(value.pid)) { owned.add(value.pid); changed = true; }
    if (!changed) break;
  }
  return all.filter((value) => value.pid !== child.pid && owned.has(value.pid));
}
const evidenceIds = ["settings.field.fit", "settings.field.alignment", "settings.field.transparency", "settings.field.blur_px", "settings.footer.state", "settings.materials.preview.actions", "toolbar.settings", "appearance.background"];
async function capture(name: string): Promise<string> {
  await sleep(250);
  const path = join(output, `${name}.png`);
  assert((await screenshot(path)).ok);
  // The 640x256 fixture needs only 15 Tile image nodes; this subtree stays small.
  const queries = Object.fromEntries(await Promise.all(evidenceIds.map(async (id) => [id, await query(id)])));
  await writeFile(join(output, `${name}.queries.json`), JSON.stringify(queries, null, 2));
  return path;
}
let failure: unknown;
try {
  await waitForServerReady();
  const owner = JSON.parse(await readFile(join(rpc, "owner.json"), "utf8"));
  assert.equal(Number(owner.pid), child.pid);
  report.descendants_at_start = descendants();
  assert((await resizeWindow(windowSize.width, windowSize.height)).ok);
  await click("toolbar.settings");
  await click("settings.nav.appearance");
  await click("settings.appearance.themes.header");
  await waitFor(async () => (await visible("settings.background.state")).text?.includes("本地 · 640 × 256") || null);
  let current = { fit: "fill" as Fit, x: "center" as Horizontal, y: "center" as Vertical }, revision = 1;
  for (const c of cases) {
    const result: Record<string, unknown> = { name: c.name, controls: c, expected: expected(c), status: "running" };
    (report.cases as Record<string, unknown>[]).push(result);
    if (current.fit !== c.fit) {
      await click("settings.field.fit");
      await click(`settings.option.fit.${c.fit}`);
      await hidden("settings.chooser.fit");
    }
    if (current.x !== c.x || current.y !== c.y) {
      await click("settings.field.alignment");
      await click(`settings.alignment.${alignmentName(c)}`);
      await hidden("settings.chooser.alignment");
    }
    await edit("settings.field.transparency", c.transparency);
    await edit("settings.field.blur_px", c.blur);
    await click("settings.save");
    await waitFor(async () => (await visible("settings.footer.state")).text === "已保存" || null);
    const saved = await readFile(configPath, "utf8");
    for (const [field, wanted] of Object.entries({ enabled: true, path: image, fit: c.fit, alignment_x: c.x, alignment_y: c.y, transparency: c.transparency })) {
      assert.equal(configValue(saved, "ui.materials.background", field), wanted, `${c.name}: persisted ${field}`);
    }
    assert.equal(configValue(saved, "ui.materials", "blur_px"), c.blur);
    const nextRevision = Number(configValue(saved, "meta", "config_revision"));
    assert(nextRevision > revision, `${c.name}: real Save must advance revision`);
    revision = nextRevision;
    await writeFile(join(output, `${c.name}.config.toml`), saved);
    if (c.name === "fit-fill") {
      await capture("global-settings-appearance");
      await click("settings.field.fit");
      await visible("settings.chooser.fit");
      await capture("global-settings-chooser");
      await key("escape");
      await hidden("settings.chooser.fit");
    }
    await click("settings.materials.preview.open");
    await visible("settings.materials.preview.actions");
    await hidden("settings.close");
    const background = await waitFor(async () => {
      const node = (await query("appearance.background")).find(shown);
      return node && sameRects(imageRects(node), expected(c).image_rects) ? node : null;
    });
    for (const [axis, wanted] of Object.entries({ x: 0, y: 0, w: windowSize.width, h: windowSize.height })) {
      assert(Math.abs(background.rect[axis as keyof Rect] - wanted) <= 0.5, `Actual window ${axis}`);
    }
    result.actual_image_rects = imageRects(background);
    result.config_revision = revision;
    result.screenshot = await capture(c.name);
    result.status = "saved_geometry_checked_pixels_pending";
    await click("settings.materials.preview.return");
    await hidden("settings.materials.preview.actions");
    await visible("settings.close");
    current = c;
  }
  report.status = "functional_checks_passed";
} catch (error) {
  failure = launchError ?? error;
  report.status = "failed";
  report.error = String(failure);
  const running = (report.cases as Record<string, unknown>[]).at(-1);
  if (running?.status === "running") { running.status = "failed"; running.error = String(failure); }
  if (child.exitCode === null && child.signalCode === null) await Promise.allSettled([
    capture("failure"), writeFile(join(output, "remaining-processes.json"), JSON.stringify(descendants(), null, 2)),
    readFile(configPath).then((value) => writeFile(join(output, "failure.config.toml"), value)),
  ]);
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
console.log(`${report.status}; visual review ${report.visual_review}: ${join(output, "report.json")}`);
if (failure) throw failure;
