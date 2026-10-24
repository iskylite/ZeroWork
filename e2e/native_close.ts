/** Native close driver; CUA must click the correct app window twice. Actual Local PTY/Metal integration. Requires a fresh -Dtest-mode=true build.
 * Cleanup termination is reported separately and is never normal-close proof.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, writeFile, rm, cp, chmod } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { waitForServerReady, waitFor, tree, query, clickTestId, key, type_, resizeWindow, screenshot, sleep } from "../zig-out/share/zenit/harness/client.ts";

const args = process.argv.slice(2);
const options: Record<string, string> = {};
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out"].includes(args[i]) && args[i + 1], `Invalid option ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--out"], "--out is required");
const output = resolve(options["--out"]);
const binary = resolve(options["--binary"] ?? "zig-out/bin/zerowork");
const isolated = await mkdtemp(join(tmpdir(), "zerowork-local-ui-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data)]);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const bundle = join(output, "ZeroWork-Native-Local.app");
const contents = join(bundle, "Contents");
await mkdir(join(contents, "MacOS"), { recursive: true });
const executable = join(contents, "MacOS", "zerowork");
await mkdir(join(contents, "Resources"), { recursive: true });
await cp(resolve("assets/macos/AppIcon.icns"), join(contents, "Resources", "AppIcon.icns"));
await cp(binary, executable);
await chmod(executable, 0o755);
await writeFile(join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>local.zerowork.native-close.${process.pid}</string><key>CFBundleName</key><string>ZeroWork Native Local</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
const log = await open(join(output, "app.log"), "w");
const child = spawn(executable, [], { env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_ISOLATE_POINTER: "0", ZENIT_E2E_BACKGROUND: "0", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0" }, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>((done) => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", (error) => { launchError = error; });
const report: Record<string, unknown> = { status: "running", binary, native_bundle: bundle, native_driver: "CUA clicks this isolated app native close button twice; Harness cancels then confirms the production modal", binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"), pid: child.pid, started_at: new Date().toISOString(), checks: [] };
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
  await type_("/bin/sleep 180");
  await key("enter");
  const running = await waitFor(async () => descendants().find((value) => value.command.endsWith("/sleep")) ?? null);
  const ownedBefore = descendants();
  report.owned_before_close = ownedBefore;
  console.log(`READY_NATIVE_CLOSE pid=${child.pid} foreground=${running.pid}`);
  // The driver must click this application's native close button through CUA.
  await waitFor(async () => (await query("local.close.confirmation")).find((value) => !value.hidden && (value.effective_opacity ?? 1) > 0 && value.rect.w > 0) ?? null, 120000);
  await capture("native-close-risk");
  await clickTestId("local.close.cancel");
  await waitFor(async () => !(await query("local.close.confirmation")).some((value) => !value.hidden && (value.effective_opacity ?? 1) > 0) || null);
  assert(descendants().some((value) => value.pid === running.pid));
  checks.push("Cancel after the native close request preserves the same real foreground process");
  console.log("READY_NATIVE_CLOSE_AGAIN");
  await waitFor(async () => (await query("local.close.confirmation")).find((value) => !value.hidden && (value.effective_opacity ?? 1) > 0 && value.rect.w > 0) ?? null, 120000);
  await clickTestId("local.close.accept");
  await Promise.race([ended, sleep(10000)]);
  assert.equal(child.exitCode, 0, "Native close must end the application normally");
  assert.equal(child.signalCode, null);
  const live = new Set(execFileSync("/bin/ps", ["-axo", "pid="], { encoding: "utf8" }).trim().split(/\s+/).map(Number));
  assert(ownedBefore.every((value) => !live.has(value.pid)), "Native close must release the owned process tree");
  checks.push("Accept after native close ends the app with exit code zero and releases its original process tree");
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
  await rm(isolated, { recursive: true, force: true });
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
