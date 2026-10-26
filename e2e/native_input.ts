/** Native close driver; CUA must click the correct app window twice. Actual Local PTY/Metal integration. Requires a fresh -Dtest-mode=true build.
 * Cleanup termination is reported separately and is never normal-close proof.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, writeFile, rm, cp, chmod, realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { waitForServerReady, waitFor, tree, query, clickTestId, key, type_, resizeWindow, screenshot, sleep } from "../zig-out/share/zenit/harness/client.ts";

const args = process.argv.slice(2);
const options: Record<string, string> = {};
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out", "--hosts-fixture", "--config-fixture"].includes(args[i]) && args[i + 1], `Invalid option ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--out"], "--out is required");
const output = resolve(options["--out"]);
const binary = resolve(options["--binary"] ?? "zig-out/bin/zerowork");
const isolated = await mkdtemp(join(await realpath(tmpdir()), "zerowork-local-ui-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data)]);
if (options["--hosts-fixture"]) await cp(resolve(options["--hosts-fixture"]), join(data, "hosts.toml"));
if (options["--config-fixture"]) await cp(resolve(options["--config-fixture"]), join(data, "config.toml"));
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const bundle = join(output, "ZeroWork-Native-Input.app");
const contents = join(bundle, "Contents");
await mkdir(join(contents, "MacOS"), { recursive: true });
const executable = join(contents, "MacOS", "zerowork");
await mkdir(join(contents, "Resources"), { recursive: true });
await cp(resolve("assets/macos/AppIcon.icns"), join(contents, "Resources", "AppIcon.icns"));
await cp(binary, executable);
await cp(join(dirname(binary), "zw_ipc.so"), join(contents, "MacOS", "zw_ipc.so"));
await chmod(executable, 0o755);
await writeFile(join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>local.zerowork.native-input.${process.pid}</string><key>CFBundleName</key><string>ZeroWork Native Input ${process.pid}</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
// Bind the final bundle identity and Info.plist. The linker's bare Mach-O
// signature still identifies itself as "zerowork" after copying into a bundle;
// Launch Services registration alone does not repair that identity mismatch.
execFileSync("/usr/bin/codesign", ["--force", "--sign", "-", join(contents, "MacOS", "zw_ipc.so")]);
execFileSync("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", `local.zerowork.native-input.${process.pid}`, bundle]);
execFileSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle]);
const launchServices = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
execFileSync(launchServices, ["-f", bundle]);
const log = await open(join(output, "app.log"), "w");
const child = spawn(executable, [], { env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_ISOLATE_POINTER: "0", ZENIT_E2E_BACKGROUND: "0", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0" }, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>((done) => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", (error) => { launchError = error; });
const report: Record<string, unknown> = { status: "running", binary, native_bundle: bundle, native_driver: "CUA physical input and native window controls; no synthetic IME proof", binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"), pid: child.pid, started_at: new Date().toISOString(), checks: [] };
const checks = report.checks as string[];
type Node = Awaited<ReturnType<typeof tree>>;
function nodes(root: Node, id: string, visible = true): Node[] {
  const shown = visible && root.hidden !== true && (root.effective_opacity ?? 1) > 0;
  if (!shown) return [];
  return [...(root.test_id === id && root.rect.w > 0 && root.rect.h > 0 ? [root] : []), ...(root.children ?? []).flatMap((value) => nodes(value, id, shown))];
}
function text(root: Node, visible = true): string {
  const shown = visible && root.hidden !== true && (root.effective_opacity ?? 1) > 0;
  if (!shown) return "";
  return (root.text ?? "") + (root.children ?? []).map((value) => text(value, shown)).join("");
}
async function visible(id: string): Promise<Node> {
  return await waitFor(async () => (await query(id)).find((node) => node.hidden !== true && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0) ?? null);
}
function descendants(): { pid: number; parent: number; command: string }[] {
  const all = execFileSync("/bin/ps", ["-axo", "pid=,ppid=,comm="], { encoding: "utf8" }).trim().split("\n").flatMap((line) => {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/);
    return match ? [{ pid: Number(match[1]), parent: Number(match[2]), command: match[3] }] : [];
  });
  const owned = new Set([child.pid!]);
  for (let i = 0; i < all.length; i++) {
    let changed = false;
    for (const process of all) if (owned.has(process.parent) && !owned.has(process.pid)) { owned.add(process.pid); changed = true; }
    if (!changed) break;
  }
  return all.filter((process) => process.pid !== child.pid && owned.has(process.pid));
}
async function capture(name: string): Promise<void> {
  // Let the actual widget enter transition settle before recording its pixels.
  await sleep(250);
  assert((await screenshot(join(output, `${name}.png`))).ok);
  await writeFile(join(output, `${name}.tree.json`), JSON.stringify(await tree(), null, 2));
}
let failure: unknown;
try {
  await waitForServerReady();
  const owner = JSON.parse(await readFile(join(rpc, "owner.json"), "utf8"));
  assert.equal(Number(owner.pid), child.pid);
  await resizeWindow(1440, 900);
  await clickTestId("workspace.empty.local");
  await visible("terminal.surface");
  await writeFile(join(output, "live.json"), JSON.stringify({ pid: child.pid, bundle, rpc, data }, null, 2));
  console.log(`READY_NATIVE_INPUT pid=${child.pid} bundle=${bundle}`);
  // CUA drives physical input, menus and native pickers in this isolated app.
  // The driver writes evidence.json before closing the actual window normally.
  await new Promise<void>((done) => {
    const timeout = setTimeout(done, 3600000);
    ended.then(() => { clearTimeout(timeout); done(); });
  });
  assert.equal(child.exitCode, 0, "Native input session must finish by normal window close");
  assert.equal(child.signalCode, null);
  report.observations = JSON.parse(await readFile(join(output, "evidence.json"), "utf8"));
  checks.push("Isolated native input session completed with a normal app exit; individual evidence is recorded separately");
  report.status = "passed";
} catch (error) {
  failure = launchError ?? error;
  report.status = "failed";
  report.error = String(failure);
  if (child.exitCode === null && child.signalCode === null) {
    await Promise.allSettled([capture("failure"), writeFile(join(output, "remaining-processes.json"), JSON.stringify(descendants(), null, 2))]);
  }
} finally {
  // Own process tree only; failure cleanup is not normal-close evidence.
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
  execFileSync(launchServices, ["-u", bundle]);
  await rm(isolated, { recursive: true, force: true });
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
