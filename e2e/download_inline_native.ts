/** Isolated current main-app download popover. No sessions or network IO.
 * Leaves its explicitly requested new visible instance open on success.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, open, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, clickTestId, key, resizeWindow, screenshot, sleep } from "../zig-out/share/zenit/harness/client.ts";

const options: Record<string, string> = {}, args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 2) { assert(["--binary", "--expected-sha", "--out"].includes(args[i]) && args[i + 1]); options[args[i]] = args[i + 1]; }
assert(options["--binary"] && options["--expected-sha"] && options["--out"]);
const output = resolve(options["--out"]), isolated = await mkdtemp(join(tmpdir(), "zerowork-inline-current-"));
const data = join(isolated, "data"), rpc = join(isolated, "rpc");
const bundle = join(output, "ZeroWork-Current-Inline.app"), contents = join(bundle, "Contents"), binary = join(contents, "MacOS", "zerowork");
await Promise.all([mkdir(join(contents, "MacOS"), { recursive: true }), mkdir(data), mkdir(rpc)]);
await copyFile(resolve(options["--binary"]), binary);
const sha = createHash("sha256").update(await readFile(binary)).digest("hex");
assert.equal(sha, options["--expected-sha"]);
await writeFile(join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>local.zerowork.inline.${process.pid}</string><key>CFBundleName</key><string>ZeroWork Current</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
await writeFile(join(data, "hosts.toml"), "");
await writeFile(join(data, "config.toml"), '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(output, "app.log"), "w");
const child = spawn(binary, [], { detached: true, env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "0", ZENIT_E2E_ISOLATE_POINTER: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", OPENAI_API_KEY: "", ANTHROPIC_API_KEY: "" }, stdio: ["ignore", log.fd, log.fd] });
const report: Record<string, any> = { status: "running", started_at: new Date().toISOString(), binary, binary_sha256: sha, pid: child.pid, isolated, rpc, data, stages: [], checks: [], input: "Synthetic public Harness input in this own, newly requested visible native app; no physical input claim", network: "No sessions, no network or transfer created", prototype: { normal_panel: "320:826473", compact_panel: "321:906514", normal: { w: 840, h: 578, radius: 14, fill: "#18181c" }, compact: { x: 16, y: 60, w: 828, h: 412 }, latest_user_requirement: "Attached to current main window; overrides older independent-tool-window design wording" } };
function shown(n: any): boolean { return !!n?.rect && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect.w > 0 && n.rect.h > 0; }
async function visible(id: string): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null); }
const windowProbe = 'import Foundation; import CoreGraphics; let pid = Int(CommandLine.arguments.last!)!; let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String:Any]] ?? []; let rows = all.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowIsOnscreen as String] as? Bool) == true }.map { w in ["id": w[kCGWindowNumber as String] ?? 0, "bounds": w[kCGWindowBounds as String] ?? [:], "onscreen": w[kCGWindowIsOnscreen as String] ?? false] as [String:Any] }; print(String(data: try! JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), encoding: .utf8)!)';
function windows(): any[] { return JSON.parse(execFileSync("/usr/bin/swift", ["-e", windowProbe, String(child.pid)], { encoding: "utf8" })); }
async function capture(name: string): Promise<any> {
  await sleep(160);
  const toolbar = await visible("toolbar.transfers"), panel = (await query("transfer.manager")).find(shown), native = windows();
  const samples = { kind: "same_rpc_owner_query_samples", toolbar, panel };
  assert((await screenshot(join(output, `${name}.png`))).ok);
  await writeFile(join(output, `${name}.queries.json`), JSON.stringify(samples, null, 2));
  report.stages.push({ name, toolbar_node_id: toolbar.id, panel_rect: panel?.rect, native_windows: native, screenshot: join(output, `${name}.png`), queries: join(output, `${name}.queries.json`) });
  console.log(`[download-inline] ${name}`);
  return { toolbar, panel, native };
}
let failure: unknown;
try {
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), child.pid);
  assert((await resizeWindow(1440, 900)).ok);
  const baseline = await capture("00-current-primary-before-open");
  assert.equal(baseline.native.length, 1, "Exactly one own native main window before open");
  const originalWindowIds = baseline.native.map(n => n.id);
  await visible("toolbar.transfers"); assert((await clickTestId("toolbar.transfers")).ok);
  await visible("transfer.manager");
  const wide = await capture("01-download-list-inside-current-window");
  assert.equal(wide.toolbar.id, baseline.toolbar.id);
  assert(shown(wide.toolbar) && shown(wide.panel), "Toolbar and actual list are queried from the same original main-window Harness owner");
  assert.deepEqual(wide.native.map(n => n.id), originalWindowIds, "Clicking downloads creates no native window");
  assert.equal(wide.panel.rect.w, 840); assert.equal(wide.panel.rect.h, 578);
  assert(!(await query("transfer.window.minimize")).some(shown) && !(await query("transfer.window.zoom")).some(shown), "Inline list exposes no independent native window controls");
  report.checks.push("Same original RPC owner queries toolbar and 840×578 list; the sole visible native window ID is unchanged");
  assert((await resizeWindow(860, 480)).ok);
  const narrow = await capture("02-download-list-follows-compact-primary");
  assert.equal(narrow.toolbar.id, baseline.toolbar.id);
  assert.deepEqual(narrow.native.map(n => n.id), originalWindowIds);
  const p = narrow.panel.rect, root = { x: 0, y: 0, w: 860, h: 480 }, anchor = await visible("toolbar.transfers");
  assert(p.x >= root.x && p.y >= anchor.rect.y + anchor.rect.h && p.x + p.w <= root.x + root.w && p.y + p.h <= root.y + root.h);
  report.checks.push("Resize keeps the list inside the same native/Cx window and below its actual toolbar anchor");
  assert((await key("escape")).ok);
  await waitFor(async () => !(await query("transfer.manager")).some(shown) || null);
  assert((await clickTestId("toolbar.transfers")).ok); await visible("transfer.manager");
  assert((await clickTestId("transfer.window.close")).ok);
  await waitFor(async () => !(await query("transfer.manager")).some(shown) || null);
  report.checks.push("Escape and the list close control hide only the inline list; reopen still works");
  assert((await resizeWindow(1440, 900)).ok);
  assert((await clickTestId("toolbar.transfers")).ok); await visible("transfer.manager");
  await capture("03-current-visible-instance-left-open");
  report.status = "passed"; report.visible_instance_left_open = true;
} catch (error) {
  failure = error; report.status = "failed"; report.error = String(error);
  if (child.exitCode === null && child.signalCode === null) { try { await capture("failure-live"); } catch (e) { report.capture_error = String(e); } }
} finally {
  if (failure && child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  await log.close(); child.unref();
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
