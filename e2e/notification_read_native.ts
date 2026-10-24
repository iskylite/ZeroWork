/** Notification attention/read receipts in two real Local ZSH sessions.
 * PREPARE (default, no app/process starts):
 *   node e2e/notification_read_native.ts --out DIR --prepare-only 1
 * ROOT SERIAL NATIVE SLOT ONLY:
 *   node e2e/notification_read_native.ts --run 1 --binary PATH --expected-sha SHA256 --out EMPTY_DIR
 * Pure PNG-reader checks, no app/RPC/native API:
 *   node e2e/notification_read_native.ts --self-test 1
 *
 * Public Harness creates the sessions and sources owned producer scripts. Only
 * root's CUA performs acceptance window/tab/focus/wheel actions. A completion
 * file is synchronization, not independent evidence of native foreground.
 * The runner never changes production metadata, calls domain backdoors, or
 * requests OS authorization. All system-event preferences and Bell are false.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { chmod, copyFile, mkdir, mkdtemp, open, readFile, readdir, realpath, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync, inflateSync } from "node:zlib";
import { waitForServerReady, waitFor, query, focused, clickAt, key, type_, resizeWindow, screenshot, stats, sleep } from "../zig-out/share/zenit/harness/client.ts";

type Rect = { x: number; y: number; w: number; h: number };
type Image = { width: number; height: number; channels: number; pixels: Buffer };
type Session = { label: string; tab: string; session_id: string; focus_id: number; input_rect: Rect; surface_id: number; shell_pid: number; producer_pid: number; spool: string; stop: string; seed: string };
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const options: Record<string, string> = {};
for (let i = 2; i < process.argv.length; i += 2) {
  assert(["--out", "--binary", "--expected-sha", "--prepare-only", "--run", "--self-test", "--abort"].includes(process.argv[i]) && process.argv[i + 1], `Invalid option ${process.argv[i]}`);
  assert(!(process.argv[i] in options), `Duplicate option ${process.argv[i]}`);
  options[process.argv[i]] = process.argv[i + 1];
}
for (const flag of ["--prepare-only", "--run", "--self-test"]) assert(options[flag] === undefined || options[flag] === "1", `${flag} only accepts 1`);

// Only the actual queried dot rectangle is measured. Decode the screenshot
// directly with Node's zlib; no image dependency or screenshot editing needed.
function paeth(a: number, b: number, c: number): number {
  const p = a + b - c, da = Math.abs(p - a), db = Math.abs(p - b), dc = Math.abs(p - c);
  return da <= db && da <= dc ? a : db <= dc ? b : c;
}
function decodePng(bytes: Buffer): Image {
  assert(bytes.subarray(0, 8).equals(Buffer.from("89504e470d0a1a0a", "hex")), "Screenshot must be PNG");
  const chunks: Buffer[] = [];
  let width = 0, height = 0, channels = 0, offset = 8, ended = false;
  while (offset + 12 <= bytes.length) {
    const length = bytes.readUInt32BE(offset), kind = bytes.toString("ascii", offset + 4, offset + 8);
    assert(offset + 12 + length <= bytes.length, "Truncated PNG chunk");
    const data = bytes.subarray(offset + 8, offset + 8 + length);
    if (kind === "IHDR") {
      assert.equal(length, 13); width = data.readUInt32BE(0); height = data.readUInt32BE(4);
      assert(width > 0 && width <= 20000 && height > 0 && height <= 20000);
      assert.equal(data[8], 8, "Only 8-bit native PNG supported");
      assert(data[9] === 6 || data[9] === 2, "Only RGBA/RGB native PNG supported");
      channels = data[9] === 6 ? 4 : 3;
      assert.equal(data[10], 0); assert.equal(data[11], 0); assert.equal(data[12], 0, "Interlaced screenshot unsupported");
    } else if (kind === "IDAT") chunks.push(data);
    else if (kind === "IEND") { ended = true; break; }
    offset += length + 12;
  }
  assert(ended && width && channels && chunks.length, "Incomplete PNG");
  const rowBytes = width * channels, raw = inflateSync(Buffer.concat(chunks), { maxOutputLength: (rowBytes + 1) * height });
  assert.equal(raw.length, (rowBytes + 1) * height);
  const pixels = Buffer.alloc(rowBytes * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (rowBytes + 1)]; assert(filter <= 4, `Unknown PNG filter ${filter}`);
    for (let x = 0; x < rowBytes; x++) {
      const i = y * rowBytes + x, a = x >= channels ? pixels[i - channels] : 0, b = y ? pixels[i - rowBytes] : 0;
      const c = y && x >= channels ? pixels[i - rowBytes - channels] : 0;
      const predictor = filter === 0 ? 0 : filter === 1 ? a : filter === 2 ? b : filter === 3 ? Math.floor((a + b) / 2) : paeth(a, b, c);
      pixels[i] = (raw[y * (rowBytes + 1) + 1 + x] + predictor) & 255;
    }
  }
  return { width, height, channels, pixels };
}
function accentPixels(image: Image, rect: Rect, scale: number): { pixels: number; area: number; bounds: Rect; colors: Record<string, number> } {
  const x0 = Math.max(0, Math.ceil(rect.x * scale)), y0 = Math.max(0, Math.ceil(rect.y * scale));
  const x1 = Math.min(image.width, Math.floor((rect.x + rect.w) * scale)), y1 = Math.min(image.height, Math.floor((rect.y + rect.h) * scale));
  assert(x1 > x0 && y1 > y0, "Dot is inside actual screenshot");
  let pixels = 0;
  const colors: Record<string, number> = {};
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const i = (y * image.width + x) * image.channels, r = image.pixels[i], g = image.pixels[i + 1], b = image.pixels[i + 2];
    // Isolated saved Dark theme: accent=99,102,241. Allow edge antialiasing,
    // require blue dominance to exclude the original green/gray status fill.
    if (Math.abs(r - 99) <= 55 && Math.abs(g - 102) <= 55 && Math.abs(b - 241) <= 55 && b > g + 50 && b > r + 50) pixels++;
    const color = `${r},${g},${b}`; colors[color] = (colors[color] ?? 0) + 1;
  }
  return { pixels, area: (x1 - x0) * (y1 - y0), bounds: { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }, colors };
}
function testPng(filter: number, unread: boolean): { encoded: Buffer; pixels: Buffer } {
  const width = 16, height = 16, channels = 4, stride = width * channels;
  const pixels = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const i = y * stride + x * channels, ring = unread && x >= 4 && x < 10 && y >= 4 && y < 10 && (x === 4 || x === 9 || y === 4 || y === 9);
    pixels.set(ring ? [99, 102, 241, 255] : [34, 197, 94, 255], i);
  }
  const rows = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    rows[y * (stride + 1)] = filter;
    for (let x = 0; x < stride; x++) {
      const i = y * stride + x, a = x >= channels ? pixels[i - channels] : 0, b = y ? pixels[i - stride] : 0, c = y && x >= channels ? pixels[i - stride - channels] : 0;
      const prediction = filter === 0 ? 0 : filter === 1 ? a : filter === 2 ? b : filter === 3 ? Math.floor((a + b) / 2) : paeth(a, b, c);
      rows[y * (stride + 1) + 1 + x] = (pixels[i] - prediction + 256) & 255;
    }
  }
  function chunk(kind: string, data: Buffer): Buffer {
    const body = Buffer.concat([Buffer.from(kind), data]); let crc = 0xffffffff;
    for (const byte of body) { crc ^= byte; for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
    const size = Buffer.alloc(4), check = Buffer.alloc(4); size.writeUInt32BE(data.length); check.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([size, body, check]);
  }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 6;
  return { encoded: Buffer.concat([Buffer.from("89504e470d0a1a0a", "hex"), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0))]), pixels };
}
if (options["--self-test"] === "1") {
  assert(!options["--run"] && !options["--binary"] && !options["--out"], "Pure self-test accepts no launch/output options");
  for (let filter = 0; filter <= 4; filter++) for (const unread of [false, true]) {
    const fixture = testPng(filter, unread), decoded = decodePng(fixture.encoded);
    assert(decoded.pixels.equals(fixture.pixels), `PNG filter ${filter} round trip`);
    assert.equal(accentPixels(decoded, { x: 4, y: 4, w: 6, h: 6 }, 1).pixels, unread ? 20 : 0);
  }
  assert.throws(() => decodePng(Buffer.from("not a PNG")));
  console.log("11/11 pure PNG filter/ROI rejection checks passed; no process, RPC, window or OS notification used");
  process.exit(0);
}

assert(options["--out"], "--out is required and must be empty");
const run = options["--run"] === "1";
assert(!(run && options["--prepare-only"]), "Choose --run or --prepare-only");
assert(!run || (options["--binary"] && /^[a-f0-9]{64}$/.test(options["--expected-sha"] ?? "")), "Run requires fixed --binary and full --expected-sha");
const output = resolve(options["--out"]), abortMarker = resolve(options["--abort"] ?? join(output, "abort"));
await mkdir(output, { recursive: true }); assert.equal((await readdir(output)).length, 0, "Retain previous evidence; output must be empty");
const report: any = {
  status: run ? "running" : "prepared_not_run", started_at: new Date().toISOString(), native_started: false,
  checks: [], stages: [], handoffs: [], sessions: [], producer_requests: [], abort_marker: abortMarker,
  scope: "Two real Local ZSH sessions, inactive-tab output/accent pixels, historical viewport, AI coverage/nonterminal focus, actual native foreground and original owner replacement",
  permissions: { notification_request: "forbidden", system_send: "forbidden", Bell: "forbidden", authorization_query: "readonly production query allowed" },
  network: { external_connections_created: 0, hosts_fixture_empty: true, AI_requests: 0 },
  input: { setup: "public Harness synthetic UI input only", acceptance: "root CUA window/tab/focus/wheel actions", foreground_from_synthetic_harness_claimed: false },
  measurement: { node: "tabs.connection_status inside exact tabs.tab.<TabId>", border_style_in_public_harness: "not exposed", method: "actual Metal PNG accent pixels within queried original 6x6 point node; no production metadata added", dark_accent_rgb: [99, 102, 241] },
  limitations: ["A completion file only synchronizes root's action; it does not itself prove OS foreground. Root must save and review actual CUA evidence.", "Scrollback is actual VT history; Local @log replay has no live Local frame source and is not fabricated.", "Normal Local replacement creates a new SessionId. Same-SessionId generation retry is not invented; its stale-generation refusal remains covered by targeted real-VT/headless tests.", "Pixel/query samples are sequential, not an atomic frame. Final screenshots still need root visual review.", "Forced cleanup is recorded separately from a normal native close."],
};
const stagePlan = [
  "Root activates exact app/PID; selects A and physically scrolls its seeded VT history upward; selects B and focuses its terminal.",
  "Owned A producer prints while inactive. Assert A accent pixels; B has no borrowed unread. Root selects A while its preserved historical viewport remains off the tail; unread must remain.",
  "Root physically scrolls A to latest tail and clicks its terminal. Assert actual latest marker, accent disappearance and new exact-original-owner NOTIFICATION_READ.",
  "Root opens AI and focuses its composer without submitting. Owned A output still reaches the underlying tail; unread remains while AI covers it.",
  "Root closes AI and focuses existing sidebar search, without touching terminal. A newest output is present, unread remains and no A read receipt occurs.",
  "Root physically focuses A at the latest tail. Assert only A receipt clears A unread.",
  "Root switches to another app. New A output must remain unread with no A receipt; root returns to exact window and focuses tail to clear.",
  "Root selects B. A gets unread output, stops its producer, and root closes only inactive A. Its shell and producer terminate while original B stays alive.",
  "A normal Local New action creates a same-title replacement C with a distinct SessionId/TabId/PID. New C unread/read receipts cannot clear or reuse old A identity.",
  "Stop only owned producers. Root closes the exact owned window normally; verify original app/shell/producer PIDs released and no OS permission/send/Bell trace.",
];
report.planned_stages = stagePlan;
if (!run) {
  if (options["--binary"]) {
    const binary = await realpath(resolve(options["--binary"]));
    const sha = createHash("sha256").update(await readFile(binary)).digest("hex");
    if (options["--expected-sha"]) assert.equal(sha, options["--expected-sha"]);
    Object.assign(report, { candidate_binary: binary, candidate_sha256: sha, candidate_not_started: true });
  }
  report.run_command = "node e2e/notification_read_native.ts --run 1 --binary ROOT_FIXED_BINARY --expected-sha ROOT_SHA256 --out NEW_EMPTY_DIRECTORY";
  report.handoff_contract = { completed_file: "JSON: method='cua', target_pid=<owned PID>, native_actions=[...], native_capture=<existing screenshot path>, notes=<actual observation>. Native foreground proof remains root-reviewed.", abort: "Write any reason to abort_marker; only this runner's owned processes are released." };
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(`prepared_not_run: ${join(output, "report.json")}`);
  process.exit(0);
}

const isolated = await mkdtemp(join(tmpdir(), "zerowork-notification-read-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data"), zdot = join(isolated, "zdot");
await Promise.all([mkdir(rpc), mkdir(data), mkdir(zdot)]);
const config = '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\ntimestamp_gutter=false\ninput_line_highlight=false\nsidebar_collapsed=false\n[completion]\nenabled=false\n[notify]\ntransfer_done=false\nreconnect=false\nai_ready=false\nbell=false\ntab_dot=true\nquiet_hours="00:00-00:00"\n';
await writeFile(join(data, "config.toml"), config);
await writeFile(join(output, "config.fixture.toml"), config);
await writeFile(join(data, "hosts.toml"), '[registry]\nschema_version=2\nrevision=1\nnext_connection_id=1\nnext_group_id=1\n');
await writeFile(join(zdot, ".zshrc"), "unsetopt BEEP NOTIFY\nPROMPT='notify> '\nRPROMPT=''\n");
const appName = `ZeroWork Notification Read ${process.pid}`, bundleId = `local.zerowork.notificationread.${randomUUID()}`;
const bundle = join(output, `${appName}.app`), contents = join(bundle, "Contents"), binary = join(contents, "MacOS", "zerowork");
await mkdir(join(contents, "MacOS"), { recursive: true });
await mkdir(join(contents, "Resources"), { recursive: true });
await copyFile(join(root, "assets/macos/AppIcon.icns"), join(contents, "Resources/AppIcon.icns"));
await writeFile(join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>${bundleId}</string><key>CFBundleName</key><string>${appName}</string><key>CFBundleDisplayName</key><string>${appName}</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleIconFile</key><string>AppIcon</string><key>NSHighResolutionCapable</key><true/></dict></plist>`);
const sourceBinary = await realpath(resolve(options["--binary"]));
assert.equal(createHash("sha256").update(await readFile(sourceBinary)).digest("hex"), options["--expected-sha"], "Source binary matches frozen SHA");
await copyFile(sourceBinary, binary); await chmod(binary, 0o755);
assert.equal(createHash("sha256").update(await readFile(binary)).digest("hex"), options["--expected-sha"], "Copied app executable matches frozen SHA");
Object.assign(report, { isolated, rpc, data, source_binary: sourceBinary, binary, binary_sha256: options["--expected-sha"], app_path: bundle, app_name: appName, bundle_id: bundleId });
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const logPath = join(output, "app.log"), log = await open(logPath, "w");
const env: NodeJS.ProcessEnv = { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "0", ZENIT_E2E_ISOLATE_POINTER: "0", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZDOTDIR: zdot, ZEROWORK_NOTIFICATION_TRACE: "1", ZEROWORK_TERMINAL_POINTER_TRACE: "1", OPENAI_API_KEY: "", ANTHROPIC_API_KEY: "" };
for (const name of ["ZEROWORK_AI_ENDPOINT", "ZEROWORK_AI_MODEL", "ZEROWORK_AI_MOCK", "ZEROWORK_AI_PROVIDER", "ZENIT_E2E_HTTP_JOB_ID", "ZENIT_E2E_HTTP_BASE", "ZENIT_E2E_HTTP_TOKEN"]) delete env[name];
const app: ChildProcess = spawn(binary, [], { cwd: isolated, env, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>(done => app.once("close", () => done()));
let launchError: Error | undefined; app.once("error", error => { launchError = error; });
report.native_started = true; report.pid = app.pid;
const sessions: Session[] = [];
const nonce = randomUUID().replaceAll("-", "").slice(0, 12);
const shown = (node: any): boolean => !!node?.rect && node.hidden !== true && node.visible !== false && (node.effective_opacity ?? node.opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0;
function flatten(node: any): any[] { return node ? [node, ...(node.children ?? []).flatMap(flatten)] : []; }
function text(node: any): string { return flatten(node).filter(shown).map(value => value.text ?? "").join(" "); }
const quote = (value: string): string => `'${value.replaceAll("'", "'\\''")}'`;
async function alive(): Promise<void> {
  if (launchError) throw launchError;
  assert(app.exitCode === null && app.signalCode === null, "Exact owned app remains alive");
  try { throw new Error(`Operator abort: ${(await readFile(abortMarker, "utf8")).slice(0, 1000)}`); }
  catch (error: any) { if (error.code !== "ENOENT") throw error; }
}
async function visible(id: string): Promise<any> { return waitFor(async () => { await alive(); return (await query(id)).find(shown) ?? null; }, 20000); }
async function click(id: string): Promise<void> {
  const node = await visible(id); report.setup_actions ??= [];
  report.setup_actions.push({ kind: "synthetic_public_harness_click", id, node: node.id, rect: node.rect });
  assert((await clickAt(node.rect.x + node.rect.w / 2, node.rect.y + node.rect.h / 2)).ok);
}
async function tabs(): Promise<any[]> { return flatten(await visible("tabs.strip")).filter(node => shown(node) && /^tabs\.tab\.\d+$/.test(node.test_id ?? "")); }
async function currentSurfaceText(): Promise<string> {
  const grid = text(await visible("local.status.grid")).match(/(\d+)×(\d+)/); assert(grid, "Actual Local grid is published");
  const lines: string[] = [];
  for (let start = 0; start < Number(grid[2]); start += 8) {
    const batch = await Promise.all(Array.from({ length: Math.min(8, Number(grid[2]) - start) }, (_, i) => query(`terminal.surface.row.${start + i}`)));
    for (const values of batch) {
      const row = values.find(shown); if (row) lines.push((row.children ?? []).filter(shown).filter((n: any) => n.tag === "text").sort((a: any, b: any) => a.rect.x - b.rect.x).map((n: any) => n.text ?? "").join(""));
    }
  }
  return lines.join("\n");
}
async function trace(): Promise<any[]> {
  const raw = await readFile(logPath, "utf8"), complete = raw.slice(0, raw.lastIndexOf("\n") + 1);
  return complete.split("\n").flatMap((line, i) => {
    const match = line.match(/(NOTIFICATION_[A-Z_]+) (\{.*\})/); if (!match) return [];
    return [{ ...JSON.parse(match[2]), prefix: match[1], log_line: i + 1, owner_id_text: match[2].match(/"owner_id":(\d+)/)?.[1], owner_generation_text: match[2].match(/"owner_generation":(\d+)/)?.[1] }];
  });
}
async function assertNoSystemEffects(): Promise<void> {
  const values = await trace();
  assert(!values.some(value => value.prefix === "NOTIFICATION_PERMISSION_REQUESTED" || value.prefix === "NOTIFICATION_SYSTEM_RESULT" || value.prefix === "NOTIFICATION_ACTIVATION" || (value.prefix === "NOTIFICATION_AUTHORIZATION" && value.explicit)), "No permission request, system send receipt, activation or explicit authorization permitted");
  assert(!values.some(value => value.prefix === "NOTIFICATION_FACT"), "No AI/transfer/reconnect business operation is requested");
}
async function reads(session: Session): Promise<any[]> { return (await trace()).filter(value => value.prefix === "NOTIFICATION_READ" && value.owner_id_text === session.session_id); }
function descendants(): { pid: number; parent: number; command: string }[] {
  const all = execFileSync("/bin/ps", ["-axo", "pid=,ppid=,comm="], { encoding: "utf8" }).trim().split("\n").flatMap(line => { const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/); return m ? [{ pid: Number(m[1]), parent: Number(m[2]), command: m[3] }] : []; });
  const owned = new Set([app.pid!]);
  for (let i = 0; i < all.length; i++) { let changed = false; for (const value of all) if (owned.has(value.parent) && !owned.has(value.pid)) { owned.add(value.pid); changed = true; } if (!changed) break; }
  return all.filter(value => value.pid !== app.pid && owned.has(value.pid));
}
function pidAlive(pid: number): boolean { try { process.kill(pid, 0); return true; } catch (error: any) { if (error.code === "ESRCH") return false; throw error; } }
async function persist(): Promise<void> { await writeFile(join(output, "report.in-progress.json"), JSON.stringify(report, null, 2)); }
async function capture(name: string): Promise<void> {
  const queries: Record<string, unknown> = {};
  for (const id of ["tabs.strip", "local.statusbar", "sidebar.search", "ai.panel", "ai.prompt", "status.detail"]) queries[id] = await query(id);
  const record = { name, at: new Date().toISOString(), focused: await focused(), queries, surface: await currentSurfaceText(), notification_trace: await trace(), processes: descendants(), query_screenshot_atomic: false };
  const treePath = join(output, `${name}.json`), imagePath = join(output, `${name}.png`);
  await writeFile(treePath, JSON.stringify(record, null, 2)); assert((await screenshot(imagePath)).ok);
  report.stages.push({ name, evidence: treePath, screenshot: imagePath, visual_review: "pending_root" }); await persist();
}
async function dot(session: Session, name: string): Promise<any> {
  const tab = await visible(session.tab), node = flatten(tab).find(value => value.test_id === "tabs.connection_status" && shown(value));
  assert(node, `Original tab ${session.tab} exposes its existing status dot`);
  assert(Math.abs(node.rect.w - 6) < 0.5 && Math.abs(node.rect.h - 6) < 0.5, "Original dot stays 6x6 logical points");
  const path = join(output, `${name}.dot.png`); assert((await screenshot(path)).ok);
  const image = decodePng(await readFile(path)), frame = await stats();
  const scale = frame.window_scale ?? image.width / 1440;
  assert(Math.abs(image.width - 1440 * scale) <= 2 && Math.abs(image.height - 900 * scale) <= 2, "Keep the controlled 1440x900 logical viewport during CUA checks");
  return { tab: session.tab, node_id: node.id, rect: node.rect, scale, screenshot: path, ...accentPixels(image, node.rect, scale) };
}
async function expectDot(session: Session, unread: boolean, name: string): Promise<any> {
  const value = await waitFor(async () => { const result = await dot(session, name); return (unread ? result.pixels >= Math.max(3, Math.ceil(result.area * 0.04)) : result.pixels === 0) ? result : null; }, 12000);
  report.checks.push({ name, original_session: session.session_id, expected_unread: unread, pixel_measurement: value });
  await assertNoSystemEffects(); return value;
}
async function handoff(stage: string, action: string, details: any = {}): Promise<void> {
  await alive(); await capture(`${stage}-before`);
  const marker = join(output, `${stage}.completed.json`);
  const value: any = { stage, status: "waiting_for_root_cua", action, target_pid: app.pid, app_path: bundle, app_name: appName, bundle_id: bundleId, completed_marker: marker, abort_marker: abortMarker,
    viewport: { width: 1440, height: 900 }, focused_before: await focused(), sessions: sessions.map(session => ({ label: session.label, tab: session.tab, session_id: session.session_id, terminal_focus_node: session.focus_id, terminal_input_test_id: "terminal.input", terminal_input_rect_at_mount: session.input_rect, terminal_surface_node: session.surface_id, shell_pid: session.shell_pid })),
    completion_schema: { method: "cua", target_pid: app.pid, native_actions: ["actual actions"], native_capture: "absolute existing CUA capture path", notes: "actual observation; no synthetic foreground claim" }, ...details };
  report.handoffs.push(value); await writeFile(join(output, "handoff.json"), JSON.stringify(value, null, 2)); await persist();
  console.log(`[notification-read] CUA HANDOFF ${stage}: ${JSON.stringify(value)}`);
  const completed = await waitFor(async () => {
    if (!(details.allow_normal_exit && app.exitCode === 0 && app.signalCode === null)) await alive();
    try { return JSON.parse(await readFile(marker, "utf8")); } catch (error: any) { if (error.code === "ENOENT") return null; throw error; }
  }, 240000);
  assert.equal(completed.method, "cua"); assert.equal(Number(completed.target_pid), app.pid);
  assert(Array.isArray(completed.native_actions) && completed.native_actions.length, "Root records actual native actions");
  assert(typeof completed.native_capture === "string" && completed.native_capture.startsWith("/"));
  assert((await stat(completed.native_capture)).size > 0, "Root stores actual CUA image evidence separately");
  value.status = "cua_marker_received_state_verification_pending"; value.cua_evidence = completed; value.finished_at = new Date().toISOString();
  await persist();
}
async function createSession(label: string, previous: string[]): Promise<Session> {
  if (previous.length === 0) await click("workspace.empty.local");
  else { assert((await key("t", { cmd: true })).ok); await click("session.menu.local"); }
  const tab = await waitFor(async () => { const added = (await tabs()).map(node => node.test_id).filter(id => !previous.includes(id)); assert(added.length <= 1); return added[0] ?? null; }, 20000);
  // Read this ancestor once while the new terminal is still small. Populated
  // row content is subsequently queried in batches to respect the RPC limit.
  // terminal.surface draws cells; its host terminal.input owns native input,
  // actual focus and wheel dispatch. No acceptance click targets the surface.
  const input = await visible("terminal.input");
  const surface = flatten(input).find(node => shown(node) && node.test_id === "terminal.surface");
  assert(surface, "The real Local drawing surface belongs to the exact input ancestor");
  const focus = await focused();
  assert.equal(focus.id, input.id, "Actual new terminal focus belongs to terminal.input, not a drawing child");
  assert.equal(focus.test_id, "terminal.input");
  const spool = join(isolated, `producer-${label}`), stop = join(spool, "stop"); await mkdir(spool);
  const receipt = join(spool, "shell.receipt"), script = join(spool, "setup.zsh"), seed = `ZW_NOTIFY_SEED_${label}_${nonce}_TAIL`;
  const body = [
    "unsetopt BEEP NOTIFY", "zmodload zsh/system || return 1", `PROMPT=${quote(`notify-${label}> `)}; RPROMPT=''`,
    `cd -- ${quote(spool)} || return 1`, "printf '\\033[3J\\033[2J\\033[H'",
    `for (( zw_line=1; zw_line<=140; zw_line++ )); do print -r -- ${quote(`ZW_NOTIFY_SEED_${label}_${nonce}`)}' row_'$zw_line; done`, `print -r -- ${quote(seed)}`,
    "function zw_notification_producer() {", "  setopt LOCAL_OPTIONS NULL_GLOB NO_BEEP", "  local zw_request zw_marker zw_rows zw_line",
    `  while [[ ! -e ${quote(stop)} ]]; do`, `    for zw_request in ${quote(spool)}/*.request(N); do`,
    "      { IFS= read -r zw_marker; IFS= read -r zw_rows; } < \"$zw_request\"",
    "      [[ \"$zw_marker\" == ZW_NOTIFY_* && \"$zw_rows\" == <-> ]] || return 2", "      (( zw_rows>=1 && zw_rows<=200 )) || return 3",
    "      for (( zw_line=1; zw_line<=zw_rows; zw_line++ )); do print -r -- \"${zw_marker}_row_${zw_line}\"; done", "      print -r -- \"${zw_marker}_TAIL\"",
    "      print -r -- \"$sysparams[pid]\" \"$zw_marker\" > \"$zw_request.done\"", "      /bin/rm -- \"$zw_request\"", "    done", "    /bin/sleep 0.05", "  done", "}",
    "zw_notification_producer &", "zw_notification_producer_pid=$!", `print -r -- "$$" "$zw_notification_producer_pid" "$ZSH_VERSION" "$PWD" > ${quote(receipt)}`, "",
  ].join("\n");
  await writeFile(script, body); await writeFile(join(output, `setup-${label}.zsh`), body);
  assert((await type_(`. ${quote(script)}`)).ok); assert((await key("enter")).ok);
  const raw = await waitFor(async () => { try { const value = await readFile(receipt, "utf8"); return value.split("\n").length === 5 ? value : null; } catch (error: any) { if (error.code === "ENOENT") return null; throw error; } }, 20000);
  const [shellPid, producerPid, version, cwd] = raw.split("\n"); assert(/^\d+$/.test(shellPid) && /^\d+$/.test(producerPid) && version && cwd === spool);
  assert.notEqual(shellPid, producerPid, "Background producer is an actual separate child of this interactive ZSH");
  const owned = descendants();
  for (const pid of [Number(shellPid), Number(producerPid)]) assert(owned.some(value => value.pid === pid && value.command.endsWith("/zsh")), "Only app-owned real ZSH PIDs are used");
  await waitFor(async () => (await currentSurfaceText()).includes(seed) || null, 15000);
  await click("local.status.identity");
  const id = await waitFor(async () => text(await visible("status.detail")).match(/会话 #(\d+)/)?.[1] ?? null, 10000);
  await click("status.detail.close");
  const session = { label, tab, session_id: id, focus_id: input.id, input_rect: input.rect, surface_id: surface.id, shell_pid: Number(shellPid), producer_pid: Number(producerPid), spool, stop, seed };
  assert(!sessions.some(value => value.tab === tab || value.session_id === id || value.shell_pid === session.shell_pid));
  sessions.push(session); report.sessions.push(session); return session;
}
async function produce(session: Session, stage: string, rows: number): Promise<string> {
  const marker = `ZW_NOTIFY_${nonce}_${session.label}_${stage}`, file = join(session.spool, `${stage}.request`);
  const readBefore = (await reads(session)).length;
  await writeFile(file, `${marker}\n${rows}\n`);
  const receipt = await waitFor(async () => { await alive(); try { const raw = await readFile(`${file}.done`, "utf8"); return raw.split("\n").length === 3 ? raw : null; } catch (error: any) { if (error.code === "ENOENT") return null; throw error; } }, 15000);
  const [pid, actualMarker] = receipt.split("\n"); assert.equal(Number(pid), session.producer_pid); assert.equal(actualMarker, marker);
  report.producer_requests.push({ stage, original_session: session.session_id, original_tab: session.tab, shell_pid: session.shell_pid, producer_pid: session.producer_pid, rows, marker, producer_receipt: `${file}.done`, read_count_before: readBefore });
  await writeFile(join(output, `producer-${session.label}-${stage}.receipt`), receipt); return `${marker}_TAIL`;
}
async function noNewRead(session: Session, baseline: number, name: string): Promise<void> {
  await sleep(650); assert.equal((await reads(session)).length, baseline, name); await assertNoSystemEffects();
}
async function readCleared(session: Session, baseline: number, latest: string, name: string): Promise<void> {
  await waitFor(async () => (await focused()).id === session.focus_id && (await currentSurfaceText()).includes(latest) || null, 20000);
  const receipt = await waitFor(async () => (await reads(session)).slice(baseline).at(-1) ?? null, 15000);
  assert(/^[1-9]\d*$/.test(receipt.owner_generation_text ?? "") && receipt.through_sequence > 0, "Read receipt carries actual nonzero original generation and output sequence");
  await expectDot(session, false, name); report.checks.push({ name: `${name}-original-owner-read`, receipt }); await capture(name);
}
async function stopProducer(session: Session): Promise<void> {
  await writeFile(session.stop, "stop only this owned producer\n");
  await waitFor(async () => !pidAlive(session.producer_pid) || null, 10000);
}

let failure: unknown;
try {
  await waitForServerReady(); assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), app.pid);
  assert((await resizeWindow(1440, 900)).ok);
  const a = await createSession("A", []), b = await createSession("B", [a.tab]);
  assert.equal(sessions.filter(session => pidAlive(session.shell_pid)).length, 2);
  await assertNoSystemEffects(); await capture("00-two-real-local-sessions");

  await handoff("01-history-then-background", "Activate this exact native app. Select A; physically scroll upward until the last seed TAIL is absent. Select B and click its actual terminal. Leave A in its preserved historical scrollback; do not use Harness foreground/focus or a synthetic scroll.", { original_a: a, original_b: b, latest_a_seed: a.seed });
  assert.equal((await focused()).id, b.focus_id); assert((await currentSurfaceText()).includes(b.seed));
  const aBefore = (await reads(a)).length, tail1 = await produce(a, "inactive-history", 72);
  await expectDot(a, true, "02-a-inactive-output-unread"); await expectDot(b, false, "02-b-no-borrowed-unread");
  await noNewRead(a, aBefore, "Inactive original A is not read by active B"); await capture("02-a-background-unread");

  await handoff("03-select-original-history", "Select original A with the real native tab click. Do not scroll downward or type. Its previous historical viewport must remain off the latest output.", { expected_offscreen_tail: tail1 });
  assert.equal((await focused()).id, a.focus_id); assert(!(await currentSurfaceText()).includes(tail1), "Actual A historical viewport remains before latest output");
  await expectDot(a, true, "03-history-does-not-clear-unread"); await noNewRead(a, aBefore, "Selecting a historical tab is not actual latest reading"); await capture("03-a-history-preserves-unread");

  await handoff("04-real-tail-and-focus", "Physically scroll original A all the way to latest output and click its actual terminal. Keep this app frontmost. Do not enter any shell command.", { expected_latest_tail: tail1 });
  await readCleared(a, aBefore, tail1, "04-actual-tail-clears-original-a");

  await handoff("05-open-ai-no-submit", "Open the existing AI assistant with its actual toolbar action and click its empty composer. Do not submit, configure a provider, request permission, or enter text.");
  await visible("ai.panel"); await visible("ai.prompt"); assert.notEqual((await focused()).id, a.focus_id);
  const aiBefore = (await reads(a)).length, aiTail = await produce(a, "ai-covered", 2);
  await waitFor(async () => (await currentSurfaceText()).includes(aiTail) || null, 15000);
  await expectDot(a, true, "05-ai-covered-tail-remains-unread"); await noNewRead(a, aiBefore, "Latest output under AI is not read"); await capture("05-ai-covered-unread");

  await handoff("06-ai-close-nonterminal-focus", "Close only the AI assistant, then click the existing sidebar search field. Do not click the terminal or type. Keep original A selected and latest output visible.", { required_focus_test_id: "sidebar.search", expected_latest_tail: aiTail });
  assert(!(await query("ai.panel")).some(shown)); assert.notEqual((await focused()).id, a.focus_id);
  const nonterminalFocus = await focused();
  assert(flatten(await visible("sidebar.search")).some(node => node.id === nonterminalFocus.id), "Actual focus belongs to sidebar search, not terminal");
  assert((await currentSurfaceText()).includes(aiTail));
  await expectDot(a, true, "06-nonterminal-focus-retains-unread"); await noNewRead(a, aiBefore, "Closing AI without actual terminal reading cannot clear A"); await capture("06-nonterminal-unread");

  await handoff("07-focus-original-tail", "Click original A terminal at its newest visible output, with the exact native app frontmost. Do not type.", { expected_latest_tail: aiTail });
  await readCleared(a, aiBefore, aiTail, "07-real-terminal-focus-clears-a");

  await handoff("08-native-app-inactive", "Switch to another native app so this exact ZeroWork window is not frontmost. Leave A selected at the current tail. Capture actual foreground app evidence; do not synthesize focus through Harness.");
  const inactiveBefore = (await reads(a)).length, inactiveTail = await produce(a, "native-window-inactive", 2);
  await waitFor(async () => (await currentSurfaceText()).includes(inactiveTail) || null, 15000);
  await expectDot(a, true, "08-os-inactive-window-retains-unread"); await noNewRead(a, inactiveBefore, "Native inactive window does not read newest output"); await capture("08-native-inactive-unread");
  await handoff("09-native-return-and-read", "Return to this exact native window and click original A terminal at latest tail. Keep it frontmost; no synthetic foreground request.", { expected_latest_tail: inactiveTail });
  await readCleared(a, inactiveBefore, inactiveTail, "09-native-return-clears-a");

  await handoff("10-select-b-preserve-owner", "Select original B through its real tab and click its terminal. Do not close anything yet.");
  assert.equal((await focused()).id, b.focus_id); assert((await currentSurfaceText()).includes(b.seed));
  const oldReads = (await reads(a)).length;
  await produce(a, "old-owner-before-close", 2); await expectDot(a, true, "10-old-a-unread-before-close"); await noNewRead(a, oldReads, "B cannot read old A output");
  await stopProducer(a);
  await handoff("11-close-only-inactive-a", "Close only inactive A via its tab close control. Do not select A or close B. If a Local close confirmation appears, confirm only captured A. The producer has already stopped.", { close_test_id: a.tab.replace("tabs.tab.", "tabs.close."), original_shell_pid: a.shell_pid });
  await waitFor(async () => !(await query(a.tab)).some(shown) && !pidAlive(a.shell_pid) || null, 15000);
  assert(pidAlive(b.shell_pid) && pidAlive(b.producer_pid), "Closing A preserves original B shell and producer");
  await noNewRead(a, oldReads, "Closing old unread owner cannot mark it read through another owner");
  const c = await createSession("C", [b.tab]); assert.notEqual(c.session_id, a.session_id);
  await handoff("12-replacement-to-background", "The normal Local New action created same-title replacement C. Select original B and focus its terminal. Do not interact with C yet.", { replacement: c, old_owner: a.session_id });
  assert.equal((await focused()).id, b.focus_id);
  const cBefore = (await reads(c)).length, cTail = await produce(c, "new-owner-unread", 2);
  await expectDot(c, true, "12-replacement-own-unread"); await noNewRead(a, oldReads, "New same-title C cannot reuse or clear old A read identity");
  await handoff("13-read-only-replacement", "Select replacement C and click its real terminal at newest tail. Keep the exact app frontmost. Do not type.", { replacement_session: c.session_id, expected_latest_tail: cTail });
  await readCleared(c, cBefore, cTail, "13-replacement-own-read-clears");
  await noNewRead(a, oldReads, "Reading C must not emit any stale A read receipt");
  report.owner_replacement = { old: { session_id: a.session_id, read_count_after_close: oldReads }, current: { session_id: c.session_id, reads: await reads(c) }, actual_same_session_generation_retry: "not fabricated; separate targeted stale-generation tests" };

  await stopProducer(b); await stopProducer(c); await assertNoSystemEffects();
  await handoff("14-normal-native-close", "Close only this exact owned app window normally with the native window close control. Both owned producers have stopped. Do not quit or close other ZeroWork instances.", { allow_normal_exit: true });
  await Promise.race([ended, sleep(15000)]); assert.equal(app.exitCode, 0); assert.equal(app.signalCode, null);
  for (const session of sessions) assert(!pidAlive(session.shell_pid) && !pidAlive(session.producer_pid), `Original owned ${session.label} PIDs released after normal close`);
  await assertNoSystemEffects();
  report.status = "native_read_checks_passed_pending_root_cua_pixel_review";
  report.normal_native_close = true;
} catch (error) {
  failure = launchError ?? error; report.status = "failed"; report.error = String(failure);
  if (app.exitCode === null && app.signalCode === null) try { await capture("failure-live"); } catch (captureError) { report.capture_error = String(captureError); }
} finally {
  report.cleanup_before = { app_pid: app.pid, descendants: descendants(), recorded_sessions: sessions };
  for (const session of sessions) try { await writeFile(session.stop, "owned cleanup\n"); } catch {}
  await sleep(150);
  if (app.exitCode === null && app.signalCode === null) {
    const owned = descendants(); report.forced_cleanup = { used: true, original_pids_only: owned.map(value => value.pid), normal_close_proof: false };
    for (const value of owned.reverse()) try { process.kill(value.pid, "SIGHUP"); } catch (error: any) { if (error.code !== "ESRCH") report.cleanup_error = String(error); }
    app.kill("SIGTERM"); await Promise.race([ended, sleep(3000)]);
    if (app.exitCode === null && app.signalCode === null) { app.kill("SIGKILL"); await ended; }
  }
  report.process_cleanup = { exit_code: app.exitCode, signal: app.signalCode, recorded_pid_states: sessions.map(session => ({ label: session.label, shell_pid: session.shell_pid, shell_alive: pidAlive(session.shell_pid), producer_pid: session.producer_pid, producer_alive: pidAlive(session.producer_pid) })) };
  report.notification_trace = await trace(); report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2)); await log.close();
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
