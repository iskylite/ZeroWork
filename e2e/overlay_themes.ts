/** Real Metal window evidence using only public Harness queries and actions. */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { chmod, cp, mkdir, mkdtemp, open, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { waitForServerReady, waitFor, query, focused, clickTestId, key, resizeWindow, screenshot, stats, sleep } from "../zig-out/share/zenit/harness/client.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2), options: Record<string, string> = {};
for (let i = 0; i < args.length; i += 2) {
  assert(["--out", "--binary", "--fixture-dir", "--native-bundle", "--native-task"].includes(args[i]) && args[i + 1], `Invalid option ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--out"] && options["--fixture-dir"], "--out and --fixture-dir are required");
const binary = resolve(options["--binary"] ?? join(root, "zig-out/bin/zerowork"));
const output = resolve(options["--out"]), fixture = resolve(options["--fixture-dir"]);
const isolated = await mkdtemp(join(tmpdir(), "zerowork-overlay-themes-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
await mkdir(output, { recursive: true }); await mkdir(rpc); await cp(fixture, data, { recursive: true });
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const nativeBundle = options["--native-bundle"] ? resolve(options["--native-bundle"]) : null;
const nativeIme = options["--native-task"] === "ime";
let executable = binary;
if (nativeBundle) {
  const contents = join(nativeBundle, "Contents");
  await mkdir(join(contents, "MacOS"), { recursive: true });
  executable = join(contents, "MacOS/zerowork");
  await cp(binary, executable); await chmod(executable, 0o755);
  const xml = (value: string) => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
  const environment = { ZENIT_E2E_FILE_RPC_DIR: rpc, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZENIT_E2E_ISOLATE_POINTER: "0", ZENIT_E2E_BACKGROUND: "0" };
  await writeFile(join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>local.zerowork.overlay.${childId()}</string><key>CFBundleName</key><string>ZeroWork Overlay Acceptance</string><key>CFBundlePackageType</key><string>APPL</string><key>LSEnvironment</key><dict>${Object.entries(environment).map(([k,v]) => `<key>${k}</key><string>${xml(v)}</string>`).join("")}</dict></dict></plist>\n`);
}
function childId() { return `${process.pid}-${Date.now()}`; }
const log = await open(join(output, "app.log"), "w");
const child = spawn(executable, [], { cwd: root, stdio: ["ignore", log.fd, log.fd], env: {
  ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZEROWORK_DATA_DIR: data,
  ZENIT_E2E_BACKGROUND: nativeBundle ? "0" : "1", ZENIT_E2E_ISOLATE_POINTER: nativeBundle ? "0" : "1", ZEROWORK_AUTOCONNECT: "0",
} });
const ended = new Promise<void>((done) => child.once("close", () => done()));
const report: any = { started_at: new Date().toISOString(), binary,
  binary_sha256: createHash("sha256").update(await readFile(executable)).digest("hex"), pid: child.pid,
  fixture, native_bundle: nativeBundle, storage: "isolated temporary data and file RPC", background: !nativeBundle, checks: [], status: "running",
  limits: ["No full-tree query: only public query(test_id) target subtrees.", "Native right-click and physical modifier release are separate CUA checks.", "SIGTERM cleanup is not evidence of normal application shutdown."] };
type Node = any;
const flatten = (n: Node): Node[] => [n, ...(n.children ?? []).flatMap(flatten)];
const shown = (n: Node) => n.visible !== false && n.rect.w > 0 && n.rect.h > 0 && (n.opacity ?? 1) > 0;
async function one(id: string): Promise<Node> {
  const nodes = await query(id); assert.equal(nodes.length, 1, id); assert(shown(nodes[0]), id); return nodes[0];
}
async function active(): Promise<number> {
  const nodes = flatten(await one("tabs.strip")).filter(n => /^tabs\.close\.\d+$/.test(n.test_id ?? "") && n.focusable === true);
  assert.equal(nodes.length, 1); return Number(nodes[0].test_id.split(".").at(-1));
}
async function click(id: string) { assert((await clickTestId(id)).ok, id); }
async function createTab(id: number) {
  await click("toolbar.new_session");
  await waitFor(async () => (await query("session.menu.saved.1")).some(shown) || null);
  await click("session.menu.saved.1");
  await waitFor(async () => await active() === id || null);
}
async function capture(name: string, ids: string[]) {
  await sleep(200); assert((await screenshot(join(output, `${name}.png`))).ok);
  const nodes: Record<string, any> = {};
  for (const id of ids) nodes[id] = await query(id);
  await writeFile(join(output, `${name}.query.json`), JSON.stringify(nodes, null, 2));
  return nodes;
}
let failure: unknown;
try {
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), child.pid);
  assert((await resizeWindow(1440, 900)).ok);
  await createTab(1);
  if (nativeBundle) {
    if (!nativeIme) await createTab(2);
    await capture("native-ready", ["tabs.strip"]);
    await writeFile(join(output, "native-runtime.json"), JSON.stringify({ pid: child.pid, bundle: nativeBundle, rpc, data, tab: (await one(`tabs.tab.${nativeIme ? 1 : 2}`)).rect }, null, 2));
    console.log(`native ready: ${join(output, "native-runtime.json")}`);
    const input = createInterface({ input: process.stdin });
    for await (const command of input) {
      if (command.trim() === "done") { input.close(); break; }
      if (command.trim() === "menu") {
        const menu = await one("context.menu");
        const anchor = await one("tabs.tab.2");
        await capture("tab-menu", ["context.menu", "tabs.strip"]);
        assert.equal(menu.rect.w, 258); assert.equal(menu.rect.h, 323);
        assert(Math.abs(menu.rect.x - anchor.rect.x) <= 0.5, "Menu aligns with clicked tab global x");
        assert(Math.abs(menu.rect.y - anchor.rect.y - anchor.rect.h - 4) <= 0.5, "Menu begins four points below clicked tab");
        report.checks.push({ name: "native CUA right-click menu", status: "passed", rect: menu.rect, anchor_tab: 2, anchor_rect: anchor.rect, screenshot: "tab-menu.png" });
      } else if (["released", "ctrl-tab"].includes(command.trim())) {
        const expected = command.trim() === "released" ? 2 : 1;
        assert.equal(await active(), expected);
        const strip = await one("tabs.strip");
        for (const node of flatten(strip).filter(n => /^tabs\.tab\.\d+$/.test(n.test_id ?? ""))) {
          assert(!(node.children?.[0]?.children ?? []).some((n: Node) => shown(n) && /^[1-9]$/.test(n.text ?? "")), "Released native keys must restore type icons");
        }
        await capture(`native-${command.trim()}`, ["tabs.strip"]);
        report.checks.push({ name: `native CUA ${command.trim()}`, status: "passed", active_tab: expected, screenshot: `native-${command.trim()}.png` });
      } else if (/^ime-[a-z-]+$/.test(command.trim())) {
        await capture(command.trim(), ["tabs.rename", "tabs.rename.input", "tabs.strip"]);
        (report.observations ??= []).push({ name: command.trim(), screenshot: `${command.trim()}.png`, query: `${command.trim()}.query.json`, focused: await focused() });
      } else throw new Error(`Unknown command ${command}`);
      await writeFile(join(output, "harness-report.json"), JSON.stringify(report, null, 2));
      console.log(`captured ${command.trim()}`);
    }
  } else {
  assert((await key("r", { cmd: true, shift: true })).ok);
  await waitFor(async () => (await query("tabs.rename")).some(shown) || null);
  await sleep(200);
  const rename = await one("tabs.rename");
  await capture("rename", ["tabs.rename", "tabs.strip"]);
  assert.equal(rename.rect.w, 380); assert.equal(rename.rect.h, 191);
  report.checks.push({ name: "single-tab rename dialog", status: "passed", viewport: [1440, 900], rect: rename.rect, screenshot: "rename.png" });
  await writeFile(join(output, "harness-report.json"), JSON.stringify(report, null, 2));
  console.log(`rename passed: ${join(output, "rename.png")} ${JSON.stringify(rename.rect)}`);
  assert((await key("escape")).ok);
  await sleep(150);
  assert((await resizeWindow(860, 480)).ok);
  for (let id = 2; id <= 7; id++) await createTab(id);
  await waitFor(async () => (await query("tabs.all")).some(shown) || null);
  await click("tabs.all");
  await waitFor(async () => (await query("tabs.picker")).some(shown) || null);
  await sleep(200);
  const picker = await one("tabs.picker");
  await capture("picker", ["tabs.picker", "tabs.strip"]);
  assert.equal(picker.rect.w, 420); assert.equal(picker.rect.h, 270);
  report.checks.push({ name: "seven-tab overflow picker", status: "passed", viewport: [860, 480], rect: picker.rect, screenshot: "picker.png" });
  assert((await key("escape")).ok);
  }
  if (child.exitCode === null && child.signalCode === null) report.stats = await stats();
  else {
    assert(nativeBundle && child.exitCode === 0 && child.signalCode === null, "Unexpected application exit");
    report.normal_native_exit = { exit_code: child.exitCode, signal: child.signalCode };
  }
  report.status = nativeIme ? "captured" : "passed";
} catch (error) {
  failure = error; report.status = "failed"; report.error = String(error);
  if (child.exitCode === null && child.signalCode === null) await capture("failure", ["tabs.rename", "tabs.picker", "tabs.strip"]).catch(() => {});
} finally {
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
  await Promise.race([ended, sleep(2000)]);
  if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await ended; }
  report.process_cleanup = { exit_code: child.exitCode, signal: child.signalCode };
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "harness-report.json"), JSON.stringify(report, null, 2));
  await log.close(); await rm(isolated, { recursive: true, force: true });
}
console.log(`${report.status}: ${join(output, "harness-report.json")}`);
if (failure) throw failure;
